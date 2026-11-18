import Foundation

/// Polling level of one provider. Each level waits longer than the one before it.
public enum SmartRefreshMode: Int, Sendable, CaseIterable, Comparable {
    case active
    case idleShort
    case idleMedium
    case idleLong

    public var interval: TimeInterval {
        switch self {
        case .active: return 60
        case .idleShort: return 180
        case .idleMedium: return 300
        case .idleLong: return 600
        }
    }

    /// Unchanged fetches in a row needed to step down to the next level, or `nil` at the slowest level.
    var stepDown: (after: Int, to: SmartRefreshMode)? {
        switch self {
        case .active: return (3, .idleShort)
        case .idleShort: return (6, .idleMedium)
        case .idleMedium: return (12, .idleLong)
        case .idleLong: return nil
        }
    }

    public static func < (lhs: SmartRefreshMode, rhs: SmartRefreshMode) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Per-provider adaptive polling: poll every minute while usage moves, and slow down step by step
/// (1 → 3 → 5 → 10 minutes) while it stays the same. Each provider keeps its own state, so a provider
/// in use does not make an idle one poll faster.
public struct SmartRefreshState: Equatable, Sendable {
    public private(set) var mode: SmartRefreshMode = .active
    public private(set) var unchangedCount = 0
    private var lastUsage: [String: Double] = [:]
    private var hasBaseline = false

    /// Usage must move by more than this many percentage points to count as a change.
    static let changeThreshold = 0.01

    public init() {}

    public var interval: TimeInterval { mode.interval }

    /// Records a successful fetch and steps the level up or down.
    public mutating func record(_ snapshot: ProviderQuotaSnapshot) {
        let usage = Dictionary(snapshot.windows.map { ($0.id, $0.usedPercent) }, uniquingKeysWith: { first, _ in first })
        defer { lastUsage = usage }

        // Nothing to compare against yet: neither a change nor a quiet fetch.
        guard hasBaseline else {
            hasBaseline = true
            return
        }

        // A window appearing or disappearing (e.g. a new 5-hour window when work starts) is a change too.
        let changed = Set(usage.keys) != Set(lastUsage.keys) || usage.contains { id, value in
            guard let previous = lastUsage[id] else { return true }
            return abs(value - previous) > Self.changeThreshold
        }
        if changed {
            activate()
            return
        }

        unchangedCount += 1
        if let step = mode.stepDown, unchangedCount >= step.after {
            mode = step.to
            unchangedCount = 0
        }
    }

    /// Returns to one-minute polling, e.g. when the user opens the popover or refreshes.
    public mutating func activate() {
        mode = .active
        unchangedCount = 0
    }
}
