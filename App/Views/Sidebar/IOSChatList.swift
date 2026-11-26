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

    var body: some View {
        List {
            sessionSections
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
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
        .fullScreenCover(isPresented: $showsSearch) {
            IOSSearchPage(workspace: workspace)
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
                Button {
                    showsSearch = true
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Theme.primaryText)
                        .frame(width: 34, height: 34)
                        .background(Theme.controlFill, in: Circle())
                        .overlay { Circle().strokeBorder(Theme.hairline, lineWidth: 0.5) }
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Search")
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

    /// One profile at a time (`InboxScope.profile`): All Profiles, or one of the profiles the list
    /// holds. It stays visible without Bot Mode, where All and the gateway's profile are the only
    /// choices and the filter changes nothing.
    private var profileFilter: some View {
        let picked = workspace.inboxScope.profile
        let profiles = ProfileRows.profiles(in: workspace.allSessions, home: workspace.bot.profileName)
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
            FilterPill(text: picked ?? String(localized: "All Profiles"))
        }
        .accessibilityLabel("Profile")
        .accessibilityValue(picked ?? String(localized: "All Profiles"))
        .accessibilityIdentifier("chat.profileFilter")
    }

    /// The source groups the list holds (`InboxScope.hiddenSources`).
    private var sourceFilter: some View {
        Menu {
            ForEach(InboxSourceGroup.allCases, id: \.self) { group in
                Toggle(isOn: Binding {
                    workspace.inboxScope.shows(group)
                } set: { shown in
                    workspace.inboxScope.set(group, shown: shown)
                }) {
                    Label(group.title, systemImage: group.symbol)
                }
            }
            if !workspace.inboxScope.isStandard {
                Divider()
                Button("Show Everything", systemImage: "line.3.horizontal.decrease.circle") {
                    workspace.inboxScope = .standard
                }
            }
        } label: {
            FilterPill(text: sourceLabel)
        }
        .accessibilityLabel("Sources")
        .accessibilityValue(sourceLabel)
        .accessibilityIdentifier("chat.sourceFilter")
    }

    private var sourceLabel: String {
        let hidden = workspace.inboxScope.hiddenSources
        if hidden.isEmpty || hidden == InboxScope.standard.hiddenSources {
            return String(localized: "All sources")
        }
        if hidden.count == 1, let only = hidden.first {
            return String(localized: "No \(only.title)")
        }
        return String(localized: "\(InboxSourceGroup.allCases.count - hidden.count) sources")
    }

    // MARK: Sessions

    @ViewBuilder
    private var sessionSections: some View {
        let sections = workspace.inboxSections
        let top = sections.pinned + sections.main
        if !workspace.inboxScope.isStandard {
            FilteredLine(workspace: workspace)
        }
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
        if isWhole, workspace.hasMoreSessions, !workspace.inboxScope.narrowsMain {
            SkeletonRows(count: 2)
                .padding(.vertical, 8)
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

    private func sessionRow(_ session: HermesSession) -> some View {
        SidebarRow(isSelected: false, height: InboxMetrics.rowHeight) {
            workspace.pick(.session(session.stableID))
        } label: {
            ChatInboxRow(session: session, workspace: workspace)
        }
    }

    private func settledRow(_ session: HermesSession) -> some View {
        SettledRow(session: session, workspace: workspace)
    }

    // MARK: States

    @ViewBuilder
    private var stateView: some View {
        if workspace.scopeHoldsNothing {
            CaughtUpState(sources: ())
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
}

/// A filter's quiet capsule: its current choice and a chevron, as the design draws the two
/// filters under the title (`mockup-v2.html`).
struct FilterPill: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Text(text)
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.tertiaryText)
                .accessibilityHidden(true)
        }
        .font(.footnote)
        .foregroundStyle(Theme.secondaryText)
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Theme.controlFill, in: Capsule())
        .overlay { Capsule().strokeBorder(Theme.hairline, lineWidth: 0.5) }
        .contentShape(Capsule())
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
                if workspace.searchText.isEmpty {
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
