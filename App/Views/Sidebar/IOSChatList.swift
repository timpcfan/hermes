#if os(iOS)
import HermesKit
import SwiftUI

/// The Chat tab's first screen: the product name and the gateway beside it, then the inbox
/// regions from `BotWorkspace.inboxSections` — Pinned and Main, Working while something runs,
/// Settled (`docs/inbox.md` §2a). The same snapshot and paging as the split view's sidebar, so a
/// long history costs no more here than there.
struct IOSChatList: View {
    @Bindable var workspace: BotWorkspace

    /// Until the window is on screen the list shows one screenful, so it draws without laying out
    /// every kept chat first (`docs/inbox.md` §1).
    @State private var isFirstFrame = true
    /// The search page: the same `workspace.search` the sidebar searches with, over the list.
    @State private var showsSearch = false
    @State private var renaming: HermesSession?
    @State private var renameText = ""
    @State private var deleting: HermesSession?
    @State private var actionError: HermesError?

    var body: some View {
        List {
            sessionSections
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.canvas)
        .environment(\.defaultMinListRowHeight, 10)
        .environment(\.sidebarShowsSelection, false)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .overlay { stateView }
        .refreshable { await workspace.refreshSessions() }
        .onAppear { workspace.activity.listAppeared() }
        .onDisappear { workspace.activity.listDisappeared() }
        .task {
            isFirstFrame = false
        }
        .modifier(ArchivedToast(workspace: workspace, bottomPadding: 8) { actionError = $0 })
        .fullScreenCover(isPresented: $showsSearch) {
            IOSSearchPage(workspace: workspace)
        }
        .alert("Rename Chat", isPresented: renameBinding) {
            TextField("Title", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { commitRename() }
                .keyboardShortcut(.defaultAction)
        }
        .alert(
            deleting.map { String(localized: "Delete “\($0.displayTitle)”?") } ?? "",
            isPresented: deleteBinding,
            presenting: deleting
        ) { session in
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { delete(session) }
        } message: { session in
            if workspace.waitingChat(forKey: session.stableID) != nil {
                Text("Its message waits for \(workspace.bot.name) and won't be sent.")
            } else {
                Text("The conversation is removed from Hermes on every device.")
            }
        }
        .alert("Something went wrong", isPresented: errorBinding, presenting: actionError) { _ in
            Button("OK", role: .cancel) {}
        } message: { error in
            Text(error.errorDescription ?? "")
        }
    }

    // MARK: Header

    /// "Hermes", the gateway's connection beside it, and the search button; under them the two
    /// filters, the profile and the sources (`mockup-v2.html`).
    private var header: some View {
        let status = ConnectionStatus(workspace)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Text("Hermes")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(Theme.primaryText)
                    .accessibilityAddTraits(.isHeader)
                HStack(spacing: 6) {
                    Circle()
                        .fill(status.color)
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                    Text(workspace.bot.name)
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(status.line)
                Spacer(minLength: 8)
                Button("Search", systemImage: "magnifyingglass") {
                    showsSearch = true
                }
                .labelStyle(.iconOnly)
                .buttonBorderShape(.circle)
                .glassButton()
                .accessibilityIdentifier("chat.search")
            }
            HStack(spacing: 8) {
                profileFilter
                sourceFilter
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 2)
        .padding(.bottom, 8)
        .background(Theme.canvas)
    }

    /// One profile at a time (`InboxScope.profile`): All Profiles, or any profile Hermes lists, one
    /// without chats included. Picked, the filter turns blue. It stays visible without Bot Mode,
    /// where All and the gateway's profile are the only choices and the filter changes nothing.
    private var profileFilter: some View {
        let picked = workspace.inboxScope.profile
        let profiles = profileChoices
        return Menu {
            Picker("Profile", selection: Binding(get: { workspace.inboxScope.profile },
                                                 set: { workspace.inboxScope.profile = $0 })) {
                Text("All Profiles").tag(nil as String?)
                ForEach(profiles, id: \.self) { name in
                    Text(name).tag(Optional(name))
                }
            }
            .pickerStyle(.inline)
        } label: {
            filterLabel(picked ?? String(localized: "All Profiles"))
        }
        .filterMenu(isActive: picked != nil)
        .accessibilityLabel("Profile")
        .accessibilityValue(picked ?? String(localized: "All Profiles"))
        .accessibilityIdentifier("chat.profileFilter")
    }

    /// The profiles the filter offers: Hermes' whole list once the roster has it, else the
    /// profiles the chats come from (`ProfileRows.filterChoices`). The chats are read only without
    /// Hermes' list, so a refresh of the list doesn't redraw the header.
    private var profileChoices: [String] {
        let listed = workspace.roster.flatMap { $0.hasLoaded ? $0.profiles.map(\.name) : nil }
        return ProfileRows.filterChoices(listed: listed, rows: listed == nil ? workspace.allSessions : [],
                                         home: workspace.bot.profileName, picked: workspace.inboxScope.profile)
    }

    /// The source groups the list holds (`InboxScope.hiddenSources`), and Unread and Needs You,
    /// which narrow Main. Any of them changed, the filter turns blue: the list says it is narrowed
    /// without a line above it.
    private var sourceFilter: some View {
        let scope = workspace.inboxScope
        return Menu {
            Section {
                ForEach(InboxSourceGroup.allCases, id: \.self) { group in
                    Toggle(isOn: Binding {
                        workspace.inboxScope.shows(group)
                    } set: { shown in
                        workspace.inboxScope.set(group, shown: shown)
                    }) {
                        Label(group.title, systemImage: group.symbol)
                    }
                }
            }
            Section("Only") {
                Toggle("Unread", isOn: $workspace.inboxScope.unreadOnly)
                Toggle("Needs You", isOn: $workspace.inboxScope.needsYouOnly)
            }
            if !scope.isStandard {
                Section {
                    Button("Show Everything", systemImage: "line.3.horizontal.decrease.circle") {
                        workspace.inboxScope = .standard
                    }
                }
            }
        } label: {
            filterLabel(sourceWords.joined(separator: " · "))
        }
        .filterMenu(isActive: !scope.sourceChanges.isEmpty)
        .accessibilityLabel("Sources")
        .accessibilityValue(sourceWords.joined(separator: ", "))
        .accessibilityIdentifier("chat.sourceFilter")
    }

    /// A filter's current choice and the chevron that says it opens a menu.
    private func filterLabel(_ text: String) -> some View {
        HStack(spacing: 4) {
            Text(text)
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .imageScale(.small)
                .accessibilityHidden(true)
        }
    }

    /// What the Sources filter says: Unread and Needs You while either narrows Main, then which
    /// sources it holds ("No Telegram", "5 sources"), or "All sources" when nothing else needs
    /// saying. The state shows in its words as well as its blue.
    private var sourceWords: [String] {
        let scope = workspace.inboxScope
        var words: [String] = []
        if scope.unreadOnly { words.append(String(localized: "Unread")) }
        if scope.needsYouOnly { words.append(String(localized: "Needs You")) }
        // Named against the standard, which already leaves Scheduled out: hiding Telegram reads
        // "No Telegram", not "5 sources".
        let hidden = scope.hiddenSources
        let dropped = hidden.subtracting(InboxScope.standard.hiddenSources)
        if dropped.isEmpty {
            if words.isEmpty { words.append(String(localized: "All sources")) }
        } else if dropped.count == 1, let only = dropped.first {
            words.append(String(localized: "No \(only.title)"))
        } else {
            words.append(String(localized: "\(InboxSourceGroup.allCases.count - hidden.count) sources"))
        }
        return words
    }

    // MARK: Sessions

    @ViewBuilder
    private var sessionSections: some View {
        let sections = workspace.inboxSections
        let top = sections.pinned + sections.main
        let listed = ChatListSnapshot.listed(top, firstFrame: isFirstFrame)
        ForEach(listed, id: \.stableID) { session in
            sessionRow(session)
        }
        let isWhole = listed.count == top.count
        if isWhole, workspace.inboxScope.unreadOnly, !top.isEmpty {
            Button("Mark All as Read") {
                Task { await workspace.unread.markAllRead(workspace.unreadChatKeys) }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.primaryText)
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .modifier(SidebarRowInsets())
        }
        if isWhole, !sections.working.isEmpty {
            InboxRegionHeader(title: String(localized: "Working"), count: sections.working.count, isExpanded: $workspace.workingExpanded)
            if workspace.workingExpanded {
                ForEach(sections.working, id: \.stableID) { session in
                    sessionRow(session)
                }
            }
        }
        if isWhole { settledRegion }
        // The next page loads from a row at the very end that draws nothing, as in the sidebar, so
        // no loading rows stand below Settled (`docs/inbox.md` §5 Paging).
        if isWhole, workspace.hasMoreSessions, !workspace.inboxScope.narrowsMain {
            Color.clear
                .frame(height: 1)
                .accessibilityHidden(true)
                .modifier(SidebarRowInsets())
                .task(id: workspace.nextSessionOffset) { await workspace.loadMoreSessions() }
        }
    }

    @ViewBuilder
    private var settledRegion: some View {
        @Bindable var settled = workspace.settled
        let revealed = settled.revealed
        if (settled.isAvailable && settled.list.total != 0) || revealed != nil {
            InboxRegionHeader(title: String(localized: "Settled"), count: settled.list.total, isExpanded: $settled.isExpanded,
                              showsActivity: settled.hasActivity)
            let rows = settled.isExpanded ? settled.list.rows : []
            if let revealed, !rows.contains(where: { $0.stableID == revealed.stableID }) {
                settledRow(revealed)
            }
            ForEach(rows, id: \.stableID) { session in
                settledRow(session)
            }
            if settled.isExpanded {
                if settled.isLoading {
                    SkeletonRows(count: 2)
                        .padding(.vertical, 4)
                        .modifier(SidebarRowInsets())
                } else if settled.list.hasMore {
                    SettledMoreRow(settled: settled)
                }
            }
        }
    }

    @ViewBuilder
    private func sessionRow(_ session: HermesSession) -> some View {
        if workspace.waitingChat(forKey: session.stableID) != nil {
            row(session)
                .contextMenu {
                    Button("Delete…", systemImage: "trash", role: .destructive) { deleting = session }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button("Delete", systemImage: "trash", role: .destructive) { deleting = session }
                }
        } else {
            row(session)
                .contextMenu { contextMenu(for: session) }
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    Button(isUnread(session) ? "Read" : "Unread",
                           systemImage: isUnread(session) ? "envelope.open" : "envelope.badge") {
                        toggleRead(session.stableID, isUnread: isUnread(session))
                    }
                    .tint(Theme.swipeAction)
                    Button(session.pinned ? "Unpin" : "Pin", systemImage: session.pinned ? "pin.slash" : "pin") {
                        togglePin(session)
                    }
                    .tint(Theme.swipeActionQuiet)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button("Settle", systemImage: "checkmark.circle") { archive(session) }
                        .tint(Theme.swipeAction)
                    Button(workspace.unread.isMuted(session.stableID) ? "Unmute" : "Mute",
                           systemImage: workspace.unread.isMuted(session.stableID) ? "bell" : "bell.slash") {
                        toggleMute(session.stableID, muted: workspace.unread.isMuted(session.stableID))
                    }
                    .tint(Theme.swipeActionQuiet)
                }
        }
    }

    private func row(_ session: HermesSession) -> some View {
        SidebarRow(isSelected: false, height: InboxMetrics.botRowHeight) {
            workspace.pick(.session(session.stableID))
        } label: {
            IOSChatRow(session: session, workspace: workspace)
        }
    }

    @ViewBuilder
    private func settledRow(_ session: HermesSession) -> some View {
        SettledRow(session: session, workspace: workspace)
            .contextMenu {
                Button("Un-settle", systemImage: "tray.and.arrow.up") { unsettle(session) }
                Divider()
                Button("Rename…", systemImage: "pencil") {
                    renameText = session.title ?? ""
                    renaming = session
                }
                Button("Copy Session ID", systemImage: "number") { Pasteboard.copy(session.id) }
                Divider()
                Button("Delete…", systemImage: "trash", role: .destructive) { deleting = session }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button("Un-settle", systemImage: "tray.and.arrow.up") { unsettle(session) }
                    .tint(Theme.swipeAction)
            }
    }

    // MARK: Row actions

    private func isUnread(_ session: HermesSession) -> Bool {
        workspace.unread.badge(for: session.stableID).isUnread
            || workspace.unread.readMark(for: session.stableID) == .markedUnread
    }

    private func toggleRead(_ key: String, isUnread: Bool) {
        if isUnread { workspace.unread.markRead(key) } else { workspace.unread.markUnread(key) }
    }

    private func togglePin(_ session: HermesSession) {
        Task { await run { try await workspace.setPinned(session, !session.pinned) } }
    }

    private func toggleMute(_ key: String, muted: Bool) {
        if muted { workspace.unread.unmute(key) } else { workspace.unread.mute(key, for: .untilTurnedOff) }
    }

    private func archive(_ session: HermesSession) {
        Task { await run { try await workspace.archive(session) } }
    }

    private func unsettle(_ session: HermesSession) {
        Task { await run { try await workspace.unarchive(session) } }
    }

    @ViewBuilder
    private func contextMenu(for session: HermesSession) -> some View {
        let key = session.stableID
        let unread = isUnread(session)
        Button(unread ? "Mark as Read" : "Mark as Unread", systemImage: unread ? "envelope.open" : "envelope.badge") {
            toggleRead(key, isUnread: unread)
        }
        Button(session.pinned ? "Unpin" : "Pin", systemImage: session.pinned ? "pin.slash" : "pin") {
            togglePin(session)
        }
        MuteMenu(unread: workspace.unread, key: key)
        Divider()
        Button("Rename…", systemImage: "pencil") {
            renameText = session.title ?? ""
            renaming = session
        }
        if workspace.capabilities?.features.sessionFork != false {
            Button("Branch", systemImage: "arrow.triangle.branch") {
                Task { await run { try await workspace.fork(session) } }
            }
        }
        if workspace.roster?.isConnected == true {
            Button("Checkpoints…", systemImage: "clock.arrow.circlepath") {
                workspace.showCheckpoints(for: session)
            }
        }
        Button("Copy Session ID", systemImage: "number") { Pasteboard.copy(session.id) }
        Divider()
        Button("Settle", systemImage: "checkmark.circle") { archive(session) }
        Button("Delete…", systemImage: "trash", role: .destructive) { deleting = session }
    }

    private func commitRename() {
        guard let session = renaming else { return }
        let title = renameText
        Task { await run { try await workspace.rename(session, to: title) } }
    }

    private func delete(_ session: HermesSession) {
        Task { await run { try await workspace.delete(session) } }
    }

    private func run(_ action: () async throws -> Void) async {
        do {
            try await action()
        } catch {
            actionError = error as? HermesError ?? .invalidResponse(error.localizedDescription)
        }
    }

    private var renameBinding: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
    }

    // MARK: States

    @ViewBuilder
    private var stateView: some View {
        if workspace.scopeHoldsNothing {
            if let profile = workspace.inboxScope.profile, workspace.listsEveryProfile, !hasChats(in: profile) {
                CaughtUpState(profile: profile)
            } else {
                CaughtUpState(sources: ())
            }
        } else if workspace.inboxScope.narrowsMain {
            if workspace.inboxSessions.isEmpty {
                CaughtUpState(scope: workspace.inboxScope)
            }
        } else if workspace.allSessions.isEmpty, !workspace.isLoadingSessions {
            switch workspace.connection {
            case .online:
                SidebarState(
                    symbol: "bubble.left.and.bubble.right",
                    title: String(localized: "No chats yet"),
                    message: String(localized: "Your conversations with \(workspace.bot.name) appear here, including ones from Telegram, Discord and the CLI.")
                )
            case .connecting, .idle:
                SidebarState(isLoading: true, title: String(localized: "Connecting to \(workspace.bot.name)…"))
            case .failed(let error):
                SidebarState(
                    symbol: "wifi.slash",
                    title: String(localized: "Can't reach \(workspace.bot.name)"),
                    message: error.errorDescription,
                    actionTitle: String(localized: "Retry")
                ) {
                    Task { await workspace.connect() }
                }
            }
        }
    }

    /// Whether any chat in the list ran in the profile. Read only while the list holds nothing, so
    /// the walk never runs as rows draw.
    private func hasChats(in profile: String) -> Bool {
        let home = workspace.bot.profileName
        return workspace.allSessions.contains { ProfileRows.profileName(of: $0, home: home) == profile }
    }
}

extension View {
    /// The two filters under the title: the system's bordered capsule, in the quiet colour, or
    /// tinted blue while it narrows the list (`docs/inbox.md` §10).
    fileprivate func filterMenu(isActive: Bool) -> some View {
        menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            .tint(isActive ? Theme.link : Theme.secondaryText)
    }
}

/// Search over the chat list: the same field, chips and results as the split view's sidebar
/// (`docs/search.md`), on its own page behind the round button. A result opens its chat and the
/// page closes; Back returns to the list.
struct IOSSearchPage: View {
    @Bindable var workspace: BotWorkspace
    @Environment(\.dismiss) private var dismiss
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationStack {
            List {
                SearchResultsSection(workspace: workspace)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Theme.canvas)
            .environment(\.defaultMinListRowHeight, 10)
            .overlay {
                // A query with no results says so; an empty field has nothing to report.
                if !workspace.searchText.isEmpty, workspace.search.isEmpty {
                    SearchEmptyState(search: workspace.search)
                }
            }
            .searchable(text: $workspace.searchText, prompt: String(localized: "Search chats"))
            .searchFocused($searchFocused)
            .onAppear { searchFocused = true }
            .onChange(of: workspace.searchText, initial: true) {
                if workspace.search.query != workspace.searchText { workspace.search.query = workspace.searchText }
            }
            // A result picked opens its screen behind this page; close it so it is what shows.
            .onChange(of: workspace.navigation.pushes) { dismiss() }
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}
#endif
