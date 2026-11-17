import Foundation

/// Fetches ad-hoc global Codex reset announcements from `codex-reset.com/api/forecast`.
/// Every failure fails silently (`nil`) so third-party tracker downtime never degrades core quota UI.
public actor CodexResetAnnouncementService {
    private static let forecastURL = URL(string: "https://codex-reset.com/api/forecast")!

    private let transport: HTTPTransport
    private var cachedAnnouncement: CodexResetAnnouncement?
    private var lastFetchAt: Date?
    private let minimumFetchInterval: TimeInterval

    public init(
        transport: HTTPTransport = EphemeralHTTPTransport(timeout: 10),
        minimumFetchInterval: TimeInterval = 300
    ) {
        self.transport = transport
        self.minimumFetchInterval = minimumFetchInterval
    }

    public func fetchAnnouncement(now: Date = Date()) async -> CodexResetAnnouncement? {
        if let lastFetchAt, now.timeIntervalSince(lastFetchAt) < minimumFetchInterval {
            return cachedAnnouncement.flatMap { $0.isActive(at: now) ? $0 : nil }
        }

        lastFetchAt = now
        var request = URLRequest(url: Self.forecastURL)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let response = try await transport.perform(request)
            guard response.statusCode == 200 else {
                AppLogger.provider.debug("codex-reset forecast returned HTTP \(response.statusCode)")
                cachedAnnouncement = nil
                return nil
            }
            let parsed = Self.parseForecast(response.data)
            cachedAnnouncement = parsed
            return parsed.flatMap { $0.isActive(at: now) ? $0 : nil }
        } catch {
            AppLogger.provider.debug("codex-reset forecast fetch skipped: \(error.localizedDescription)")
            cachedAnnouncement = nil
            return nil
        }
    }

    static func parseForecast(_ data: Data) -> CodexResetAnnouncement? {
        guard let decoded = try? JSONDecoder().decode(WireForecast.self, from: data),
              let alert = decoded.latest_alert
        else {
            return nil
        }
        let kind = (alert.kind ?? "").lowercased()
        let stateRaw = (alert.state ?? "").lowercased()
        let state = CodexResetAnnouncement.State(rawValue: stateRaw) ?? .other
        let targetAt = DateParsing.parseISO8601(alert.window?.target_at ?? alert.window?.target)
        let windowEnd = DateParsing.parseISO8601(alert.window?.end_at ?? alert.window?.end)
        return CodexResetAnnouncement(
            id: alert.id ?? "unknown",
            kind: kind,
            state: state,
            summary: alert.summary ?? alert.observation_message ?? "",
            targetAt: targetAt,
            windowEnd: windowEnd,
            windowLabel: alert.window?.label,
            sourceURL: validatedWebURL(from: alert.url)
        )
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

    private struct WireForecast: Decodable {
        let latest_alert: WireAlert?
    }

    private struct WireAlert: Decodable {
        let id: String?
        let kind: String?
        let state: String?
        let summary: String?
        let observation_message: String?
        let url: String?
        let window: WireWindow?
    }

    private struct WireWindow: Decodable {
        let label: String?
        let target_at: String?
        let target: String?
        let end_at: String?
        let end: String?
    }
}
