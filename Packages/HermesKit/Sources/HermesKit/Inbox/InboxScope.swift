import Foundation

/// Where a chat came from, as the inbox's filter groups it (`docs/inbox.md` §5): by the gateway's
/// `source` for its session.
public enum InboxSourceGroup: String, CaseIterable, Codable, Sendable {
    /// Started here, in Hermes Desktop or by another API client.
    case thisApp
    case telegram
    case discord
    /// `hermes chat` and the TUI.
    case terminal
    /// An editor over ACP.
    case editor
    /// A scheduled task's run (`cron`).
    case scheduled
    /// Every other platform (Slack, WhatsApp, the Board's workers…).
    case other

    public init(source: String?) {
        let source = source?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        switch source {
        case "", "api_server", "desktop", "hermes_app": self = .thisApp
        case "telegram": self = .telegram
        case "discord": self = .discord
        case "cli", "tui": self = .terminal
        case "acp": self = .editor
        case "cron": self = .scheduled
        default: self = .other
        }
    }
}

/// The inbox's filter (`docs/inbox.md` §5), kept per gateway on the device: which sources it
/// holds, whether empty chats hide, and the states that narrow Main (never Pinned, Working or
/// Settled). Decoding is lenient: a key it doesn't know, or one missing, takes its default, so a
/// stored filter survives the app adding a group.
public struct InboxScope: Codable, Equatable, Sendable {
    /// Source groups left out; scheduled runs by default, as they aren't chats.
    public var hiddenSources: Set<InboxSourceGroup>
    public var unreadOnly: Bool
    public var needsYouOnly: Bool
    /// Chats with no messages (a chat opened and never used) stay out.
    public var hidesEmpty: Bool
    /// The one profile listed while the list holds every profile's chats (`docs/inbox.md` §9); nil
    /// is All Profiles. It holds every region, Settled included.
    public var profile: String?

    public static let standard = InboxScope()

    public init(hiddenSources: Set<InboxSourceGroup> = [.scheduled], unreadOnly: Bool = false, needsYouOnly: Bool = false,
                hidesEmpty: Bool = true, profile: String? = nil) {
        self.hiddenSources = hiddenSources
        self.unreadOnly = unreadOnly
        self.needsYouOnly = needsYouOnly
        self.hidesEmpty = hidesEmpty
        self.profile = profile
    }

    /// The filter as it applies to a list of one profile's chats (Bot Mode not connected, or a
    /// Hermes without every profile's list): the profile choice waits, kept, for the next time.
    public var withoutProfile: InboxScope {
        var scope = self
        scope.profile = nil
        return scope
    }

    public var isStandard: Bool { self == .standard }

    /// Unread or Needs You is on: Main holds only chats in one of those states.
    public var narrowsMain: Bool { unreadOnly || needsYouOnly }

    public func shows(_ group: InboxSourceGroup) -> Bool { !hiddenSources.contains(group) }

    public mutating func set(_ group: InboxSourceGroup, shown: Bool) {
        if shown { hiddenSources.remove(group) } else { hiddenSources.insert(group) }
    }

    /// Whether the inbox holds this chat. A pinned chat is kept even when empty, and so is one
    /// with a turn running here (`keep`): a new chat has no messages until its first is stored.
    /// `home` is the gateway's own profile, which rows without a profile belong to.
    public func holds(_ session: HermesSession, keep: Bool = false, home: String? = nil) -> Bool {
        guard shows(InboxSourceGroup(source: session.source)) else { return false }
        if let profile, ProfileRows.profileName(of: session, home: home) != profile { return false }
        if hidesEmpty, session.messageCount == 0, !session.pinned, !keep { return false }
        return true
    }

    /// Whether a Main row passes the state filters (either one, when both are on).
    public func narrowsIn(unread: Bool, needsYou: Bool) -> Bool {
        guard narrowsMain else { return true }
        return (unreadOnly && unread) || (needsYouOnly && needsYou)
    }

    /// What differs from the standard filter, in the menu's order, for the "Filtered:" line.
    public var changes: [Change] {
        var changes: [Change] = []
        for group in InboxSourceGroup.allCases where shows(group) != InboxScope.standard.shows(group) {
            changes.append(.source(group, shown: shows(group)))
        }
        if unreadOnly { changes.append(.unread) }
        if needsYouOnly { changes.append(.needsYou) }
        if !hidesEmpty { changes.append(.showsEmpty) }
        if let profile { changes.append(.profile(profile)) }
        return changes
    }

    public enum Change: Equatable, Sendable {
        case source(InboxSourceGroup, shown: Bool)
        case unread
        case needsYou
        case showsEmpty
        case profile(String)
    }

    // MARK: Stored

    private enum Keys: String, CodingKey { case hiddenSources, unreadOnly, needsYouOnly, hidesEmpty, profile }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let names = (try? c.decodeIfPresent([String].self, forKey: .hiddenSources)) ?? nil
        hiddenSources = names.map { Set($0.compactMap(InboxSourceGroup.init(rawValue:))) } ?? InboxScope.standard.hiddenSources
        unreadOnly = (try? c.decodeIfPresent(Bool.self, forKey: .unreadOnly)) ?? false
        needsYouOnly = (try? c.decodeIfPresent(Bool.self, forKey: .needsYouOnly)) ?? false
        hidesEmpty = (try? c.decodeIfPresent(Bool.self, forKey: .hidesEmpty)) ?? true
        profile = (try? c.decodeIfPresent(String.self, forKey: .profile)) ?? nil
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(hiddenSources.map(\.rawValue).sorted(), forKey: .hiddenSources)
        try c.encode(unreadOnly, forKey: .unreadOnly)
        try c.encode(needsYouOnly, forKey: .needsYouOnly)
        try c.encode(hidesEmpty, forKey: .hidesEmpty)
        try c.encodeIfPresent(profile, forKey: .profile)
    }
}
