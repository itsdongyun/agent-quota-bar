import Foundation

/// HTTP response container returned by `HTTPTransport`.
public struct HTTPResponseData: Sendable {
    public let data: Data
    public let statusCode: Int
    public let headers: [String: String]

    public init(data: Data, statusCode: Int, headers: [String: String] = [:]) {
        self.data = data
        self.statusCode = statusCode
        self.headers = headers
    }

    public func headerValue(named name: String) -> String? {
        for (key, value) in headers where key.caseInsensitiveCompare(name) == .orderedSame {
            return value
        }
        return nil
    }
}

/// Abstract HTTP transport for dependency injection and deterministic testing.
public protocol HTTPTransport: Sendable {
    func perform(_ request: URLRequest) async throws -> HTTPResponseData
}

/// Ephemeral URLSession-backed HTTP transport that avoids writing response bodies to Cache.db.
public final class EphemeralHTTPTransport: HTTPTransport, @unchecked Sendable {
    public static let shared = EphemeralHTTPTransport()

    private let session: URLSession

    public init(timeout: TimeInterval = 20) {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = max(timeout, 30)
        self.session = URLSession(configuration: config)
    }

    public func perform(_ request: URLRequest) async throws -> HTTPResponseData {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        var normalizedHeaders: [String: String] = [:]
        for (key, value) in httpResponse.allHeaderFields {
            if let keyStr = key as? String, let valStr = value as? String {
                normalizedHeaders[keyStr] = valStr
            }
        }
        return HTTPResponseData(
            data: data,
            statusCode: httpResponse.statusCode,
            headers: normalizedHeaders
        )
    }
}
