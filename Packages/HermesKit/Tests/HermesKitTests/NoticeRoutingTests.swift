import Foundation
@testable import HermesKit
import HermesPush
import Testing

/// A tap on a notice opens the chat it came from; a Bot's own chat still opens the Bot
/// (`docs/notifications.md` §3). The notices are shaped as the push plugin sends them.
@Suite("Notice routing")
struct NoticeRoutingTests {
    /// Bot Mode with two Bots, the researcher's own chat known, and two chats on the list.
    private let routing = NoticeRouting(
        botChats: ["sess_researcher": "researcher", "sess_primary": "default"],
        chatKeys: ["api_1760_welcome": "api_1760_welcome", "sess_listed": "key_listed", "key_listed": "key_listed"]
    )

    private func reply(_ session: String?, profile: String? = nil) -> PushNotice {
        var notice = PushNotice(kind: .reply, id: "reply-1", thread: session ?? "", sessionID: session)
        notice.profile = profile
        return notice
    }

    @Test("A Bot's own chat opens the Bot, with or without a profile")
    func botsOwnChat() {
        #expect(routing.destination(for: reply("sess_researcher", profile: "researcher")) == .bot("researcher"))
        #expect(routing.destination(for: reply("sess_primary")) == .bot("default"))
    }

    @Test("A listed chat with a profile opens that chat, not the Bot")
    func listedChatWithProfile() {
        #expect(routing.destination(for: reply("api_1760_welcome", profile: "researcher")) == .chat("api_1760_welcome"))
        #expect(routing.destination(for: reply("sess_listed", profile: "writer")) == .chat("key_listed"))
    }

    @Test("A listed chat without a profile opens by its list key")
    func listedChatWithoutProfile() {
        #expect(routing.destination(for: reply("sess_listed")) == .chat("key_listed"))
    }

    @Test("A Bot's reply naming no chat opens the Bot")
    func profileWithoutChat() {
        #expect(routing.destination(for: reply(nil, profile: "researcher")) == .bot("researcher"))
        #expect(routing.destination(for: reply(nil)) == nil)
    }

    @Test("A chat the list doesn't hold yet opens by its id, whatever profile ran it")
    func unlistedChat() {
        // A gateway started under a profile on its own URL tags every chat with that profile, and
        // Bot Mode can list the same profile as a Bot: a chat made since the list loaded is still
        // the gateway's.
        #expect(routing.destination(for: reply("sess_new", profile: "researcher")) == .chat("sess_new"))
        #expect(routing.destination(for: reply("sess_new", profile: "work")) == .chat("sess_new"))
        #expect(routing.destination(for: reply("sess_new")) == .chat("sess_new"))
        #expect(NoticeRouting().destination(for: reply("sess_new", profile: "researcher")) == .chat("sess_new"))
    }

    @Test("A group chat's message opens the room, whoever sent it")
    func room() {
        var notice = PushNotice(kind: .message, id: "msg-1", thread: "room:r1", bot: "Ada", memberID: "writer", roomID: "r1")
        notice.profile = "writer"
        #expect(routing.destination(for: notice) == .room("r1"))
        #expect(NoticeRouting.chat(of: notice) == nil)
    }

    @Test("A card's news opens the card, even with the Bot's profile")
    func card() {
        var notice = PushNotice(kind: .cardReview, id: "card-1", thread: "main")
        notice.cardID = "c1"
        notice.board = "main"
        notice.projectID = "p1"
        notice.profile = "writer"
        #expect(routing.destination(for: notice) == .card("c1", board: "main", projectID: "p1"))
        #expect(NoticeRouting.chat(of: notice) == nil)
    }

    @Test("A tidy's report opens tidying for its Bot")
    func tidied() {
        var notice = PushNotice(kind: .tidied, id: "tidy-1")
        notice.profile = "researcher"
        #expect(routing.destination(for: notice) == .tidying(bot: "researcher"))
        #expect(routing.destination(for: PushNotice(kind: .tidied, id: "tidy-2")) == .tidying(bot: nil))
    }

    @Test("A scheduled task's notice opens Tasks", arguments: [PushNotice.Kind.task, .taskFailed])
    func task(kind: PushNotice.Kind) {
        let notice = PushNotice(kind: kind, id: "task-1", thread: "task:job1")
        #expect(routing.destination(for: notice) == .tasks)
        #expect(NoticeRouting.chat(of: notice) == nil)
    }

    /// The list holds every profile's chats (`docs/inbox.md` §9): two profiles share an id, one
    /// researcher chat is listed under its profiled key, and the gateway serves the main profile.
    private let everyProfile = NoticeRouting(
        botChats: ["sess_researcher": "researcher"],
        chatKeys: [
            "api_1760_welcome": "api_1760_welcome",
            "p:researcher:api_1760_welcome": "p:researcher:api_1760_welcome",
            "p:writer:api_2200_notes": "p:writer:api_2200_notes",
        ],
        home: "default"
    )

    @Test("Two profiles sharing an id each open their own row")
    func sharedIdAcrossProfiles() {
        #expect(everyProfile.destination(for: reply("api_1760_welcome")) == .chat("api_1760_welcome"))
        #expect(everyProfile.destination(for: reply("api_1760_welcome", profile: "default")) == .chat("api_1760_welcome"))
        #expect(everyProfile.destination(for: reply("api_1760_welcome", profile: "researcher")) == .chat("p:researcher:api_1760_welcome"))
    }

    @Test("An unlisted chat opens under its profile's key, not the bare id")
    func unlistedChatUnderItsProfile() {
        #expect(everyProfile.destination(for: reply("sess_new", profile: "researcher")) == .chat("p:researcher:sess_new"))
        // The gateway's own profile keeps the bare id, so its caches carry over.
        #expect(everyProfile.destination(for: reply("sess_new", profile: "default")) == .chat("sess_new"))
        #expect(everyProfile.destination(for: reply("sess_new")) == .chat("sess_new"))
        // A Bot's own chat still opens the Bot.
        #expect(everyProfile.destination(for: reply("sess_researcher", profile: "researcher")) == .bot("researcher"))
    }

    @Test("A gateway that serves a profile keeps that profile's chats bare")
    func homeProfileKeepsBareKeys() {
        let scoped = NoticeRouting(chatKeys: ["api_9_scoped": "api_9_scoped"], home: "work")
        #expect(scoped.destination(for: reply("api_9_scoped", profile: "work")) == .chat("api_9_scoped"))
        #expect(scoped.destination(for: reply("sess_new", profile: "work")) == .chat("sess_new"))
        #expect(scoped.destination(for: reply("sess_new", profile: "researcher")) == .chat("p:researcher:sess_new"))
        #expect(scoped.destination(for: reply("sess_new", profile: "default")) == .chat("p:default:sess_new"))
    }
}
