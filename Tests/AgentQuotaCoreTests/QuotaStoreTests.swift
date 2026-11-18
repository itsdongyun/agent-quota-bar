import XCTest
@testable import AgentQuotaCore

private final class StubQuotaProvider: QuotaProvider, @unchecked Sendable {
    let providerID: ProviderID
    private let lock = NSLock()
    var statusResult: ProviderConnectionStatus = .connected
    var fetchHandler: @Sendable () async throws -> ProviderQuotaSnapshot

    init(
        providerID: ProviderID,
        statusResult: ProviderConnectionStatus = .connected,
        fetchHandler: @escaping @Sendable () async throws -> ProviderQuotaSnapshot
    ) {
        self.providerID = providerID
        self.statusResult = statusResult
        self.fetchHandler = fetchHandler
    }

    func setStatusResult(_ status: ProviderConnectionStatus) {
        lock.withLock { statusResult = status }
    }

    func checkConnectionStatus() async -> ProviderConnectionStatus {
        lock.withLock { statusResult }
    }

    func fetchUsage() async throws -> ProviderQuotaSnapshot {
        try await fetchHandler()
    }
}

@MainActor
final class QuotaStoreTests: XCTestCase {
    func testRefreshAllDoesNotAdvanceLastUpdatedAtWhenAllProvidersFail() async {
        let failingClaude = StubQuotaProvider(providerID: .claude) {
            throw QuotaProviderError.rateLimited(retryAfter: nil)
        }
        let failingCodex = StubQuotaProvider(providerID: .codex) {
            throw QuotaProviderError.loginRequired
        }
        let failingAgy = StubQuotaProvider(providerID: .antigravity) {
            throw QuotaProviderError.notInstalled
        }
        let store = QuotaStore(
            providers: [failingClaude, failingCodex, failingAgy],
            announcementService: ResetAnnouncementService(
                transport: MockHTTPTransport(response: HTTPResponseData(data: Data(), statusCode: 500))
            ),
            settingsStore: InMemorySettingsStore(),
            snapshotStore: InMemorySnapshotStore()
        )

        await store.refreshAll()
        XCTAssertNil(store.lastUpdatedAt)
        XCTAssertEqual(store.connectionStatuses[.claude], .rateLimited(retryAfter: nil))
        XCTAssertEqual(store.connectionStatuses[.codex], .loginRequired)
        XCTAssertEqual(store.connectionStatuses[.antigravity], .notInstalled)
    }

    func testPassiveRefreshConnectionStatusesPreservesActiveFetchErrors() async {
        let claude = StubQuotaProvider(providerID: .claude, statusResult: .connected) {
            throw QuotaProviderError.rateLimited(retryAfter: Date().addingTimeInterval(60))
        }
        let codex = StubQuotaProvider(providerID: .codex, statusResult: .connected) {
            ProviderQuotaSnapshot(provider: .codex, windows: [])
        }
        let agy = StubQuotaProvider(providerID: .antigravity, statusResult: .connected) {
            throw QuotaProviderError.loginRequired
        }
        let store = QuotaStore(
            providers: [claude, codex, agy],
            announcementService: ResetAnnouncementService(
                transport: MockHTTPTransport(response: HTTPResponseData(data: Data(), statusCode: 500))
            ),
            settingsStore: InMemorySettingsStore(),
            snapshotStore: InMemorySnapshotStore()
        )

        await store.refreshAll()
        XCTAssertNotNil(store.lastUpdatedAt) // codex succeeded

        // Opening Settings calls passive refreshConnectionStatuses(); active errors must remain intact.
        await store.refreshConnectionStatuses(forceVerify: false)
        if case .rateLimited = store.connectionStatuses[.claude] {} else {
            XCTFail("Expected claude rateLimited to be preserved, got \(String(describing: store.connectionStatuses[.claude]))")
        }
        XCTAssertEqual(store.connectionStatuses[.antigravity], .loginRequired)
        XCTAssertEqual(store.connectionStatuses[.codex], .connected)
    }

    func testDisablingProvidersClearsOnlyTheirAnnouncementsAndReEnablingFetches() async throws {
        let nowISO = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-600))
        let codexJSON = #"{"latest_alert":{"id":"1","kind":"watch","state":"active","url":"https://codex-reset.com/w"}}"#
        let claudeJSON = #"{"lastResetAt":"\#(nowISO)","lastResetUrl":"https://x.com/ClaudeDevs/status/1","lastResetType":"reset"}"#
        let agyJSON = #"{"events":[{"id":"ag1","announcedAt":"\#(nowISO)","sourceUrl":"https://x.com/_mohansolo/status/1","text":"Reset","models":["Gemini"],"verified":true}]}"#

        let codex = StubQuotaProvider(providerID: .codex) {
            ProviderQuotaSnapshot(provider: .codex, windows: [])
        }
        let claude = StubQuotaProvider(providerID: .claude) {
            ProviderQuotaSnapshot(provider: .claude, windows: [])
        }
        let agy = StubQuotaProvider(providerID: .antigravity) {
            ProviderQuotaSnapshot(provider: .antigravity, windows: [])
        }
        let transport = MockHTTPTransport(handlers: [{ req in
            switch req.url?.host {
            case "codex-reset.com":
                return HTTPResponseData(data: Data(codexJSON.utf8), statusCode: 200)
            case "claude-resets.com":
                return HTTPResponseData(data: Data(claudeJSON.utf8), statusCode: 200)
            case "antigravityreset.com":
                return HTTPResponseData(data: Data(agyJSON.utf8), statusCode: 200)
            default:
                return HTTPResponseData(data: Data(), statusCode: 404)
            }
        }])
        let store = QuotaStore(
            providers: [claude, codex, agy],
            announcementService: ResetAnnouncementService(transport: transport),
            settingsStore: InMemorySettingsStore(),
            snapshotStore: InMemorySnapshotStore()
        )

        await store.refreshAll()
        XCTAssertNotNil(store.resetAnnouncements[.codex])
        XCTAssertNotNil(store.resetAnnouncements[.claude])
        XCTAssertNotNil(store.resetAnnouncements[.antigravity])

        store.setProviderEnabled(false, for: .codex)
        XCTAssertNil(store.resetAnnouncements[.codex])
        XCTAssertNotNil(store.resetAnnouncements[.claude])
        XCTAssertNotNil(store.resetAnnouncements[.antigravity])

        store.setProviderEnabled(true, for: .codex)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(store.connectionStatuses[.codex], .connected)
        XCTAssertNotNil(store.resetAnnouncements[.codex])
    }

    func testSnapshotPersistenceLoadsOnInitAndRetainsLastDataOn429() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let fileURL = tempDir.appendingPathComponent("snapshots.json")

        let reset = Date().addingTimeInterval(3600)
        let savedWindow = QuotaWindow(
            id: "claude.5h",
            provider: .claude,
            category: .fiveHour,
            cadence: .fiveHour,
            label: "5h Limit",
            usedPercent: 44,
            resetsAt: reset
        )
        let initialSnapshot = ProviderQuotaSnapshot(
            provider: .claude,
            planName: "Max",
            windows: [savedWindow],
            fetchedAt: Date(timeIntervalSince1970: 1_794_900_000)
        )

        let writerStore = FileQuotaSnapshotStore(fileURL: fileURL)
        writerStore.save([.claude: initialSnapshot])

        let rateLimitedClaude = StubQuotaProvider(providerID: .claude) {
            throw QuotaProviderError.rateLimited(retryAfter: Date().addingTimeInterval(900))
        }
        let store = QuotaStore(
            providers: [rateLimitedClaude],
            announcementService: ResetAnnouncementService(
                transport: MockHTTPTransport(response: HTTPResponseData(data: Data(), statusCode: 500))
            ),
            settingsStore: InMemorySettingsStore(),
            snapshotStore: FileQuotaSnapshotStore(fileURL: fileURL)
        )

        XCTAssertEqual(store.snapshots[.claude]?.windows.first?.usedPercent, 44)
        XCTAssertEqual(store.lastUpdatedAt, initialSnapshot.fetchedAt)

        await store.refreshAll()

        XCTAssertEqual(store.snapshots[.claude]?.windows.first?.usedPercent, 44)
        if case .rateLimited = store.connectionStatuses[.claude] {} else {
            XCTFail("Expected rateLimited status, got \(String(describing: store.connectionStatuses[.claude]))")
        }
    }

    func testForcedRefreshDuringRunningRefreshRunsAnotherPass() async throws {
        final class Counter: @unchecked Sendable {
            let lock = NSLock()
            var fetches = 0
        }
        let counter = Counter()
        let slowClaude = StubQuotaProvider(providerID: .claude) {
            counter.lock.withLock { counter.fetches += 1 }
            try await Task.sleep(for: .milliseconds(200))
            return ProviderQuotaSnapshot(provider: .claude, windows: [])
        }
        var settings = QuotaSettings()
        for id in [ProviderID.codex, .antigravity] {
            var prefs = settings.preferences(for: id)
            prefs.isEnabled = false
            settings.providerPreferences[id] = prefs
        }
        let store = QuotaStore(
            providers: [slowClaude],
            announcementService: ResetAnnouncementService(
                transport: MockHTTPTransport(response: HTTPResponseData(data: Data(), statusCode: 500))
            ),
            settingsStore: InMemorySettingsStore(stored: settings),
            snapshotStore: InMemorySnapshotStore()
        )

        let background = Task { await store.refreshAll() }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(store.isRefreshing)

        // A timer/popover refresh during a running pass is skipped...
        await store.refreshAll()
        XCTAssertEqual(counter.lock.withLock { counter.fetches }, 1)

        // ...but a user recheck waits for it and runs a fresh pass.
        await store.refreshConnectionStatuses(forceVerify: true)
        await background.value
        XCTAssertEqual(counter.lock.withLock { counter.fetches }, 2)
        XCTAssertFalse(store.isRefreshing)
    }

    func testVisibleWindowsShowPassedResetAsUnusedInsteadOfStaleUsage() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cached = ProviderQuotaSnapshot(
            provider: .claude,
            windows: [
                QuotaWindow(
                    id: "claude.5h", provider: .claude, category: .fiveHour, cadence: .fiveHour,
                    label: "5h Limit", usedPercent: 95, resetsAt: now.addingTimeInterval(-60)
                ),
                QuotaWindow(
                    id: "claude.7d", provider: .claude, category: .sevenDay, cadence: .sevenDay,
                    label: "7d Limit", usedPercent: 40, resetsAt: now.addingTimeInterval(3600)
                ),
            ],
            fetchedAt: now.addingTimeInterval(-3600)
        )
        let store = QuotaStore(
            providers: [],
            announcementService: ResetAnnouncementService(
                transport: MockHTTPTransport(response: HTTPResponseData(data: Data(), statusCode: 500))
            ),
            settingsStore: InMemorySettingsStore(),
            snapshotStore: InMemorySnapshotStore(stored: [.claude: cached])
        )

        let windows = store.visibleWindows(for: .claude, now: now)
        XCTAssertEqual(windows.map(\.usedPercent), [0, 40])
        XCTAssertNil(windows[0].resetsAt)
        XCTAssertEqual(windows[1].resetsAt, now.addingTimeInterval(3600))
    }

    private func makeStore(_ providers: [any QuotaProvider]) -> QuotaStore {
        var settings = QuotaSettings()
        let ids = Set(providers.map(\.providerID))
        for id in ProviderID.allCases where !ids.contains(id) {
            var prefs = settings.preferences(for: id)
            prefs.isEnabled = false
            settings.providerPreferences[id] = prefs
        }
        return QuotaStore(
            providers: providers,
            announcementService: ResetAnnouncementService(
                transport: MockHTTPTransport(response: HTTPResponseData(data: Data(), statusCode: 500))
            ),
            settingsStore: InMemorySettingsStore(stored: settings),
            snapshotStore: InMemorySnapshotStore()
        )
    }

    func testSmartRefreshLevelsAreTrackedPerProvider() async {
        final class Counter: @unchecked Sendable {
            let lock = NSLock()
            var value = 0.0
        }
        let counter = Counter()
        let busyClaude = StubQuotaProvider(providerID: .claude) {
            let percent = counter.lock.withLock { () -> Double in
                counter.value += 1
                return counter.value
            }
            return ProviderQuotaSnapshot(provider: .claude, windows: [
                QuotaWindow(id: "claude.5h", provider: .claude, category: .fiveHour, cadence: .fiveHour,
                            label: "5h", usedPercent: percent, resetsAt: nil),
            ])
        }
        let idleCodex = StubQuotaProvider(providerID: .codex) {
            ProviderQuotaSnapshot(provider: .codex, windows: [
                QuotaWindow(id: "codex.5h", provider: .codex, category: .fiveHour, cadence: .fiveHour,
                            label: "5h", usedPercent: 5, resetsAt: nil),
            ])
        }
        let store = makeStore([busyClaude, idleCodex])

        for _ in 0..<4 {
            await store.refreshAll()
        }
        XCTAssertEqual(store.refreshStates[.claude]?.mode, .active)
        XCTAssertEqual(store.refreshStates[.codex]?.mode, .idleShort)
    }

    func testAutomaticRefreshRespectsBackoffButUserRefreshBypassesIt() async {
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var fetches = 0
        }
        let box = Box()
        let claude = StubQuotaProvider(providerID: .claude) {
            let count = box.lock.withLock { () -> Int in
                box.fetches += 1
                return box.fetches
            }
            if count == 1 {
                throw QuotaProviderError.httpError(503)
            }
            return ProviderQuotaSnapshot(provider: .claude, windows: [])
        }
        let store = makeStore([claude])

        await store.refreshAll()
        XCTAssertEqual(store.backoffStates[.claude]?.consecutiveFailures, 1)

        await store.refreshAll() // automatic: still backing off
        XCTAssertEqual(box.lock.withLock { box.fetches }, 1)

        await store.userRefresh() // user action ignores backoff
        XCTAssertEqual(box.lock.withLock { box.fetches }, 2)
        XCTAssertEqual(store.backoffStates[.claude], .initial)
        XCTAssertEqual(store.connectionStatuses[.claude], .connected)

        await store.userRefresh() // debounced: within the minimum interval
        XCTAssertEqual(box.lock.withLock { box.fetches }, 2)
    }

    func testClaudeSignOutDropsItsData() async {
        let claude = StubQuotaProvider(providerID: .claude) {
            ProviderQuotaSnapshot(provider: .claude, windows: [])
        }
        let store = makeStore([claude])
        await store.refreshAll()
        XCTAssertNotNil(store.snapshots[.claude])

        store.claudeDidSignOut()
        XCTAssertNil(store.snapshots[.claude])
        XCTAssertEqual(store.connectionStatuses[.claude], .loginRequired)
    }

    func testAnnouncementsAreFetchedTogetherForEnabledProvidersOnlyAndCached() async {
        let transport = MockHTTPTransport(handlers: [{ _ in HTTPResponseData(data: Data("{}".utf8), statusCode: 200) }])
        let claude = StubQuotaProvider(providerID: .claude) { ProviderQuotaSnapshot(provider: .claude, windows: []) }
        let codex = StubQuotaProvider(providerID: .codex) { ProviderQuotaSnapshot(provider: .codex, windows: []) }
        var settings = QuotaSettings()
        var agyPrefs = settings.preferences(for: .antigravity)
        agyPrefs.isEnabled = false
        settings.providerPreferences[.antigravity] = agyPrefs
        let store = QuotaStore(
            providers: [claude, codex],
            announcementService: ResetAnnouncementService(transport: transport),
            settingsStore: InMemorySettingsStore(stored: settings),
            snapshotStore: InMemorySnapshotStore()
        )

        await store.refreshAll()
        let hosts = Set(transport.recordedRequests.compactMap { $0.url?.host })
        XCTAssertEqual(hosts, ["claude-resets.com", "codex-reset.com"])

        // Usage refreshes inside the 30-minute window reuse the cached announcements.
        await store.userRefresh()
        XCTAssertEqual(transport.recordedRequests.count, 2)
    }

    func testStoreRecordsEarlyResetFromConsecutiveFetches() async {
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var used = 70.0
        }
        let box = Box()
        let resetsAt = Date().addingTimeInterval(2 * 86_400)
        let codex = StubQuotaProvider(providerID: .codex) {
            let used = box.lock.withLock { box.used }
            return ProviderQuotaSnapshot(provider: .codex, windows: [
                QuotaWindow(id: "codex.7d", provider: .codex, category: .sevenDay, cadence: .sevenDay,
                            label: "7d", usedPercent: used, resetsAt: resetsAt),
            ])
        }
        let store = makeStore([codex])

        await store.refreshAll()
        XCTAssertNil(store.detectedResets[.codex])

        box.lock.withLock { box.used = 0 }
        await store.userRefresh()
        XCTAssertEqual(store.detectedResets[.codex]?.windows.map(\.id), ["codex.7d"])

        store.setProviderEnabled(false, for: .codex)
        XCTAssertNil(store.detectedResets[.codex])
    }

    func testSignInDuringAnOldFetchFetchesAgainWithTheNewLogin() async throws {
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var calls = 0
        }
        let box = Box()
        let claude = StubQuotaProvider(providerID: .claude) {
            let call = box.lock.withLock { () -> Int in
                box.calls += 1
                return box.calls
            }
            if call == 1 {
                try await Task.sleep(for: .milliseconds(200))
                throw QuotaProviderError.loginRequired // started before sign-in
            }
            return ProviderQuotaSnapshot(provider: .claude, windows: [])
        }
        let store = makeStore([claude])

        let background = Task { await store.refreshAll() }
        try await Task.sleep(for: .milliseconds(50))
        store.claudeDidSignIn()
        await background.value
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(box.lock.withLock { box.calls }, 2)
        XCTAssertEqual(store.connectionStatuses[.claude], .connected)
    }

    func testSignInDropsThePreviousLoginsUsageSoNoFalseResetIsDetected() async throws {
        let resetsAt = Date().addingTimeInterval(2 * 86_400)
        let oldAccount = ProviderQuotaSnapshot(provider: .claude, windows: [
            QuotaWindow(id: "claude.7d", provider: .claude, category: .sevenDay, cadence: .sevenDay,
                        label: "7d", usedPercent: 80, resetsAt: resetsAt),
        ])
        let claude = StubQuotaProvider(providerID: .claude) {
            ProviderQuotaSnapshot(provider: .claude, windows: [
                QuotaWindow(id: "claude.7d", provider: .claude, category: .sevenDay, cadence: .sevenDay,
                            label: "7d", usedPercent: 10, resetsAt: resetsAt),
            ])
        }
        var settings = QuotaSettings()
        for id in [ProviderID.codex, .antigravity] {
            var prefs = settings.preferences(for: id)
            prefs.isEnabled = false
            settings.providerPreferences[id] = prefs
        }
        let store = QuotaStore(
            providers: [claude],
            announcementService: ResetAnnouncementService(
                transport: MockHTTPTransport(response: HTTPResponseData(data: Data(), statusCode: 500))
            ),
            settingsStore: InMemorySettingsStore(stored: settings),
            snapshotStore: InMemorySnapshotStore(stored: [.claude: oldAccount])
        )

        store.claudeDidSignIn()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(store.snapshots[.claude]?.windows.first?.usedPercent, 10)
        XCTAssertNil(store.detectedResets[.claude])
    }
}
