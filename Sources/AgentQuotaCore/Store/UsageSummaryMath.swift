import Foundation

/// Popover grouping of quota windows: short rolling limits (5-hour or daily) vs weekly limits.
public enum UsageSlot: String, CaseIterable, Sendable, Identifiable {
    case short
    case weekly

    public var id: String { rawValue }
}

/// How urgently a window needs attention, judged from usage and projected burn at reset.
public enum PaceLevel: Int, Comparable, Sendable {
    case normal = 0
    case warning
    case critical

    public static func < (lhs: PaceLevel, rhs: PaceLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// One provider's representative short and weekly windows for the popover and menu bar.
public struct ProviderUsageSummary: Identifiable, Equatable, Sendable {
    public let provider: ProviderID
    public let short: QuotaWindow?
    public let weekly: QuotaWindow?

    public var id: ProviderID { provider }

    public init(provider: ProviderID, short: QuotaWindow?, weekly: QuotaWindow?) {
        self.provider = provider
        self.short = short
        self.weekly = weekly
    }

    public func window(for slot: UsageSlot) -> QuotaWindow? {
        switch slot {
        case .short: return short
        case .weekly: return weekly
        }
    }
}

/// Pure calculations behind the popover summary table, pace charts, and menu bar rings.
public enum UsageSummaryMath {
    public static let warningUsedPercent: Double = 75
    public static let criticalUsedPercent: Double = 90
    /// Projected usage at reset (`used / elapsed`) that flags a window.
    public static let warningProjectedPercent: Double = 80
    public static let criticalProjectedPercent: Double = 100
    /// Below this elapsed fraction the projection is too noisy to judge.
    public static let minimumElapsedForProjection: Double = 0.1

    /// Maps a window to its popover slot; windows longer than a day but shorter than a week are not shown.
    public static func slot(for window: QuotaWindow) -> UsageSlot? {
        switch window.cadence {
        case .fiveHour:
            return .short
        case .sevenDay:
            return .weekly
        case .other:
            let day: TimeInterval = 24 * 3600
            if window.windowDurationSeconds <= day * 1.5 { return .short }
            if window.windowDurationSeconds >= day * 6 { return .weekly }
            return nil
        }
    }

    /// Picks the provider-wide window for each slot, falling back to the most used model-specific window.
    public static func summary(for provider: ProviderID, windows: [QuotaWindow]) -> ProviderUsageSummary {
        func pick(_ target: UsageSlot) -> QuotaWindow? {
            let candidates = windows.filter { slot(for: $0) == target }
            if let primary = candidates.first(where: { $0.category != .modelSpecific }) {
                return primary
            }
            return candidates.max { $0.usedPercent < $1.usedPercent }
        }
        return ProviderUsageSummary(provider: provider, short: pick(.short), weekly: pick(.weekly))
    }

    /// Usage percent the window would reach at reset if the current burn rate holds.
    public static func projectedPercent(for window: QuotaWindow, now: Date = Date()) -> Double? {
        guard let elapsed = window.elapsedFraction(at: now), elapsed >= minimumElapsedForProjection else {
            return nil
        }
        return window.usedPercent / elapsed
    }

    public static func paceLevel(for window: QuotaWindow, now: Date = Date()) -> PaceLevel {
        let projected = projectedPercent(for: window, now: now) ?? 0
        if window.usedPercent >= criticalUsedPercent || projected >= criticalProjectedPercent {
            return .critical
        }
        if window.usedPercent >= warningUsedPercent || projected >= warningProjectedPercent {
            return .warning
        }
        return .normal
    }

    /// The window needing the most attention: worst pace level first, then highest usage.
    public static func mostPressingWindow(in summary: ProviderUsageSummary, now: Date = Date()) -> QuotaWindow? {
        [summary.short, summary.weekly].compactMap { $0 }.max { lhs, rhs in
            let lhsLevel = paceLevel(for: lhs, now: now)
            let rhsLevel = paceLevel(for: rhs, now: now)
            if lhsLevel != rhsLevel { return lhsLevel < rhsLevel }
            return lhs.usedPercent < rhs.usedPercent
        }
    }
}
