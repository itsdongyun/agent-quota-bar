import Foundation

/// Failures that back off automatic fetches, because retrying them on schedule only makes them last longer.
public enum FetchBackoffFailure: Equatable, Sendable {
    /// HTTP 429. `retryAfter` is the server's wait in seconds, if it gave a positive one.
    case rateLimited(retryAfter: TimeInterval?)
    /// HTTP 5xx, or a CLI that failed to run.
    case serverError
    /// A login problem that retrying cannot fix but that costs a Keychain prompt or a token exchange each time
    /// (`keychainDenied`, `sessionExpired`). The user's own refresh still retries right away.
    case authFailure
    /// The network is unreachable. Nothing clears the backoff when the network returns, so its cap is low.
    case network
}

/// Backoff of one provider's automatic fetches. A success resets it.
public struct FetchBackoffState: Equatable, Sendable {
    public let consecutiveFailures: Int
    /// Automatic fetches wait until this time; `nil` means no wait.
    public let retryNotBefore: Date?

    public static let initial = FetchBackoffState(consecutiveFailures: 0, retryNotBefore: nil)

    public init(consecutiveFailures: Int, retryNotBefore: Date?) {
        self.consecutiveFailures = consecutiveFailures
        self.retryNotBefore = retryNotBefore
    }
}

/// Exponential backoff after rate limits, server errors, and network errors: 1, 2, 4, 8, 16, then 30 minutes
/// (network errors stop at 5), plus up to 20% jitter that only delays. User-initiated fetches ignore it.
public enum FetchBackoffPolicy {
    static let baseDelay: TimeInterval = 60
    static let maxDelay: TimeInterval = 30 * 60
    static let maxNetworkDelay: TimeInterval = 5 * 60
    /// Caps an unusually long `Retry-After` so one response cannot freeze refreshes for hours.
    static let maxRetryAfter: TimeInterval = 60 * 60
    public static let maxJitterFraction = 0.2

    public static func shouldFetch(_ state: FetchBackoffState, now: Date) -> Bool {
        guard let notBefore = state.retryNotBefore else { return true }
        return now >= notBefore
    }

    public static func recordFailure(
        _ state: FetchBackoffState,
        failure: FetchBackoffFailure,
        now: Date,
        jitterFraction: Double
    ) -> FetchBackoffState {
        let failures = state.consecutiveFailures + 1
        let delay = delay(consecutiveFailures: failures, failure: failure, jitterFraction: jitterFraction)
        return FetchBackoffState(consecutiveFailures: failures, retryNotBefore: now.addingTimeInterval(delay))
    }

    static func delay(consecutiveFailures: Int, failure: FetchBackoffFailure, jitterFraction: Double) -> TimeInterval {
        guard consecutiveFailures > 0 else { return 0 }
        let cap: TimeInterval
        var retryAfter: TimeInterval?
        switch failure {
        case let .rateLimited(value):
            cap = maxDelay
            retryAfter = value
        case .serverError, .authFailure:
            cap = maxDelay
        case .network:
            cap = maxNetworkDelay
        }
        // Cap the exponent before pow so a long failure streak cannot overflow.
        let exponent = Double(min(consecutiveFailures - 1, 16))
        var delay = min(baseDelay * pow(2, exponent), cap)
        if let retryAfter, retryAfter > 0 {
            delay = max(delay, min(retryAfter, maxRetryAfter))
        }
        return delay * (1 + min(max(jitterFraction, 0), maxJitterFraction))
    }

    /// The backoff class of a fetch error, or `nil` when retrying costs nothing or cannot help
    /// (a missing login is a local check, and a bad payload stays bad).
    public static func failure(for error: Error, now: Date) -> FetchBackoffFailure? {
        if let error = error as? QuotaProviderError {
            switch error {
            case let .rateLimited(retryAfter):
                let seconds = retryAfter.map { $0.timeIntervalSince(now) }
                return .rateLimited(retryAfter: seconds.flatMap { $0 > 0 ? $0 : nil })
            case let .httpError(code) where code >= 500:
                return .serverError
            case .executionFailed:
                return .serverError
            case .keychainDenied, .sessionExpired:
                return .authFailure
            default:
                return nil
            }
        }
        if error is URLError {
            return .network
        }
        return nil
    }
}
