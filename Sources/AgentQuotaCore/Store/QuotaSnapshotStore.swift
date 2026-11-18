import Foundation

/// Persistence abstraction for the most recent successful quota snapshot per provider.
public protocol QuotaSnapshotStoring: Sendable {
    func load() -> [ProviderID: ProviderQuotaSnapshot]
    func save(_ snapshots: [ProviderID: ProviderQuotaSnapshot])
}

/// Persists the latest successful snapshots as JSON in Application Support so restarts retain last known data.
public final class FileQuotaSnapshotStore: QuotaSnapshotStoring, @unchecked Sendable {
    /// Info.plist key that overrides the Application Support folder name (set for dev bundles so they don't share state).
    public static let supportDirectoryNameInfoKey = "AgentQuotaBarSupportDirectoryName"
    public static let defaultSupportDirectoryName = "AgentQuotaBar"

    private let fileURL: URL
    private let lock = NSLock()

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
            let directoryName = Bundle.main.object(forInfoDictionaryKey: Self.supportDirectoryNameInfoKey) as? String
                ?? Self.defaultSupportDirectoryName
            self.fileURL = appSupport
                .appendingPathComponent(directoryName, isDirectory: true)
                .appendingPathComponent("snapshots.json")
        }
    }

    public func load() -> [ProviderID: ProviderQuotaSnapshot] {
        lock.withLock {
            guard let data = try? Data(contentsOf: fileURL) else { return [:] }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let raw = try? decoder.decode([String: ProviderQuotaSnapshot].self, from: data) else {
                return [:]
            }
            var result: [ProviderID: ProviderQuotaSnapshot] = [:]
            for (key, value) in raw {
                if let provider = ProviderID(rawValue: key) {
                    result[provider] = value
                }
            }
            return result
        }
    }

    public func save(_ snapshots: [ProviderID: ProviderQuotaSnapshot]) {
        lock.withLock {
            let raw = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.key.rawValue, $0.value) })
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(raw) else { return }
            let dir = fileURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

/// Persisted HTTP 429 cooldown state to avoid hammering rate-limited endpoints across refreshes or restarts.
public struct RateLimitCooldownState: Codable, Equatable, Sendable {
    public let blockedUntil: Date
    public let consecutiveFailures: Int
    public let recordedAt: Date

    public init(blockedUntil: Date, consecutiveFailures: Int, recordedAt: Date) {
        self.blockedUntil = blockedUntil
        self.consecutiveFailures = consecutiveFailures
        self.recordedAt = recordedAt
    }
}

public protocol RateLimitCooldownStoring: Sendable {
    func load() -> RateLimitCooldownState?
    func save(_ state: RateLimitCooldownState?)
}

public final class UserDefaultsRateLimitCooldownStore: RateLimitCooldownStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String
    private let lock = NSLock()

    public init(provider: ProviderID, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.key = "AgentQuotaBar.RateLimitCooldown.\(provider.rawValue).v1"
    }

    public func load() -> RateLimitCooldownState? {
        lock.withLock {
            guard let data = defaults.data(forKey: key) else { return nil }
            return try? JSONDecoder().decode(RateLimitCooldownState.self, from: data)
        }
    }

    public func save(_ state: RateLimitCooldownState?) {
        lock.withLock {
            guard let state, let data = try? JSONEncoder().encode(state) else {
                defaults.removeObject(forKey: key)
                return
            }
            defaults.set(data, forKey: key)
        }
    }
}

public final class InMemoryRateLimitCooldownStore: RateLimitCooldownStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var state: RateLimitCooldownState?

    public init(initialState: RateLimitCooldownState? = nil) {
        self.state = initialState
    }

    public func load() -> RateLimitCooldownState? {
        lock.withLock { state }
    }

    public func save(_ state: RateLimitCooldownState?) {
        lock.withLock { self.state = state }
    }
}
