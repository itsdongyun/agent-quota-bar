import Foundation
import Observation
import AgentQuotaCore

/// Owns the live mock scenario in `--mock-data` mode and pushes every edit straight into the store.
@MainActor
@Observable
final class MockDataController {
    private let source: MockScenarioSource
    private let store: QuotaStore
    private var isApplyingPreset = false

    var scenario: MockScenario {
        didSet {
            guard !isApplyingPreset, scenario != oldValue else { return }
            source.scenario = scenario
            let changed = ProviderID.allCases.filter { scenario[$0] != oldValue[$0] }
            let bannerChanged = scenario.codexResetBanner != oldValue.codexResetBanner
            Task { await store.refresh(changed, includeAnnouncement: bannerChanged) }
        }
    }

    init(source: MockScenarioSource, store: QuotaStore) {
        self.source = source
        self.store = store
        self.scenario = source.scenario
    }

    /// Replaces the whole scenario and reloads from scratch, so no stale data from the previous state remains.
    func apply(_ preset: MockScenarioPreset) {
        let next = preset.scenario
        isApplyingPreset = true
        scenario = next
        isApplyingPreset = false
        source.scenario = next
        store.clearSnapshots()
        Task { await store.refresh(ProviderID.allCases, includeAnnouncement: true) }
    }
}
