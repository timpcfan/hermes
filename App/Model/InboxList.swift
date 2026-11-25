import Foundation
import HermesKit
#if os(iOS)
import UIKit
#endif

/// The filter's source groups and states as the menu and the "Filtered:" line name them
/// (`docs/inbox.md` §5).
extension InboxSourceGroup {
    var title: String {
        switch self {
        case .thisApp: String(localized: "This App")
        case .telegram: String(localized: "Telegram")
        case .discord: String(localized: "Discord")
        case .terminal: String(localized: "Terminal")
        case .editor: String(localized: "Editor")
        case .scheduled: String(localized: "Scheduled")
        case .other: String(localized: "Other Platforms")
        }
    }

    var symbol: String {
        switch self {
        case .thisApp:
            #if os(macOS)
            "macbook"
            #else
            UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
            #endif
        case .telegram: "paperplane"
        case .discord: "gamecontroller"
        case .terminal: "terminal"
        case .editor: "chevron.left.forwardslash.chevron.right"
        case .scheduled: "calendar.badge.clock"
        case .other: "bubble.left.and.bubble.right"
        }
    }
}

extension InboxScope.Change {
    var title: String {
        switch self {
        case .source(let group, let shown): shown ? group.title : String(localized: "No \(group.title)")
        case .unread: String(localized: "Unread")
        case .needsYou: String(localized: "Needs You")
        case .showsEmpty: String(localized: "Empty Chats")
        case .profile(let name): name
        }
    }
}

extension InboxScope {
    /// "No Telegram · Unread": what the filter changes, for its line and its button.
    var summary: String { changes.map(\.title).joined(separator: " · ") }

    private static func key(_ id: UUID) -> String { "inboxScope.\(id.uuidString)" }

    /// The filter kept for this gateway. `-HERMES_INBOX_SCOPE <json>` starts with another one, for
    /// screenshots.
    static func stored(for gateway: UUID) -> InboxScope {
        var data = UserDefaults.standard.data(forKey: key(gateway))
        #if DEBUG
        if let flag = UserDefaults.standard.string(forKey: "HERMES_INBOX_SCOPE") { data = Data(flag.utf8) }
        #endif
        return data.flatMap { try? JSONDecoder().decode(InboxScope.self, from: $0) } ?? .standard
    }

    func store(for gateway: UUID) {
        UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: Self.key(gateway))
    }
}

extension BotWorkspace {
    /// The chats in the list, region by region: Pinned, Main, Working (`docs/inbox.md` §2a).
    /// Settled is listed apart (`settledSessions`).
    var inboxSessions: [HermesSession] { inboxSections.ordered }

    /// The Chats inbox's regions (`docs/inbox.md` §2a). The filter picks which sources it holds
    /// and whether empty chats hide, and Unread or Needs You narrow Main (`docs/inbox.md` §5);
    /// every chat it holds is listed, as this build has no projects to keep some apart
    /// (`docs/projects.md`).
    ///
    /// Built once per change to what it reads, never per row drawn: the list, which chats run or
    /// wait (sets that move only when one starts, stops or starts waiting, not with each streamed
    /// word), the return times, the last lines and the filter. The selection isn't among them.
    var inboxSections: InboxSections<HermesSession> {
        let key = InboxSectionsCache.Key(
            sessions: sessionsRevision, activity: activity.inbox, returns: inboxReturns,
            lines: unread.linesRevision, scope: inboxScope,
            filterInputs: inboxScope.unreadOnly ? unread.badgesRevision : 0, waiting: waitingChats.map(\.key)
        )
        if let sectionsCache, sectionsCache.key == key { return sectionsCache.sections }
        let sections = buildSections(activity: key.activity)
        sectionsCache = InboxSectionsCache(key: key, sections: sections)
        return sections
    }

    private func buildSections(activity: InboxActivity) -> InboxSections<HermesSession> {
        let scope = inboxScope
        var rows = allSessions.filter { holds($0, live: activity.live) }
        // New chats whose first message waits for the gateway (`docs/chat.md` §4). They are this
        // app's, so they show wherever this app's chats do; sending, they sit in Working.
        if scope.shows(.thisApp), !waitingChats.isEmpty {
            rows += WaitingChat.rows(waitingChats, listed: Set(sessions.map(\.stableID)))
        }
        let returns = inboxReturns
        var sections = InboxSections.partition(
            rows, key: \.stableID, pinned: \.pinned, archived: \.archived, activity: activity, returns: returns,
            rowTime: { self.rowTime($0, live: activity.live) },
            workingTime: { session in
                [self.lastSentAt[session.stableID], session.lastActive].compactMap(\.self).max()
            }
        )
        // Unread and Needs You narrow Main only: what's pinned, running or settled stays in view.
        if scope.narrowsMain {
            sections.main = sections.main.filter { session in
                let key = session.stableID
                return scope.narrowsIn(unread: unread.badge(for: key).isUnread, needsYou: activity.needsYou.contains(key))
            }
        }
        return sections
    }

    /// Whether the filter holds a chat. An empty chat stays while a turn runs in it or the person
    /// sent in it here: a new chat has no stored messages until its first lands.
    private func holds(_ session: HermesSession, live: Set<String>) -> Bool {
        let key = session.stableID
        return inboxScope.holds(session, keep: live.contains(key) || lastSentAt[key] != nil, home: bot.profileName)
    }

    /// A chat's time on its row and in the order (`RowTime`, `docs/inbox.md` §2): its last line's
    /// message, standing at its activity only while a turn runs in it.
    func rowTime(_ session: HermesSession) -> Date? {
        rowTime(session, live: activity.inbox.live)
    }

    /// A row's time when the row already knows whether its chat runs (its own line): it doesn't
    /// then follow every chat's start and stop.
    func rowTime(_ session: HermesSession, isLive: Bool) -> Date? {
        RowTime.of(line: unread.lastLines[session.stableID], live: isLive, activity: session.lastActive, created: session.startedAt)
    }

    private func rowTime(_ session: HermesSession, live: Set<String>) -> Date? {
        rowTime(session, isLive: live.contains(session.stableID))
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
        let session = settled.session(forKey: key) ?? session(forKey: key) ?? HermesSession.placeholder(forKey: key)
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
    func publishReturns() {
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

    /// The filter holds no chat at all, new ones included, while the gateway has some: its empty
    /// state. With no chats at all, "No chats yet" says so instead.
    var scopeHoldsNothing: Bool {
        !allSessions.isEmpty && !hasMoreSessions && !allSessions.contains { holds($0, live: activity.inbox.live) }
            && (waitingChats.isEmpty || !inboxScope.shows(.thisApp))
    }

    /// How many listed chats are unread, and how many wait on the person, for the menu's counts.
    /// Read when the menu opens, not as the list draws.
    func stateCounts() -> (unread: Int, needsYou: Int) {
        let sections = inboxSections
        let rows = sections.ordered
        let unreadCount = rows.reduce(0) { unread.badge(for: $1.stableID).isUnread ? $0 + 1 : $0 }
        let needsYou = rows.reduce(0) { activity.inbox.needsYou.contains($1.stableID) ? $0 + 1 : $0 }
        return (unreadCount, needsYou)
    }

    /// The unread chats the inbox lists, Pinned, then Main, then Working, for Mark All as Read.
    var unreadChatKeys: [String] {
        inboxSections.ordered.map(\.stableID).filter { unread.badge(for: $0).isUnread }
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
        var scope: InboxScope
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
