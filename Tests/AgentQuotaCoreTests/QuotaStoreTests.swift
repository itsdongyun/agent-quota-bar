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
            announcementService: CodexResetAnnouncementService(
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
            announcementService: CodexResetAnnouncementService(
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

    func testDisablingCodexClearsAnnouncementAndReEnablingFetches() async throws {
        let watchJSON = #"{"latest_alert":{"id":"1","kind":"watch","state":"active","url":"https://codex-reset.com/w"}}"#
        let codex = StubQuotaProvider(providerID: .codex) {
            ProviderQuotaSnapshot(provider: .codex, windows: [])
        }
        let claude = StubQuotaProvider(providerID: .claude) {
            ProviderQuotaSnapshot(provider: .claude, windows: [])
        }
        let agy = StubQuotaProvider(providerID: .antigravity) {
            ProviderQuotaSnapshot(provider: .antigravity, windows: [])
        }
        let store = QuotaStore(
            providers: [claude, codex, agy],
            announcementService: CodexResetAnnouncementService(
                transport: MockHTTPTransport(response: HTTPResponseData(data: Data(watchJSON.utf8), statusCode: 200))
            ),
            settingsStore: InMemorySettingsStore(),
            snapshotStore: InMemorySnapshotStore()
        )

        await store.refreshAll()
        XCTAssertNotNil(store.codexResetAnnouncement)

        store.setProviderEnabled(false, for: .codex)
        XCTAssertNil(store.codexResetAnnouncement)

        store.setProviderEnabled(true, for: .codex)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(store.connectionStatuses[.codex], .connected)
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
            announcementService: CodexResetAnnouncementService(
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
}
