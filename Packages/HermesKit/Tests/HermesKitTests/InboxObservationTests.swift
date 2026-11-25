import Foundation
import Observation
import Testing
@testable import HermesKit

/// The list is built once per change to what it reads, never per row drawn, and never because a
/// row was selected (`docs/inbox.md` §9). The workspace's own cache and scope are these types, so
/// the rule is proven here on the same code the app runs: `InboxSectionsCache`, `InboxScope.holds`
/// and `InboxSections.partition`, wired the way `BotWorkspace.inboxSections` wires them.
@Suite("Inbox observation")
struct InboxObservationTests {
    /// onChange runs on the thread that makes the change, so a flag read right after it is enough.
    private final class Flag: @unchecked Sendable {
        var fired = false
    }

    /// The workspace's shape, at the size the list reads it: revisions and sets, not the rows
    /// themselves, plus the selection the chat screen reads and the list must not.
    // @Observable expands to a file-level extension, so the class can't be private.
    @Observable
    final class ListModel {
        var selection: String?
        var scope = InboxScope.standard
        var sessionsRevision = 0
        var badgesRevision = 0
        var linesRevision = 0
        var activity = InboxActivity()
        var returns: [String: Date] = [:]
        var waiting: [String] = []
        var rows: [HermesSession] = []
        var unread: Set<String> = []
        /// What the cache holds isn't observed: a read that fills it must not dirty the list.
        @ObservationIgnored var cache: InboxSectionsCache<HermesSession>?
        @ObservationIgnored var builds = 0

        var inboxSections: InboxSections<HermesSession> {
            let key = InboxSectionsCache<HermesSession>.Key(
                sessions: sessionsRevision, activity: activity, returns: returns,
                lines: linesRevision, scope: scope,
                filterInputs: scope.unreadOnly ? badgesRevision : 0, waiting: waiting
            )
            if let cache, cache.key == key { return cache.sections }
            builds += 1
            let sections = build(activity: key.activity)
            cache = InboxSectionsCache(key: key, sections: sections)
            return sections
        }

        private func build(activity: InboxActivity) -> InboxSections<HermesSession> {
            let kept = rows.filter { row in
                scope.holds(row, keep: activity.live.contains(row.stableID), home: "default")
            }
            var sections = InboxSections.partition(
                kept, key: \.stableID, pinned: \.pinned, archived: \.archived, activity: activity,
                returns: returns, rowTime: { $0.activityDate }, workingTime: { $0.activityDate }
            )
            if scope.narrowsMain {
                sections.main = sections.main.filter { row in
                    scope.narrowsIn(unread: unread.contains(row.stableID),
                                    needsYou: activity.needsYou.contains(row.stableID))
                }
            }
            return sections
        }
    }

    private static let base = Date(timeIntervalSince1970: 1_760_600_000)

    private static func row(_ id: String, profile: String? = nil, ago: Double = 0) -> HermesSession {
        var session = HermesSession(id: id, title: id, startedAt: base.addingTimeInterval(-ago),
                                    lastActive: base.addingTimeInterval(-ago), messageCount: 2)
        session.profile = profile
        return session
    }

    private static func model() -> ListModel {
        let model = ListModel()
        // Two profiles share `welcome`: the gateway's own row keeps its key, the other's is namespaced.
        model.rows = ProfileRows.tagged([
            row("welcome", ago: 10), row("welcome", profile: "researcher", ago: 20),
            row("budget", profile: "researcher", ago: 30), row("notes", profile: "writer", ago: 40),
        ], home: "default")
        return model
    }

    /// Reads the list under observation, makes one change, and reports whether the list was told.
    private static func fires(_ model: ListModel, _ change: (ListModel) -> Void) -> Bool {
        let flag = Flag()
        withObservationTracking {
            _ = model.inboxSections
        } onChange: {
            flag.fired = true
        }
        change(model)
        return flag.fired
    }

    // MARK: Selection

    @Test func selectingARowDoesNotDirtyTheList() {
        let model = Self.model()
        #expect(model.inboxSections.ordered.count == 4)
        #expect(model.builds == 1)
        // Opening a chat, then another, then closing: the list is told nothing and rebuilds nothing.
        #expect(!Self.fires(model) { $0.selection = "welcome" })
        #expect(!Self.fires(model) { $0.selection = "p:researcher:welcome" })
        #expect(!Self.fires(model) { $0.selection = nil })
        #expect(model.inboxSections.ordered.count == 4)
        #expect(model.builds == 1)
    }

    @Test func anUnchangedRefreshServesTheBuiltRegionsAgain() {
        let model = Self.model()
        let first = model.inboxSections
        // The revisions the cache reads are the same, so the regions come back as they were built.
        let again = model.inboxSections
        #expect(again.ordered.map(\.stableID) == first.ordered.map(\.stableID))
        #expect(model.builds == 1)
    }

    // MARK: What the list does read

    @Test func theFilterRebuildsTheList() {
        let model = Self.model()
        #expect(Self.fires(model) { $0.scope.profile = "researcher" })
        #expect(model.inboxSections.ordered.map(\.stableID) == ["p:researcher:welcome", "p:researcher:budget"])
        #expect(Self.fires(model) { $0.scope = .standard })
        #expect(model.inboxSections.ordered.count == 4)
    }

    @Test func aNewListPageRebuildsTheList() {
        let model = Self.model()
        #expect(model.inboxSections.ordered.count == 4)
        #expect(Self.fires(model) { $0.sessionsRevision &+= 1 })
        #expect(model.inboxSections.ordered.count == 4)
        #expect(model.builds == 2)
    }

    @Test func aTurnStartingOrWaitingRebuildsTheList() {
        let model = Self.model()
        let budget = "p:researcher:budget"
        #expect(Self.fires(model) { $0.activity = InboxActivity(live: [budget]) })
        #expect(model.inboxSections.working.map(\.stableID) == [budget])
        #expect(Self.fires(model) { $0.activity = InboxActivity(live: [budget], needsYou: [budget]) })
        #expect(model.inboxSections.working.isEmpty)
    }

    @Test func aNewLastLineOrReturnTimeRebuildsTheList() {
        let model = Self.model()
        #expect(Self.fires(model) { $0.linesRevision &+= 1 })
        #expect(Self.fires(model) { $0.returns = ["p:writer:notes": Self.base] })
        #expect(model.inboxSections.main.first?.stableID == "p:writer:notes")
        #expect(Self.fires(model) { $0.waiting = ["p:writer:new"] })
    }

    @Test func unreadBadgesRebuildOnlyWhileUnreadNarrowsTheList() {
        let model = Self.model()
        let notes = "p:writer:notes"
        model.unread = [notes]
        // Under All, the badges are the rows' own marks: the regions don't read them.
        #expect(!Self.fires(model) { $0.badgesRevision &+= 1 })
        #expect(model.builds == 1)
        model.scope.unreadOnly = true
        #expect(model.inboxSections.main.map(\.stableID) == [notes])
        // Under Unread they narrow Main, so a badge changing rebuilds it.
        #expect(Self.fires(model) { $0.badgesRevision &+= 1 })
        model.unread = []
        #expect(model.inboxSections.main.isEmpty)
    }

    // MARK: Every profile's rows

    @Test func twoProfilesSharingAnIDStayTwoRows() {
        let model = Self.model()
        let keys = model.inboxSections.ordered.map(\.stableID)
        #expect(keys.contains("welcome"))
        #expect(keys.contains("p:researcher:welcome"))
        #expect(Set(keys).count == keys.count)
        // Selecting one of the pair leaves the other listed, and rebuilds nothing.
        #expect(!Self.fires(model) { $0.selection = "p:researcher:welcome" })
        #expect(model.inboxSections.ordered.map(\.stableID) == keys)
    }

    @Test func theCacheKeyHoldsEveryInputAndNoSelection() {
        let key = InboxSectionsCache<HermesSession>.Key(
            sessions: 1, activity: InboxActivity(), returns: [:], lines: 0,
            scope: .standard, filterInputs: 0, waiting: []
        )
        #expect(key == InboxSectionsCache<HermesSession>.Key(
            sessions: 1, activity: InboxActivity(), returns: [:], lines: 0,
            scope: .standard, filterInputs: 0, waiting: []
        ))
        var scope = InboxScope.standard
        scope.profile = "researcher"
        #expect(key != InboxSectionsCache<HermesSession>.Key(
            sessions: 1, activity: InboxActivity(), returns: [:], lines: 0,
            scope: scope, filterInputs: 0, waiting: []
        ))
        #expect(key != InboxSectionsCache<HermesSession>.Key(
            sessions: 1, activity: InboxActivity(live: ["a"]), returns: [:], lines: 0,
            scope: .standard, filterInputs: 0, waiting: []
        ))
        #expect(key != InboxSectionsCache<HermesSession>.Key(
            sessions: 1, activity: InboxActivity(), returns: ["a": Self.base], lines: 0,
            scope: .standard, filterInputs: 0, waiting: []
        ))
        #expect(key != InboxSectionsCache<HermesSession>.Key(
            sessions: 1, activity: InboxActivity(), returns: [:], lines: 0,
            scope: .standard, filterInputs: 0, waiting: ["a"]
        ))
    }
}