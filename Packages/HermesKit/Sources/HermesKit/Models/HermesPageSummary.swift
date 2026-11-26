import Foundation

/// Settings → Hermes on <gateway>: the line under the Skills and Tasks rows. Until there's a count
/// it says what Apps and Tools says ("Loading…", "Not connected"), and after a failed read what the
/// page itself says (`docs/inbox.md` §10).
public enum HermesPageSummary {
    /// "104 skills". A list already read stays counted through a reload or the gateway going away,
    /// as the Skills page keeps showing it (`SkillCatalog.shown`).
    public static func skills(_ catalog: SkillCatalog, from address: URL, isLoading: Bool, isOnline: Bool) -> String {
        switch catalog.shown(for: address, isLoading: isLoading, isUnreachable: !isOnline) {
        case .list, .empty: skillCount(catalog.skills.count)
        case .placeholders: String(localized: "Loading…")
        case .offline: String(localized: "Not connected")
        case .failed: String(localized: "Couldn't list skills")
        }
    }

    /// "5 tasks · 2 active", where active is every task that isn't paused. `jobs` is nil until
    /// the list has been read once; a list read before stays counted.
    public static func tasks(_ jobs: [CronJob]?, failed: Bool, isOnline: Bool) -> String {
        guard let jobs else {
            if !isOnline { return String(localized: "Not connected") }
            return failed ? String(localized: "Couldn't load tasks") : String(localized: "Loading…")
        }
        guard !jobs.isEmpty else { return String(localized: "No tasks") }
        let active = jobs.count(where: { !$0.isPaused })
        let total = jobs.count == 1 ? String(localized: "1 task") : String(localized: "\(jobs.count) tasks")
        let state = active == 0 ? String(localized: "all paused") : String(localized: "\(active) active")
        return total + " · " + state
    }

    static func skillCount(_ count: Int) -> String {
        switch count {
        case 0: String(localized: "No skills")
        case 1: String(localized: "1 skill")
        default: String(localized: "\(count) skills")
        }
    }
}
