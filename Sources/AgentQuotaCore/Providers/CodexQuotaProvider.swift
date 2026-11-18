import Foundation

/// Reads Codex CLI's `~/.codex/auth.json` and queries ChatGPT's wham usage endpoint.
public actor CodexQuotaProvider: QuotaProvider {
    public nonisolated let providerID: ProviderID = .codex

    public struct Credentials: Sendable, Equatable {
        public let accessToken: String
        public let refreshToken: String?
        public let accountID: String?

        public init(accessToken: String, refreshToken: String?, accountID: String?) {
            self.accessToken = accessToken
            self.refreshToken = refreshToken
            self.accountID = accountID
        }
    }

    public typealias CredentialReader = @Sendable () -> Credentials?

    private static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    private let transport: HTTPTransport
    private let subprocess: SubprocessRunning
    private let credentialReader: CredentialReader
    private let environment: [String: String]
    private var inFlightUsageTask: Task<ProviderQuotaSnapshot, Error>?

    public init(
        transport: HTTPTransport = EphemeralHTTPTransport.shared,
        subprocess: SubprocessRunning = SystemSubprocessRunner.shared,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        credentialReader: CredentialReader? = nil
    ) {
        self.transport = transport
        self.subprocess = subprocess
        self.environment = environment
        self.credentialReader = credentialReader ?? {
            Self.defaultReadCredentials(homeDirectory: homeDirectory, environment: environment)
        }
    }

    public func checkConnectionStatus() async -> ProviderConnectionStatus {
        if let credentials = credentialReader() {
            if let expiry = DateParsing.jwtExpiry(from: credentials.accessToken), expiry <= Date() {
                return .sessionExpired
            }
            return .connected
        }
        if subprocess.resolveBinary("codex", environment: environment) == nil {
            return .notInstalled
        }
        return .loginRequired
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
        guard let credentials = credentialReader() else {
            if subprocess.resolveBinary("codex", environment: environment) == nil {
                throw QuotaProviderError.notInstalled
            }
            throw QuotaProviderError.loginRequired
        }

        // Token refresh belongs to the CLI. Refreshing here rotates the refresh token in a way
        // ~/.codex/auth.json never sees, which logs the CLI out; the next `codex` run renews it instead.
        if let expiry = DateParsing.jwtExpiry(from: credentials.accessToken), expiry <= Date() {
            throw QuotaProviderError.sessionExpired
        }

        let response = try await requestUsage(credentials: credentials)
        if response.statusCode == 401 {
            // The CLI may have renewed its token since it was read; retry once with the newer one.
            if let latest = credentialReader(), latest.accessToken != credentials.accessToken {
                return try Self.parseUsageResponse(try await requestUsage(credentials: latest))
            }
            throw QuotaProviderError.sessionExpired
        }
        return try Self.parseUsageResponse(response)
    }

    // MARK: - Usage Response Parsing (internal for unit testing)

    static func parseUsageResponse(
        _ response: HTTPResponseData,
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
            throw QuotaProviderError.invalidResponse(.invalidPayload(.codex))
        }

        var windows: [QuotaWindow] = []
        var seenIDs = Set<String>()

        if let primary = decoded.rate_limit?.primary_window {
            if let window = makeWindow(
                from: primary,
                defaultDuration: QuotaCadence.fiveHour.durationSeconds,
                category: .resolvedFromCadence,
                modelName: nil,
                baseIDPrefix: "codex",
                slotTag: "primary",
                seenIDs: &seenIDs
            ) {
                windows.append(window)
            }
        }

        if let secondary = decoded.rate_limit?.secondary_window {
            if let window = makeWindow(
                from: secondary,
                defaultDuration: QuotaCadence.sevenDay.durationSeconds,
                category: .resolvedFromCadence,
                modelName: nil,
                baseIDPrefix: "codex",
                slotTag: "secondary",
                seenIDs: &seenIDs
            ) {
                windows.append(window)
            }
        }

        for (index, extra) in (decoded.additional_rate_limits ?? []).enumerated() {
            let rawName = (extra.limit_name ?? extra.metered_feature ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Unnamed limits get no model name so the UI shows a localized generic label.
            let modelName: String? = rawName.isEmpty ? nil : rawName
            let slug = (modelName ?? "model-\(index + 1)").lowercased().replacingOccurrences(of: " ", with: "-")

            if let primary = extra.rate_limit?.primary_window,
               let window = makeWindow(
                   from: primary,
                   defaultDuration: QuotaCadence.fiveHour.durationSeconds,
                   category: .fixedModel,
                   modelName: modelName,
                   baseIDPrefix: "codex.model.\(slug)",
                   slotTag: "primary-\(index)",
                   seenIDs: &seenIDs
               )
            {
                windows.append(window)
            }
            if let secondary = extra.rate_limit?.secondary_window,
               let window = makeWindow(
                   from: secondary,
                   defaultDuration: QuotaCadence.sevenDay.durationSeconds,
                   category: .fixedModel,
                   modelName: modelName,
                   baseIDPrefix: "codex.model.\(slug)",
                   slotTag: "secondary-\(index)",
                   seenIDs: &seenIDs
               )
            {
                windows.append(window)
            }
        }

        let plan = decoded.plan_type.flatMap { $0.isEmpty ? nil : $0.prefix(1).uppercased() + $0.dropFirst() }
        return ProviderQuotaSnapshot(
            provider: .codex,
            planName: plan,
            accountLabel: decoded.email,
            windows: windows,
            fetchedAt: now
        )
    }

    private enum WindowCategoryResolution {
        case resolvedFromCadence
        case fixedModel
    }

    private static func makeWindow(
        from wire: WireWindow,
        defaultDuration: TimeInterval,
        category resolution: WindowCategoryResolution,
        modelName: String?,
        baseIDPrefix: String,
        slotTag: String,
        seenIDs: inout Set<String>
    ) -> QuotaWindow? {
        guard let usedPercent = wire.used_percent else { return nil }
        let duration = TimeInterval(wire.limit_window_seconds ?? Int(defaultDuration))
        let cadence = classifyCadence(durationSeconds: duration)
        let cadenceSuffix = shortCadenceSuffix(cadence: cadence, durationSeconds: duration)

        let resolvedCategory: QuotaWindowCategory
        let label: String
        let candidateID: String

        switch resolution {
        case .resolvedFromCadence:
            switch cadence {
            case .fiveHour:
                resolvedCategory = .fiveHour
                label = "5h Limit"
                candidateID = slotTag == "primary" ? "codex.5h" : "codex.\(slotTag)"
            case .sevenDay:
                resolvedCategory = .sevenDay
                label = "7d Limit"
                candidateID = slotTag == "secondary" ? "codex.7d" : "codex.\(slotTag)"
            case .other:
                resolvedCategory = .modelSpecific
                label = "Quota (\(cadenceSuffix))"
                candidateID = "codex.\(slotTag).\(cadenceSuffix)"
            }
        case .fixedModel:
            resolvedCategory = .modelSpecific
            let name = modelName ?? "Model"
            label = "\(name) (\(cadenceSuffix))"
            candidateID = "\(baseIDPrefix).\(cadenceSuffix)"
        }

        let uniqueID: String
        if seenIDs.insert(candidateID).inserted {
            uniqueID = candidateID
        } else {
            var fallback = "\(candidateID).\(slotTag)"
            var suffix = 2
            while !seenIDs.insert(fallback).inserted {
                fallback = "\(candidateID).\(slotTag).\(suffix)"
                suffix += 1
            }
            uniqueID = fallback
        }

        return QuotaWindow(
            id: uniqueID,
            provider: .codex,
            category: resolvedCategory,
            cadence: cadence,
            modelName: modelName,
            label: label,
            usedPercent: usedPercent,
            resetsAt: DateParsing.parseUnixTimestamp(wire.reset_at),
            windowDurationSeconds: duration
        )
    }

    private static func classifyCadence(durationSeconds: TimeInterval) -> QuotaCadence {
        if durationSeconds <= 6 * 3600 {
            return .fiveHour
        }
        if durationSeconds >= 5 * 86_400 && durationSeconds <= 9 * 86_400 {
            return .sevenDay
        }
        return .other
    }

    private static func shortCadenceSuffix(cadence: QuotaCadence, durationSeconds: TimeInterval) -> String {
        switch cadence {
        case .fiveHour: return "5h"
        case .sevenDay: return "7d"
        case .other:
            let hours = max(1, Int((durationSeconds / 3600).rounded()))
            return hours >= 24 && hours % 24 == 0 ? "\(hours / 24)d" : "\(hours)h"
        }
    }

    // MARK: - Credentials & Network

    static func defaultReadCredentials(homeDirectory: URL, environment: [String: String]) -> Credentials? {
        let codexHome = environment["CODEX_HOME"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? homeDirectory.appendingPathComponent(".codex", isDirectory: true)
        let authURL = codexHome.appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: authURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = json["tokens"] as? [String: Any],
              let accessToken = (tokens["access_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !accessToken.isEmpty
        else {
            return nil
        }
        let refreshToken = (tokens["refresh_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let accountID = (tokens["account_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Credentials(accessToken: accessToken, refreshToken: refreshToken, accountID: accountID)
    }

    private func requestUsage(credentials: Credentials) async throws -> HTTPResponseData {
        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let accountID = credentials.accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        return try await transport.perform(request)
    }

    // MARK: - Wire Models

    private struct WireUsageResponse: Decodable {
        let plan_type: String?
        let email: String?
        let rate_limit: WireRateLimitDetails?
        let additional_rate_limits: [WireAdditionalRateLimit]?
    }

    private struct WireRateLimitDetails: Decodable {
        let primary_window: WireWindow?
        let secondary_window: WireWindow?
    }

    private struct WireWindow: Decodable {
        let used_percent: Double?
        let limit_window_seconds: Int?
        let reset_at: Double?
    }

    private struct WireAdditionalRateLimit: Decodable {
        let limit_name: String?
        let metered_feature: String?
        let rate_limit: WireRateLimitDetails?
    }
}
