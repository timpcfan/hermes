import Foundation

/// The Requests view's filters, as the service spells them (`/api/recent`). The scope is always
/// added by `queryItems`; it is never a user choice.
public struct MonitoringRequestQuery: Sendable, Equatable {
    public var search: String
    public var status: MonitoringStatusFilter
    public var cost: MonitoringCostFilter
    public var minimumCost: Double?
    public var maximumCost: Double?
    public var sort: MonitoringRequestSort
    /// 1-based.
    public var page: Int
    public var size: Int
    /// A frozen point: only rows up to this global append position. Nil follows the newest.
    public var upto: Int?
    /// The day the frozen point belongs to; the service ignores `upto` when its day differs.
    public var day: String?

    public init(
        search: String = "", status: MonitoringStatusFilter = .all, cost: MonitoringCostFilter = .any,
        minimumCost: Double? = nil, maximumCost: Double? = nil, sort: MonitoringRequestSort = .newest,
        page: Int = 1, size: Int = 50, upto: Int? = nil, day: String? = nil
    ) {
        self.search = search
        self.status = status
        self.cost = cost
        self.minimumCost = minimumCost
        self.maximumCost = maximumCost
        self.sort = sort
        self.page = page
        self.size = size
        self.upto = upto
        self.day = day
    }

    /// The first page, no query and the default order: the one state that may follow live
    /// snapshots (PLAN, "实时更新": search, filters and paging freeze the day's point).
    public var followsLive: Bool {
        page == 1 && search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && status == .all && cost == .any && minimumCost == nil && maximumCost == nil
            && sort == .newest
    }

    public var hasFilters: Bool {
        !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || status != .all || cost != .any || minimumCost != nil || maximumCost != nil || sort != .newest
    }

    /// The service's query string, in a stable order. The scope comes first so a proxy's log
    /// reads it before the filters.
    public var queryItems: [URLQueryItem] {
        var items = [URLQueryItem(name: "scope", value: MonitoringSnapshot.scope)]
        let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { items.append(URLQueryItem(name: "q", value: trimmed)) }
        items.append(URLQueryItem(name: "st", value: status.rawValue))
        if cost != .any { items.append(URLQueryItem(name: "cost", value: cost.rawValue)) }
        if let minimumCost { items.append(URLQueryItem(name: "cmin", value: Self.number(minimumCost))) }
        if let maximumCost { items.append(URLQueryItem(name: "cmax", value: Self.number(maximumCost))) }
        items.append(URLQueryItem(name: "sort", value: sort.rawValue))
        items.append(URLQueryItem(name: "page", value: String(max(1, page))))
        items.append(URLQueryItem(name: "size", value: String(min(max(0, size), 200))))
        if let upto { items.append(URLQueryItem(name: "upto", value: String(upto))) }
        if let day, !day.isEmpty { items.append(URLQueryItem(name: "day", value: day)) }
        return items
    }

    /// A locale-independent decimal for the query: `1`, `0.25`, `0.000001`.
    static func number(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        if value.rounded() == value, abs(value) < 1e15 { return String(Int64(value)) }
        var text = String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), arguments: [value])
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    /// The same query on another page.
    public func paging(to page: Int) -> MonitoringRequestQuery {
        var copy = self
        copy.page = max(1, page)
        return copy
    }

    /// The same filters at a new frozen point.
    public func frozen(at freeze: MonitoringFreeze) -> MonitoringRequestQuery {
        var copy = self
        copy.upto = freeze.upto
        copy.day = freeze.day
        copy.page = 1
        return copy
    }
}

public enum MonitoringStatusFilter: String, Sendable, Equatable, CaseIterable, Identifiable {
    case all = "any"
    case success = "ok"
    case failed = "err"
    case cancelled = "cxl"

    public var id: String { rawValue }
}

public enum MonitoringCostFilter: String, Sendable, Equatable, CaseIterable, Identifiable {
    case any
    case priced
    case none
    case unpriced

    public var id: String { rawValue }
}

public enum MonitoringRequestSort: String, Sendable, Equatable, CaseIterable, Identifiable {
    case newest = "new"
    case oldest = "old"
    case costDescending = "cost"
    case costAscending = "cost_asc"
    case duration = "ms"

    public var id: String { rawValue }
}

/// A day and the global append position the day's list was cut at. The API's `upto` is a global
/// position, so unrelated traffic doesn't move the frozen rows.
public struct MonitoringFreeze: Sendable, Equatable {
    public var day: String
    public var upto: Int

    public init(day: String, upto: Int) {
        self.day = day
        self.upto = upto
    }

    /// The point to freeze at from a snapshot, or nil when the service doesn't say where its day
    /// ends yet (the app then stays live rather than freeze at a guessed point).
    public init?(_ snapshot: MonitoringSnapshot) {
        guard let upto = snapshot.recentDay.upto, !snapshot.day.isEmpty else { return nil }
        day = snapshot.day
        self.upto = upto
    }
}

/// What the Requests view does when the day rolls over while it is frozen (`PLAN.md`,
/// "跨零点明确提示已换日，重置冻结点").
public enum MonitoringRollover {
    public enum Outcome: Sendable, Equatable {
        /// The same business day: the frozen point stands.
        case unchanged
        /// The service's day moved past the frozen one: say so, and take a new point.
        case rolledOver(previous: String, current: String)
    }

    public static func check(frozen: String?, current: String?) -> Outcome {
        guard let current, let frozen, !frozen.isEmpty, !current.isEmpty, frozen != current else {
            return .unchanged
        }
        return .rolledOver(previous: frozen, current: current)
    }
}

/// How the source freshness fields become what the overview claims. A source that is down,
/// stale or unknown never shows a live exit or an in-flight count of zero.
public struct MonitoringFreshnessPolicy: Sendable, Equatable {
    /// The service writes a snapshot every few seconds; a source silent this long is stale.
    public var traceStaleAfter: TimeInterval
    public var probesStaleAfter: TimeInterval
    /// Usage is read from a file; a quiet file is healthy, so it may rest longer.
    public var usageStaleAfter: TimeInterval
    /// No valid snapshot for this long in stream mode marks the data stale.
    public var snapshotStaleAfter: TimeInterval
    /// Polling reads every 10 s on purpose; allow one missed beat before calling it stale.
    public var pollingStaleAfter: TimeInterval

    public init(
        traceStaleAfter: TimeInterval = 60, probesStaleAfter: TimeInterval = 60,
        usageStaleAfter: TimeInterval = 900, snapshotStaleAfter: TimeInterval = 10,
        pollingStaleAfter: TimeInterval = 20
    ) {
        self.traceStaleAfter = traceStaleAfter
        self.probesStaleAfter = probesStaleAfter
        self.usageStaleAfter = usageStaleAfter
        self.snapshotStaleAfter = snapshotStaleAfter
        self.pollingStaleAfter = pollingStaleAfter
    }

    public static let standard = MonitoringFreshnessPolicy()

    /// The age of the last valid snapshot the app received, in seconds.
    public static func snapshotAge(receivedAt: Date, now: Date) -> TimeInterval {
        max(0, now.timeIntervalSince(receivedAt))
    }

    /// Whether what is on screen is old: more than 10 s without a valid snapshot while streaming,
    /// or more than one polling beat while the app is in polling mode.
    public func snapshotIsStale(receivedAt: Date, now: Date, isPolling: Bool) -> Bool {
        let age = Self.snapshotAge(receivedAt: receivedAt, now: now)
        return age > (isPolling ? pollingStaleAfter : snapshotStaleAfter)
    }

    /// A collector's state from its freshness record and the snapshot's own server time. The
    /// source's last success is compared with the server clock, not the phone's.
    public func state(of source: MonitoringSourceFreshness, at serverTime: Double?, staleAfter: TimeInterval) -> MonitoringSourceState {
        guard let ok = source.ok else { return .unknown }
        guard ok else { return .down }
        guard let lastSuccess = source.lastSuccessAt else { return .unknown }
        // An unset snapshot clock can't prove the source current; don't call it live.
        guard let serverTime else { return .unknown }
        return serverTime - lastSuccess > staleAfter ? .stale : .live
    }

    public func traceState(_ snapshot: MonitoringSnapshot) -> MonitoringSourceState {
        guard let freshness = snapshot.freshness else {
            // A scoped service without freshness can't prove the trace is current. Its bare
            // `trace.ok` only says the last read worked, so it isn't a live claim.
            return .unknown
        }
        return state(of: freshness.trace, at: snapshot.serverTime, staleAfter: traceStaleAfter)
    }

    public func probesState(_ snapshot: MonitoringSnapshot) -> MonitoringSourceState {
        guard let freshness = snapshot.freshness else { return .unknown }
        return state(of: freshness.probes, at: snapshot.serverTime, staleAfter: probesStaleAfter)
    }

    public func usageState(_ snapshot: MonitoringSnapshot) -> MonitoringSourceState {
        guard let freshness = snapshot.freshness else { return .unknown }
        return state(of: freshness.usage, at: snapshot.serverTime, staleAfter: usageStaleAfter)
    }
}

public enum MonitoringSourceState: String, Sendable, Equatable {
    case live, stale, down, unknown

    /// A source that can be trusted for a live claim right now.
    public var isLive: Bool { self == .live }
}
