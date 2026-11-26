import Foundation

/// What a chat's top bar says (`docs/chat.md` §4): where the person is, in the chat's own name and
/// the profile it runs in.
public enum ChatHeader {
    /// The chat's name: its row's title, else the words of its first message, else `fallback`
    /// (a draft has no row yet: "New chat").
    public static func title(of session: HermesSession?, fallback: String) -> String {
        guard let session else { return fallback }
        if let title = session.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        if let preview = session.listPreview?.trimmingCharacters(in: .whitespacesAndNewlines), !preview.isEmpty {
            return preview
        }
        return fallback
    }

    /// The profile a chat runs in, named as the chat list names it (`ProfileRows.profileName`):
    /// the chat's own profile, else the gateway's. A draft passes the profile it will be created
    /// in.
    public static func profile(of profile: String?, home: String?) -> String {
        ProfileRows.profileName(profile, home: home)
    }
}
