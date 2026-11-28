import Foundation
import Testing
@testable import HermesKit

@Suite("Settled list")
struct SettledListTests {
    private static func session(_ id: String, archived: Bool = true, pinned: Bool = false) -> HermesSession {
        var session = HermesSession(id: id)
        session.archived = archived
        session.pinned = pinned
        return session
    }

    private static func page(_ ids: [String], total: Int) -> SettledPage {
        SettledPage(sessions: ids.map { session($0) }, total: total)
    }

    // MARK: Hermes' page

    @Test func aPageKeepsOnlyArchivedRowsAndTheTotal() async throws {
        // `archived=only` still back-fills pinned chats from the other side of the filter.
        let server = try await LoopbackServer.start { line, _ in
            guard line.hasPrefix("GET /api/sessions?") else { return .page(404, "application/json", Data("{}".utf8)) }
            return .page(200, "application/json", Data(#"""
            {"sessions": [
              {"id": "s1", "archived": true, "pinned": false, "last_active": 1760600300},
              {"id": "s2", "archived": true, "pinned": false, "last_active": 1760600200},
              {"id": "p1", "archived": false, "pinned": true, "last_active": 1760600900},
              {"id": "s9", "archived": true, "pinned": true, "last_active": 1760600100}
            ], "total": 37, "limit": 2, "offset": 0}
            """#.utf8))
        }
        defer { server.stop() }
        let client = BackendClient(baseURL: server.baseURL, credential: .sessionToken("token"))
        let page = try await client.archivedSessions(limit: 2, offset: 0, profile: "work")
        #expect(page.sessions.map(\.id) == ["s1", "s2", "s9"])
        #expect(page.total == 37)
        let asked = try #require(server.requests.first { $0.hasPrefix("GET /api/sessions?") })
        #expect(asked.contains("archived=only"))
        #expect(asked.contains("order=recent"))
        #expect(asked.contains("limit=2"))
        #expect(asked.contains("offset=0"))
        #expect(asked.contains("profile=work"))
    }

    @Test func aPageWithoutATotalCountsWhatCame() throws {
        let data = Data(#"{"sessions": [{"id": "a", "archived": true}, {"id": "b", "archived": false}]}"#.utf8)
        let page = SettledPage(dashboard: try JSONDecoder().decode(DashboardSessionPage.self, from: data))
        #expect(page.total == 1)
    }

    // MARK: Paging

    @Test func pagesFollowOneAnother() {
        var list = SettledList()
        let generation = list.reset()
        let applied1 = list.apply(Self.page(["a", "b"], total: 5), offset: 0, limit: 2, generation: generation)
        #expect(applied1)
        #expect(list.hasMore)
        let applied2 = list.apply(Self.page(["c", "d"], total: 5), offset: 2, limit: 2, generation: generation)
        #expect(applied2)
        #expect(list.rows.map(\.id) == ["a", "b", "c", "d"])
        #expect(list.nextOffset == 4)
        let applied3 = list.apply(Self.page(["e"], total: 5), offset: 4, limit: 2, generation: generation)
        #expect(applied3)
        #expect(!list.hasMore)
    }

    @Test func aPageFromBeforeAResetIsDropped() {
        var list = SettledList()
        let old = list.reset()
        let current = list.reset()
        let applied1 = list.apply(Self.page(["a"], total: 1), offset: 0, limit: 10, generation: old)
        #expect(!applied1)
        #expect(list.rows.isEmpty)
        let applied2 = list.apply(Self.page(["b"], total: 1), offset: 0, limit: 10, generation: current)
        #expect(applied2)
        #expect(list.rows.map(\.id) == ["b"])
    }

    @Test func aPageForAnotherPlaceIsDropped() {
        var list = SettledList()
        let generation = list.reset()
        list.apply(Self.page(["a", "b"], total: 9), offset: 0, limit: 2, generation: generation)
        // The same "more" twice: the second answer is no longer where the list ends.
        let applied1 = list.apply(Self.page(["c"], total: 9), offset: 2, limit: 2, generation: generation)
        #expect(applied1)
        let applied2 = list.apply(Self.page(["c"], total: 9), offset: 2, limit: 2, generation: generation)
        #expect(!applied2)
        #expect(list.rows.map(\.id) == ["a", "b", "c"])
    }

    @Test func aPinBackFilledIntoEveryPageListsOnce() {
        var list = SettledList()
        let generation = list.reset()
        list.apply(Self.page(["a", "pin"], total: 9), offset: 0, limit: 1, generation: generation)
        list.apply(Self.page(["b", "pin"], total: 9), offset: 1, limit: 1, generation: generation)
        #expect(list.rows.map(\.id) == ["a", "pin", "b"])
    }

    // MARK: Reloading

    @Test func aReloadKeepsTheRowsUntilItsPageReplacesThem() {
        var list = SettledList()
        let generation = list.reset()
        list.apply(Self.page(["a", "b", "c"], total: 9), offset: 0, limit: 3, generation: generation)
        // The list moved while Settled is open: the rows and the offsets stay, so the region
        // doesn't blank while the page is on its way, and a page from before the restart is
        // dropped.
        let reload = list.restart()
        #expect(list.rows.map(\.id) == ["a", "b", "c"])
        #expect(list.nextOffset == 3)
        let stale = list.apply(Self.page(["old"], total: 9), offset: 3, limit: 2, generation: generation)
        #expect(!stale)
        // The first page takes the old rows' place, in Hermes' order.
        let replaced = list.replace(Self.page(["b", "a", "d"], total: 9), limit: 3, generation: reload)
        #expect(replaced)
        #expect(list.rows.map(\.id) == ["b", "a", "d"])
        #expect(list.nextOffset == 3)
        #expect(list.hasMore)
    }

    @Test func aPageFromBeforeTheRestartCannotReplaceTheRows() {
        var list = SettledList()
        let generation = list.reset()
        list.apply(Self.page(["a"], total: 2), offset: 0, limit: 1, generation: generation)
        let reload = list.restart()
        let stale = list.replace(Self.page(["b"], total: 2), limit: 1, generation: generation)
        #expect(!stale)
        #expect(list.rows.map(\.id) == ["a"])
        let replaced = list.replace(Self.page(["b"], total: 2), limit: 1, generation: reload)
        #expect(replaced)
        #expect(list.rows.map(\.id) == ["b"])
    }

    // MARK: Here

    @Test func settlingHereListsItFirstAndCountsIt() {
        var list = SettledList()
        let generation = list.reset()
        list.apply(Self.page(["a", "b"], total: 2), offset: 0, limit: 10, generation: generation)
        list.settledHere(Self.session("new", archived: false))
        #expect(list.rows.map(\.id) == ["new", "a", "b"])
        #expect(list.rows.first?.archived == true)
        #expect(list.total == 3)
        #expect(list.nextOffset == 11)
        list.unsettledHere("new")
        #expect(list.rows.map(\.id) == ["a", "b"])
        #expect(list.total == 2)
        #expect(list.nextOffset == 10)
    }

    @Test func unsettlingAChatNotLoadedOnlyCountsIt() {
        var list = SettledList()
        list.noteTotal(4)
        list.unsettledHere("elsewhere")
        #expect(list.total == 3)
        #expect(list.nextOffset == 0)
    }

    @Test func theCountAloneSaysThereIsMore() {
        var list = SettledList()
        #expect(!list.hasMore)
        list.noteTotal(73)
        #expect(list.hasMore)
        #expect(list.rows.isEmpty)
    }
}
