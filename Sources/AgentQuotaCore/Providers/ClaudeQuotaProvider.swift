import Foundation
import Security

/// Reads Claude Code's `statusLine` rate-limit cache when fresh and falls back to Anthropic's OAuth usage API with 429 cooldown.
public actor ClaudeQuotaProvider: QuotaProvider {
    public nonisolated let providerID: ProviderID = .claude

    public struct Credentials: Sendable, Equatable {
        public let accessToken: String
        public let refreshToken: String?
        public let expiresAt: Date?

        public init(accessToken: String, refreshToken: String?, expiresAt: Date?) {
            self.accessToken = accessToken
            self.refreshToken = refreshToken
            self.expiresAt = expiresAt
        }
    }

    public enum CredentialReadResult: Sendable {
        case found(Credentials)
        case notFound
        case keychainDenied
    }

    public typealias CredentialReader = @Sendable () -> CredentialReadResult

    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let tokenRefreshURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    private static let oauthClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let betaHeader = "oauth-2025-04-20"
    private static let keychainService = "Claude Code-credentials"
    private static let cliStatusTTL: TimeInterval = 300
    static let statusLineFreshnessTTL: TimeInterval = 15 * 60
    static let baseRateLimitCooldown: TimeInterval = 15 * 60
    static let maxRateLimitCooldown: TimeInterval = 60 * 60

    private let transport: HTTPTransport
    private let subprocess: SubprocessRunning
    private let credentialReader: CredentialReader
    private let environment: [String: String]
    private let statusLineCacheURL: URL
    private let cooldownStore: RateLimitCooldownStoring
    private let nowProvider: @Sendable () -> Date
    private var cachedSourceCredentials: Credentials?
    private var cachedRefreshedCredentials: Credentials?
    private var cachedCLIStatus: (status: CLIAuthStatus, fetchedAt: Date)?
    private var inFlightUsageTask: Task<ProviderQuotaSnapshot, Error>?

    public init(
        transport: HTTPTransport = EphemeralHTTPTransport.shared,
        subprocess: SubprocessRunning = SystemSubprocessRunner.shared,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        credentialReader: CredentialReader? = nil,
        statusLineCacheURL: URL? = nil,
        cooldownStore: RateLimitCooldownStoring = UserDefaultsRateLimitCooldownStore(provider: .claude),
        nowProvider: @escaping @Sendable () -> Date = Date.init
    ) {
        self.transport = transport
        self.subprocess = subprocess
        self.environment = environment
        self.credentialReader = credentialReader ?? {
            Self.defaultReadCredentials(homeDirectory: homeDirectory, environment: environment)
        }
        self.statusLineCacheURL = statusLineCacheURL ?? Self.defaultConfigDirectory(
            homeDirectory: homeDirectory,
            environment: environment
        )
        .appendingPathComponent("cache", isDirectory: true)
        .appendingPathComponent("statusline-rate-limits.json")
        self.cooldownStore = cooldownStore
        self.nowProvider = nowProvider
    }

    public func checkConnectionStatus() async -> ProviderConnectionStatus {
        guard let binary = subprocess.resolveBinary("claude", environment: environment) else {
            return .notInstalled
        }
        if let status = await fetchCLIAuthStatus(binary: binary) {
            if !status.loggedIn {
                cachedCLIStatus = nil
                cachedRefreshedCredentials = nil
                return .loginRequired
            }
            cachedCLIStatus = (status, Date())
        }
        switch resolveCredentials() {
        case .found:
            return .connected
        case .notFound:
            return .loginRequired
        case .keychainDenied:
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
        let now = nowProvider()
        let cliStatus = await refreshCLIStatusIfNeeded(now: now)
        if let cliStatus, !cliStatus.loggedIn {
            invalidateAuthCaches()
            throw QuotaProviderError.loginRequired
        }

        let statusLineSnapshot = readStatusLineSnapshot(
            planName: cliStatus?.resolvedPlanName,
            accountLabel: cliStatus?.email
        )
        if let statusLineSnapshot, isFreshStatusLineSnapshot(statusLineSnapshot, now: now) {
            return statusLineSnapshot
        }

        if let cooldown = cooldownStore.load(), cooldown.blockedUntil > now {
            if let statusLineSnapshot,
               statusLineSnapshot.fetchedAt > cooldown.recordedAt,
               hasOnlyActiveWindows(statusLineSnapshot, now: now)
            {
                return statusLineSnapshot
            }
            throw QuotaProviderError.rateLimited(retryAfter: cooldown.blockedUntil)
        }

        var credentials: Credentials
        switch resolveCredentials() {
        case let .found(creds):
            credentials = creds
        case .notFound:
            if subprocess.resolveBinary("claude", environment: environment) == nil {
                throw QuotaProviderError.notInstalled
            }
            throw QuotaProviderError.loginRequired
        case .keychainDenied:
            throw QuotaProviderError.keychainDenied
        }

        if let expiresAt = credentials.expiresAt,
           expiresAt.timeIntervalSince(now) <= 60,
           let refreshToken = credentials.refreshToken,
           !refreshToken.isEmpty
        {
            do {
                credentials = try await refreshOAuthToken(refreshToken: refreshToken, now: now)
            } catch let error as QuotaProviderError where error == .loginRequired {
                throw error
            } catch let error as QuotaProviderError {
                if case let .rateLimited(retryAfter) = error {
                    let next = recordRateLimitCooldown(retryAfter: retryAfter, now: now)
                    throw QuotaProviderError.rateLimited(retryAfter: next.blockedUntil)
                }
                if expiresAt.timeIntervalSince(now) <= 0 {
                    throw error
                }
            } catch {
                if expiresAt.timeIntervalSince(now) <= 0 {
                    throw error
                }
            }
        }

        let response = try await requestUsage(accessToken: credentials.accessToken)
        if response.statusCode == 401,
           let refreshToken = credentials.refreshToken,
           !refreshToken.isEmpty
        {
            do {
                let refreshed = try await refreshOAuthToken(refreshToken: refreshToken, now: now)
                let retry = try await requestUsage(accessToken: refreshed.accessToken)
                return try handleUsageResponse(
                    retry,
                    planName: cliStatus?.resolvedPlanName,
                    accountLabel: cliStatus?.email,
                    now: now
                )
            } catch let error as QuotaProviderError {
                if case let .rateLimited(retryAfter) = error {
                    let next = recordRateLimitCooldown(retryAfter: retryAfter, now: now)
                    throw QuotaProviderError.rateLimited(retryAfter: next.blockedUntil)
                }
                throw error
            }
        }

        return try handleUsageResponse(
            response,
            planName: cliStatus?.resolvedPlanName,
            accountLabel: cliStatus?.email,
            now: now
        )
    }

    private func handleUsageResponse(
        _ response: HTTPResponseData,
        planName: String?,
        accountLabel: String?,
        now: Date
    ) throws -> ProviderQuotaSnapshot {
        if response.statusCode == 401 || response.statusCode == 403 {
            invalidateAuthCaches()
        }
        do {
            let snapshot = try Self.parseUsageResponse(
                response,
                planName: planName,
                accountLabel: accountLabel,
                now: now
            )
            cooldownStore.save(nil)
            return snapshot
        } catch let error as QuotaProviderError {
            if case let .rateLimited(retryAfter) = error {
                let next = recordRateLimitCooldown(retryAfter: retryAfter, now: now)
                throw QuotaProviderError.rateLimited(retryAfter: next.blockedUntil)
            }
            throw error
        }
    }

    // MARK: - Usage Response & StatusLine Parsing (internal for unit testing)

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

    static func parseStatusLineCache(
        _ data: Data,
        fallbackDate: Date = Date(),
        planName: String? = nil,
        accountLabel: String? = nil
    ) -> ProviderQuotaSnapshot? {
        guard let decoded = try? JSONDecoder().decode(WireStatusLineCache.self, from: data) else {
            return nil
        }

        var windows: [QuotaWindow] = []
        if let fiveHour = decoded.five_hour, let pct = fiveHour.used_percentage {
            windows.append(QuotaWindow(
                id: "claude.5h",
                provider: .claude,
                category: .fiveHour,
                cadence: .fiveHour,
                label: "5h Limit",
                usedPercent: pct,
                resetsAt: fiveHour.resets_at.map { Date(timeIntervalSince1970: $0) }
            ))
        }
        if let sevenDay = decoded.seven_day, let pct = sevenDay.used_percentage {
            windows.append(QuotaWindow(
                id: "claude.7d",
                provider: .claude,
                category: .sevenDay,
                cadence: .sevenDay,
                label: "7d Limit",
                usedPercent: pct,
                resetsAt: sevenDay.resets_at.map { Date(timeIntervalSince1970: $0) }
            ))
        }
        guard !windows.isEmpty else { return nil }

        let fetchedAt = decoded.updated_at.map { Date(timeIntervalSince1970: $0) } ?? fallbackDate
        return ProviderQuotaSnapshot(
            provider: .claude,
            planName: planName,
            accountLabel: accountLabel,
            windows: windows,
            fetchedAt: fetchedAt
        )
    }

    private func readStatusLineSnapshot(planName: String?, accountLabel: String?) -> ProviderQuotaSnapshot? {
        guard let data = try? Data(contentsOf: statusLineCacheURL) else { return nil }
        let modDate = (try? FileManager.default.attributesOfItem(atPath: statusLineCacheURL.path)[.modificationDate] as? Date) ?? nowProvider()
        return Self.parseStatusLineCache(
            data,
            fallbackDate: modDate,
            planName: planName,
            accountLabel: accountLabel
        )
    }

    private func isFreshStatusLineSnapshot(_ snapshot: ProviderQuotaSnapshot, now: Date) -> Bool {
        let age = now.timeIntervalSince(snapshot.fetchedAt)
        guard age >= -60, age <= Self.statusLineFreshnessTTL else { return false }
        return hasOnlyActiveWindows(snapshot, now: now)
    }

    private func hasOnlyActiveWindows(_ snapshot: ProviderQuotaSnapshot, now: Date) -> Bool {
        !snapshot.windows.isEmpty && snapshot.windows.allSatisfy { window in
            guard let resetsAt = window.resetsAt else { return true }
            return resetsAt > now
        }
    }

    private func recordRateLimitCooldown(retryAfter: Date?, now: Date) -> RateLimitCooldownState {
        let previous = cooldownStore.load()
        let nextFailures = (previous?.consecutiveFailures ?? 0) + 1
        let exponent = max(0, min(nextFailures - 1, 2))
        let backoffSeconds = min(Self.maxRateLimitCooldown, Self.baseRateLimitCooldown * pow(2.0, Double(exponent)))
        let backoffUntil = now.addingTimeInterval(backoffSeconds)
        let blockedUntil: Date
        if let retryAfter, retryAfter > now.addingTimeInterval(60) {
            blockedUntil = max(retryAfter, backoffUntil)
        } else {
            blockedUntil = backoffUntil
        }
        let state = RateLimitCooldownState(
            blockedUntil: blockedUntil,
            consecutiveFailures: nextFailures,
            recordedAt: now
        )
        cooldownStore.save(state)
        return state
    }

    // MARK: - Credentials & Network

    private func resolveCredentials() -> CredentialReadResult {
        switch credentialReader() {
        case let .found(diskCreds):
            let sourceChanged = cachedSourceCredentials.map {
                $0.accessToken != diskCreds.accessToken || $0.refreshToken != diskCreds.refreshToken
            } ?? true
            if sourceChanged {
                cachedSourceCredentials = diskCreds
                cachedRefreshedCredentials = nil
                return .found(diskCreds)
            }
            if let cached = cachedRefreshedCredentials {
                // Keep in-memory rotated refreshToken even near/past accessToken expiry.
                return .found(cached)
            }
            return .found(diskCreds)
        case .notFound:
            cachedSourceCredentials = nil
            cachedRefreshedCredentials = nil
            return .notFound
        case .keychainDenied:
            cachedSourceCredentials = nil
            cachedRefreshedCredentials = nil
            return .keychainDenied
        }
    }

    private func invalidateAuthCaches() {
        cachedRefreshedCredentials = nil
        cachedCLIStatus = nil
    }

    static func defaultConfigDirectory(homeDirectory: URL, environment: [String: String]) -> URL {
        environment["CLAUDE_CONFIG_DIR"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? homeDirectory.appendingPathComponent(".claude", isDirectory: true)
    }

    static func defaultReadCredentials(homeDirectory: URL, environment: [String: String]) -> CredentialReadResult {
        let configDir = defaultConfigDirectory(homeDirectory: homeDirectory, environment: environment)
        let fileURL = configDir.appendingPathComponent(".credentials.json")
        if let data = try? Data(contentsOf: fileURL),
           let creds = parseCredentialPayload(data)
        {
            return .found(creds)
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let creds = parseCredentialPayload(data) else {
                return .notFound
            }
            return .found(creds)
        case errSecItemNotFound:
            return .notFound
        case errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed:
            AppLogger.provider.warning("Claude Keychain access denied or interaction required (OSStatus \(status))")
            return .keychainDenied
        default:
            AppLogger.provider.warning("Claude Keychain lookup failed (OSStatus \(status))")
            return .notFound
        }
    }

    static func parseCredentialPayload(_ data: Data) -> Credentials? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let oauth = (root["claudeAiOauth"] as? [String: Any]) ?? root
        guard let accessToken = (oauth["accessToken"] as? String ?? oauth["access_token"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !accessToken.isEmpty
        else {
            return nil
        }
        let refreshToken = (oauth["refreshToken"] as? String ?? oauth["refresh_token"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let expiresAt = DateParsing.parseUnixTimestamp(oauth["expiresAt"] as? Double)
            ?? DateParsing.jwtExpiry(from: accessToken)
        return Credentials(accessToken: accessToken, refreshToken: refreshToken, expiresAt: expiresAt)
    }

    private func requestUsage(accessToken: String) async throws -> HTTPResponseData {
        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-cli/2.1.0 (external, cli)", forHTTPHeaderField: "User-Agent")
        return try await transport.perform(request)
    }

    private func refreshOAuthToken(refreshToken: String, now: Date) async throws -> Credentials {
        var request = URLRequest(url: Self.tokenRefreshURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Self.oauthClientID,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let response = try await transport.perform(request)
        switch response.statusCode {
        case 200:
            break
        case 400, 401:
            invalidateAuthCaches()
            throw QuotaProviderError.loginRequired
        case 429:
            throw QuotaProviderError.rateLimited(retryAfter: response.retryAfterDate(now: now))
        default:
            throw QuotaProviderError.httpError(response.statusCode)
        }
        guard let json = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
              let accessToken = (json["access_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !accessToken.isEmpty
        else {
            throw QuotaProviderError.invalidResponse(.invalidPayload(.claude))
        }
        let nextRefresh = (json["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? refreshToken
        let expiresIn = json["expires_in"] as? Double
        let expiresAt = expiresIn.map { now.addingTimeInterval($0) } ?? DateParsing.jwtExpiry(from: accessToken)
        let refreshed = Credentials(accessToken: accessToken, refreshToken: nextRefresh, expiresAt: expiresAt)
        cachedRefreshedCredentials = refreshed
        return refreshed
    }

    private func refreshCLIStatusIfNeeded(now: Date) async -> CLIAuthStatus? {
        if let cached = cachedCLIStatus,
           cached.status.loggedIn,
           now.timeIntervalSince(cached.fetchedAt) < Self.cliStatusTTL
        {
            return cached.status
        }
        guard let binary = subprocess.resolveBinary("claude", environment: environment) else {
            return nil
        }
        let status = await fetchCLIAuthStatus(binary: binary)
        if let status, status.loggedIn {
            cachedCLIStatus = (status, now)
        } else {
            cachedCLIStatus = nil
        }
        return status
    }

    private func fetchCLIAuthStatus(binary: String) async -> CLIAuthStatus? {
        guard let output = try? await subprocess.run(
            binary: binary,
            arguments: ["auth", "status", "--json"],
            environment: SystemSubprocessRunner.augmentedEnvironment(environment),
            currentDirectoryURL: nil,
            timeout: 5
        ) else {
            return nil
        }
        return try? JSONDecoder().decode(CLIAuthStatus.self, from: output.stdout)
    }

    // MARK: - Wire Models

    private struct CLIAuthStatus: Decodable, Sendable {
        let loggedIn: Bool
        let email: String?
        let subscriptionType: String?
        let planTier: String?

        var resolvedPlanName: String? {
            let raw = planTier ?? subscriptionType
            guard let raw, !raw.isEmpty else { return nil }
            return raw.prefix(1).uppercased() + raw.dropFirst()
        }
    }

    private struct WireUsageResponse: Decodable {
        let five_hour: WireBucket?
        let seven_day: WireBucket?
    }

    private struct WireBucket: Decodable {
        let utilization: Double?
        let resets_at: String?
    }

    private struct WireStatusLineCache: Decodable {
        let updated_at: Double?
        let five_hour: WireStatusLineBucket?
        let seven_day: WireStatusLineBucket?
    }

    private struct WireStatusLineBucket: Decodable {
        let used_percentage: Double?
        let resets_at: Double?
    }
}
