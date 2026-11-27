import Foundation
import HermesKit
import Observation

/// The app-wide Xunxin link (`docs/monitoring.md`): the saved settings, the one live session and
/// the last snapshot. It hangs off `AppModel`, not a gateway or a window, so switching either
/// changes nothing here and a failed connection never touches a chat.
@MainActor
@Observable
final class MonitoringModel {
    private(set) var settings: MonitoringSettings
    private(set) var hasStoredToken: Bool
    /// A settings file that couldn't be read. The app keeps running with no connection.
    private(set) var storeError: String?
    private(set) var snapshot: MonitoringSnapshot?
    private(set) var snapshotReceivedAt: Date?
    private(set) var connectionState: MonitoringConnectionState = .idle
    private(set) var isRunning = false
    /// Changes before any result from a replaced connection may be published.
    private(set) var connectionGeneration = 0

    @ObservationIgnored private var consumers: Set<UUID> = []
    @ObservationIgnored private var sessionGeneration = 0
    @ObservationIgnored private var sessionTask: Task<Void, Never>?
    @ObservationIgnored private var stoppingTask: Task<Void, Never>?
    @ObservationIgnored private var requestConsumers: [WeakRequests] = []
    @ObservationIgnored private var usesDebugConnection = false
    @ObservationIgnored private var freshnessTask: Task<Void, Never>?
    private var freshnessRevision = 0

    var presentation: MonitoringPresentation? {
        _ = freshnessRevision
        guard let snapshot else { return nil }
        return MonitoringPresentation(
            snapshot: snapshot, receivedAt: snapshotReceivedAt, now: now(), state: connectionState,
            receiptAge: snapshotReceivedUptime.map { max(0, uptime() - $0) }
        )
    }

    private final class WeakRequests {
        weak var value: MonitoringRequestsModel?
        init(_ value: MonitoringRequestsModel) { self.value = value }
    }

    fileprivate func register(_ requests: MonitoringRequestsModel) {
        requestConsumers.removeAll { $0.value == nil }
        requestConsumers.append(WeakRequests(requests))
    }

    @ObservationIgnored private let store: MonitoringSettingsStore
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let uptime: @Sendable () -> TimeInterval
    @ObservationIgnored private var snapshotReceivedUptime: TimeInterval?
    @ObservationIgnored private let makeTransport: @Sendable (MonitoringConnection) -> any MonitoringTransport
    @ObservationIgnored private let checkConnection: @Sendable (MonitoringConnection, Duration) async -> MonitoringConnectionCheck
    @ObservationIgnored private var session: MonitoringSession?
    @ObservationIgnored private var updatesTask: Task<Void, Never>?

    init(
        store: MonitoringSettingsStore = .standard(), now: @escaping @Sendable () -> Date = Date.init,
        uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        makeTransport: @escaping @Sendable (MonitoringConnection) -> any MonitoringTransport = { MonitoringClient(connection: $0) },
        checkConnection: @escaping @Sendable (MonitoringConnection, Duration) async -> MonitoringConnectionCheck = {
            await MonitoringClient(connection: $0).check(timeout: $1)
        }
    ) {
        self.store = store
        self.now = now
        self.uptime = uptime
        self.makeTransport = makeTransport
        self.checkConnection = checkConnection
        var loaded = MonitoringSettings.initial
        var problem: String?
        if Self.debugOverride == nil {
            do {
                loaded = try store.load()
            } catch {
                problem = statsError(error)
            }
        }
        let adjusted = Self.debugAdjusted(loaded)
        let debug = Self.debugOverride != nil
        settings = adjusted
        storeError = problem
        usesDebugConnection = debug
        hasStoredToken = !debug && adjusted.auth == .bearer && store.hasStoredToken()
    }

    /// `-HERMES_MONITOR_URL http://127.0.0.1:48081`: a development connection that never
    /// touches the saved one (screenshots and UI tests against the mock monitor).
    private static var debugOverride: String? {
        #if DEBUG
        if let raw = UserDefaults.standard.string(forKey: "HERMES_MONITOR_URL")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty, (try? MonitoringAddress.url(from: raw)) != nil {
            return raw
        }
        #endif
        return nil
    }

    private static func debugAdjusted(_ loaded: MonitoringSettings) -> MonitoringSettings {
        #if DEBUG
        guard let raw = debugOverride else { return loaded }
        // A development target is a separate no-auth connection, never a credential alias.
        return MonitoringSettings(
            enabled: true,
            name: UserDefaults.standard.string(forKey: "HERMES_MONITOR_NAME") ?? MonitoringSettings.initial.name,
            baseURL: raw, auth: .none
        )
        #else
        return loaded
        #endif
    }

    // MARK: - State

    /// Why the link can't connect, in the words the Stats screen shows. Nil means it can.
    var setupIssue: String? {
        guard settings.enabled else {
            return statsString("Monitoring is off. Turn it on in Settings.")
        }
        let address = settings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else {
            return statsString("Add the monitor service's address in Settings.")
        }
        do {
            _ = try connection(settings: settings, typedToken: "")
        } catch let error as MonitoringAddressError {
            return statsError(error)
        } catch {
            return statsError(error)
        }
        if settings.auth == .bearer, !hasStoredToken {
            return statsString("Add the access token in Settings.")
        }
        return nil
    }

    var isConfigured: Bool { setupIssue == nil }

    var displayName: String {
        // The stored default name is English; it reads in the app's language until renamed.
        let name = settings.displayName
        return name == MonitoringSettings.initial.name ? statsString("Xunxin monitor") : name
    }

    /// What the subtitle says after the link's name.
    var statusText: String {
        switch connectionState {
        case .idle:
            isConfigured ? statsString("Paused") : statsString("Not set up")
        case .connecting: statsString("Connecting…")
        case .live: statsString("Live")
        case .polling: statsString("Polling every 10 seconds")
        case .offline: statsString("Offline")
        case .incompatible: statsString("Incompatible service")
        }
    }

    var isSnapshotStale: Bool {
        _ = freshnessRevision
        guard let snapshotReceivedAt else { return false }
        return MonitoringFreshnessPolicy.standard.snapshotIsStale(
            receivedAt: snapshotReceivedAt, now: now(), isPolling: connectionState.isPolling
        )
    }

    // MARK: - Lifecycle

    /// Each Stats scene owns one demand token, including while setup is disabled. Repeated
    /// appearance/active callbacks are idempotent; the last foreground consumer stops the link.
    func setConsumer(_ id: UUID, active: Bool) {
        if active { consumers.insert(id) } else { consumers.remove(id) }
        reconcileSession()
    }

    private func reconcileSession() {
        guard !consumers.isEmpty, settings.enabled else {
            stop()
            return
        }
        start()
    }

    private func start() {
        guard session == nil else { return }
        guard let connection = try? connection(settings: settings, typedToken: "") else {
            connectionState = .offline(reason: setupIssue ?? statsString("Monitoring isn't set up."))
            return
        }
        let session = MonitoringSession(
            transport: makeTransport(connection),
            configuration: MonitoringSessionConfiguration(
                connection: connection, allowsStreaming: settings.liveUpdates
            ),
            now: now
        )
        self.session = session
        isRunning = true
        // One low-frequency clock shared by visible consumers, canceled with the last demand.
        freshnessTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                guard let self else { return }
                self.freshnessRevision &+= 1
            }
        }
        sessionGeneration += 1
        let generation = sessionGeneration
        let connectionGeneration = connectionGeneration
        updatesTask = Task { [weak self] in
            for await update in session.updates {
                guard let self, !Task.isCancelled,
                      generation == self.sessionGeneration,
                      connectionGeneration == self.connectionGeneration else { return }
                switch update {
                case .state(let state):
                    switch state {
                    case .offline(let reason): connectionState = .offline(reason: statsErrorText(reason))
                    case .incompatible(let reason): connectionState = .incompatible(reason: statsErrorText(reason))
                    case .polling(let reason): connectionState = .polling(reason: statsErrorText(reason))
                    default: connectionState = state
                    }
                case .snapshot(let snapshot, let receivedAt):
                    self.snapshot = snapshot
                    snapshotReceivedAt = receivedAt
                    snapshotReceivedUptime = uptime()
                    requestConsumers.removeAll { $0.value == nil }
                    for consumer in requestConsumers { consumer.value?.snapshotChanged(snapshot) }
                }
            }
        }
        // A replacement waits for the old session's stop before starting its transport.
        let stopping = stoppingTask
        sessionTask = Task {
            await stopping?.value
            guard !Task.isCancelled else { return }
            await session.start()
        }
    }

    private func stop() {
        sessionGeneration += 1
        freshnessTask?.cancel()
        freshnessTask = nil
        sessionTask?.cancel()
        let starting = sessionTask
        sessionTask = nil
        updatesTask?.cancel()
        updatesTask = nil
        let previous = stoppingTask
        if let session {
            stoppingTask = Task {
                await previous?.value
                await starting?.value
                await session.finish()
            }
        }
        session = nil
        isRunning = false
        connectionState = .idle
    }

    /// Check Again refreshes the shared session, never creates a second polling loop.
    func refresh() {
        reconcileSession()
        let session = session
        Task { await session?.refresh() }
    }

    private func invalidateConnection() {
        connectionGeneration += 1
        stop()
        snapshot = nil
        snapshotReceivedAt = nil
        snapshotReceivedUptime = nil
        requestConsumers.removeAll { $0.value == nil }
        for consumer in requestConsumers { consumer.value?.connectionChanged() }
    }

    // MARK: - Calls

    /// A page of the day's requests. The Requests screen owns the query; this only carries it.
    func recent(_ query: MonitoringRequestQuery) async throws -> MonitoringRecentPage {
        guard settings.enabled,
              let connection = try? connection(settings: settings, typedToken: "") else {
            throw MonitoringModelError.notConfigured
        }
        let generation = connectionGeneration
        let result = try await makeTransport(connection).recent(query)
        guard generation == connectionGeneration, settings.enabled, !Task.isCancelled else {
            throw CancellationError()
        }
        return result
    }

    /// The settings editor's bounded three-part check. It never touches the running session.
    func check(
        baseURL: String, auth: MonitoringAuthMode, typedToken: String, timeout: Duration = .seconds(8)
    ) async throws -> MonitoringConnectionCheck {
        let connection = try connection(baseURL: baseURL, auth: auth, typedToken: typedToken)
        let generation = connectionGeneration
        let result = await checkConnection(connection, timeout)
        guard generation == connectionGeneration, !Task.isCancelled else { throw CancellationError() }
        return result
    }

    /// The connection a draft would save, with the stored token standing in for a blank field.
    func connection(baseURL: String, auth: MonitoringAuthMode, typedToken: String) throws -> MonitoringConnection {
        let trimmed = typedToken.trimmingCharacters(in: .whitespacesAndNewlines)
        var token: String?
        if auth == .bearer, !usesDebugConnection {
            token = trimmed.isEmpty ? try store.storedToken() : trimmed
        }
        return try MonitoringConnection(baseURLString: baseURL, token: token)
    }

    private func connection(settings: MonitoringSettings, typedToken: String) throws -> MonitoringConnection {
        try connection(baseURL: settings.baseURL, auth: settings.auth, typedToken: typedToken)
    }

    /// Saves the settings and, when one was typed, the token. A failed write throws and leaves the
    /// previous configuration and token as they were (`MonitoringSettingsStore`).
    func save(_ settings: MonitoringSettings, token: String) throws {
        #if DEBUG
        if usesDebugConnection {
            // The launch override is a disposable connection, including edits made in its form.
            // It must never stage a credential or overwrite the person's saved connection.
            invalidateConnection()
            self.settings = Self.debugAdjusted(settings)
            hasStoredToken = false
            storeError = nil
            reconcileSession()
            return
        }
        #endif
        let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines)
        try store.save(settings, token: normalized.isEmpty ? nil : normalized)
        invalidateConnection()
        self.settings = Self.debugAdjusted(try store.load())
        usesDebugConnection = Self.debugOverride != nil
        hasStoredToken = !usesDebugConnection && settings.auth == .bearer && store.hasStoredToken()
        storeError = nil
        reconcileSession()
    }

    func reloadSettings() {
        #if DEBUG
        if Self.debugOverride != nil {
            let adjusted = Self.debugAdjusted(.initial)
            if adjusted != settings || !usesDebugConnection {
                invalidateConnection()
                settings = adjusted
                usesDebugConnection = true
            }
            hasStoredToken = false
            reconcileSession()
            return
        }
        #endif
        guard let loaded = try? store.load() else { return }
        let adjusted = Self.debugAdjusted(loaded)
        let debug = Self.debugOverride != nil
        if adjusted != settings || debug != usesDebugConnection {
            invalidateConnection()
            settings = adjusted
            usesDebugConnection = debug
        }
        hasStoredToken = !usesDebugConnection && settings.auth == .bearer && store.hasStoredToken()
        reconcileSession()
    }
}

enum MonitoringModelError: Error, LocalizedError {
    case notConfigured

    var errorDescription: String? {
        statsString("Monitoring isn't set up. Add the monitor service in Settings.")
    }
}

/// The Requests screen's filters, the frozen point and the loaded page. It talks to the monitor
/// service only through `MonitoringModel`, so a gateway's state never enters here.
@MainActor
@Observable
final class MonitoringRequestsModel {
    let monitoring: MonitoringModel

    var searchText = ""
    private(set) var appliedSearch = ""
    private(set) var status: MonitoringStatusFilter = .all
    private(set) var cost: MonitoringCostFilter = .any
    var minimumText = ""
    var maximumText = ""
    private(set) var sort: MonitoringRequestSort = .newest
    private(set) var page = 1
    private(set) var pageData: MonitoringRecentPage?
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var freeze: MonitoringFreeze?
    /// A day rollover's sentence, shown until the list is touched again.
    private(set) var notice: String?
    /// The last `upto` the live list was loaded at, so every 3 s snapshot doesn't reload it.
    private(set) var lastLoadedUpto: Int?

    private var generation = 0
    private var isVisible = false
    private var loadTask: Task<MonitoringRecentPage, any Error>?
    private var reloadTask: Task<Void, Never>?
    private var freezesNextPage = false

    init(monitoring: MonitoringModel) {
        self.monitoring = monitoring
        monitoring.register(self)
    }

    func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        if visible {
            if pageData == nil { scheduleLoad() }
            else { snapshotChanged(monitoring.snapshot) }
        } else {
            cancelLoad()
        }
    }

    private func cancelLoad() {
        generation += 1
        reloadTask?.cancel()
        reloadTask = nil
        loadTask?.cancel()
        loadTask = nil
        isLoading = false
    }

    fileprivate func connectionChanged() {
        cancelLoad()
        pageData = nil
        freeze = nil
        lastLoadedUpto = nil
        page = 1
        notice = nil
        error = nil
        freezesNextPage = false
    }

    private func scheduleLoad() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in await self?.load() }
    }

    var query: MonitoringRequestQuery {
        MonitoringRequestQuery(
            search: appliedSearch, status: status, cost: cost,
            minimumCost: Self.amount(minimumText), maximumCost: Self.amount(maximumText),
            sort: sort, page: page, size: 50,
            upto: freeze?.upto, day: freeze?.day
        )
    }

    var followsLive: Bool { freeze == nil && query.followsLive }

    var newerCount: Int {
        var count = pageData?.newer ?? 0
        if freeze != nil, let snapshot = monitoring.snapshot {
            count = max(count, snapshot.recentDay.count - (pageData?.dayCount ?? 0))
        }
        return max(0, count)
    }

    var amountProblem: String? {
        guard let minimum = Self.amount(minimumText), let maximum = Self.amount(maximumText) else { return nil }
        return minimum > maximum ? statsString("The lowest amount is above the highest.") : nil
    }

    var canGoBack: Bool { page > 1 && !isLoading }
    var canGoForward: Bool { (pageData?.pages ?? 1) > page && !isLoading }

    // MARK: - Loading

    func load() async {
        generation += 1
        let generation = generation
        let connectionGeneration = monitoring.connectionGeneration
        let query = query
        let followedSnapshot = monitoring.snapshot.flatMap { MonitoringFreeze($0) }
        loadTask?.cancel()
        let task = Task { try await monitoring.recent(query) }
        loadTask = task
        isLoading = true
        error = nil
        do {
            let loaded = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
            guard !Task.isCancelled, generation == self.generation,
                  connectionGeneration == monitoring.connectionGeneration else { return }
            pageData = loaded
            page = loaded.page
            isLoading = false
            loadTask = nil
            if freezesNextPage || !query.followsLive {
                freeze = MonitoringFreeze(day: loaded.day, upto: loaded.upto)
                freezesNextPage = false
            }
            if followsLive { lastLoadedUpto = loaded.upto }
            // Coalesce a snapshot that advanced during this load. A persistently lagging
            // /recent endpoint must not turn one snapshot into an unbounded request loop.
            if followedSnapshot != monitoring.snapshot.flatMap({ MonitoringFreeze($0) }) {
                snapshotChanged(monitoring.snapshot)
            }
        } catch {
            guard generation == self.generation,
                  connectionGeneration == monitoring.connectionGeneration else { return }
            isLoading = false
            loadTask = nil
            if !(error is CancellationError), !Task.isCancelled {
                self.error = statsError(error)
            }
        }
    }

    /// Only visible Requests consumers follow the already accepted shared session updates.
    /// A hidden list catches up once on reappearance, without another polling loop.
    func snapshotChanged(_ snapshot: MonitoringSnapshot?) {
        guard isVisible, let snapshot else { return }
        let day = freeze?.day ?? pageData?.day
        // /recent can cross midnight before SSE. An older accepted snapshot cannot roll a
        // newer authoritative page back to yesterday or keep restarting its load.
        if let day, snapshot.day < day { return }
        if case .rolledOver(let previous, let current) = MonitoringRollover.check(
            frozen: day, current: snapshot.day
        ) {
            cancelLoad()
            freeze = nil
            pageData = nil
            lastLoadedUpto = nil
            page = 1
            notice = statsString("The day rolled over from \(previous) to \(current). The list starts at the new day.")
            scheduleLoad()
            return
        }
        guard followsLive, !isLoading else { return }
        // A /recent response can be ahead of SSE. Never reload backwards to that older point.
        guard pageData == nil || (snapshot.recentDay.upto ?? 0) > (lastLoadedUpto ?? 0) else { return }
        scheduleLoad()
    }

    // MARK: - Changes

    func apply() {
        freezesNextPage = false
        page = 1
        notice = nil
        freezeIfNeeded()
        scheduleLoad()
    }

    func submitSearch() {
        appliedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        apply()
    }

    func setStatus(_ status: MonitoringStatusFilter) {
        self.status = status
        apply()
    }

    func setCost(_ cost: MonitoringCostFilter) {
        self.cost = cost
        apply()
    }

    func setSort(_ sort: MonitoringRequestSort) {
        self.sort = sort
        apply()
    }

    func clearFilters() {
        freezesNextPage = false
        searchText = ""
        appliedSearch = ""
        status = .all
        cost = .any
        minimumText = ""
        maximumText = ""
        sort = .newest
        page = 1
        freeze = nil
        notice = nil
        scheduleLoad()
    }

    func showNewer() {
        // Let /recent choose its current high-water atomically, then freeze to that response.
        freeze = nil
        freezesNextPage = true
        page = 1
        notice = nil
        scheduleLoad()
    }

    func nextPage() {
        guard canGoForward else { return }
        page += 1
        freezeIfNeeded()
        scheduleLoad()
    }

    func previousPage() {
        guard canGoBack else { return }
        page -= 1
        scheduleLoad()
    }

    private func freezeIfNeeded() {
        guard freeze == nil, !followsLive, let loaded = pageData else { return }
        freeze = MonitoringFreeze(day: loaded.day, upto: loaded.upto)
    }

    /// `1`, `0.25`, `1,5` as a person types it, or nil for blank or nonsense.
    private static func amount(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Double(trimmed.replacingOccurrences(of: ",", with: "."))
    }
}
