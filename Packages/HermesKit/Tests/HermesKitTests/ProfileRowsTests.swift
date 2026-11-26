import Foundation
import Testing
@testable import HermesKit

@Suite("Profile rows")
struct ProfileRowsTests {
    private static func session(_ id: String, profile: String? = nil, messages: Int? = 2) -> HermesSession {
        var session = HermesSession(id: id, messageCount: messages)
        session.profile = profile
        return session
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    // MARK: Keys

    @Test func keysRoundTrip() {
        let key = ProfileRowKey.key(profile: "money", lineageID: "s1")
        #expect(key == "p:money:s1")
        let parsed = ProfileRowKey.parse(key)
        #expect(parsed.profile == "money")
        #expect(parsed.lineageID == "s1")
    }

    @Test func theGatewaysOwnChatsKeepTheirKeys() {
        // No profile, or an empty one: the key is the lineage id, so the device's unread marks,
        // cached transcripts and drafts carry over untouched.
        #expect(ProfileRowKey.key(profile: nil, lineageID: "s1") == "s1")
        #expect(ProfileRowKey.key(profile: "", lineageID: "s1") == "s1")
        let plain = ProfileRowKey.parse("s1")
        #expect(plain.profile == nil)
        #expect(plain.lineageID == "s1")
    }

    @Test func malformedKeysFallBackToTheWholeKey() {
        // No colon after the prefix, an empty profile or an empty id: not a profiled key.
        for malformed in ["p:money", "p::s1", "p:money:"] {
            let parsed = ProfileRowKey.parse(malformed)
            #expect(parsed.profile == nil)
            #expect(parsed.lineageID == malformed)
        }
        // A lineage id may hold colons; the first one after the profile ends the name.
        let parsed = ProfileRowKey.parse("p:money:s1:extra")
        #expect(parsed.profile == "money")
        #expect(parsed.lineageID == "s1:extra")
    }

    @Test func twoProfilesChatsWithOneIdNeverShareARow() {
        var own = Self.session("api_1760_welcome")
        own.keyProfile = nil
        var foreign = Self.session("api_1760_welcome", profile: "researcher")
        foreign.keyProfile = "researcher"
        #expect(own.stableID == "api_1760_welcome")
        #expect(foreign.stableID == "p:researcher:api_1760_welcome")
        #expect(own.stableID != foreign.stableID)
    }

    @Test func storedIDKeysRespectTheHomeProfile() {
        // A notice names a chat by its stored id and profile; the gateway's own stays plain.
        #expect(ProfileRowKey.key(storedID: "s1", profile: "money", home: "money") == "s1")
        #expect(ProfileRowKey.key(storedID: "s1", profile: "money", home: nil) == "p:money:s1")
        #expect(ProfileRowKey.key(storedID: "s1", profile: "default", home: nil) == "s1")
        #expect(ProfileRowKey.key(storedID: "s1", profile: nil, home: nil) == "s1")
    }

    // MARK: Home and tagging

    @Test func isHomeReadsTheAddressThenTheFlagThenTheName() {
        #expect(ProfileRows.isHome(nil, home: "money"))
        #expect(ProfileRows.isHome("", home: "money"))
        #expect(ProfileRows.isHome("money", home: "money"))
        #expect(!ProfileRows.isHome("default", home: "money"))
        // No home known: the row's own flag, else the name "default".
        #expect(ProfileRows.isHome("main", isDefault: true, home: nil))
        #expect(!ProfileRows.isHome("default", isDefault: false, home: nil))
        #expect(ProfileRows.isHome("default", home: nil))
        #expect(!ProfileRows.isHome("money", home: nil))
    }

    @Test func taggingKeysOnlyForeignRows() {
        var own = Self.session("s1", profile: "money")
        own.isDefaultProfile = true
        let foreign = Self.session("s2", profile: "researcher")
        let untagged = Self.session("s3")
        let rows = ProfileRows.tagged([own, foreign, untagged], home: "money")
        #expect(rows[0].keyProfile == nil)
        #expect(rows[0].stableID == "s1")
        #expect(rows[1].keyProfile == "researcher")
        #expect(rows[1].stableID == "p:researcher:s2")
        #expect(rows[2].keyProfile == nil)
    }

    @Test func profileNamesAndOrder() {
        let rows = [Self.session("s1", profile: "writer"), Self.session("s2"),
                    Self.session("s3", profile: "money"), Self.session("s4", profile: "writer")]
        #expect(ProfileRows.profiles(in: rows, home: "money") == ["money", "writer"])
        #expect(ProfileRows.profiles(in: rows, home: nil) == ["default", "money", "writer"])
        #expect(ProfileRows.profileName(of: Self.session("s5"), home: "money") == "money")
        #expect(ProfileRows.profileName(of: Self.session("s5"), home: nil) == "default")
    }

    @Test func badgesNameTheProfileAndTheRepository() {
        #expect(ProfileRows.badge(profile: "money", project: nil) == "money")
        #expect(ProfileRows.badge(profile: "paimon", project: "hermesapp") == "paimon · hermesapp")
    }

    // MARK: The page

    @Test func thePageDecodesSessionsOrDataAndSkipsBadRows() throws {
        let page = try Self.decode(ProfileSessionsPage.self, """
        {"sessions": [{"id": "s1", "profile": "money"}, {"title": "no id"}, {"id": "s2"}], "total": 7}
        """)
        #expect(page.sessions.map(\.id) == ["s1", "s2"])
        #expect(page.total == 7)
        let dataKeyed = try Self.decode(ProfileSessionsPage.self, #"{"data": [{"id": "s1"}]}"#)
        #expect(dataKeyed.sessions.map(\.id) == ["s1"])
        #expect(dataKeyed.total == nil)
    }

    @Test func hasMoreByTheCountElseAFullPage() {
        let counted = ProfileSessionsPage(sessions: [], total: 30)
        #expect(counted.hasMore(offset: 0, limit: 25))
        #expect(!counted.hasMore(offset: 25, limit: 25))
        var uncounted = ProfileSessionsPage(sessions: (0..<25).map { Self.session("s\($0)") }, total: nil)
        #expect(uncounted.hasMore(offset: 0, limit: 25))
        uncounted.sessions.removeLast()
        #expect(!uncounted.hasMore(offset: 0, limit: 25))
    }

    @Test func aRefreshDropsPagesOnTheirWay() {
        var paging = ChatListPaging()
        let old = paging.beginRefresh()
        #expect(paging.accepts(old))
        let new = paging.beginRefresh()
        #expect(new != old)
        #expect(!paging.accepts(old))
        #expect(paging.accepts(new))
    }

    // MARK: Settled across profiles

    @Test func settledKeepsOnlyArchivedRowsAndCountsTheRest() {
        var archived = Self.session("s1", profile: "money")
        archived.archived = true
        archived.keyProfile = "money"
        var pinned = Self.session("s2", profile: "money")
        pinned.pinned = true  // back-filled from the other side of the filter
        pinned.keyProfile = "money"
        let page = ProfileSessionsPage(sessions: [archived, pinned], total: nil)
        let settled = SettledPage(profiles: page, limit: 10, offset: 0)
        #expect(settled.sessions.map(\.stableID) == ["p:money:s1"])
        #expect(settled.total == 1)
        // A full page without a count: there's at least one more past it.
        let full = ProfileSessionsPage(sessions: (0..<10).map {
            var row = Self.session("s\($0)")
            row.archived = true
            return row
        }, total: nil)
        #expect(SettledPage(profiles: full, limit: 10, offset: 0).total == 11)
    }

    @Test func settledRowsWithOneIdStaySeparate() {
        var own = Self.session("welcome")
        own.archived = true
        var foreign = Self.session("welcome", profile: "researcher")
        foreign.archived = true
        foreign.keyProfile = "researcher"
        var list = SettledList()
        let generation = list.reset()
        let applied = list.apply(SettledPage(sessions: [own, foreign], total: 2), offset: 0, limit: 10, generation: generation)
        #expect(applied)
        #expect(list.rows.count == 2)
        #expect(list.session(forKey: "p:researcher:welcome")?.profile == "researcher")
        // Un-settling one leaves the other.
        list.unsettledHere("p:researcher:welcome")
        #expect(list.rows.map(\.stableID) == ["welcome"])
        #expect(list.total == 1)
        // A page from before a reset changes nothing.
        let stale = generation
        list.reset()
        let dropped = list.apply(SettledPage(sessions: [own], total: 1), offset: 0, limit: 10, generation: stale)
        #expect(!dropped)
        #expect(list.rows.isEmpty)
    }

    // MARK: The row's fields

    @Test func decodingProfileFieldsAndReadMarks() throws {
        let row = try Self.decode(HermesSession.self, """
        {"id": "s1", "profile": "money", "is_default_profile": false,
         "git_repo_root": "/Users/dev/hermesapp", "_key_profile": "money",
         "last_read_at": null, "last_active": 200}
        """)
        #expect(row.profile == "money")
        #expect(row.isDefaultProfile == false)
        #expect(row.projectName == "hermesapp")
        #expect(row.keyProfile == "money")
        #expect(row.readMark == .untracked)
        #expect(!row.isUnreadOnGateway)
        // An empty profile or repository root reads as none.
        let bare = try Self.decode(HermesSession.self, #"{"id": "s1", "profile": "", "git_repo_root": ""}"#)
        #expect(bare.profile == nil)
        #expect(bare.gitRepoRoot == nil)
        #expect(bare.readMark == nil)  // last_read_at absent: Hermes doesn't serve the mark
        let marked = try Self.decode(HermesSession.self, #"{"id": "s1", "last_read_at": 0}"#)
        #expect(marked.readMark == .markedUnread)
        #expect(marked.isUnreadOnGateway)
    }

    @Test func readMarksRoundTripThroughTheCache() throws {
        var row = Self.session("s1", profile: "money")
        row.keyProfile = "money"
        row.gitRepoRoot = "/Users/dev/hermesapp"
        row.readMark = .readUntil(Date(timeIntervalSince1970: 100))
        let back = try JSONDecoder().decode(HermesSession.self, from: JSONEncoder().encode(row))
        #expect(back.profile == "money")
        #expect(back.keyProfile == "money")
        #expect(back.stableID == row.stableID)
        #expect(back.readMark == row.readMark)
        #expect(back.projectName == "hermesapp")
    }

    @Test func placeholdersNameTheProfileTheKeyHolds() {
        let foreign = HermesSession.placeholder(forKey: "p:money:s1")
        #expect(foreign.id == "s1")
        #expect(foreign.profile == "money")
        #expect(foreign.stableID == "p:money:s1")
        let own = HermesSession.placeholder(forKey: "s1")
        #expect(own.profile == nil)
        #expect(own.stableID == "s1")
    }

    @Test func stableIDFollowsTheLineageRoot() {
        var row = Self.session("live-id", profile: "money")
        row.keyProfile = "money"
        row.lineageRootID = "root-id"
        #expect(row.stableID == "p:money:root-id")
    }

    @Test func projectNamesTakeTheRepositorysFolder() {
        var row = Self.session("s1")
        row.gitRepoRoot = "/Users/dev/work/hermesapp/"
        #expect(row.projectName == "hermesapp")
        row.gitRepoRoot = "   "
        #expect(row.projectName == nil)
        row.gitRepoRoot = "/"
        #expect(row.projectName == nil)
    }

    // MARK: The scope's profile filter

    @Test func theScopeHoldsOnlyTheChosenProfile() {
        var scope = InboxScope.standard
        scope.profile = "money"
        let money = Self.session("s1", profile: "money")
        let own = Self.session("s2", profile: "default")
        let untagged = Self.session("s3")
        #expect(scope.holds(money, home: "default"))
        #expect(!scope.holds(own, home: "default"))
        // A row without a profile belongs to the gateway's own, whichever profile that is.
        #expect(!scope.holds(untagged, home: "default"))
        #expect(!scope.holds(untagged, home: nil))
        #expect(scope.holds(untagged, home: "money"))
        #expect(scope.changes.contains(.profile("money")))
        // Bot Mode not connected: the choice waits, kept, for the next time.
        #expect(scope.withoutProfile.holds(own, home: "default"))
        #expect(scope.withoutProfile.profile == nil)
        #expect(scope.profile == "money")
    }

    // MARK: Profile filter

    @Test func filterListsEveryProfileHermesListsWithChatsOrNot() {
        let rows = [Self.session("s1", profile: "money"), Self.session("s2")]
        // `scout` has no chat: Hermes' list still names it. Duplicates go, the gateway's own leads.
        let listed = ["writer", "default", "scout", "money", "writer"]
        #expect(ProfileRows.filterChoices(listed: listed, rows: rows, home: "default", picked: nil)
                == ["default", "money", "scout", "writer"])
        // The gateway's own profile leads even when Hermes' list leaves it out.
        #expect(ProfileRows.filterChoices(listed: ["money"], rows: [], home: "work", picked: nil) == ["work", "money"])
        #expect(ProfileRows.filterChoices(listed: [], rows: rows, home: nil, picked: nil) == ["default"])
    }

    @Test func filterFallsBackToTheChatsProfilesWithoutHermesList() {
        let rows = [Self.session("s1", profile: "money"), Self.session("s2"), Self.session("s3", profile: "art")]
        #expect(ProfileRows.filterChoices(listed: nil, rows: rows, home: "default", picked: nil) == ["default", "art", "money"])
        // The picked profile stays listed, so the menu can show it checked.
        #expect(ProfileRows.filterChoices(listed: nil, rows: rows, home: "default", picked: "travel")
                == ["default", "art", "money", "travel"])
        #expect(ProfileRows.filterChoices(listed: ["money"], rows: [], home: "default", picked: "default") == ["default", "money"])
    }
}
