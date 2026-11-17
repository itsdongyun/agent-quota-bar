import Foundation

/// Provider states a mock scenario can put a provider in.
public enum MockProviderStatus: String, CaseIterable, Sendable, Identifiable {
    case connected
    /// Fetch stays in flight until the status changes.
    case loading
    case notInstalled
    case loginRequired
    case keychainDenied
    case rateLimited
    case error

    public var id: String { rawValue }

    func providerError(provider: ProviderID, now: Date) -> QuotaProviderError? {
        switch self {
        case .connected, .loading: return nil
        case .notInstalled: return .notInstalled
        case .loginRequired: return .loginRequired
        case .keychainDenied: return .keychainDenied
        case .rateLimited: return .rateLimited(retryAfter: now.addingTimeInterval(180))
        case .error: return .invalidResponse(.invalidPayload(provider))
        }
    }
}

/// Period of a provider's short limit.
public enum MockShortCadence: String, CaseIterable, Sendable, Identifiable {
    case fiveHour
    case daily

    public var id: String { rawValue }
}

/// One mock window. `elapsed` is the elapsed fraction of the window (`0...1`), so a marker keeps its
/// chart position no matter when the data is fetched.
public struct MockWindowState: Equatable, Sendable {
    public var isEnabled: Bool
    public var used: Double
    public var elapsed: Double

    public init(isEnabled: Bool = true, used: Double, elapsed: Double) {
        self.isEnabled = isEnabled
        self.used = used
        self.elapsed = elapsed
    }
}

public struct MockProviderState: Equatable, Sendable {
    public var status: MockProviderStatus
    public var plan: String
    /// When set, both windows are model-specific (as Antigravity reports them).
    public var model: String?
    public var shortCadence: MockShortCadence
    public var short: MockWindowState
    public var weekly: MockWindowState

    public init(
        status: MockProviderStatus = .connected,
        plan: String = "",
        model: String? = nil,
        shortCadence: MockShortCadence = .fiveHour,
        short: MockWindowState,
        weekly: MockWindowState
    ) {
        self.status = status
        self.plan = plan
        self.model = model
        self.shortCadence = shortCadence
        self.short = short
        self.weekly = weekly
    }
}

/// Everything the mock providers report, editable at runtime for UI work.
public struct MockScenario: Equatable, Sendable {
    public var providers: [ProviderID: MockProviderState]
    public var codexResetBanner: Bool

    public init(providers: [ProviderID: MockProviderState], codexResetBanner: Bool = false) {
        self.providers = providers
        self.codexResetBanner = codexResetBanner
    }

    public subscript(provider: ProviderID) -> MockProviderState {
        get {
            providers[provider] ?? MockProviderState(
                short: MockWindowState(isEnabled: false, used: 0, elapsed: 0),
                weekly: MockWindowState(isEnabled: false, used: 0, elapsed: 0)
            )
        }
        set { providers[provider] = newValue }
    }

    /// Builds the snapshot for `provider`, or throws the error its status stands for.
    public func snapshot(for provider: ProviderID, now: Date = Date()) throws -> ProviderQuotaSnapshot {
        let state = self[provider]
        if let error = state.status.providerError(provider: provider, now: now) {
            throw error
        }
        var windows: [QuotaWindow] = []
        if state.short.isEnabled {
            let isDaily = state.shortCadence == .daily
            windows.append(Self.window(
                provider: provider,
                slot: "short",
                state: state.short,
                model: state.model,
                cadence: isDaily ? .other : .fiveHour,
                category: .fiveHour,
                duration: isDaily ? 24 * 3600 : QuotaCadence.fiveHour.durationSeconds,
                now: now
            ))
        }
        if state.weekly.isEnabled {
            windows.append(Self.window(
                provider: provider,
                slot: "weekly",
                state: state.weekly,
                model: state.model,
                cadence: .sevenDay,
                category: .sevenDay,
                duration: QuotaCadence.sevenDay.durationSeconds,
                now: now
            ))
        }
        return ProviderQuotaSnapshot(
            provider: provider,
            planName: state.plan.isEmpty ? nil : state.plan,
            windows: windows,
            fetchedAt: now
        )
    }

    private static func window(
        provider: ProviderID,
        slot: String,
        state: MockWindowState,
        model: String?,
        cadence: QuotaCadence,
        category: QuotaWindowCategory,
        duration: TimeInterval,
        now: Date
    ) -> QuotaWindow {
        let elapsed = max(0, min(1, state.elapsed))
        return QuotaWindow(
            id: "mock.\(provider.rawValue).\(slot)",
            provider: provider,
            // Daily windows only exist as model-specific limits in real providers.
            category: model != nil || cadence == .other ? .modelSpecific : category,
            cadence: cadence,
            modelName: model,
            label: model ?? slot,
            usedPercent: state.used,
            resetsAt: now.addingTimeInterval((1 - elapsed) * duration),
            windowDurationSeconds: duration
        )
    }
}

/// Ready-made scenarios covering the states the popover and menu bar must handle.
public enum MockScenarioPreset: String, CaseIterable, Sendable, Identifiable {
    case design
    case relaxed
    case overPace
    case nearLimit
    case justReset
    case errors
    case loading
    case empty

    public var id: String { rawValue }

    public var scenario: MockScenario {
        switch self {
        case .design:
            return Self.make((12, 0.33, 30, 0.5), (55, 0.6, 70, 0.55), (20, 0.18, 85, 0.95))
        case .relaxed:
            return Self.make((10, 0.5, 20, 0.6), (15, 0.4, 25, 0.5), (5, 0.3, 30, 0.7))
        case .overPace:
            return Self.make((60, 0.3, 55, 0.3), (70, 0.4, 80, 0.45), (50, 0.2, 65, 0.35))
        case .nearLimit:
            return Self.make((95, 0.7, 92, 0.8), (98, 0.9, 99, 0.95), (91, 0.6, 96, 0.9))
        case .justReset:
            return Self.make((0, 0.02, 1, 0.01), (2, 0.03, 0, 0.01), (0, 0.01, 3, 0.02))
        case .errors:
            var scenario = Self.designScenario
            scenario[.claude].status = .loginRequired
            scenario[.codex].status = .rateLimited
            scenario[.antigravity].status = .notInstalled
            return scenario
        case .loading:
            var scenario = Self.designScenario
            for provider in ProviderID.allCases {
                scenario[provider].status = .loading
            }
            return scenario
        case .empty:
            var scenario = Self.designScenario
            for provider in ProviderID.allCases {
                scenario[provider].short.isEnabled = false
                scenario[provider].weekly.isEnabled = false
            }
            return scenario
        }
    }

    private static var designScenario: MockScenario { MockScenarioPreset.design.scenario }

    /// Each tuple: (short used, short elapsed, weekly used, weekly elapsed).
    private static func make(
        _ claude: (Double, Double, Double, Double),
        _ codex: (Double, Double, Double, Double),
        _ antigravity: (Double, Double, Double, Double)
    ) -> MockScenario {
        func state(_ values: (Double, Double, Double, Double), plan: String, model: String?) -> MockProviderState {
            MockProviderState(
                plan: plan,
                model: model,
                short: MockWindowState(used: values.0, elapsed: values.1),
                weekly: MockWindowState(used: values.2, elapsed: values.3)
            )
        }
        return MockScenario(providers: [
            .claude: state(claude, plan: "Max", model: nil),
            .codex: state(codex, plan: "Pro", model: nil),
            .antigravity: state(antigravity, plan: "", model: "Gemini"),
        ])
    }
}

/// Thread-safe holder of the live scenario shared by the UI and the mock providers.
public final class MockScenarioSource: @unchecked Sendable {
    private let lock = NSLock()
    private var current: MockScenario

    public init(scenario: MockScenario = MockScenarioPreset.design.scenario) {
        current = scenario
    }

    public var scenario: MockScenario {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}

/// Provider serving the live mock scenario. No network, Keychain, or CLI access.
public struct MockQuotaProvider: QuotaProvider {
    public let providerID: ProviderID
    private let source: MockScenarioSource

    public init(providerID: ProviderID, source: MockScenarioSource) {
        self.providerID = providerID
        self.source = source
    }

    public func checkConnectionStatus() async -> ProviderConnectionStatus {
        .connected
    }

    public func fetchUsage() async throws -> ProviderQuotaSnapshot {
        while source.scenario[providerID].status == .loading {
            try await Task.sleep(for: .milliseconds(200))
        }
        return try source.scenario.snapshot(for: providerID)
    }

    public static func all(source: MockScenarioSource) -> [any QuotaProvider] {
        ProviderID.allCases.map { MockQuotaProvider(providerID: $0, source: source) }
    }
}

/// Serves a Codex reset forecast while the scenario's banner is on, and HTTP 404 otherwise.
public struct MockAnnouncementTransport: HTTPTransport {
    private let source: MockScenarioSource

    public init(source: MockScenarioSource) {
        self.source = source
    }

    public func perform(_ request: URLRequest) async throws -> HTTPResponseData {
        guard source.scenario.codexResetBanner else {
            return HTTPResponseData(data: Data(), statusCode: 404)
        }
        let target = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3 * 3600))
        let json = """
        {"latest_alert": {"id": "mock", "kind": "watch", "state": "watch", "summary": "Mock reset",
          "url": "https://codex-reset.com", "window": {"target_at": "\(target)"}}}
        """
        return HTTPResponseData(data: Data(json.utf8), statusCode: 200)
    }
}
