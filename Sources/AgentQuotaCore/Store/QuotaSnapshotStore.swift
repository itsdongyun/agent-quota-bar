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
