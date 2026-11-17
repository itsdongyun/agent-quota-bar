import XCTest
@testable import AgentQuotaCore

final class QuotaSettingsAndChartTests: XCTestCase {
    func testLimitFilteringAcrossProviders() {
        let now = Date()
        let reset = now.addingTimeInterval(3 * 24 * 3600)

        let claude5h = QuotaWindow(id: "claude.5h", provider: .claude, category: .fiveHour, cadence: .fiveHour, label: "5h", usedPercent: 10, resetsAt: reset)
        let claude7d = QuotaWindow(id: "claude.7d", provider: .claude, category: .sevenDay, cadence: .sevenDay, label: "7d", usedPercent: 40, resetsAt: reset)
        let claudeSonnet = QuotaWindow(id: "claude.7d.sonnet", provider: .claude, category: .modelSpecific, cadence: .sevenDay, modelName: "Sonnet", label: "Sonnet", usedPercent: 20, resetsAt: reset)

        let agy5h = QuotaWindow(id: "antigravity.gemini-5h", provider: .antigravity, category: .modelSpecific, cadence: .fiveHour, modelName: "Gemini", label: "Gemini (5h)", usedPercent: 21, resetsAt: reset)
        let agy7d = QuotaWindow(id: "antigravity.gemini-weekly", provider: .antigravity, category: .modelSpecific, cadence: .sevenDay, modelName: "Gemini", label: "Gemini (7d)", usedPercent: 36, resetsAt: reset)

        var claudePrefs = ProviderLimitPreferences()
        claudePrefs.showFiveHour = false
        claudePrefs.showModelSpecific = false
        XCTAssertFalse(claudePrefs.allows(claude5h))
        XCTAssertTrue(claudePrefs.allows(claude7d))
        XCTAssertFalse(claudePrefs.allows(claudeSonnet))

        var agyPrefs = ProviderLimitPreferences()
        agyPrefs.showFiveHour = false
        XCTAssertFalse(agyPrefs.allows(agy5h))
        XCTAssertTrue(agyPrefs.allows(agy7d))

        agyPrefs.disabledWindowIDs.insert(agy7d.id)
        XCTAssertFalse(agyPrefs.allows(agy7d))
    }
}
