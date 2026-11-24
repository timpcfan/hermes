import Foundation
import Testing
@testable import HermesKit

@Suite("Inbox scope")
struct InboxScopeTests {
    private static func session(source: String?, messages: Int? = 3, pinned: Bool = false) -> HermesSession {
        var session = HermesSession(id: UUID().uuidString)
        session.source = source
        session.messageCount = messages
        session.pinned = pinned
        return session
    }

    @Test func sourcesFallIntoTheirGroups() {
        #expect(InboxSourceGroup(source: nil) == .thisApp)
        #expect(InboxSourceGroup(source: "api_server") == .thisApp)
        #expect(InboxSourceGroup(source: " Desktop ") == .thisApp)
        #expect(InboxSourceGroup(source: "telegram") == .telegram)
        #expect(InboxSourceGroup(source: "discord") == .discord)
        #expect(InboxSourceGroup(source: "cli") == .terminal)
        #expect(InboxSourceGroup(source: "tui") == .terminal)
        #expect(InboxSourceGroup(source: "acp") == .editor)
        #expect(InboxSourceGroup(source: "cron") == .scheduled)
        #expect(InboxSourceGroup(source: "slack") == .other)
    }

    @Test func theStandardScopeHoldsEveryChatButRunsAndEmptyOnes() {
        let scope = InboxScope.standard
        #expect(scope.isStandard)
        #expect(scope.holds(Self.session(source: "telegram")))
        #expect(scope.holds(Self.session(source: nil)))
        #expect(!scope.holds(Self.session(source: "cron")))
        #expect(!scope.holds(Self.session(source: nil, messages: 0)))
        // A count Hermes didn't give isn't taken for empty.
        #expect(scope.holds(Self.session(source: nil, messages: nil)))
        #expect(!scope.narrowsMain)
        #expect(scope.changes.isEmpty)
    }

    @Test func pinnedAndRunningEmptyChatsStay() {
        let scope = InboxScope.standard
        #expect(scope.holds(Self.session(source: nil, messages: 0, pinned: true)))
        // A new chat while its first turn runs: no messages stored yet.
        #expect(scope.holds(Self.session(source: nil, messages: 0), keep: true))
    }

    @Test func hidingASourceAndShowingEmptyChats() {
        var scope = InboxScope.standard
        scope.set(.telegram, shown: false)
        scope.set(.scheduled, shown: true)
        scope.hidesEmpty = false
        #expect(!scope.holds(Self.session(source: "telegram")))
        #expect(scope.holds(Self.session(source: "cron")))
        #expect(scope.holds(Self.session(source: nil, messages: 0)))
        #expect(scope.changes == [.source(.telegram, shown: false), .source(.scheduled, shown: true), .showsEmpty])
        #expect(!scope.isStandard)
    }

    @Test func statesNarrowWithEitherOneOn() {
        var scope = InboxScope.standard
        #expect(scope.narrowsIn(unread: false, needsYou: false))
        scope.unreadOnly = true
        #expect(scope.narrowsIn(unread: true, needsYou: false))
        #expect(!scope.narrowsIn(unread: false, needsYou: true))
        scope.needsYouOnly = true
        #expect(scope.narrowsIn(unread: false, needsYou: true))
        #expect(!scope.narrowsIn(unread: false, needsYou: false))
        #expect(scope.changes == [.unread, .needsYou])
    }

    @Test func storedScopesReadLeniently() throws {
        var scope = InboxScope.standard
        scope.set(.discord, shown: false)
        scope.unreadOnly = true
        let again = try JSONDecoder().decode(InboxScope.self, from: JSONEncoder().encode(scope))
        #expect(again == scope)
        // A group this version doesn't know is dropped; missing keys take their defaults.
        let older = try JSONDecoder().decode(InboxScope.self, from: Data(#"{"hiddenSources": ["cron-ish", "discord"], "extra": 1}"#.utf8))
        #expect(older.hiddenSources == [.discord])
        #expect(older.hidesEmpty)
        #expect(!older.unreadOnly)
        let empty = try JSONDecoder().decode(InboxScope.self, from: Data("{}".utf8))
        #expect(empty == .standard)
    }
}
