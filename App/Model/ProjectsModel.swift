import Foundation
import HermesKit
import Observation

/// What is left of a gateway's projects in this build, which has no Projects screens
/// (`docs/projects.md`): the socket's `session.active_list`, the one place the chat list learns
/// what runs elsewhere (`LiveActivity`, the Working region, `docs/inbox.md` §2), and the gateway's
/// default folder, where a new chat starts and the Inspector's files open. Every call runs in this
/// gateway's profile.
@MainActor
@Observable
final class ProjectsModel {
    @ObservationIgnored private weak var workspace: BotWorkspace?

    /// The gateway's default folder: where a new chat runs when it names none.
    private(set) var defaultFolder: String?

    @ObservationIgnored private var activeFetch: Task<[ActiveSession]?, Never>?
    @ObservationIgnored private var activeFetched: (at: Date, rows: [ActiveSession])?
    @ObservationIgnored private var folderTask: Task<Void, Never>?

    init(workspace: BotWorkspace) {
        self.workspace = workspace
    }

    var client: ProjectsClient? {
        guard let roster = workspace?.roster, roster.isConnected else { return nil }
        return ProjectsClient(profile: workspace?.bot.profileName) { method, params in
            try await roster.request(method, params)
        }
    }

    /// The socket (re)connected: the default folder, once per connection.
    func connected() {
        folderTask?.cancel()
        folderTask = Task { [weak self] in
            guard let client = self?.client, let location = try? await client.forCwd(nil), !Task.isCancelled else { return }
            self?.defaultFolder = location.cwd
        }
    }

    func disconnected() {
        folderTask?.cancel()
        folderTask = nil
        activeFetch = nil
        activeFetched = nil
    }

    /// `session.active_list`, shared. The chat list's live lines ask at several moments (a change
    /// event, the polls of each window), and one answer serves them all: a request under way is
    /// joined, and an answer under 2 s old is reused.
    func activeSessions() async -> [ActiveSession]? {
        if let activeFetched, Date.now.timeIntervalSince(activeFetched.at) < 2 { return activeFetched.rows }
        if let activeFetch { return await activeFetch.value }
        guard let client else { return nil }
        let fetch = Task { try? await client.activeSessions() }
        activeFetch = fetch
        let rows = await fetch.value
        activeFetch = nil
        guard let rows else { return nil }
        activeFetched = (.now, rows)
        return rows
    }
}

/// Where a live chat runs, from `session.info` (also inside `session.create` / `session.resume`).
struct LiveWorkspace: Equatable {
    var cwd: String
    var branch: String?
    /// Set for projects someone made only.
    var projectID: String?

    init?(info: JSONValue?) {
        guard let info, let cwd = info["cwd"]?.stringValue, !cwd.isEmpty else { return nil }
        self.cwd = cwd
        branch = info["branch"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        projectID = info["project"]?["id"]?.stringValue
    }
}
