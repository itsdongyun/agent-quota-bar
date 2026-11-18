import Foundation

/// Per-provider limit visibility preferences selected by the user.
public struct ProviderLimitPreferences: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    public var showFiveHour: Bool
    public var showSevenDay: Bool
    public var showModelSpecific: Bool
    /// Optional explicit disabled window IDs when the user narrows model-specific windows.
    public var disabledWindowIDs: Set<String>

    public init(
        isEnabled: Bool = true,
        showFiveHour: Bool = true,
        showSevenDay: Bool = true,
        showModelSpecific: Bool = true,
        disabledWindowIDs: Set<String> = []
    ) {
        self.isEnabled = isEnabled
        self.showFiveHour = showFiveHour
        self.showSevenDay = showSevenDay
        self.showModelSpecific = showModelSpecific
        self.disabledWindowIDs = disabledWindowIDs
    }

    /// Returns whether a normalized quota window should be visible under these preferences.
    public func allows(_ window: QuotaWindow) -> Bool {
        guard isEnabled else { return false }
        if disabledWindowIDs.contains(window.id) {
            return false
        }
        switch window.category {
        case .fiveHour:
            return showFiveHour
        case .sevenDay:
            return showSevenDay
        case .modelSpecific:
            guard showModelSpecific else { return false }
            if window.provider == .antigravity {
                switch window.cadence {
                case .fiveHour: return showFiveHour
                case .sevenDay: return showSevenDay
                case .other: return true
                }
            }
            return true
        }
    }
}

/// Persisted user settings for providers and limit filters. Refresh timing is automatic (`SmartRefreshState`);
/// a `refreshInterval` key saved by older versions is ignored when decoding.
public struct QuotaSettings: Codable, Equatable, Sendable {
    public var providerPreferences: [ProviderID: ProviderLimitPreferences]

    public init(
        providerPreferences: [ProviderID: ProviderLimitPreferences] = Dictionary(
            uniqueKeysWithValues: ProviderID.allCases.map { ($0, ProviderLimitPreferences()) }
        )
    ) {
        self.providerPreferences = providerPreferences
    }

    public func preferences(for provider: ProviderID) -> ProviderLimitPreferences {
        providerPreferences[provider] ?? ProviderLimitPreferences()
    }
}

/// Persistence abstraction for user settings (defaults to UserDefaults).
public protocol QuotaSettingsStoring: Sendable {
    func load() -> QuotaSettings
    func save(_ settings: QuotaSettings)
}

public final class UserDefaultsQuotaSettingsStore: QuotaSettingsStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard, key: String = "AgentQuotaBar.QuotaSettings.v1") {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> QuotaSettings {
        lock.withLock {
            guard let data = defaults.data(forKey: key),
                  let decoded = try? JSONDecoder().decode(QuotaSettings.self, from: data)
            else {
                return QuotaSettings()
            }
            return decoded
        }
    }

    public func save(_ settings: QuotaSettings) {
        lock.withLock {
            if let data = try? JSONEncoder().encode(settings) {
                defaults.set(data, forKey: key)
            }
        }
    }
}
