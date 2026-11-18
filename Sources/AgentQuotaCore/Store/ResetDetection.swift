import Foundation

/// A reset seen in the app's own usage data before the window's scheduled reset time, such as a global or
/// banked reset. Detected from consecutive fetches, so it needs no third-party tracker.
public struct DetectedReset: Equatable, Sendable {
    public let provider: ProviderID
    /// The windows that reset early, as reported after the reset.
    public let windows: [QuotaWindow]
    public let detectedAt: Date

    public static let displayDuration: TimeInterval = 12 * 3600
    /// Usage must fall by at least this many percentage points; usage never falls inside a window otherwise.
    static let minimumDrop: Double = 5
    /// A drop this close to the scheduled reset is the regular reset, not an early one.
    static let scheduledResetTolerance: TimeInterval = 2 * 60
    /// The reset time must move later by at least this much to count as a new window; smaller moves are
    /// rounding of the server's timestamp.
    static let minimumResetShift: TimeInterval = 60 * 60
    /// An unused window has nothing to reset, and some providers (Antigravity) report its reset time as
    /// "now + window length", which moves on every fetch. Only windows in use can be detected.
    static let minimumUsageBeforeReset: Double = 1

    public init(provider: ProviderID, windows: [QuotaWindow], detectedAt: Date) {
        self.provider = provider
        self.windows = windows
        self.detectedAt = detectedAt
    }

    public func isActive(at now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(detectedAt)
        return age >= 0 && age <= Self.displayDuration
    }

    /// Compares two snapshots of one provider and returns the windows that reset while their scheduled reset
    /// was still ahead. Two signals, either one enough:
    /// - the reset time moved later: a new window started. This holds even when heavy use after the reset
    ///   pushed usage back above the old value before the next fetch.
    /// - usage dropped: covers resets that clear usage without moving the reset time.
    public static func detect(previous: ProviderQuotaSnapshot, current: ProviderQuotaSnapshot, now: Date) -> DetectedReset? {
        let before = Dictionary(previous.windows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let reset = current.windows.filter { window in
            guard let old = before[window.id],
                  old.usedPercent >= minimumUsageBeforeReset,
                  let scheduled = old.resetsAt,
                  scheduled.timeIntervalSince(now) > scheduledResetTolerance
            else {
                return false
            }
            if let newReset = window.resetsAt, newReset.timeIntervalSince(scheduled) >= minimumResetShift {
                return true
            }
            return old.usedPercent - window.usedPercent >= minimumDrop
        }
        guard !reset.isEmpty else { return nil }
        return DetectedReset(provider: current.provider, windows: reset, detectedAt: now)
    }
}
