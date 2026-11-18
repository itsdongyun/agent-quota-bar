import Foundation

/// Duration cadence of a quota window.
public enum QuotaCadence: String, Codable, Sendable, Equatable {
    case fiveHour
    case sevenDay
    case other

    public var durationSeconds: TimeInterval {
        switch self {
        case .fiveHour: return 5 * 3600
        case .sevenDay: return 7 * 24 * 3600
        case .other: return 24 * 3600
        }
    }
}

/// High-level filter category for user limit selection.
public enum QuotaWindowCategory: String, CaseIterable, Codable, Sendable, Hashable {
    case fiveHour
    case sevenDay
    case modelSpecific
}

/// A single normalized quota window across any provider.
public struct QuotaWindow: Identifiable, Equatable, Codable, Sendable {
    public let id: String
    public let provider: ProviderID
    public let category: QuotaWindowCategory
    public let cadence: QuotaCadence
    public let modelName: String?
    public let label: String
    public let usedPercent: Double
    public let resetsAt: Date?
    public let windowDurationSeconds: TimeInterval

    public init(
        id: String,
        provider: ProviderID,
        category: QuotaWindowCategory,
        cadence: QuotaCadence,
        modelName: String? = nil,
        label: String,
        usedPercent: Double,
        resetsAt: Date?,
        windowDurationSeconds: TimeInterval? = nil
    ) {
        self.id = id
        self.provider = provider
        self.category = category
        self.cadence = cadence
        self.modelName = modelName
        self.label = label
        self.usedPercent = max(0, min(100, usedPercent))
        self.resetsAt = resetsAt
        self.windowDurationSeconds = windowDurationSeconds ?? cadence.durationSeconds
    }

    /// Once `resetsAt` has passed, the stored usage belongs to the previous window. Until a fetch reports the
    /// new window, show it as unused with an unknown reset instead of the stale pre-reset usage.
    public func resolvingPassedReset(at now: Date = Date()) -> QuotaWindow {
        guard let resetsAt, resetsAt <= now else { return self }
        return QuotaWindow(
            id: id,
            provider: provider,
            category: category,
            cadence: cadence,
            modelName: modelName,
            label: label,
            usedPercent: 0,
            resetsAt: nil,
            windowDurationSeconds: windowDurationSeconds
        )
    }

    public var remainingPercent: Double {
        max(0, min(100, 100 - usedPercent))
    }

    /// Elapsed fraction of the current window in `0...1`, derived from `resetsAt`.
    public func elapsedFraction(at now: Date = Date()) -> Double? {
        guard let resetsAt, windowDurationSeconds > 0 else { return nil }
        let remaining = resetsAt.timeIntervalSince(now)
        let elapsed = windowDurationSeconds - remaining
        return max(0, min(1, elapsed / windowDurationSeconds))
    }
}

/// Structured error detail for user-facing localization without hardcoded English text.
public enum ProviderErrorDetail: Equatable, Sendable {
    case httpStatus(Int)
    case invalidPayload(ProviderID)
    case missingJSON(ProviderID)
    case cliExited(ProviderID, Int32)
    case cliStatus(ProviderID, String)
    case message(String)
}

/// Connection health for a provider's local CLI integration.
public enum ProviderConnectionStatus: Equatable, Sendable {
    case unknown
    case connected
    case notInstalled
    case loginRequired
    case sessionExpired
    case keychainDenied
    case rateLimited(retryAfter: Date?)
    case error(ProviderErrorDetail)

    public var isHealthy: Bool {
        if case .connected = self { return true }
        return false
    }
}

/// Normalized quota snapshot returned by a provider adapter.
public struct ProviderQuotaSnapshot: Equatable, Codable, Sendable {
    public let provider: ProviderID
    public let planName: String?
    public let accountLabel: String?
    public let windows: [QuotaWindow]
    public let fetchedAt: Date

    public init(
        provider: ProviderID,
        planName: String? = nil,
        accountLabel: String? = nil,
        windows: [QuotaWindow],
        fetchedAt: Date = Date()
    ) {
        self.provider = provider
        self.planName = planName
        self.accountLabel = accountLabel
        self.windows = windows
        self.fetchedAt = fetchedAt
    }
}

/// Third-party global reset watch, banked reset grant, or recent reset notice for a provider.
public struct ResetAnnouncement: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case watch
        case bankedReset
        case recentReset
    }

    public enum State: String, Equatable, Sendable {
        case watch
        case active
        case confirmed
        case other
    }

    public static let recentResetMaxAge: TimeInterval = 24 * 3600
    public static let bankedResetMaxAge: TimeInterval = 7 * 24 * 3600
    private static let futureClockSkewTolerance: TimeInterval = 300

    public let id: String
    public let provider: ProviderID
    public let kind: Kind
    public let state: State
    public let summary: String
    public let announcedAt: Date?
    public let targetAt: Date?
    public let windowEnd: Date?
    public let expiresAt: Date?
    public let windowLabel: String?
    public let sourceURL: URL?

    public init(
        id: String,
        provider: ProviderID,
        kind: Kind,
        state: State,
        summary: String,
        announcedAt: Date? = nil,
        targetAt: Date? = nil,
        windowEnd: Date? = nil,
        expiresAt: Date? = nil,
        windowLabel: String? = nil,
        sourceURL: URL? = nil
    ) {
        self.id = id
        self.provider = provider
        self.kind = kind
        self.state = state
        self.summary = summary
        self.announcedAt = announcedAt
        self.targetAt = targetAt
        self.windowEnd = windowEnd
        self.expiresAt = expiresAt
        self.windowLabel = windowLabel
        self.sourceURL = sourceURL
    }

    /// True only while a watch notice, banked reset grant, or recent global reset is still relevant.
    public func isActive(at now: Date = Date()) -> Bool {
        switch kind {
        case .watch:
            guard state == .watch || state == .active else {
                return false
            }
            if let windowEnd, now > windowEnd.addingTimeInterval(3600) {
                return false
            }
            return true
        case .bankedReset:
            if let expiresAt, now > expiresAt {
                return false
            }
            if let announcedAt {
                let age = now.timeIntervalSince(announcedAt)
                return age >= -Self.futureClockSkewTolerance && age <= Self.bankedResetMaxAge
            }
            return expiresAt != nil
        case .recentReset:
            guard let announcedAt else {
                return false
            }
            let age = now.timeIntervalSince(announcedAt)
            return age >= -Self.futureClockSkewTolerance && age <= Self.recentResetMaxAge
        }
    }
}
