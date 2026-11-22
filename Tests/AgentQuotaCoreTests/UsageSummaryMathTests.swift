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

    func testSummaryPrefersAntigravityGeminiOverHigherUsageSecondaryModels() {
        let geminiWeekly = QuotaWindow(
            id: "antigravity.gemini-weekly",
            provider: .antigravity,
            category: .modelSpecific,
            cadence: .sevenDay,
            modelName: "Gemini",
            label: "Gemini (7d)",
            usedPercent: 27,
            resetsAt: now.addingTimeInterval(6 * day)
        )
        let geminiShort = QuotaWindow(
            id: "antigravity.gemini-5h",
            provider: .antigravity,
            category: .modelSpecific,
            cadence: .fiveHour,
            modelName: "Gemini",
            label: "Gemini (5h)",
            usedPercent: 2,
            resetsAt: now.addingTimeInterval(4 * 3600)
        )
        let claudeGPTWeekly = QuotaWindow(
            id: "antigravity.3p-weekly",
            provider: .antigravity,
            category: .modelSpecific,
            cadence: .sevenDay,
            modelName: "Claude/GPT",
            label: "Claude/GPT (7d)",
            usedPercent: 52,
            resetsAt: now.addingTimeInterval(5 * day)
        )
        let claudeGPTShort = QuotaWindow(
            id: "antigravity.3p-5h",
            provider: .antigravity,
            category: .modelSpecific,
            cadence: .fiveHour,
            modelName: "Claude/GPT",
            label: "Claude/GPT (5h)",
            usedPercent: 40,
            resetsAt: now.addingTimeInterval(3 * 3600)
        )
        let argonWeekly = QuotaWindow(
            id: "antigravity.gemini-argon-wtu-weekly",
            provider: .antigravity,
            category: .modelSpecific,
            cadence: .sevenDay,
            modelName: "Gemini 4 Argon",
            label: "Gemini 4 Argon (7d)",
            usedPercent: 80,
            resetsAt: now.addingTimeInterval(7 * day)
        )

        let summary = UsageSummaryMath.summary(
            for: .antigravity,
            windows: [claudeGPTWeekly, claudeGPTShort, argonWeekly, geminiWeekly, geminiShort]
        )
        XCTAssertEqual(summary.weekly?.id, "antigravity.gemini-weekly")
        XCTAssertEqual(summary.short?.id, "antigravity.gemini-5h")
    }

    func testSummaryFallsBackToMostUsedModelWindowWhenNoPrimaryExists() {
        let claude = window("antigravity.3p-weekly", provider: .antigravity, category: .modelSpecific, cadence: .sevenDay, used: 52, remaining: 5 * day)
        let argon = window("antigravity.gemini-argon-wtu-weekly", provider: .antigravity, category: .modelSpecific, cadence: .sevenDay, used: 20, remaining: 6 * day)
        let summary = UsageSummaryMath.summary(for: .antigravity, windows: [argon, claude])
        XCTAssertEqual(summary.weekly?.id, "antigravity.3p-weekly")
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

}
