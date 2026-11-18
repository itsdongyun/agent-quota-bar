import Foundation

/// Normalized error type emitted by provider adapters.
public enum QuotaProviderError: Error, Equatable, Sendable {
    case notInstalled
    case loginRequired
    /// The CLI's access token expired; the CLI renews it the next time it runs.
    case sessionExpired
    case keychainDenied
    case rateLimited(retryAfter: Date?)
    case httpError(Int)
    case invalidResponse(ProviderErrorDetail)
    case executionFailed(ProviderErrorDetail)

    public var connectionStatus: ProviderConnectionStatus {
        switch self {
        case .notInstalled:
            return .notInstalled
        case .loginRequired:
            return .loginRequired
        case .sessionExpired:
            return .sessionExpired
        case .keychainDenied:
            return .keychainDenied
        case let .rateLimited(retryAfter):
            return .rateLimited(retryAfter: retryAfter)
        case let .httpError(code):
            return .error(.httpStatus(code))
        case let .invalidResponse(detail), let .executionFailed(detail):
            return .error(detail)
        }
    }
}

/// Unified interface implemented by every AI agent quota provider.
public protocol QuotaProvider: Sendable {
    var providerID: ProviderID { get }
    func checkConnectionStatus() async -> ProviderConnectionStatus
    func fetchUsage() async throws -> ProviderQuotaSnapshot
}

extension HTTPResponseData {
    /// Parses `Retry-After` header seconds into a future `Date`, if valid and positive.
    func retryAfterDate(now: Date = Date()) -> Date? {
        guard let raw = headerValue(named: "Retry-After")?.trimmingCharacters(in: .whitespacesAndNewlines),
              let seconds = TimeInterval(raw),
              seconds > 0
        else {
            return nil
        }
        return now.addingTimeInterval(min(seconds, 3600))
    }
}
