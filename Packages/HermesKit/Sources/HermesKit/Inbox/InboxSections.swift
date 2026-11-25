import Foundation

/// Where a chat sits in the Chats inbox (`docs/inbox.md` §2a): the regions top to bottom.
public enum InboxRegion: Sendable, Equatable {
    /// Pinned, neither running nor settled.
    case pinned
    /// Idle, finished, stopped, or waiting on the person.
    case main
    /// A turn runs in it (sending included); pinned chats that run come here too.
    case working
    /// Marked finished by the person: Hermes' `archived` flag.
    case settled
}

/// What the list knows about a chat's turn, as sets that change only when a chat starts, stops
/// or starts waiting on the person, never with each streamed word (`docs/inbox.md` §2a).
public struct InboxActivity: Equatable, Sendable {
    /// Chats with a turn running, waiting ones included (`ActivityLine.isLive`).
    public var live: Set<String>
    /// Chats waiting on an approval, an answer or a key.
    public var needsYou: Set<String>

    public init(live: Set<String> = [], needsYou: Set<String> = []) {
        self.live = live
        self.needsYou = needsYou
    }

    /// Working: live and not waiting on the person.
    public func isWorking(_ key: String) -> Bool {
        live.contains(key) && !needsYou.contains(key)
    }
}

/// The inbox's regions, in order (`docs/inbox.md` §2a). Built in one pass over the chats, then
/// each region sorted once; counts, keyboard order, unread and the list all read the same result.
public struct InboxSections<Row> {
    public var pinned: [Row] = []
    public var main: [Row] = []
    public var working: [Row] = []
    /// Archived rows that came in with a list page anyway: Hermes back-fills pinned chats across
    /// the `archived` filter, so a page is never taken to hold one side only.
    public var settled: [Row] = []

    public init() {}

    /// The rows in list order: Pinned, Main, then Working (Settled is listed apart).
    public var ordered: [Row] { pinned + main + working }

    /// Which region a chat belongs to. Settled wins over everything (the person marked it), then
    /// waiting on the person (Main, never Working), then running, then pinned.
    public static func region(archived: Bool, pinned: Bool, key: String, activity: InboxActivity) -> InboxRegion {
        if archived { return .settled }
        if activity.isWorking(key) { return .working }
        return pinned ? .pinned : .main
    }

    /// - Parameters:
    ///   - key: the chat's stable key, as the activity sets and `returns` use.
    ///   - rowTime: the row's own time (`RowTime`).
    ///   - returns: when each chat came back to the top (`InboxReturns`).
    ///   - workingTime: Working's order, the person's last send here or else the chat's activity.
    public static func partition(
        _ rows: [Row],
        key: (Row) -> String,
        pinned: (Row) -> Bool,
        archived: (Row) -> Bool,
        activity: InboxActivity,
        returns: [String: Date],
        rowTime: (Row) -> Date?,
        workingTime: (Row) -> Date?
    ) -> InboxSections<Row> {
        var sections = InboxSections()
        var pinnedTimes: [Date] = []
        var mainTimes: [Date] = []
        var workingTimes: [Date] = []
        for row in rows {
            let rowKey = key(row)
            switch region(archived: archived(row), pinned: pinned(row), key: rowKey, activity: activity) {
            case .settled:
                sections.settled.append(row)
            case .working:
                sections.working.append(row)
                workingTimes.append(workingTime(row) ?? .distantPast)
            case .pinned:
                sections.pinned.append(row)
                pinnedTimes.append(rowTime(row) ?? .distantPast)
            case .main:
                sections.main.append(row)
                let own = rowTime(row) ?? .distantPast
                mainTimes.append(max(own, returns[rowKey] ?? .distantPast))
            }
        }
        sections.pinned = newestFirst(sections.pinned, times: pinnedTimes)
        sections.main = newestFirst(sections.main, times: mainTimes)
        sections.working = newestFirst(sections.working, times: workingTimes)
        return sections
    }

    /// Newest first; ties keep the order they came in.
    private static func newestFirst(_ rows: [Row], times: [Date]) -> [Row] {
        rows.indices.sorted { a, b in times[a] != times[b] ? times[a] > times[b] : a < b }.map { rows[$0] }
    }
}

/// Which chat opens after the open one is settled (`docs/inbox.md` §5 Settle): the next one down
/// in Main, else the one above it, else none.
public enum InboxNext {
    public static func after<Key: Equatable>(_ key: Key, in main: [Key]) -> Key? {
        guard let index = main.firstIndex(of: key) else { return main.first }
        if index + 1 < main.count { return main[index + 1] }
        return index > 0 ? main[index - 1] : nil
    }
}

/// The inbox's regions as last built, and what they were built from (`BotWorkspace.inboxSections`).
/// An equal key serves the built regions again, so the list is rebuilt only when one of these
/// changed — never because a row was selected (`docs/inbox.md` §9).
public struct InboxSectionsCache<Row> {
    public struct Key: Equatable {
        public var sessions: Int
        public var activity: InboxActivity
        public var returns: [String: Date]
        public var lines: Int
        public var scope: InboxScope
        /// What the filter reads besides the list (the unread badges under Unread).
        public var filterInputs: Int
        public var waiting: [String]

        public init(sessions: Int, activity: InboxActivity, returns: [String: Date], lines: Int,
                    scope: InboxScope, filterInputs: Int, waiting: [String]) {
            self.sessions = sessions
            self.activity = activity
            self.returns = returns
            self.lines = lines
            self.scope = scope
            self.filterInputs = filterInputs
            self.waiting = waiting
        }
    }

    public let key: Key
    public let sections: InboxSections<Row>

    public init(key: Key, sections: InboxSections<Row>) {
        self.key = key
        self.sections = sections
    }
}
