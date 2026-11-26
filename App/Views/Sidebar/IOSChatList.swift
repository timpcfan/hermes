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
    }

    // MARK: Header

    /// "Hermes" and, beside it, the gateway's connection: a dot in the state's colour and its
    /// name. The search button joins them in P2.
    private var header: some View {
        let status = ConnectionStatus(workspace)
        return HStack(alignment: .center, spacing: 8) {
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
        }
        .padding(.horizontal, 18)
        .padding(.top, 2)
        .padding(.bottom, 6)
        .background(Theme.canvas)
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
#endif
