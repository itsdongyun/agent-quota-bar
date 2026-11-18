import Foundation
import Security

/// The app's own Claude login. Never shared with the Claude Code CLI.
public struct ClaudeCredentials: Codable, Sendable, Equatable {
    public var refreshToken: String
    public var accessToken: String?
    public var expiresAt: Date?
    public var email: String?

    public init(refreshToken: String, accessToken: String?, expiresAt: Date?, email: String?) {
        self.refreshToken = refreshToken
        self.accessToken = accessToken
        self.expiresAt = expiresAt
        self.email = email
    }
}

/// Storage for the app's Claude login. `load()` throws `QuotaProviderError.keychainDenied` when access is refused.
public protocol ClaudeCredentialStoring: Sendable {
    func load() throws -> ClaudeCredentials?
    func save(_ credentials: ClaudeCredentials) throws
    func delete()
}

/// Keeps the login in an app-owned Keychain item and caches it in memory, so polling reads the Keychain once.
public final class KeychainClaudeCredentialStore: ClaudeCredentialStoring, @unchecked Sendable {
    public static let shared = KeychainClaudeCredentialStore()

    private let service: String
    private let account = "default"
    private let lock = NSLock()
    private var cache: ClaudeCredentials??

    public init(service: String = "com.agentquotabar.app.claude-oauth") {
        self.service = service
    }

    public func load() throws -> ClaudeCredentials? {
        try lock.withLock {
            if let cache { return cache }
            var query = baseQuery()
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            switch status {
            case errSecSuccess:
                let decoded = (result as? Data).flatMap { try? JSONDecoder().decode(ClaudeCredentials.self, from: $0) }
                cache = .some(decoded)
                return decoded
            case errSecItemNotFound:
                cache = .some(nil)
                return nil
            default:
                // Not cached: the user may allow access on the next attempt.
                AppLogger.provider.warning("Claude login Keychain read failed (OSStatus \(status, privacy: .public))")
                throw QuotaProviderError.keychainDenied
            }
        }
    }

    public func save(_ credentials: ClaudeCredentials) throws {
        try lock.withLock {
            // Cache first: a rotated refresh token must survive this session even if the Keychain write fails.
            cache = .some(credentials)
            let data = try JSONEncoder().encode(credentials)
            let update: [String: Any] = [kSecValueData as String: data]
            var status = SecItemUpdate(baseQuery() as CFDictionary, update as CFDictionary)
            if status == errSecItemNotFound {
                var item = baseQuery()
                item[kSecValueData as String] = data
                item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                status = SecItemAdd(item as CFDictionary, nil)
            }
            guard status == errSecSuccess else {
                AppLogger.provider.error("Claude login Keychain write failed (OSStatus \(status, privacy: .public))")
                throw QuotaProviderError.keychainDenied
            }
        }
    }

    public func delete() {
        lock.withLock {
            cache = .some(nil)
            SecItemDelete(baseQuery() as CFDictionary)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

/// Process-local store for tests and previews.
public final class InMemoryClaudeCredentialStore: ClaudeCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var credentials: ClaudeCredentials?

    public init(_ credentials: ClaudeCredentials? = nil) {
        self.credentials = credentials
    }

    public func load() throws -> ClaudeCredentials? { lock.withLock { credentials } }
    public func save(_ credentials: ClaudeCredentials) throws { lock.withLock { self.credentials = credentials } }
    public func delete() { lock.withLock { credentials = nil } }
}
