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

    @ObservationIgnored private let store: MonitoringSettingsStore
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var session: MonitoringSession?
    @ObservationIgnored private var updatesTask: Task<Void, Never>?

    init(store: MonitoringSettingsStore = .standard(), now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.now = now
        var loaded = MonitoringSettings.initial
        var problem: String?
        do {
            loaded = try store.load()
        } catch {
            problem = error.localizedDescription
        }
        settings = Self.debugAdjusted(loaded)
        storeError = problem
        hasStoredToken = ((try? store.storedToken()) ?? nil)?.isEmpty == false
    }

    /// `-HERMES_MONITOR_URL http://127.0.0.1:48081`: a development connection that never
    /// touches the saved one (screenshots and UI tests against the mock monitor).
    private static func debugAdjusted(_ loaded: MonitoringSettings) -> MonitoringSettings {
        #if DEBUG
        var settings = loaded
        if let raw = UserDefaults.standard.string(forKey: "HERMES_MONITOR_URL")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty, (try? MonitoringAddress.url(from: raw)) != nil {
            settings.enabled = true
            settings.baseURL = raw
            settings.name = UserDefaults.standard.string(forKey: "HERMES_MONITOR_NAME") ?? settings.name
        }
        return settings
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
            _ = try MonitoringConnection(settings: settings, token: try store.storedToken())
        } catch let error as MonitoringAddressError {
            return error.errorDescription
        } catch {
            return error.localizedDescription
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
        guard let snapshotReceivedAt else { return false }
        return MonitoringFreshnessPolicy.standard.snapshotIsStale(
            receivedAt: snapshotReceivedAt, now: now(), isPolling: connectionState.isPolling
        )
    }

    // MARK: - Lifecycle

    /// Starts the one session. Called when Stats becomes visible; a second call does nothing, so a
    /// view appearing twice can't open two streams.
    func start() {
        guard session == nil else { return }
        guard settings.enabled else {
            connectionState = .idle
            return
        }
        guard let connection = try? connection(settings: settings, typedToken: "") else {
            connectionState = .offline(reason: setupIssue ?? statsString("Monitoring isn't set up."))
            return
        }
        let client = MonitoringClient(connection: connection)
        let session = MonitoringSession(
            transport: client,
            configuration: MonitoringSessionConfiguration(
                connection: connection,
                allowsStreaming: settings.liveUpdates
            )
        )
        self.session = session
        isRunning = true
        updatesTask = Task { [weak self] in
            for await update in session.updates {
                guard let self else { return }
                switch update {
                case .state(let state):
                    connectionState = state
                case .snapshot(let snapshot, let receivedAt):
                    self.snapshot = snapshot
                    snapshotReceivedAt = receivedAt
                }
            }
        }
        Task { await session.start() }
    }

    /// Stops the stream and polling when Stats leaves the screen or the app goes away. The last
    /// snapshot stays for the next look; nothing here touches a gateway.
    func stop() {
        guard let session else { return }
        updatesTask?.cancel()
        updatesTask = nil
        self.session = nil
        isRunning = false
        connectionState = .idle
        Task { await session.stop(); await session.finish() }
    }

    /// Coming back to the foreground, or Check Again: one fresh snapshot without waiting for the
    /// stream's next correction.
    func refresh() {
        if session == nil {
            start()
            return
        }
        Task { await session?.refresh() }
    }

    private func restartSession() {
        guard isRunning else { return }
        stop()
        start()
    }

    // MARK: - Calls

    /// A page of the day's requests. The Requests screen owns the query; this only carries it.
    func recent(_ query: MonitoringRequestQuery) async throws -> MonitoringRecentPage {
        guard let connection = try? connection(settings: settings, typedToken: "") else {
            throw MonitoringModelError.notConfigured
        }
        return try await MonitoringClient(connection: connection).recent(query)
    }

    /// The settings editor's bounded three-part check. It never touches the running session.
    func check(
        baseURL: String, auth: MonitoringAuthMode, typedToken: String, timeout: Duration = .seconds(8)
    ) async throws -> MonitoringConnectionCheck {
        let connection = try connection(baseURL: baseURL, auth: auth, typedToken: typedToken)
        return await MonitoringClient(connection: connection).check(timeout: timeout)
    }

    /// The connection a draft would save, with the stored token standing in for a blank field.
    func connection(baseURL: String, auth: MonitoringAuthMode, typedToken: String) throws -> MonitoringConnection {
        let trimmed = typedToken.trimmingCharacters(in: .whitespacesAndNewlines)
        var token: String?
        if auth == .bearer {
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
        try store.save(settings, token: token)
        self.settings = Self.debugAdjusted(try store.load())
        hasStoredToken = ((try? store.storedToken()) ?? nil)?.isEmpty == false
        storeError = nil
        if !self.settings.enabled {
            snapshot = nil
            snapshotReceivedAt = nil
            connectionState = .idle
        }
        restartSession()
    }

    func reloadSettings() {
        if let loaded = try? store.load() { settings = Self.debugAdjusted(loaded) }
        hasStoredToken = ((try? store.storedToken()) ?? nil)?.isEmpty == false
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

    init(monitoring: MonitoringModel) {
        self.monitoring = monitoring
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
        isLoading = true
        error = nil
        do {
            let loaded = try await monitoring.recent(query)
            guard generation == self.generation else { return }
            pageData = loaded
            isLoading = false
            if followsLive { lastLoadedUpto = loaded.upto }
        } catch {
            guard generation == self.generation else { return }
            isLoading = false
            self.error = error.localizedDescription
        }
    }

    /// A snapshot arrived. A live list follows it; a frozen one only counts what came after its
    /// point, and a day rollover says so and starts again at the new day.
    func snapshotChanged(_ snapshot: MonitoringSnapshot?) {
        guard let snapshot else { return }
        if let freeze, case .rolledOver(let previous, let current) = MonitoringRollover.check(
            frozen: freeze.day, current: snapshot.day
        ) {
            self.freeze = nil
            page = 1
            notice = String(
                localized: "The day rolled over from \(previous) to \(current). The list starts at the new day."
            )
            Task { await load() }
            return
        }
        guard followsLive, freeze == nil else { return }
        guard snapshot.recentDay.upto != lastLoadedUpto || pageData?.day != snapshot.day else { return }
        Task { await load() }
    }

    // MARK: - Changes

    func apply() {
        page = 1
        notice = nil
        freezeIfNeeded()
        Task { await load() }
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
        Task { await load() }
    }

    func showNewer() {
        guard let snapshot = monitoring.snapshot, let point = MonitoringFreeze(snapshot) else { return }
        freeze = point
        page = 1
        notice = nil
        Task { await load() }
    }

    func nextPage() {
        guard canGoForward else { return }
        page += 1
        freezeIfNeeded()
        Task { await load() }
    }

    func previousPage() {
        guard canGoBack else { return }
        page -= 1
        Task { await load() }
    }

    private func freezeIfNeeded() {
        guard freeze == nil, !followsLive, let snapshot = monitoring.snapshot,
              let point = MonitoringFreeze(snapshot) else { return }
        freeze = point
    }

    /// `1`, `0.25`, `1,5` as a person types it, or nil for blank or nonsense.
    private static func amount(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Double(trimmed.replacingOccurrences(of: ",", with: "."))
    }
}
