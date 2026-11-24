import Foundation

/// One page of the settled chats as Hermes answered it: only rows that say they're archived, and
/// the count of all of them (`BackendClient.archivedSessions`).
public struct SettledPage: Equatable, Sendable {
    public var sessions: [HermesSession]
    public var total: Int

    public init(sessions: [HermesSession], total: Int) {
        self.sessions = sessions
        self.total = total
    }

    init(dashboard page: DashboardSessionPage) {
        // A back-filled pin from the other side of the filter is not settled.
        let archived = page.sessions.filter(\.archived)
        self.init(sessions: archived, total: page.total ?? archived.count)
    }
}

/// The inbox's Settled region (`docs/inbox.md` §2a): Hermes' archived chats, most recently active
/// first, loaded only while the region is open, ten first and then 25 at a time. A load carries
/// the generation it started in; a page from before a reset is dropped, so a refresh and a page
/// that was on its way can't interleave.
public struct SettledList: Equatable, Sendable {
    /// The first page when the region opens.
    public static let firstPage = 10
    /// Each "Show 25 more".
    public static let morePage = 25

    public private(set) var rows: [HermesSession] = []
    /// How many settled chats Hermes has; nil until it has said.
    public private(set) var total: Int?
    /// Where the next page starts, in Hermes' order.
    public private(set) var nextOffset = 0
    public private(set) var generation = 0

    public init() {}

    /// More settled chats than are loaded.
    public var hasMore: Bool {
        guard let total else { return false }
        return nextOffset < total
    }

    /// Starts over (the region closed, or the list moved): the next page is the first, and pages
    /// on their way are dropped. Returns the generation new loads carry.
    @discardableResult
    public mutating func reset() -> Int {
        generation += 1
        rows = []
        nextOffset = 0
        return generation
    }

    /// The count alone (a `limit=1` read while the region is folded).
    public mutating func noteTotal(_ total: Int) {
        self.total = total
    }

    /// A page asked for at `offset` with `limit`, in `generation`. Returns false when it's from an
    /// older generation or no longer where the list ends, and changes nothing then.
    @discardableResult
    public mutating func apply(_ page: SettledPage, offset: Int, limit: Int, generation: Int) -> Bool {
        guard generation == self.generation, offset == nextOffset else { return false }
        let known = Set(rows.map(\.stableID))
        var seen = known
        for session in page.sessions where !seen.contains(session.stableID) {
            seen.insert(session.stableID)
            rows.append(session)
        }
        total = page.total
        nextOffset = offset + limit
        return true
    }

    /// Settled here: at the top at once, counted, and the offsets past it shift by one.
    public mutating func settledHere(_ session: HermesSession) {
        var row = session
        row.archived = true
        rows.removeAll { $0.stableID == session.stableID }
        rows.insert(row, at: 0)
        total = (total ?? 0) + 1
        nextOffset += 1
    }

    /// Un-settled here (or its settle undone): gone from the region and the count.
    public mutating func unsettledHere(_ key: String) {
        let before = rows.count
        rows.removeAll { $0.stableID == key }
        if rows.count < before { nextOffset = max(0, nextOffset - 1) }
        if let total { self.total = max(0, total - 1) }
    }

    public func session(forKey key: String) -> HermesSession? {
        rows.first { $0.stableID == key || $0.id == key }
    }
}
