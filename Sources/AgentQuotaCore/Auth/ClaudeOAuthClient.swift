import Foundation

/// Tokens returned by Anthropic's OAuth token endpoint.
public struct ClaudeOAuthTokens: Sendable, Equatable {
    public let accessToken: String
    /// `nil` when the server did not rotate the refresh token; keep the previous one then.
    public let refreshToken: String?
    public let expiresAt: Date?

    public init(accessToken: String, refreshToken: String?, expiresAt: Date?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }
}

/// Talks to Anthropic's OAuth endpoints with the app's own login, independent of the Claude Code CLI's tokens.
///
/// Uses Claude Code's public PKCE client (no client secret) with the read-only `user:profile` scope.
public struct ClaudeOAuthClient: Sendable {
    public enum Config {
        public static let authorizeURL = URL(string: "https://claude.ai/oauth/authorize")!
        public static let tokenURL = URL(string: "https://console.anthropic.com/v1/oauth/token")!
        public static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
        public static let profileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!
        public static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
        public static let scope = "user:profile"
        public static let betaHeader = "oauth-2025-04-20"
        /// Fixed ports outside macOS's ephemeral range so outgoing connections cannot take them.
        public static let callbackPorts: [UInt16] = [1456, 1458]
        public static let callbackPath = "/callback"
        /// Used when the server omits `expires_in`.
        static let fallbackLifetime: TimeInterval = 30 * 60

        public static func redirectURI(port: UInt16) -> String {
            "http://localhost:\(port)\(callbackPath)"
        }
    }

    private let transport: HTTPTransport
    private let nowProvider: @Sendable () -> Date

    public init(
        transport: HTTPTransport = EphemeralHTTPTransport.shared,
        nowProvider: @escaping @Sendable () -> Date = Date.init
    ) {
        self.transport = transport
        self.nowProvider = nowProvider
    }

    public static func authorizeURL(pkce: PKCECodes, redirectURI: String) -> URL {
        var components = URLComponents(url: Config.authorizeURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: Config.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: Config.scope),
            URLQueryItem(name: "code_challenge", value: pkce.codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: pkce.state),
        ]
        return components.url!
    }

    public func exchangeCode(code: String, state: String, codeVerifier: String, redirectURI: String) async throws -> ClaudeOAuthTokens {
        try await postToken([
            "grant_type": "authorization_code",
            "code": code,
            "state": state,
            "redirect_uri": redirectURI,
            "client_id": Config.clientID,
            "code_verifier": codeVerifier,
        ])
    }

    public func refresh(refreshToken: String) async throws -> ClaudeOAuthTokens {
        try await postToken([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Config.clientID,
        ])
    }

    /// The signed-in account's email, used only as a display label.
    public func fetchEmail(accessToken: String) async throws -> String? {
        let response = try await transport.perform(authorizedGET(Config.profileURL, accessToken: accessToken))
        guard response.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any]
        else {
            return nil
        }
        let email = (root["account"] as? [String: Any])?["email"] as? String
        return email?.isEmpty == false ? email : nil
    }

    public func fetchUsage(accessToken: String) async throws -> HTTPResponseData {
        try await transport.perform(authorizedGET(Config.usageURL, accessToken: accessToken))
    }

    /// A refresh token that was used, rotated, or revoked fails for good: Anthropic answers `400 invalid_grant`
    /// (RFC 6749 §5.2), so 400 must not be read as an ordinary HTTP error that a retry could fix.
    static func isDeadGrant(statusCode: Int, body: String) -> Bool {
        statusCode == 401 || (statusCode == 400 && body.contains("invalid_grant"))
    }

    // MARK: - Private

    private func authorizedGET(_ url: URL, accessToken: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Config.betaHeader, forHTTPHeaderField: "anthropic-beta")
        return request
    }

    private func postToken(_ payload: [String: String]) async throws -> ClaudeOAuthTokens {
        var request = URLRequest(url: Config.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let response = try await transport.perform(request)
        switch response.statusCode {
        case 200...299:
            break
        case 429:
            throw QuotaProviderError.rateLimited(retryAfter: response.retryAfterDate(now: nowProvider()))
        default:
            let body = String(data: response.data, encoding: .utf8) ?? ""
            if Self.isDeadGrant(statusCode: response.statusCode, body: body) {
                throw QuotaProviderError.loginRequired
            }
            throw QuotaProviderError.httpError(response.statusCode)
        }

        guard let root = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
              let accessToken = root["access_token"] as? String, !accessToken.isEmpty
        else {
            throw QuotaProviderError.invalidResponse(.invalidPayload(.claude))
        }
        let refreshToken = (root["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let lifetime = (root["expires_in"] as? NSNumber)?.doubleValue ?? Config.fallbackLifetime
        return ClaudeOAuthTokens(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: nowProvider().addingTimeInterval(lifetime)
        )
    }
}
