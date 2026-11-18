import Foundation

/// Fetches Claude usage with the app's own OAuth login (see `ClaudeLoginCoordinator`), refreshing its own tokens.
/// The Claude Code CLI's credentials are never read or touched.
public actor ClaudeQuotaProvider: QuotaProvider {
    public nonisolated let providerID: ProviderID = .claude

    /// Refresh this long before expiry so a request never goes out with a token about to lapse.
    static let refreshMargin: TimeInterval = 5 * 60

    private let client: ClaudeOAuthClient
    private let credentialStore: ClaudeCredentialStoring
    private let nowProvider: @Sendable () -> Date
    private var inFlightUsageTask: Task<ProviderQuotaSnapshot, Error>?
    private var inFlightRefreshTask: Task<ClaudeCredentials, Error>?

    public init(
        transport: HTTPTransport = EphemeralHTTPTransport.shared,
        credentialStore: ClaudeCredentialStoring = KeychainClaudeCredentialStore.shared,
        nowProvider: @escaping @Sendable () -> Date = Date.init
    ) {
        self.client = ClaudeOAuthClient(transport: transport, nowProvider: nowProvider)
        self.credentialStore = credentialStore
        self.nowProvider = nowProvider
    }

    public func checkConnectionStatus() async -> ProviderConnectionStatus {
        do {
            return try credentialStore.load() == nil ? .loginRequired : .connected
        } catch {
            return .keychainDenied
        }
    }

    public func fetchUsage() async throws -> ProviderQuotaSnapshot {
        if let inFlightUsageTask {
            return try await inFlightUsageTask.value
        }
        let task = Task<ProviderQuotaSnapshot, Error> {
            try await performFetchUsage()
        }
        inFlightUsageTask = task
        defer { inFlightUsageTask = nil }
        return try await task.value
    }

    private func performFetchUsage() async throws -> ProviderQuotaSnapshot {
        guard let stored = try credentialStore.load() else {
            throw QuotaProviderError.loginRequired
        }

        var credentials = stored
        if !hasUsableAccessToken(credentials) {
            credentials = try await refreshedCredentials(from: credentials)
        }

        var response = try await client.fetchUsage(accessToken: credentials.accessToken ?? "")
        if response.statusCode == 401 {
            // The access token was revoked early; renew it once and retry.
            credentials = try await refreshedCredentials(from: credentials)
            response = try await client.fetchUsage(accessToken: credentials.accessToken ?? "")
            if response.statusCode == 401 {
                throw QuotaProviderError.sessionExpired
            }
        }

        return try Self.parseUsageResponse(response, accountLabel: credentials.email, now: nowProvider())
    }

    private func hasUsableAccessToken(_ credentials: ClaudeCredentials) -> Bool {
        guard let token = credentials.accessToken, !token.isEmpty, let expiresAt = credentials.expiresAt else {
            return false
        }
        return expiresAt > nowProvider().addingTimeInterval(Self.refreshMargin)
    }

    /// Exchanges the refresh token once, even when several fetches ask at the same time, because Anthropic
    /// rotates refresh tokens and a second exchange with the old one would revoke the login.
    private func refreshedCredentials(from current: ClaudeCredentials) async throws -> ClaudeCredentials {
        if let inFlightRefreshTask {
            return try await inFlightRefreshTask.value
        }
        let task = Task<ClaudeCredentials, Error> {
            let tokens: ClaudeOAuthTokens
            do {
                tokens = try await client.refresh(refreshToken: current.refreshToken)
            } catch QuotaProviderError.loginRequired {
                // The login may have changed while the request ran. Only drop the login this token belongs to;
                // a newer sign-in that replaced it is used instead.
                let latest = try? credentialStore.load()
                if let latest, latest.refreshToken != current.refreshToken {
                    return latest
                }
                if latest != nil {
                    AppLogger.provider.warning("Claude refresh token is no longer valid; sign-in required")
                    credentialStore.delete()
                }
                throw QuotaProviderError.loginRequired
            }

            // Signed out meanwhile: saving would bring the removed login back.
            guard let latest = try? credentialStore.load() else {
                throw QuotaProviderError.loginRequired
            }
            // Signed in again meanwhile: keep the new login rather than overwrite it.
            guard latest.refreshToken == current.refreshToken else {
                return latest
            }

            let renewed = ClaudeCredentials(
                refreshToken: tokens.refreshToken ?? current.refreshToken,
                accessToken: tokens.accessToken,
                expiresAt: tokens.expiresAt,
                email: current.email
            )
            do {
                try credentialStore.save(renewed)
            } catch {
                // The store keeps it in memory; only a restart before the next successful write loses it.
                AppLogger.provider.error("Claude renewed tokens could not be persisted")
            }
            return renewed
        }
        inFlightRefreshTask = task
        defer { inFlightRefreshTask = nil }
        return try await task.value
    }

    // MARK: - Usage Response Parsing (internal for unit testing)

    static func parseUsageResponse(
        _ response: HTTPResponseData,
        planName: String? = nil,
        accountLabel: String? = nil,
        now: Date = Date()
    ) throws -> ProviderQuotaSnapshot {
        switch response.statusCode {
        case 200:
            break
        case 401, 403:
            throw QuotaProviderError.loginRequired
        case 429:
            throw QuotaProviderError.rateLimited(retryAfter: response.retryAfterDate(now: now))
        default:
            throw QuotaProviderError.httpError(response.statusCode)
        }

        let decoded: WireUsageResponse
        do {
            decoded = try JSONDecoder().decode(WireUsageResponse.self, from: response.data)
        } catch {
            throw QuotaProviderError.invalidResponse(.invalidPayload(.claude))
        }

        var windows: [QuotaWindow] = []
        if let fiveHour = decoded.five_hour, let pct = fiveHour.utilization {
            windows.append(QuotaWindow(
                id: "claude.5h",
                provider: .claude,
                category: .fiveHour,
                cadence: .fiveHour,
                label: "5h Limit",
                usedPercent: pct,
                resetsAt: DateParsing.parseISO8601(fiveHour.resets_at)
            ))
        }
        if let sevenDay = decoded.seven_day, let pct = sevenDay.utilization {
            windows.append(QuotaWindow(
                id: "claude.7d",
                provider: .claude,
                category: .sevenDay,
                cadence: .sevenDay,
                label: "7d Limit",
                usedPercent: pct,
                resetsAt: DateParsing.parseISO8601(sevenDay.resets_at)
            ))
        }

        return ProviderQuotaSnapshot(
            provider: .claude,
            planName: planName,
            accountLabel: accountLabel,
            windows: windows,
            fetchedAt: now
        )
    }

    // MARK: - Wire Models

    private struct WireUsageResponse: Decodable {
        let five_hour: WireBucket?
        let seven_day: WireBucket?
    }

    private struct WireBucket: Decodable {
        let utilization: Double?
        let resets_at: String?
    }
}
