import Foundation
import Testing
@testable import HermesKit

@Suite("Inbox sections")
struct InboxSectionsTests {
    private static let base = Date(timeIntervalSince1970: 1_760_600_000)
    private static func t(_ seconds: Double) -> Date { base.addingTimeInterval(seconds) }

    private struct Row: Equatable {
        var key: String
        var pinned = false
        var archived = false
        var time: Double = 0
        var sent: Double?
    }

    private static func partition(_ rows: [Row], live: Set<String> = [], needsYou: Set<String> = [], returns: [String: Date] = [:]) -> InboxSections<Row> {
        InboxSections.partition(
            rows, key: \.key, pinned: \.pinned, archived: \.archived,
            activity: InboxActivity(live: live, needsYou: needsYou), returns: returns,
            rowTime: { t($0.time) }, workingTime: { $0.sent.map(t) ?? t($0.time) }
        )
    }

    // MARK: Regions

    @Test func eachChatHasOneRegionByPriority() {
        let activity = InboxActivity(live: ["run", "ask", "pinrun"], needsYou: ["ask"])
        func region(_ key: String, pinned: Bool = false, archived: Bool = false) -> InboxRegion {
            InboxSections<Row>.region(archived: archived, pinned: pinned, key: key, activity: activity)
        }
        #expect(region("idle") == .main)
        #expect(region("run") == .working)
        // Waiting on the person is Main, never Working.
        #expect(region("ask") == .main)
        #expect(region("ask", pinned: true) == .pinned)
        // A pinned chat that runs goes to Working.
        #expect(region("pinrun", pinned: true) == .working)
        // Settled wins over everything, a running chat included.
        #expect(region("run", archived: true) == .settled)
        #expect(region("idle", pinned: true, archived: true) == .settled)
    }

    @Test func archivedRowsBackFilledIntoAPageLeaveTheOtherRegions() {
        // Hermes back-fills pinned chats across the archived filter: an archived, pinned row
        // arrives with the unarchived page and must not show in Pinned or Main.
        let rows = [Row(key: "a", time: 3), Row(key: "b", pinned: true, archived: true, time: 9), Row(key: "c", archived: true, time: 1)]
        let sections = Self.partition(rows)
        #expect(sections.pinned.isEmpty)
        #expect(sections.main.map(\.key) == ["a"])
        #expect(sections.settled.map(\.key) == ["b", "c"])
        #expect(sections.ordered.map(\.key) == ["a"])
    }

    @Test func sendingAndStartingCountAsWorking() {
        // `.sending` and `.starting` are live and not waiting: Working.
        let sections = Self.partition([Row(key: "s", time: 1), Row(key: "i", time: 2)], live: ["s"])
        #expect(sections.working.map(\.key) == ["s"])
        #expect(sections.main.map(\.key) == ["i"])
    }

    // MARK: Order

    @Test func mainOrdersByTheLaterOfRowTimeAndReturn() {
        let rows = [Row(key: "new", time: 50), Row(key: "old", time: 10), Row(key: "mid", time: 30)]
        let sections = Self.partition(rows, returns: ["old": Self.t(60)])
        #expect(sections.main.map(\.key) == ["old", "new", "mid"])
        // A return older than the row's own time changes nothing.
        let stale = Self.partition(rows, returns: ["old": Self.t(5)])
        #expect(stale.main.map(\.key) == ["new", "mid", "old"])
    }

    @Test func pinnedSitAboveMainAndWorkingBelow() {
        let rows = [Row(key: "a", time: 1), Row(key: "p", pinned: true, time: 0), Row(key: "w", time: 99)]
        let sections = Self.partition(rows, live: ["w"])
        #expect(sections.ordered.map(\.key) == ["p", "a", "w"])
    }

    @Test func workingOrdersByLastSend() {
        let rows = [Row(key: "a", time: 90, sent: 10), Row(key: "b", time: 5, sent: 40), Row(key: "c", time: 20)]
        let sections = Self.partition(rows, live: ["a", "b", "c"])
        #expect(sections.working.map(\.key) == ["b", "c", "a"])
    }

    @Test func tiesKeepTheOrderTheyCameIn() {
        let rows = [Row(key: "x", time: 1), Row(key: "y", time: 1), Row(key: "z", time: 1)]
        #expect(Self.partition(rows).main.map(\.key) == ["x", "y", "z"])
    }

    // MARK: After Settle

    @Test func settlingOpensTheNextThenThePreviousThenNothing() {
        #expect(InboxNext.after("b", in: ["a", "b", "c"]) == "c")
        #expect(InboxNext.after("c", in: ["a", "b", "c"]) == "b")
        #expect(InboxNext.after("a", in: ["a"]) == nil)
        // Settled from Pinned or Working: Main's first.
        #expect(InboxNext.after("p", in: ["a", "b"]) == "a")
        #expect(InboxNext.after("p", in: [String]()) == nil)
    }
}

@Suite("Inbox returns")
struct InboxReturnsTests {
    private static let base = Date(timeIntervalSince1970: 1_760_600_000)
    private static func t(_ seconds: Double) -> Date { base.addingTimeInterval(seconds) }

    private static func started(_ phases: [String: InboxReturns.Phase] = [:]) -> InboxReturns {
        var returns = InboxReturns()
        returns.observe(phases, now: Self.t(0))
        return returns
    }

    @Test func theFirstLookIsOnlyABaseline() {
        var returns = InboxReturns()
        // Already waiting and stopped when the app opens: nothing returns by itself.
        let changed = returns.observe(["a": .needsYou, "b": .failed], now: Self.t(0))
        #expect(!changed)
        #expect(returns.times.isEmpty)
    }

    @Test func waitingOnThePersonReturnsAtOnce() {
        var returns = Self.started(["a": .working])
        let changed1 = returns.observe(["a": .needsYou], now: Self.t(5))
        #expect(changed1)
        #expect(returns.times["a"] == Self.t(5))
        // Still waiting at the next look: the time stays.
        let changed2 = returns.observe(["a": .needsYou], now: Self.t(9))
        #expect(!changed2)
        #expect(returns.times["a"] == Self.t(5))
    }

    @Test func waitingSeenWithoutTheRunBeforeItStillReturns() {
        // A chat elsewhere seen first when it already waits (a 5 s poll).
        var returns = Self.started()
        let changed = returns.observe(["a": .needsYou], now: Self.t(3))
        #expect(changed)
        #expect(returns.times["a"] == Self.t(3))
    }

    @Test func aStopReturnsAtOnce() {
        var returns = Self.started(["a": .working])
        let changed = returns.observe(["a": .failed], now: Self.t(4))
        #expect(changed)
        #expect(returns.times["a"] == Self.t(4))
    }

    @Test func aStopFoundOnAnIdleChatDoesNotReturn() {
        // A failed turn read while counting unread, never seen running: no jump.
        var returns = Self.started()
        let changed = returns.observe(["a": .failed], now: Self.t(4))
        #expect(!changed)
        #expect(returns.times.isEmpty)
    }

    @Test func aFinishWaitsOutTheGrace() {
        var returns = Self.started(["a": .working])
        let changed1 = returns.observe([:], now: Self.t(10))
        #expect(!changed1)
        #expect(returns.nextDeadline == Self.t(10 + InboxReturns.finishGrace))
        let changed2 = returns.settle(now: Self.t(11))
        #expect(!changed2)
        let changed3 = returns.settle(now: Self.t(12))
        #expect(changed3)
        // At the moment it left, not when the grace ran out.
        #expect(returns.times["a"] == Self.t(10))
        #expect(returns.nextDeadline == nil)
    }

    @Test func workAgainWithinTheGraceNeverReturns() {
        var returns = Self.started(["a": .working])
        returns.observe([:], now: Self.t(10))
        returns.observe(["a": .working], now: Self.t(11))
        let changed = returns.settle(now: Self.t(20))
        #expect(!changed)
        #expect(returns.times.isEmpty)
    }

    @Test func aFinishAfterWaitingAlsoReturns() {
        var returns = Self.started(["a": .needsYou])
        returns.observe([:], now: Self.t(10))
        let changed = returns.settle(now: Self.t(13))
        #expect(changed)
        #expect(returns.times["a"] == Self.t(10))
    }

    @Test func aLaterLookSettlesAnExpiredGrace() {
        var returns = Self.started(["a": .working])
        returns.observe([:], now: Self.t(10))
        let changed = returns.observe([:], now: Self.t(30))
        #expect(changed)
        #expect(returns.times["a"] == Self.t(10))
    }

    @Test func onlyListedChatsAreKept() {
        var returns = InboxReturns(times: ["a": Self.t(1), "b": Self.t(2)])
        let changed1 = returns.prune(keeping: ["a"])
        #expect(changed1)
        #expect(returns.times.keys.sorted() == ["a"])
        let changed2 = returns.prune(keeping: ["a", "c"])
        #expect(!changed2)
    }

    @Test func keptOnTheDeviceRoundTrips() {
        var returns = InboxReturns(times: ["a": Self.t(1)])
        returns.returned("b", at: Self.t(7))
        let again = InboxReturns.decoded(returns.encoded())
        #expect(again.times == returns.times)
        #expect(InboxReturns.decoded(Data("nope".utf8)).times.isEmpty)
        #expect(InboxReturns.decoded(nil).times.isEmpty)
    }

    @Test func anEarlierTimeNeverMovesAReturnBack() {
        var returns = InboxReturns(times: ["a": Self.t(10)])
        returns.returned("a", at: Self.t(5))
        #expect(returns.times["a"] == Self.t(10))
    }
}
