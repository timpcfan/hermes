import Foundation
import HermesKit
import os

/// The inbox's Settled region for one gateway (`docs/inbox.md` §2a): chats the person marked
/// finished, which Hermes keeps as archived. Only the Dashboard backend lists them
/// (`GET /api/sessions?archived=only`), so without Bot Mode linked the region isn't there and
/// Settle still works (archive; search finds them). Folded, it asks for the count alone; open, ten
/// rows, then 25 at a time.
@MainActor
@Observable
final class SettledChats {
    @ObservationIgnored private weak var workspace: BotWorkspace?
    private(set) var list = SettledList()
    /// Open on this device, per gateway; folded by default.
    var isExpanded: Bool {
        didSet {
            guard isExpanded != oldValue else { return }
            UserDefaults.standard.set(isExpanded, forKey: Self.expandedKey(gateway))
            if isExpanded {
                hasActivity = false
                noteSeen(list.rows.first?.lastActive ?? newestActivity)
                if list.rows.isEmpty { Task { await loadFirst() } }
            } else {
                // Folded: no rows kept, nothing loading; the next open starts at the top.
                list.reset()
                isLoading = false
            }
        }
    }
    private(set) var isLoading = false
    /// Hermes answered (or a gateway without the Dashboard backend, or a refusal, didn't).
    private(set) var isAvailable = false
    /// A settled chat had activity elsewhere since the person last looked (its `last_active` moved
    /// past the newest they saw): a dot on the header, never a count (`docs/inbox.md` §2a S4).
    private(set) var hasActivity = false
    /// A settled chat opened from search, a notification or a link (`docs/inbox.md` §2a S5): it
    /// stays where it is and shows in the region even while it's folded.
    var revealed: HermesSession?

    @ObservationIgnored private let gateway: UUID
    /// The newest activity among the settled chats when the person last looked (kept per gateway).
    @ObservationIgnored private var seenActivity: Date?
    @ObservationIgnored private var newestActivity: Date?
    @ObservationIgnored private var countTask: Task<Void, Never>?
    @ObservationIgnored private static let log = Logger(subsystem: "co.caffeinatedcode.hermes", category: "settled")

    init(workspace: BotWorkspace) {
        self.workspace = workspace
        gateway = workspace.id
        isExpanded = UserDefaults.standard.bool(forKey: Self.expandedKey(workspace.id))
        let seen = UserDefaults.standard.double(forKey: Self.seenKey(workspace.id))
        seenActivity = seen > 0 ? Date(timeIntervalSince1970: seen) : nil
    }

    private static func expandedKey(_ id: UUID) -> String { "inbox.settledExpanded.\(id.uuidString)" }
    private static func seenKey(_ id: UUID) -> String { "inbox.settledSeen.\(id.uuidString)" }

    private var client: BackendClient? { workspace?.roster?.boardClient }

    // MARK: Reading

    /// The list moved (a refresh, `sessions.changed`): the count, and the open rows from the top.
    /// Calls close together share one read.
    func refresh() {
        guard client != nil else {
            isAvailable = false
            return
        }
        guard countTask == nil else { return }
        countTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled else { return }
            if self.isExpanded {
                await self.reload()
            } else {
                await self.readCount()
            }
            self.countTask = nil
        }
    }

    /// The count, and the newest settled chat's activity for the header's dot.
    private func readCount() async {
        guard let client, let workspace else { return }
        do {
            let page = try await client.archivedSessions(limit: 1, offset: 0, profile: workspace.bot.profileName)
            isAvailable = true
            list.noteTotal(page.total)
            noteNewest(page.sessions.first?.lastActive)
        } catch {
            noteFailure(error)
        }
    }

    /// The region opened: its first ten.
    func loadFirst() async {
        let generation = list.reset()
        await load(offset: 0, limit: SettledList.firstPage, generation: generation)
    }

    /// "Show 25 more".
    func loadMore() async {
        guard !isLoading, list.hasMore else { return }
        await load(offset: list.nextOffset, limit: SettledList.morePage, generation: list.generation)
    }

    /// Open and the list moved: as many rows as are shown, again from the top.
    private func reload() async {
        let shown = max(SettledList.firstPage, list.nextOffset)
        let generation = list.reset()
        await load(offset: 0, limit: min(100, shown), generation: generation)
    }

    private func load(offset: Int, limit: Int, generation: Int) async {
        guard let client, let workspace else { return }
        isLoading = true
        defer { if list.generation == generation { isLoading = false } }
        do {
            let page = try await client.archivedSessions(limit: limit, offset: offset, profile: workspace.bot.profileName)
            isAvailable = true
            list.apply(page, offset: offset, limit: limit, generation: generation)
            if offset == 0 {
                noteNewest(page.sessions.first?.lastActive)
                noteSeen(newestActivity)
            }
        } catch {
            noteFailure(error)
        }
    }

    private func noteFailure(_ error: any Error) {
        // Refused, or a backend without the route: the region isn't there until it answers.
        switch error as? BackendClient.Failure {
        case .signInRequired?, .http(404, _)?: isAvailable = false
        default: break
        }
        let nsError = error as NSError
        Self.log.error("settled chats: \(nsError.domain, privacy: .public) \(nsError.code)")
    }

    // MARK: Activity (S4)

    /// The newest activity among settled chats: newer than what the person saw while the region
    /// was folded, and not their own settle, lights the header's dot.
    private func noteNewest(_ date: Date?) {
        guard let date else { return }
        newestActivity = max(newestActivity ?? date, date)
        guard !isExpanded, let seenActivity else {
            if seenActivity == nil { noteSeen(date) }
            return
        }
        if date > seenActivity { hasActivity = true }
    }

    private func noteSeen(_ date: Date?) {
        guard let date, date > (seenActivity ?? .distantPast) else { return }
        seenActivity = date
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: Self.seenKey(gateway))
    }

    // MARK: Settling here

    func settledHere(_ session: HermesSession) {
        // Folded, the region keeps no rows: only the count moves.
        if isExpanded {
            list.settledHere(session)
        } else {
            list.noteTotal((list.total ?? 0) + 1)
        }
        // The person's own settle is no news.
        noteSeen(.now)
        newestActivity = .now
    }

    func unsettledHere(_ key: String) {
        list.unsettledHere(key)
        if revealed?.stableID == key { revealed = nil }
    }

    func session(forKey key: String) -> HermesSession? {
        if let revealed, revealed.stableID == key || revealed.id == key { return revealed }
        return list.session(forKey: key)
    }

    /// Whether this chat is settled as far as the app knows.
    func contains(_ key: String) -> Bool {
        session(forKey: key) != nil
    }

    func tearDown() {
        countTask?.cancel()
        countTask = nil
    }
}
