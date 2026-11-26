import Foundation
import HermesPush

/// What a chat row says at its trailing edge (BRIEF ios-tab-layout): the one place an
/// `ActivityLine` becomes one of the four states the row draws.
public enum ChatRowState: Equatable, Sendable {
    /// Hermes is working on the turn.
    case running
    /// Nothing runs: the chat's last turn finished (or it never ran).
    case done
    /// Hermes waits for the person: an approval, an answer or a key.
    case needsYou
    /// The last turn stopped; the reason is the row's red line.
    case failed(reason: String)
}

extension ActivityLine {
    /// The row's state (`ChatRowStatus` in the design). A message the gateway hasn't taken yet
    /// (`.sending`) is not finished work and not Hermes working: it reads as running, so the row
    /// doesn't say Done over a message that is still on its way.
    public var chatRowState: ChatRowState {
        switch self {
        case .starting, .thinking, .writing, .tool, .helpers, .routine, .sending:
            .running
        case .waiting:
            .needsYou
        case .failed(let reason):
            .failed(reason: reason)
        }
    }
}

/// A chat row's second line: where the chat came from and whose it is — "telegram · money", and
/// the project when it ran in a repository: "desktop · paimon · IB-Robot". Sessions carry no
/// device, so the row never names one (BRIEF).
public enum ChatRowSubtitle {
    public static func text(source: String?, profile: String?, project: String?) -> String {
        var parts: [String] = []
        if let platform = platformName(source) { parts.append(platform) }
        if let profile, !profile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(profile)
        }
        if let project, !project.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(project)
        }
        return parts.joined(separator: " · ")
    }

    /// The platform's row name. Hermes' own API sources read as "app" (this app, Desktop and
    /// another API client are the same origin); a source the app doesn't know speaks for itself.
    public static func platformName(_ source: String?) -> String? {
        let name = source?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        switch name {
        case "", "api_server", "hermes_app": return String(localized: "app")
        case "desktop": return String(localized: "desktop")
        case "cli", "tui": return String(localized: "terminal")
        case "acp": return String(localized: "editor")
        case "cron": return String(localized: "scheduled")
        case "telegram": return String(localized: "telegram")
        case "discord": return String(localized: "discord")
        default: return name
        }
    }
}

/// How long a running chat's turn has been going, at the row's compact width: "45s", "4m",
/// "2h 5m".
public enum ChatRowDuration {
    public static func short(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m" }
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m"
    }
}

/// A profile's fallback avatar: the first letter and a colour that doesn't move between launches.
/// The colour comes from the same name hash the Bot faces use, so a profile without a photo and a
/// Bot with one share a family (`docs/bot-faces.md` §1–2).
public enum ProfileMonogram {
    public static func initial(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "?" }
        return String(first).uppercased()
    }

    public static func color(for name: String) -> FaceColor {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return FaceLook(profile: trimmed.isEmpty ? "default" : trimmed).color
    }
}
