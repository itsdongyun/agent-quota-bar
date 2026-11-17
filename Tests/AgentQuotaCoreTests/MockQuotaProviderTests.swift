import XCTest
@testable import AgentQuotaCore

final class MockQuotaProviderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testSnapshotPlacesWindowsByElapsedFraction() throws {
        let snapshot = try MockScenarioPreset.design.scenario.snapshot(for: .codex, now: now)
        XCTAssertEqual(snapshot.planName, "Pro")
        XCTAssertEqual(snapshot.windows.count, 2)
        let summary = UsageSummaryMath.summary(for: .codex, windows: snapshot.windows)
        XCTAssertEqual(summary.short?.elapsedFraction(at: now) ?? -1, 0.6, accuracy: 0.0001)
        XCTAssertEqual(summary.weekly?.usedPercent, 70)
    }

    func testDailyCadenceMapsToShortSlot() throws {
        var scenario = MockScenarioPreset.design.scenario
        scenario[.claude].shortCadence = .daily
        let snapshot = try scenario.snapshot(for: .claude, now: now)
        let summary = UsageSummaryMath.summary(for: .claude, windows: snapshot.windows)
        XCTAssertEqual(summary.short?.windowDurationSeconds, 24 * 3600)
    }

    func testDisabledWindowsAreOmitted() throws {
        let snapshot = try MockScenarioPreset.empty.scenario.snapshot(for: .antigravity, now: now)
        XCTAssertTrue(snapshot.windows.isEmpty)
    }

    func testErrorStatusThrowsProviderError() {
        let scenario = MockScenarioPreset.errors.scenario
        XCTAssertThrowsError(try scenario.snapshot(for: .claude, now: now)) { error in
            XCTAssertEqual(error as? QuotaProviderError, .loginRequired)
        }
    }

    func testLoadingFetchFinishesOnceStatusChanges() async throws {
        let source = MockScenarioSource(scenario: MockScenarioPreset.loading.scenario)
        let provider = MockQuotaProvider(providerID: .codex, source: source)
        let fetch = Task { try await provider.fetchUsage() }
        try await Task.sleep(for: .milliseconds(300))
        source.scenario[.codex].status = .connected
        let snapshot = try await fetch.value
        XCTAssertEqual(snapshot.windows.count, 2)
    }

    func testAnnouncementTransportFollowsBannerToggle() async throws {
        let source = MockScenarioSource()
        let service = CodexResetAnnouncementService(
            transport: MockAnnouncementTransport(source: source),
            minimumFetchInterval: 0
        )
        let off = await service.fetchAnnouncement()
        XCTAssertNil(off)
        source.scenario.codexResetBanner = true
        let on = await service.fetchAnnouncement()
        XCTAssertNotNil(on)
    }
}
