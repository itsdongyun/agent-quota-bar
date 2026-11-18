import XCTest
@testable import AgentQuotaCore

final class ResetDetectionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_795_000_000)

    private func snapshot(_ used: Double, resetsIn: TimeInterval?) -> ProviderQuotaSnapshot {
        ProviderQuotaSnapshot(provider: .codex, windows: [
            QuotaWindow(id: "codex.7d", provider: .codex, category: .sevenDay, cadence: .sevenDay,
                        label: "7d", usedPercent: used, resetsAt: resetsIn.map { now.addingTimeInterval($0) }),
        ])
    }

    func testUsageDropBeforeScheduledResetIsAnEarlyReset() throws {
        let detected = try XCTUnwrap(DetectedReset.detect(
            previous: snapshot(60, resetsIn: 3 * 86_400),
            current: snapshot(0, resetsIn: 7 * 86_400),
            now: now
        ))
        XCTAssertEqual(detected.windows.map(\.id), ["codex.7d"])
        XCTAssertTrue(detected.isActive(at: now.addingTimeInterval(3600)))
        XCTAssertFalse(detected.isActive(at: now.addingTimeInterval(DetectedReset.displayDuration + 1)))
    }

    func testResetIsDetectedFromMovedResetTimeEvenAfterUsageClimbedBack() {
        // Reset 3 days early, then heavy use pushed usage past the old value before the next fetch.
        let detected = DetectedReset.detect(
            previous: snapshot(40, resetsIn: 3 * 86_400),
            current: snapshot(55, resetsIn: 7 * 86_400),
            now: now
        )
        XCTAssertEqual(detected?.windows.map(\.id), ["codex.7d"])
        // A few seconds of timestamp rounding is not a new window.
        XCTAssertNil(DetectedReset.detect(
            previous: snapshot(40, resetsIn: 3 * 86_400),
            current: snapshot(45, resetsIn: 3 * 86_400 + 1),
            now: now
        ))
    }

    func testUnusedRollingWindowIsNotMistakenForAResetAfterALongGap() {
        // Antigravity reports an unused window's reset as "now + length", so it moves with every fetch;
        // after the Mac slept for hours it has moved far, but nothing was reset.
        XCTAssertNil(DetectedReset.detect(
            previous: snapshot(0, resetsIn: 7 * 86_400 - 3 * 3600),
            current: snapshot(0, resetsIn: 7 * 86_400),
            now: now
        ))
    }

    func testScheduledResetSmallDropsAndRisesAreNotDetected() {
        // The regular reset at its scheduled time.
        XCTAssertNil(DetectedReset.detect(previous: snapshot(60, resetsIn: 30), current: snapshot(0, resetsIn: 7 * 86_400), now: now))
        // Rounding noise.
        XCTAssertNil(DetectedReset.detect(previous: snapshot(60, resetsIn: 86_400), current: snapshot(58, resetsIn: 86_400), now: now))
        // Usage going up.
        XCTAssertNil(DetectedReset.detect(previous: snapshot(10, resetsIn: 86_400), current: snapshot(20, resetsIn: 86_400), now: now))
        // No known schedule to compare against.
        XCTAssertNil(DetectedReset.detect(previous: snapshot(60, resetsIn: nil), current: snapshot(0, resetsIn: nil), now: now))
    }

    func testCodexLastResetIsShownWhenNoWatchIsLive() throws {
        let json = #"{"latest_alert":null,"last_reset_at":"2026-11-18T03:00:00.000Z"}"#
        let now = try XCTUnwrap(DateParsing.parseISO8601("2026-11-18T05:00:00Z"))
        let parsed = try XCTUnwrap(ResetAnnouncementService.parseCodexForecast(Data(json.utf8), now: now))
        XCTAssertEqual(parsed.kind, .recentReset)
        XCTAssertTrue(parsed.isActive(at: now))
        // Shown for 12 hours after the reset (03:00), not a full day.
        XCTAssertTrue(parsed.isActive(at: now.addingTimeInterval(9 * 3600)))
        XCTAssertFalse(parsed.isActive(at: now.addingTimeInterval(11 * 3600)))

        let watchJSON = #"{"latest_alert":{"id":"9","kind":"watch","state":"active"},"last_reset_at":"2026-11-18T03:00:00.000Z"}"#
        XCTAssertEqual(ResetAnnouncementService.parseCodexForecast(Data(watchJSON.utf8), now: now)?.kind, .watch)
    }
}
