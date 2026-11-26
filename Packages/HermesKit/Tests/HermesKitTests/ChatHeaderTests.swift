import Foundation
import Testing
@testable import HermesKit

@Suite("Chat header")
struct ChatHeaderTests {
    @Test func theTitleIsTheRowsThenItsFirstMessageThenTheFallback() {
        var session = HermesSession(id: "s1")
        #expect(ChatHeader.title(of: session, fallback: "New chat") == "New chat")
        #expect(ChatHeader.title(of: nil, fallback: "New chat") == "New chat")

        session.preview = "Look at this receipt"
        #expect(ChatHeader.title(of: session, fallback: "New chat") == "Look at this receipt")

        session.title = "Trip"
        #expect(ChatHeader.title(of: session, fallback: "New chat") == "Trip")
    }

    @Test func anEmptyTitleOrPreviewFallsThrough() {
        var session = HermesSession(id: "s1")
        session.title = "   "
        session.preview = ""
        #expect(ChatHeader.title(of: session, fallback: "New chat") == "New chat")
        // A compaction summary is no preview (HermesSession.listPreview drops it).
        session.title = nil
        session.preview = "[CONTEXT COMPACTION] the chat so far"
        #expect(ChatHeader.title(of: session, fallback: "New chat") == "New chat")
    }

    @Test func theProfileIsTheChatsThenTheGateways() {
        var session = HermesSession(id: "s1")
        session.profile = "researcher"
        #expect(ChatHeader.profile(of: session.profile, home: "researcher") == "researcher")
        #expect(ChatHeader.profile(of: session.profile, home: nil) == "researcher")
        #expect(ChatHeader.profile(of: nil, home: "hermes") == "hermes")
        // The gateway's own profile, when the address names none: the main one.
        #expect(ChatHeader.profile(of: nil, home: nil) == "default")
    }

    @Test func theListsProfileNameMatches() {
        var session = HermesSession(id: "s1")
        session.profile = "money"
        #expect(ProfileRows.profileName(of: session, home: "hermes") == "money")
        #expect(ProfileRows.profileName(of: session, home: "hermes") == ChatHeader.profile(of: "money", home: "hermes"))
    }
}
