import Foundation

/// Fetches ad-hoc global reset watches, banked reset grants, and recent reset notices per provider.
/// Every failure fails silently (`nil`) so third-party tracker downtime never degrades core quota UI.
public actor ResetAnnouncementService {
    private static let codexForecastURL = URL(string: "https://codex-reset.com/api/forecast")!
    private static let claudeSummaryURL = URL(string: "https://claude-resets.com/data/summary.json")!
    private static let antigravityStateURL = URL(string: "https://antigravityreset.com/api/state")!

    private struct CacheEntry {
        let lastFetchAt: Date
        let announcement: ResetAnnouncement?
    }

    private let transport: HTTPTransport
    private let minimumFetchInterval: TimeInterval
    private var cache: [ProviderID: CacheEntry] = [:]
    private var inFlightTasks: [ProviderID: Task<ResetAnnouncement?, Never>] = [:]

    public init(
        transport: HTTPTransport = EphemeralHTTPTransport(timeout: 10),
        minimumFetchInterval: TimeInterval = 300
    ) {
        self.transport = transport
        self.minimumFetchInterval = minimumFetchInterval
    }

    public func fetchAnnouncement(
        for provider: ProviderID,
        now: Date = Date()
    ) async -> ResetAnnouncement? {
        if let entry = cache[provider],
           now.timeIntervalSince(entry.lastFetchAt) < minimumFetchInterval
        {
            return entry.announcement.flatMap { $0.isActive(at: now) ? $0 : nil }
        }

        if let existingTask = inFlightTasks[provider] {
            return await existingTask.value
        }

        let task = Task<ResetAnnouncement?, Never> { [self] in
            await self.performFetch(for: provider, now: now)
        }
        inFlightTasks[provider] = task
        let result = await task.value
        inFlightTasks[provider] = nil
        return result
    }

    private func performFetch(for provider: ProviderID, now: Date) async -> ResetAnnouncement? {
        let endpoint = Self.endpointURL(for: provider)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("agent-quota-bar/1.0", forHTTPHeaderField: "User-Agent")

        let parsed: ResetAnnouncement?
        do {
            let response = try await transport.perform(request)
            if response.statusCode == 200 {
                parsed = Self.parseResponse(response.data, for: provider, now: now)
            } else {
                AppLogger.provider.debug("\(provider.rawValue) reset tracker returned HTTP \(response.statusCode)")
                parsed = nil
            }
        } catch {
            AppLogger.provider.debug("\(provider.rawValue) reset tracker fetch skipped: \(error.localizedDescription)")
            parsed = nil
        }

        cache[provider] = CacheEntry(lastFetchAt: now, announcement: parsed)
        return parsed.flatMap { $0.isActive(at: now) ? $0 : nil }
    }

    private static func endpointURL(for provider: ProviderID) -> URL {
        switch provider {
        case .codex: return codexForecastURL
        case .claude: return claudeSummaryURL
        case .antigravity: return antigravityStateURL
        }
    }

    static func parseResponse(
        _ data: Data,
        for provider: ProviderID,
        now: Date = Date()
    ) -> ResetAnnouncement? {
        switch provider {
        case .codex:
            return parseCodexForecast(data)
        case .claude:
            return parseClaudeSummary(data, now: now)
        case .antigravity:
            return parseAntigravityState(data)
        }
    }

    // MARK: - Codex (`codex-reset.com/api/forecast`)

    static func parseCodexForecast(_ data: Data) -> ResetAnnouncement? {
        guard let decoded = try? JSONDecoder().decode(WireCodexForecast.self, from: data),
              let alert = decoded.latest_alert
        else {
            return nil
        }
        let rawKind = (alert.kind ?? "").lowercased()
        let stateRaw = (alert.state ?? "").lowercased()
        let state = ResetAnnouncement.State(rawValue: stateRaw) ?? .other
        let targetAt = DateParsing.parseISO8601(alert.window?.target_at ?? alert.window?.target)
        let windowEnd = DateParsing.parseISO8601(alert.window?.end_at ?? alert.window?.end)

        // Codex only surfaces upcoming `watch` alerts; confirmed historical resets stay inactive.
        let kind: ResetAnnouncement.Kind = rawKind == "watch" ? .watch : .recentReset
        return ResetAnnouncement(
            id: alert.id ?? "codex-unknown",
            provider: .codex,
            kind: kind,
            state: state,
            summary: alert.summary ?? alert.observation_message ?? "",
            announcedAt: nil,
            targetAt: targetAt,
            windowEnd: windowEnd,
            expiresAt: nil,
            windowLabel: alert.window?.label,
            sourceURL: validatedWebURL(from: alert.url)
        )
    }

    // MARK: - Claude (`claude-resets.com/data/summary.json`)

    static func parseClaudeSummary(_ data: Data, now: Date = Date()) -> ResetAnnouncement? {
        guard let decoded = try? JSONDecoder().decode(WireClaudeSummary.self, from: data) else {
            return nil
        }

        var candidates: [ResetAnnouncement] = []

        for banked in decoded.bankedResets ?? [] {
            let announcedAt = DateParsing.parseISO8601(banked.date)
            let expiresAt = DateParsing.parseISO8601(banked.usableUntil)
            guard announcedAt != nil || expiresAt != nil else { continue }
            candidates.append(
                ResetAnnouncement(
                    id: banked.id ?? "claude-banked-\(banked.date ?? "unknown")",
                    provider: .claude,
                    kind: .bankedReset,
                    state: .active,
                    summary: banked.scope ?? "",
                    announcedAt: announcedAt,
                    expiresAt: expiresAt,
                    windowLabel: banked.scope,
                    sourceURL: validatedWebURL(from: banked.url)
                )
            )
        }

        if let lastResetAt = DateParsing.parseISO8601(decoded.lastResetAt) {
            let isBanked = decoded.lastResetType?.lowercased() == "banked"
            let expiresAt = DateParsing.parseISO8601(decoded.lastResetUsableUntil)
            let sourceURL = validatedWebURL(from: decoded.lastResetUrl)
            let alreadyTracked = isBanked && candidates.contains {
                $0.announcedAt == lastResetAt || ($0.sourceURL != nil && $0.sourceURL == sourceURL)
            }
            if !alreadyTracked {
                candidates.append(
                    ResetAnnouncement(
                        id: "claude-latest-\(Int(lastResetAt.timeIntervalSince1970))",
                        provider: .claude,
                        kind: isBanked ? .bankedReset : .recentReset,
                        state: .active,
                        summary: decoded.lastResetScope ?? "",
                        announcedAt: lastResetAt,
                        expiresAt: isBanked ? expiresAt : nil,
                        windowLabel: decoded.lastResetScope,
                        sourceURL: sourceURL
                    )
                )
            }
        }

        let sortByRecency: (ResetAnnouncement, ResetAnnouncement) -> Bool = { lhs, rhs in
            let lhsDate = lhs.announcedAt ?? lhs.expiresAt ?? .distantPast
            let rhsDate = rhs.announcedAt ?? rhs.expiresAt ?? .distantPast
            return lhsDate > rhsDate
        }

        if let newestActive = candidates.filter({ $0.isActive(at: now) }).sorted(by: sortByRecency).first {
            return newestActive
        }
        return candidates.sorted(by: sortByRecency).first
    }

    // MARK: - Antigravity (`antigravityreset.com/api/state`)

    static func parseAntigravityState(_ data: Data) -> ResetAnnouncement? {
        guard let decoded = try? JSONDecoder().decode(WireAntigravityState.self, from: data) else {
            return nil
        }

        let candidates: [ResetAnnouncement] = (decoded.events ?? []).compactMap { event in
            if event.verified == false {
                return nil
            }
            guard let announcedAt = DateParsing.parseISO8601(event.announcedAt) else {
                return nil
            }
            let models = (event.models ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let modelLabel = models.isEmpty ? nil : models.joined(separator: ", ")

            return ResetAnnouncement(
                id: event.id ?? "antigravity-\(Int(announcedAt.timeIntervalSince1970))",
                provider: .antigravity,
                kind: .recentReset,
                state: .active,
                summary: event.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                announcedAt: announcedAt,
                windowLabel: modelLabel,
                sourceURL: validatedWebURL(from: event.sourceUrl)
            )
        }

        return candidates.sorted {
            ($0.announcedAt ?? .distantPast) > ($1.announcedAt ?? .distantPast)
        }.first
    }

    private static func validatedWebURL(from raw: String?) -> URL? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = url.host,
              !host.isEmpty
        else {
            return nil
        }
        return url
    }

    // MARK: - Wire Models

    private struct WireCodexForecast: Decodable {
        let latest_alert: WireCodexAlert?
    }

    private struct WireCodexAlert: Decodable {
        let id: String?
        let kind: String?
        let state: String?
        let summary: String?
        let observation_message: String?
        let url: String?
        let window: WireCodexWindow?
    }

    private struct WireCodexWindow: Decodable {
        let label: String?
        let target_at: String?
        let target: String?
        let end_at: String?
        let end: String?
    }

    private struct WireClaudeSummary: Decodable {
        let lastResetAt: String?
        let lastResetUrl: String?
        let lastResetScope: String?
        let lastResetType: String?
        let lastResetUsableUntil: String?
        let bankedResets: [WireClaudeBankedReset]?
    }

    private struct WireClaudeBankedReset: Decodable {
        let id: String?
        let date: String?
        let scope: String?
        let usableUntil: String?
        let url: String?
    }

    private struct WireAntigravityState: Decodable {
        let events: [WireAntigravityEvent]?
    }

    private struct WireAntigravityEvent: Decodable {
        let id: String?
        let announcedAt: String?
        let sourceUrl: String?
        let text: String?
        let models: [String]?
        let verified: Bool?
    }
}
