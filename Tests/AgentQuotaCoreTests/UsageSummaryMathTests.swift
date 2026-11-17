import XCTest
@testable import AgentQuotaCore

final class UsageSummaryMathTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let day: TimeInterval = 24 * 3600

    private func window(
        _ id: String,
        provider: ProviderID = .claude,
        category: QuotaWindowCategory,
        cadence: QuotaCadence,
        used: Double,
        remaining: TimeInterval,
        duration: TimeInterval? = nil
    ) -> QuotaWindow {
        QuotaWindow(
            id: id,
            provider: provider,
            category: category,
            cadence: cadence,
            modelName: category == .modelSpecific ? id : nil,
            label: id,
            usedPercent: used,
            resetsAt: now.addingTimeInterval(remaining),
            windowDurationSeconds: duration
        )
    }

    func testSlotMapsDailyWindowsToShortAndSkipsMidLengthWindows() {
        let daily = window("daily", category: .modelSpecific, cadence: .other, used: 0, remaining: 3600, duration: day)
        let threeDay = window("3d", category: .modelSpecific, cadence: .other, used: 0, remaining: 3600, duration: 3 * day)
        XCTAssertEqual(UsageSummaryMath.slot(for: daily), .short)
        XCTAssertNil(UsageSummaryMath.slot(for: threeDay))
    }

    func testSummaryPrefersProviderWideWindowOverModelSpecific() {
        let weekly = window("7d", category: .sevenDay, cadence: .sevenDay, used: 30, remaining: 3 * day)
        let sonnet = window("sonnet", category: .modelSpecific, cadence: .sevenDay, used: 80, remaining: 3 * day)
        let summary = UsageSummaryMath.summary(for: .claude, windows: [sonnet, weekly])
        XCTAssertEqual(summary.weekly?.id, "7d")
        XCTAssertNil(summary.short)
    }

    func testSummaryFallsBackToMostUsedModelWindow() {
        let gemini = window("gemini-5h", provider: .antigravity, category: .modelSpecific, cadence: .fiveHour, used: 20, remaining: 3600)
        let claude = window("claude-5h", provider: .antigravity, category: .modelSpecific, cadence: .fiveHour, used: 45, remaining: 3600)
        let summary = UsageSummaryMath.summary(for: .antigravity, windows: [gemini, claude])
        XCTAssertEqual(summary.short?.id, "claude-5h")
    }

    func testPaceLevelUsesProjectedUsageAtReset() {
        // Half the week elapsed: 30% projects to 60% (normal), 45% to 90% (warning), 60% to 120% (critical).
        let half = 3.5 * day
        XCTAssertEqual(UsageSummaryMath.paceLevel(for: window("a", category: .sevenDay, cadence: .sevenDay, used: 30, remaining: half), now: now), .normal)
        XCTAssertEqual(UsageSummaryMath.paceLevel(for: window("b", category: .sevenDay, cadence: .sevenDay, used: 45, remaining: half), now: now), .warning)
        XCTAssertEqual(UsageSummaryMath.paceLevel(for: window("c", category: .sevenDay, cadence: .sevenDay, used: 60, remaining: half), now: now), .critical)
    }

    func testPaceLevelIgnoresProjectionRightAfterReset() {
        // 5% used with 2% elapsed would project to 250%, but the window just started.
        let fresh = window("fresh", category: .sevenDay, cadence: .sevenDay, used: 5, remaining: 0.98 * 7 * day)
        XCTAssertEqual(UsageSummaryMath.paceLevel(for: fresh, now: now), .normal)
        let nearlyFull = window("full", category: .sevenDay, cadence: .sevenDay, used: 92, remaining: 0.98 * 7 * day)
        XCTAssertEqual(UsageSummaryMath.paceLevel(for: nearlyFull, now: now), .critical)
    }

    func testMostPressingWindowPrefersWorseLevel() {
        let short = window("5h", category: .fiveHour, cadence: .fiveHour, used: 40, remaining: 4 * 3600)
        let weekly = window("7d", category: .sevenDay, cadence: .sevenDay, used: 50, remaining: 6 * day)
        let summary = ProviderUsageSummary(provider: .claude, short: short, weekly: weekly)
        // Both critical (5h projects 200%, weekly 350%), so the higher usage wins.
        XCTAssertEqual(UsageSummaryMath.mostPressingWindow(in: summary, now: now)?.id, "7d")

        let calmWeekly = window("7d-calm", category: .sevenDay, cadence: .sevenDay, used: 50, remaining: 3 * day)
        // Weekly now projects 87.5% (warning), so the critical 5h window wins.
        let calmSummary = ProviderUsageSummary(provider: .claude, short: short, weekly: calmWeekly)
        XCTAssertEqual(UsageSummaryMath.mostPressingWindow(in: calmSummary, now: now)?.id, "5h")
    }
}
