import Foundation
import Observation

/// Central state store coordinating quota fetches, refresh timer, and user limit filtering.
@MainActor
@Observable
public final class QuotaStore {
    public private(set) var snapshots: [ProviderID: ProviderQuotaSnapshot] = [:]
    public private(set) var connectionStatuses: [ProviderID: ProviderConnectionStatus] = Dictionary(
        uniqueKeysWithValues: ProviderID.allCases.map { ($0, .unknown) }
    )
    public private(set) var resetAnnouncements: [ProviderID: ResetAnnouncement] = [:]
    public private(set) var isRefreshing = false
    public private(set) var refreshingProviders: Set<ProviderID> = []
    public private(set) var lastUpdatedAt: Date?

    public var settings: QuotaSettings {
        didSet {
            settingsStore.save(settings)
            if oldValue.refreshInterval != settings.refreshInterval {
                restartRefreshTimer()
            }
        }
    }

    private let providers: [ProviderID: any QuotaProvider]
    private let announcementService: ResetAnnouncementService
    private let settingsStore: QuotaSettingsStoring
    private let snapshotStore: QuotaSnapshotStoring
    private var refreshTimerTask: Task<Void, Never>?
    private var refreshAllTask: Task<Void, Never>?
    private var inFlightProviderTasks: [ProviderID: Task<Bool, Never>] = [:]

    public init(
        providers: [any QuotaProvider]? = nil,
        announcementService: ResetAnnouncementService = ResetAnnouncementService(),
        settingsStore: QuotaSettingsStoring = UserDefaultsQuotaSettingsStore(),
        snapshotStore: QuotaSnapshotStoring = FileQuotaSnapshotStore()
    ) {
        let resolvedProviders = providers ?? [
            ClaudeQuotaProvider(),
            CodexQuotaProvider(),
            AntigravityQuotaProvider(),
        ]
        self.providers = Dictionary(uniqueKeysWithValues: resolvedProviders.map { ($0.providerID, $0) })
        self.announcementService = announcementService
        self.settingsStore = settingsStore
        self.snapshotStore = snapshotStore
        self.settings = settingsStore.load()
        let cachedSnapshots = snapshotStore.load()
        self.snapshots = cachedSnapshots
        self.lastUpdatedAt = cachedSnapshots.values.map(\.fetchedAt).max()
    }

    public func start() {
        restartRefreshTimer()
        Task {
            await refreshAll()
        }
    }

    public func stop() {
        refreshTimerTask?.cancel()
        refreshTimerTask = nil
    }

    /// Refreshes all enabled providers concurrently so slower CLI probes do not block fast HTTP providers.
    /// A call made while a refresh runs is skipped, unless `force` is set: then it waits for the running pass
    /// and starts a new one, so a user-requested recheck always sees the latest login state.
    public func refreshAll(force: Bool = false) async {
        if refreshAllTask != nil {
            guard force else { return }
            while let running = refreshAllTask {
                await running.value
            }
        }

        isRefreshing = true
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performRefreshAll()
            // Cleared inside the task so waiters that resume after it see no running pass.
            self.refreshAllTask = nil
            self.isRefreshing = false
        }
        refreshAllTask = task
        await task.value
    }

    private func performRefreshAll() async {
        let enabledProviders = ProviderID.allCases.filter { settings.preferences(for: $0).isEnabled }
        let disabledProviders = ProviderID.allCases.filter { !settings.preferences(for: $0).isEnabled }
        refreshingProviders.formUnion(enabledProviders)

        for providerID in disabledProviders {
            resetAnnouncements.removeValue(forKey: providerID)
        }

        let anySucceeded = await withTaskGroup(of: Bool.self) { group in
            for providerID in enabledProviders {
                group.addTask { [weak self] in
                    await self?.refreshProvider(providerID) ?? false
                }
                group.addTask { [weak self] in
                    await self?.refreshAnnouncement(for: providerID)
                    return false
                }
            }
            for providerID in disabledProviders {
                group.addTask { [weak self] in
                    await self?.probeDisabledProviderStatus(providerID)
                    return false
                }
            }

            var succeeded = false
            for await result in group where result {
                succeeded = true
            }
            return succeeded
        }

        if enabledProviders.isEmpty || anySucceeded {
            lastUpdatedAt = Date()
        }
    }

    /// Refreshes connection statuses concurrently. When `forceVerify` is false (e.g. opening Settings),
    /// existing runtime fetch errors (rate limits, API errors, login/keychain errors) are preserved
    /// instead of being overwritten by lightweight binary/file existence checks.
    public func refreshConnectionStatuses(forceVerify: Bool = false) async {
        let probed = await withTaskGroup(of: (ProviderID, ProviderConnectionStatus).self) { group in
            for providerID in ProviderID.allCases {
                guard let provider = providers[providerID] else { continue }
                group.addTask {
                    (providerID, await provider.checkConnectionStatus())
                }
            }
            var results: [(ProviderID, ProviderConnectionStatus)] = []
            for await item in group {
                results.append(item)
            }
            return results
        }

        for (providerID, status) in probed {
            let isEnabled = settings.preferences(for: providerID).isEnabled
            if !isEnabled {
                connectionStatuses[providerID] = status
            } else {
                applyPassiveStatusCheck(status, for: providerID)
            }
        }

        if forceVerify {
            await refreshAll(force: true)
        }
    }

    /// The provider's windows allowed by the user's filter. Windows whose reset has passed since the last
    /// successful fetch (offline, rate limited, or loaded from disk) are shown as reset, not with stale usage.
    public func visibleWindows(for providerID: ProviderID, now: Date = Date()) -> [QuotaWindow] {
        guard let snapshot = snapshots[providerID] else { return [] }
        let prefs = settings.preferences(for: providerID)
        return snapshot.windows
            .filter { prefs.allows($0) }
            .map { $0.resolvingPassedReset(at: now) }
    }

    /// Short and weekly window summaries for each enabled provider, in display order.
    public func usageSummaries(now: Date = Date()) -> [ProviderUsageSummary] {
        ProviderID.allCases
            .filter { settings.preferences(for: $0).isEnabled }
            .map { UsageSummaryMath.summary(for: $0, windows: visibleWindows(for: $0, now: now)) }
    }

    public func setProviderEnabled(_ enabled: Bool, for providerID: ProviderID) {
        var prefs = settings.preferences(for: providerID)
        prefs.isEnabled = enabled
        settings.providerPreferences[providerID] = prefs
        if !enabled {
            resetAnnouncements.removeValue(forKey: providerID)
            return
        }

        Task { [weak self] in
            guard let self else { return }
            async let usageSucceeded = self.refreshProvider(providerID)
            async let announcementRefresh: Void = self.refreshAnnouncement(for: providerID)
            let succeeded = await usageSucceeded
            _ = await announcementRefresh
            if succeeded {
                self.lastUpdatedAt = Date()
            }
        }
    }

    public func updatePreferences(_ transform: (inout ProviderLimitPreferences) -> Void, for providerID: ProviderID) {
        var prefs = settings.preferences(for: providerID)
        transform(&prefs)
        settings.providerPreferences[providerID] = prefs
    }

    // MARK: - Private

    @discardableResult
    private func refreshProvider(_ providerID: ProviderID) async -> Bool {
        if let existing = inFlightProviderTasks[providerID] {
            return await existing.value
        }

        guard let provider = providers[providerID] else {
            refreshingProviders.remove(providerID)
            return false
        }

        refreshingProviders.insert(providerID)
        let task = Task<Bool, Never> { [weak self] in
            guard let self else { return false }
            defer {
                self.refreshingProviders.remove(providerID)
                self.inFlightProviderTasks[providerID] = nil
            }

            do {
                let snapshot = try await provider.fetchUsage()
                self.snapshots[providerID] = snapshot
                self.snapshotStore.save(self.snapshots)
                self.connectionStatuses[providerID] = .connected
                return true
            } catch let error as QuotaProviderError {
                self.connectionStatuses[providerID] = error.connectionStatus
                AppLogger.store.warning("Provider \(providerID.rawValue) fetch error: \(String(describing: error))")
                return false
            } catch {
                self.connectionStatuses[providerID] = .error(.message(error.localizedDescription))
                AppLogger.store.warning("Provider \(providerID.rawValue) unexpected error: \(error.localizedDescription)")
                return false
            }
        }
        inFlightProviderTasks[providerID] = task
        return await task.value
    }

    private func probeDisabledProviderStatus(_ providerID: ProviderID) async {
        guard let provider = providers[providerID] else {
            connectionStatuses[providerID] = .unknown
            return
        }
        connectionStatuses[providerID] = await provider.checkConnectionStatus()
    }

    private func applyPassiveStatusCheck(_ probed: ProviderConnectionStatus, for providerID: ProviderID) {
        let current = connectionStatuses[providerID] ?? .unknown
        switch probed {
        case .notInstalled, .loginRequired, .sessionExpired, .keychainDenied:
            connectionStatuses[providerID] = probed
        case .connected:
            switch current {
            case .unknown, .notInstalled, .connected:
                connectionStatuses[providerID] = .connected
            case .loginRequired, .sessionExpired, .keychainDenied, .rateLimited, .error:
                // Keep active fetch failures until an actual fetch succeeds.
                break
            }
        case .unknown, .rateLimited, .error:
            connectionStatuses[providerID] = probed
        }
    }

    private func refreshAnnouncement(for providerID: ProviderID) async {
        let fetched = await announcementService.fetchAnnouncement(for: providerID)
        guard settings.preferences(for: providerID).isEnabled else {
            resetAnnouncements.removeValue(forKey: providerID)
            return
        }
        if let fetched {
            resetAnnouncements[providerID] = fetched
        } else {
            resetAnnouncements.removeValue(forKey: providerID)
        }
    }

    private func restartRefreshTimer() {
        refreshTimerTask?.cancel()
        let intervalSeconds = settings.refreshInterval.rawValue
        refreshTimerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(intervalSeconds))
                guard !Task.isCancelled else { break }
                await self?.refreshAll()
            }
        }
    }
}
