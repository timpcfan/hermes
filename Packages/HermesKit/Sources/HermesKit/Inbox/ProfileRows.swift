import Foundation

/// How the chat list keys a row when it lists every profile's chats (`docs/inbox.md` §9): the
/// gateway's own chats keep their lineage id, so what this device kept for them (unread marks,
/// cached transcripts, drafts) carries over; another profile's take `p:<profile>:<lineage id>`, so
/// two profiles' chats with the same id never share a row. Everything that keys a chat (the list,
/// the selection, the open chats, unread, the transcript cache, notices) goes through here.
public enum ProfileRowKey {
    public static let prefix = "p:"

    public static func key(profile: String?, lineageID: String) -> String {
        guard let profile, !profile.isEmpty else { return lineageID }
        return "\(prefix)\(profile):\(lineageID)"
    }

    /// The profile (nil for the gateway's own) and the lineage id a key names. Profile names never
    /// hold a colon (Hermes allows `[a-z0-9_-]`), so the first colon after the prefix ends it.
    public static func parse(_ key: String) -> (profile: String?, lineageID: String) {
        guard key.hasPrefix(prefix) else { return (nil, key) }
        let rest = key.dropFirst(prefix.count)
        guard let colon = rest.firstIndex(of: ":"), colon != rest.startIndex else { return (nil, key) }
        let id = rest[rest.index(after: colon)...]
        guard !id.isEmpty else { return (nil, key) }
        return (String(rest[..<colon]), String(id))
    }

    /// The key for a chat a notice or another profile's event names by its stored id.
    public static func key(storedID: String, profile: String?, home: String?) -> String {
        key(profile: ProfileRows.isHome(profile, home: home) ? nil : profile, lineageID: storedID)
    }
}

/// Every profile's chats as one list (`GET /api/profiles/sessions`, `docs/inbox.md` §9).
public enum ProfileRows {
    /// Whether rows of `profile` are the gateway's own: the profile its address serves (`home`,
    /// `BotConfiguration.profileName`), or the main one when it serves no other.
    public static func isHome(_ profile: String?, isDefault: Bool? = nil, home: String?) -> Bool {
        guard let profile, !profile.isEmpty else { return true }
        if let home { return profile == home }
        return isDefault ?? (profile == "default")
    }

    /// Keys every row that isn't the gateway's own under its profile.
    public static func tagged(_ rows: [HermesSession], home: String?) -> [HermesSession] {
        rows.map { row in
            var row = row
            row.keyProfile = isHome(row.profile, isDefault: row.isDefaultProfile, home: home) ? nil : row.profile
            return row
        }
    }

    /// The name a row's profile mark shows: its profile, or the gateway's own for a row without one.
    public static func profileName(of row: HermesSession, home: String?) -> String {
        row.profile ?? home ?? "default"
    }

    /// The profiles the rows come from, the gateway's own first, then by name.
    public static func profiles(in rows: [HermesSession], home: String?) -> [String] {
        let own = home ?? "default"
        let names = Set(rows.map { profileName(of: $0, home: home) }).subtracting([own])
        return [own] + names.sorted()
    }

    /// The row's mark: "money", or "paimon · hermesapp" when it ran in a repository.
    public static func badge(profile: String, project: String?) -> String {
        guard let project else { return profile }
        return "\(profile) · \(project)"
    }
}

/// A page of every profile's chats (`GET /api/profiles/sessions`): `{sessions, total, limit,
/// offset}` like the dashboard's own list. Hermes reads each profile's newest `limit + offset` and
/// merges them, so offsets page through the merged order; each profile's pins are back-filled
/// whatever the `archived` filter, so the caller filters rows by their own `archived`.
public struct ProfileSessionsPage: Decodable, Sendable {
    public var sessions: [HermesSession]
    public var total: Int?

    public init(sessions: [HermesSession], total: Int?) {
        self.sessions = sessions
        self.total = total
    }

    public init(from decoder: any Decoder) throws {
        enum Keys: String, CodingKey { case sessions, data, total }
        let c = try decoder.container(keyedBy: Keys.self)
        let rows = (try? c.decode([LossyElement<HermesSession>].self, forKey: .sessions))
            ?? (try c.decode([LossyElement<HermesSession>].self, forKey: .data))
        sessions = rows.compactMap(\.value)
        total = try? c.decodeIfPresent(Int.self, forKey: .total)
    }

    /// More rows past this page: by Hermes' count, else a full page.
    public func hasMore(offset: Int, limit: Int) -> Bool {
        if let total { return offset + limit < total }
        return sessions.count >= limit
    }
}

/// The chat list's paging (`docs/inbox.md` §5 Paging): where the next page starts, and the
/// generation pages carry. A refresh starts a new generation, so a page asked for before it lands
/// on nothing: its rows, read against the old list, would come back after the fresh ones.
public struct ChatListPaging: Equatable, Sendable {
    public private(set) var generation = 0
    public var nextOffset = 0
    public var hasMore = false

    public init(nextOffset: Int = 0) {
        self.nextOffset = nextOffset
    }

    /// A refresh started: earlier pages are dropped. Returns the generation it carries.
    public mutating func beginRefresh() -> Int {
        generation &+= 1
        return generation
    }

    /// Whether a page that started in `generation` still belongs to the list.
    public func accepts(_ generation: Int) -> Bool {
        generation == self.generation
    }
}
