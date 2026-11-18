import Foundation
import Observation

/// Central state store coordinating quota fetches, per-provider smart polling, backoff, and user limit filtering.
@MainActor
@Observable
public final class QuotaStore {
    public private(set) var snapshots: [ProviderID: ProviderQuotaSnapshot] = [:]
    public private(set) var connectionStatuses: [ProviderID: ProviderConnectionStatus] = Dictionary(
        uniqueKeysWithValues: ProviderID.allCases.map { ($0, .unknown) }
    )
    public private(set) var resetAnnouncements: [ProviderID: ResetAnnouncement] = [:]
    /// Early resets seen in the app's own usage data (see `DetectedReset`).
    public private(set) var detectedResets: [ProviderID: DetectedReset] = [:]
    public private(set) var isRefreshing = false
    public private(set) var refreshingProviders: Set<ProviderID> = []
    public private(set) var lastUpdatedAt: Date?
    /// Smart polling level of each provider.
    public private(set) var refreshStates: [ProviderID: SmartRefreshState] = [:]
    /// Failure backoff of each provider's automatic fetches.
    public private(set) var backoffStates: [ProviderID: FetchBackoffState] = [:]

    public var settings: QuotaSettings {
        didSet { settingsStore.save(settings) }
    }

    /// User-initiated fetches (refresh button, opening the popover) closer together than this are skipped:
    /// the data is already fresh and back-to-back requests are what trigger 429s.
    static let userRefreshMinimumInterval: TimeInterval = 10
    /// Opening the popover only refetches data older than this; it is opened far more often than the refresh
    /// button is pressed, and Antigravity's CLI takes seconds per run.
    static let popoverRefreshMinimumInterval: TimeInterval = 60

    private let providers: [ProviderID: any QuotaProvider]
    private let announcementService: ResetAnnouncementService
    private let settingsStore: QuotaSettingsStoring
    private let snapshotStore: QuotaSnapshotStoring
    private var isStarted = false
    private var scheduledTasks: [ProviderID: Task<Void, Never>] = [:]
    private var announcementTask: Task<Void, Never>?
    private var refreshAllTask: Task<Void, Never>?
    private var inFlightProviderTasks: [ProviderID: Task<Bool, Never>] = [:]
    /// Bumped when a provider's login or enabled state changes, so a fetch that started before the change
    /// is neither reused nor allowed to write its stale result.
    private var sessionGenerations: [ProviderID: Int] = [:]
    private var inFlightGenerations: [ProviderID: Int] = [:]
    private var lastRequestAt: [ProviderID: Date] = [:]
    private var lastUserRefreshAt: Date?
    private var appNapActivity: NSObjectProtocol?

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

    /// Fetches every enabled provider now, then keeps each on its own smart schedule.
    public func start() {
        guard !isStarted else { return }
        isStarted = true
        // A menu bar app is a prime App Nap target; napping delays the polling timers for minutes.
        appNapActivity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Periodic quota refresh"
        )
        Task {
            await refreshAll()
        }
        scheduleAnnouncementRefresh()
    }

    public func stop() {
        isStarted = false
        announcementTask?.cancel()
        announcementTask = nil
        for task in scheduledTasks.values {
            task.cancel()
        }
        scheduledTasks.removeAll()
        if let appNapActivity {
            ProcessInfo.processInfo.endActivity(appNapActivity)
            self.appNapActivity = nil
        }
    }

    /// Refreshes all enabled providers concurrently so slower CLI probes do not block fast HTTP providers.
    /// A call made while a refresh runs is skipped, unless `force` is set: then it waits for the running pass
    /// and starts a new one, so a user-requested recheck always sees the latest login state.
    /// Providers still backing off are skipped unless `bypassBackoff` is set.
    public func refreshAll(force: Bool = false, bypassBackoff: Bool = false) async {
        if refreshAllTask != nil {
            guard force else { return }
            while let running = refreshAllTask {
                await running.value
            }
        }

        isRefreshing = true
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performRefreshAll(bypassBackoff: bypassBackoff)
            // Cleared inside the task so waiters that resume after it see no running pass.
            self.refreshAllTask = nil
            self.isRefreshing = false
        }
        refreshAllTask = task
        await task.value
    }

    /// The refresh button: ignores backoff and returns every provider to one-minute polling.
    public func userRefresh() async {
        let now = Date()
        if let lastUserRefreshAt, now.timeIntervalSince(lastUserRefreshAt) < Self.userRefreshMinimumInterval {
            return
        }
        lastUserRefreshAt = now
        for providerID in enabledProviderIDs {
            refreshStates[providerID, default: SmartRefreshState()].activate()
        }
        // Force: a pass already running (wake, start) may have skipped providers that are backing off.
        await refreshAll(force: true, bypassBackoff: true)
    }

    /// Opening the popover means the user is looking: poll every minute again, and fetch providers whose data
    /// is older than the minimum interval, ignoring backoff like any user action.
    public func popoverDidOpen() {
        let now = Date()
        var stale: [ProviderID] = []
        for providerID in enabledProviderIDs {
            refreshStates[providerID, default: SmartRefreshState()].activate()
            if let last = lastRequestAt[providerID], now.timeIntervalSince(last) < Self.popoverRefreshMinimumInterval {
                scheduleNextRefresh(for: providerID)
            } else {
                stale.append(providerID)
            }
        }
        guard !stale.isEmpty else { return }
        Task { [weak self] in
            await self?.refreshProviders(stale, bypassBackoff: true)
        }
    }

    /// After the Mac wakes, timers that were due during sleep fire at once; refresh now within backoff.
    public func handleSystemWake() {
        AppLogger.store.info("System woke; refreshing providers")
        Task { [weak self] in
            await self?.refreshAll()
        }
    }

    /// The app's own Claude login changed: start over with a clean schedule and fetch right away.
    public func claudeDidSignIn() {
        sessionGenerations[.claude, default: 0] += 1
        // Usage of a previous login (maybe another account) must not be compared with the new one.
        snapshots.removeValue(forKey: .claude)
        detectedResets.removeValue(forKey: .claude)
        snapshotStore.save(snapshots)
        refreshStates[.claude] = SmartRefreshState()
        backoffStates[.claude] = .initial
        connectionStatuses[.claude] = .unknown
        guard settings.preferences(for: .claude).isEnabled else { return }
        Task { [weak self] in
            await self?.refreshProviders([.claude], bypassBackoff: true)
        }
    }

    /// Drops Claude's data after sign-out so the popover does not keep showing another session's usage.
    public func claudeDidSignOut() {
        sessionGenerations[.claude, default: 0] += 1
        snapshots.removeValue(forKey: .claude)
        detectedResets.removeValue(forKey: .claude)
        snapshotStore.save(snapshots)
        refreshStates[.claude] = SmartRefreshState()
        backoffStates[.claude] = .initial
        connectionStatuses[.claude] = .loginRequired
    }

    private var enabledProviderIDs: [ProviderID] {
        ProviderID.allCases.filter { settings.preferences(for: $0).isEnabled }
    }

    private func performRefreshAll(bypassBackoff: Bool) async {
        let enabledProviders = enabledProviderIDs
        let disabledProviders = ProviderID.allCases.filter { !settings.preferences(for: $0).isEnabled }

        for providerID in disabledProviders {
            resetAnnouncements.removeValue(forKey: providerID)
        }

        await withTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                await self?.refreshProviders(enabledProviders, bypassBackoff: bypassBackoff)
            }
            group.addTask { [weak self] in
                await self?.refreshAnnouncements()
            }
            for providerID in disabledProviders {
                group.addTask { [weak self] in
                    await self?.probeDisabledProviderStatus(providerID)
                }
            }
        }

        if enabledProviders.isEmpty {
            lastUpdatedAt = Date()
        }
    }

    /// Fetches usage for the given providers concurrently.
    private func refreshProviders(_ providerIDs: [ProviderID], bypassBackoff: Bool) async {
        await withTaskGroup(of: Void.self) { group in
            for providerID in providerIDs {
                group.addTask { [weak self] in
                    _ = await self?.refreshProviderIfAllowed(providerID, bypassBackoff: bypassBackoff)
                }
            }
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
            sessionGenerations[providerID, default: 0] += 1
            resetAnnouncements.removeValue(forKey: providerID)
            detectedResets.removeValue(forKey: providerID)
            scheduledTasks.removeValue(forKey: providerID)?.cancel()
            return
        }

        refreshStates[providerID] = SmartRefreshState()
        Task { [weak self] in
            await self?.refreshProviders([providerID], bypassBackoff: true)
        }
        // Cached providers answer from the cache, so only the newly enabled one is requested.
        Task { [weak self] in
            await self?.refreshAnnouncements()
        }
    }

    public func updatePreferences(_ transform: (inout ProviderLimitPreferences) -> Void, for providerID: ProviderID) {
        var prefs = settings.preferences(for: providerID)
        transform(&prefs)
        settings.providerPreferences[providerID] = prefs
    }

    // MARK: - Private

    private func refreshProviderIfAllowed(_ providerID: ProviderID, bypassBackoff: Bool) async -> Bool {
        let backoff = backoffStates[providerID] ?? .initial
        if !bypassBackoff, !FetchBackoffPolicy.shouldFetch(backoff, now: Date()) {
            let remaining = Int((backoff.retryNotBefore?.timeIntervalSinceNow ?? 0).rounded(.up))
            AppLogger.store.info(
                "\(providerID.rawValue, privacy: .public) automatic refresh skipped: backing off \(remaining, privacy: .public)s after \(backoff.consecutiveFailures, privacy: .public) failure(s)"
            )
            scheduleNextRefresh(for: providerID)
            return false
        }
        return await refreshProvider(providerID)
    }

    @discardableResult
    private func refreshProvider(_ providerID: ProviderID) async -> Bool {
        let generation = sessionGenerations[providerID, default: 0]
        while let existing = inFlightProviderTasks[providerID] {
            if inFlightGenerations[providerID] == generation {
                return await existing.value
            }
            // Started before a sign-in or sign-out: its answer belongs to the old login, so fetch again after it.
            _ = await existing.value
        }

        guard let provider = providers[providerID] else {
            refreshingProviders.remove(providerID)
            return false
        }

        refreshingProviders.insert(providerID)
        lastRequestAt[providerID] = Date()
        let task = Task<Bool, Never> { [weak self] in
            guard let self else { return false }
            defer {
                self.refreshingProviders.remove(providerID)
                self.inFlightProviderTasks[providerID] = nil
                self.scheduleNextRefresh(for: providerID)
            }

            do {
                let snapshot = try await provider.fetchUsage()
                guard self.sessionGenerations[providerID, default: 0] == generation else { return false }
                if let previous = self.snapshots[providerID],
                   let detected = DetectedReset.detect(previous: previous, current: snapshot, now: Date())
                {
                    self.detectedResets[providerID] = detected
                    AppLogger.store.info(
                        "\(providerID.rawValue, privacy: .public) early reset detected: \(detected.windows.map(\.id).joined(separator: ","), privacy: .public)"
                    )
                }
                self.snapshots[providerID] = snapshot
                self.snapshotStore.save(self.snapshots)
                self.connectionStatuses[providerID] = .connected
                self.refreshStates[providerID, default: SmartRefreshState()].record(snapshot)
                self.backoffStates[providerID] = .initial
                self.lastUpdatedAt = Date()
                let mode = self.refreshStates[providerID]?.mode ?? .active
                AppLogger.store.info(
                    "\(providerID.rawValue, privacy: .public) fetched; next in \(Int(mode.interval), privacy: .public)s (\(String(describing: mode), privacy: .public))"
                )
                return true
            } catch {
                guard self.sessionGenerations[providerID, default: 0] == generation else { return false }
                self.recordFailure(error, for: providerID)
                return false
            }
        }
        inFlightProviderTasks[providerID] = task
        inFlightGenerations[providerID] = generation
        return await task.value
    }

    private func recordFailure(_ error: Error, for providerID: ProviderID) {
        if let providerError = error as? QuotaProviderError {
            connectionStatuses[providerID] = providerError.connectionStatus
        } else {
            connectionStatuses[providerID] = .error(.message(error.localizedDescription))
        }

        let now = Date()
        guard let failure = FetchBackoffPolicy.failure(for: error, now: now) else {
            AppLogger.store.warning(
                "\(providerID.rawValue, privacy: .public) fetch failed: \(String(describing: error), privacy: .public)"
            )
            return
        }
        let next = FetchBackoffPolicy.recordFailure(
            backoffStates[providerID] ?? .initial,
            failure: failure,
            now: now,
            jitterFraction: Double.random(in: 0...FetchBackoffPolicy.maxJitterFraction)
        )
        backoffStates[providerID] = next
        let delay = Int((next.retryNotBefore?.timeIntervalSince(now) ?? 0).rounded(.up))
        AppLogger.store.warning(
            "\(providerID.rawValue, privacy: .public) fetch failed: \(String(describing: error), privacy: .public); backing off \(delay, privacy: .public)s after \(next.consecutiveFailures, privacy: .public) failure(s)"
        )
    }

    /// Plans the provider's next automatic fetch after its smart interval, or later if it is backing off.
    /// Called after every request, so a manual or popover fetch pushes the timer back instead of letting
    /// the scheduled one follow seconds later.
    private func scheduleNextRefresh(for providerID: ProviderID) {
        scheduledTasks.removeValue(forKey: providerID)?.cancel()
        guard isStarted, settings.preferences(for: providerID).isEnabled else { return }

        // While a reset is announced as imminent, keep polling every minute so it shows up right away.
        let watching = resetAnnouncements[providerID].map { $0.kind == .watch && $0.isActive(at: Date()) } ?? false
        let interval = watching ? SmartRefreshMode.active.interval : (refreshStates[providerID] ?? SmartRefreshState()).interval
        var dueAt = Date().addingTimeInterval(interval)
        if let notBefore = backoffStates[providerID]?.retryNotBefore, notBefore > dueAt {
            dueAt = notBefore
        }
        scheduledTasks[providerID] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, dueAt.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self else { return }
            // Detach first: the fetch reschedules this provider, and cancelling the running task
            // would cancel its in-flight announcement request too.
            self.scheduledTasks[providerID] = nil
            await self.refreshProviders([providerID], bypassBackoff: false)
        }
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

    /// Fetches reset announcements for all enabled providers together, on their own slow schedule rather than
    /// with each usage refresh: they are announced hours ahead and are not usage data.
    private func refreshAnnouncements(ignoringCache: Bool = false) async {
        let enabled = enabledProviderIDs
        guard !enabled.isEmpty else { return }
        let fetched = await announcementService.fetchAnnouncements(for: enabled, ignoringCache: ignoringCache)
        for providerID in ProviderID.allCases {
            if settings.preferences(for: providerID).isEnabled, enabled.contains(providerID) {
                resetAnnouncements[providerID] = fetched[providerID]
            } else if !settings.preferences(for: providerID).isEnabled {
                resetAnnouncements.removeValue(forKey: providerID)
            }
        }
    }

    private func scheduleAnnouncementRefresh() {
        announcementTask?.cancel()
        let interval = announcementService.minimumFetchInterval
        announcementTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, let self else { return }
                // The tick lands right at the cache's edge; skip the cache so it never slips a whole period.
                await self.refreshAnnouncements(ignoringCache: true)
            }
        }
    }
}
