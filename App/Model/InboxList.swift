import Foundation
import HermesKit

/// The filters over the chat list (`filterChip`, `docs/inbox.md` §5).
enum InboxFilter: String, CaseIterable {
    case all, unread, needsYou, running

    var title: String {
        switch self {
        case .all: String(localized: "All")
        case .unread: String(localized: "Unread")
        case .needsYou: String(localized: "Needs You")
        case .running: String(localized: "Running")
        }
    }
}

/// Show's choices, as the filter menu names them (`inboxFilterMenu`, `docs/inbox.md` §5).
extension InboxShow {
    var title: String {
        switch self {
        case .thisApp: String(localized: "This App")
        case .all: String(localized: "All Chats")
        case .otherPlatforms: String(localized: "Other Platforms")
        case .scheduled: String(localized: "Scheduled Tasks")
        }
    }

    /// Each launch starts with this app's chats. `-HERMES_INBOX_SHOW all|otherPlatforms|scheduled`
    /// starts with another choice, for screenshots.
    static var atLaunch: InboxShow {
        #if DEBUG
        UserDefaults.standard.string(forKey: "HERMES_INBOX_SHOW").flatMap(InboxShow.init(rawValue:)) ?? .thisApp
        #else
        .thisApp
        #endif
    }
}

extension BotWorkspace {
    /// The chats in the list, region by region: Pinned, Main, Working (`docs/inbox.md` §2a).
    /// Settled is listed apart (`settledSessions`).
    var inboxSessions: [HermesSession] { inboxSections.ordered }

    /// The Chats inbox's regions (`docs/inbox.md` §2a). Show picks where the chats come from,
    /// this app's by default (`docs/inbox.md` §5); every chat it holds is listed, as this build has
    /// no projects to keep some apart (`docs/projects.md`). Scheduled runs are in it only under
    /// Scheduled Tasks (`ScheduledRuns`).
    ///
    /// Built once per change to what it reads, never per row drawn: the list, which chats run or
    /// wait (sets that move only when one starts, stops or starts waiting, not with each streamed
    /// word), the return times, the last lines and the filter. The selection isn't among them.
    var inboxSections: InboxSections<HermesSession> {
        let key = InboxSectionsCache.Key(
            sessions: sessionsRevision, activity: activity.inbox, returns: inboxReturns,
            lines: unread.linesRevision, show: inboxShow, filter: inboxFilter,
            filterInputs: inboxFilter == .unread ? unread.badgesRevision : 0, waiting: waitingChats.map(\.key)
        )
        if let sectionsCache, sectionsCache.key == key { return sectionsCache.sections }
        let sections = buildSections(activity: key.activity)
        sectionsCache = InboxSectionsCache(key: key, sections: sections)
        return sections
    }

    private func buildSections(activity: InboxActivity) -> InboxSections<HermesSession> {
        var rows = allSessions.filter { shows($0) && matches(inboxFilter, key: $0.stableID, activity: activity) }
        // New chats whose first message waits for the gateway (`docs/chat.md` §4). They are this
        // app's, so they show wherever this app's chats do; sending, they sit in Working.
        if inboxFilter == .all, inboxShow.includes(.thisApp), !waitingChats.isEmpty {
            rows += WaitingChat.rows(waitingChats, listed: Set(sessions.map(\.stableID)))
        }
        let returns = inboxReturns
        return InboxSections.partition(
            rows, key: \.stableID, pinned: \.pinned, archived: \.archived, activity: activity, returns: returns,
            rowTime: { self.rowTime($0, live: activity.live) },
            workingTime: { session in
                [self.lastSentAt[session.stableID], session.lastActive].compactMap(\.self).max()
            }
        )
    }

    /// A chat's time on its row and in the order (`RowTime`, `docs/inbox.md` §2): its last line's
    /// message, standing at its activity only while a turn runs in it.
    func rowTime(_ session: HermesSession) -> Date? {
        rowTime(session, live: activity.inbox.live)
    }

    private func rowTime(_ session: HermesSession, live: Set<String>) -> Date? {
        let key = session.stableID
        return RowTime.of(line: unread.lastLines[key], live: live.contains(key),
                          activity: session.lastActive, created: session.startedAt)
    }

    // MARK: Returns (`docs/inbox.md` §2a)

    private static func returnsKey(_ id: UUID) -> String { "inboxReturns.\(id.uuidString)" }

    /// The return times kept on this device, so a cold launch keeps Main's order.
    func restoreReturns() {
        returnTracker = InboxReturns.decoded(UserDefaults.standard.data(forKey: Self.returnsKey(id)))
        inboxReturns = returnTracker.times
    }

    /// What the chats are doing changed (`LiveActivity`): chats that started waiting on the
    /// person or stopped return now; finished ones after a short grace.
    func noteActivity(_ phases: [String: InboxReturns.Phase]) {
        returnTracker.observe(phases, now: .now)
        publishReturns()
        scheduleReturnGrace()
    }

    /// Un-settled, or sent in from Settled: back at the top of Main.
    func noteReturned(_ key: String) {
        returnTracker.returned(key, at: .now)
        publishReturns()
    }

    /// The person sent in a chat here: Working's order.
    func noteSent(_ key: String) {
        lastSentAt[key] = .now
    }

    // MARK: Settled (`docs/inbox.md` §2a)

    /// Whether the app knows this chat as settled: listed in Settled, opened from search as one,
    /// or back-filled into the chat list with `archived`.
    func isSettled(_ key: String) -> Bool {
        settled.contains(key) || session(forKey: key)?.archived == true
    }

    /// The chat being sent in is settled: un-settle it, fire and forget (S3). The send goes ahead
    /// whatever Hermes answers; a failure leaves it settled.
    func unsettleBeforeSend(_ key: String) {
        guard isSettled(key) else { return }
        let session = settled.session(forKey: key) ?? session(forKey: key) ?? HermesSession(id: key)
        Task { try? await unarchive(session) }
    }

    /// The chat to settle or un-settle from the menu bar (⇧⌘S): the open one.
    var openSettleTarget: HermesSession? {
        guard case .session(let key) = selection, waitingChat(forKey: key) == nil else { return nil }
        return session(forKey: key) ?? settled.session(forKey: key)
    }

    /// ⇧⌘S: settles the open chat, or un-settles it when it's settled.
    func toggleOpenChatSettled() async throws {
        guard let session = openSettleTarget else { return }
        if isSettled(session.stableID) {
            try await unarchive(session)
        } else {
            try await archive(session)
        }
    }

    private func scheduleReturnGrace() {
        returnGrace?.cancel()
        guard let deadline = returnTracker.nextDeadline else { return }
        returnGrace = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow) + 0.05))
            guard let self, !Task.isCancelled else { return }
            self.returnTracker.settle(now: .now)
            self.publishReturns()
            self.scheduleReturnGrace()
        }
    }

    /// Only chats still listed keep a time; the rest go when the list is next saved.
    private func publishReturns() {
        let listed = Set(allSessions.map(\.stableID))
        if hasFetchedSessions { returnTracker.prune(keeping: listed) }
        let times = returnTracker.times
        guard times != inboxReturns else { return }
        inboxReturns = times
        returnsSave?.cancel()
        returnsSave = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled else { return }
            UserDefaults.standard.set(self.returnTracker.encoded(), forKey: Self.returnsKey(self.id))
        }
    }

    /// Whether Show holds a chat (`docs/inbox.md` §5).
    func shows(_ session: HermesSession) -> Bool {
        inboxShow.shows(session)
    }

    /// Show holds no chat at all, new ones included, while the gateway has some: the
    /// Show empty state (`caughtUpThisApp`…). With no chats at all, "No chats yet" says so instead.
    var showHoldsNothing: Bool {
        !allSessions.isEmpty && !hasMoreSessions && !allSessions.contains(where: shows)
            && (waitingChats.isEmpty || !inboxShow.includes(.thisApp))
    }

    func matches(_ filter: InboxFilter, key: String) -> Bool {
        matches(filter, key: key, activity: activity.inbox)
    }

    private func matches(_ filter: InboxFilter, key: String, activity: InboxActivity) -> Bool {
        switch filter {
        case .all: true
        case .unread: unread.badge(for: key).isUnread
        case .needsYou: activity.needsYou.contains(key)
        case .running: activity.isWorking(key)
        }
    }

    /// How many of the chats Show holds a filter would show.
    func count(for filter: InboxFilter) -> Int {
        allSessions.reduce(0) { shows($1) && matches(filter, key: $1.stableID) ? $0 + 1 : $0 }
    }

    /// The unread chats Show holds, for Mark All as Read.
    var unreadChatKeys: [String] {
        allSessions.filter(shows).map(\.stableID).filter { unread.badge(for: $0).isUnread }
    }

    /// ⌥⌘↓ / ⌥⌘↑: the next or previous unread chat (or Bot) along the list.
    func selectAdjacentUnread(_ step: Int) {
        let order = sidebarOrder
        let unreadItems = order.filter { item in
            switch item {
            case .session(let key): unread.badge(for: key).isUnread
            case .bot(let name): unread.badge(for: UnreadStore.botKey(name)).isUnread
            case .group(let id): unread.badge(for: UnreadStore.groupKey(id)).isUnread
            default: false
            }
        }
        guard !unreadItems.isEmpty else { return }
        let current = selection.flatMap { order.firstIndex(of: $0) } ?? (step > 0 ? -1 : order.count)
        let next = step > 0
            ? unreadItems.first { order.firstIndex(of: $0)! > current } ?? unreadItems.first
            : unreadItems.last { order.firstIndex(of: $0)! < current } ?? unreadItems.last
        selection = next
    }

    /// The open chat's inbox key and whether it's unread, for ⇧⌘U.
    func toggleOpenChatRead() {
        guard let key = unread.openKey else { return }
        if unread.readMark(for: key) == .markedUnread || unread.badge(for: key).isUnread {
            unread.markRead(key)
        } else {
            unread.markUnread(key)
            // Marked unread: it reads as new next time; the chat stays open meanwhile.
        }
    }
}

/// The inbox's regions as last built, and what they were built from (`BotWorkspace.inboxSections`).
struct InboxSectionsCache {
    struct Key: Equatable {
        var sessions: Int
        var activity: InboxActivity
        var returns: [String: Date]
        var lines: Int
        var show: InboxShow
        var filter: InboxFilter
        /// What the filter reads besides the list (the unread badges under Unread).
        var filterInputs: Int
        var waiting: [String]
    }

    let key: Key
    let sections: InboxSections<HermesSession>
}

extension SidebarItem {
    /// A project's home, its Board or All Projects: screens this build doesn't have
    /// (`docs/projects.md`). A window restored onto one, or a launch flag naming one, opens nothing.
    var isProjectScreen: Bool {
        switch self {
        case .project, .board, .allProjects: true
        default: false
        }
    }
}
