#if os(iOS)
import HermesKit
import SwiftUI

/// The Bot tab: every Bot as a row, pinned first, then groups and the hidden ones folded away —
/// the same `BotRosterSections` the split view's Bots mode lists (BRIEF: the existing All Bots
/// list, no filter bar here). Without Bot Mode the tab says what is missing and how to link it.
struct IOSBotList: View {
    @Bindable var workspace: BotWorkspace
    @Environment(WindowRouter.self) private var router: WindowRouter?

    var body: some View {
        Group {
            if let roster = workspace.roster {
                List {
                    BotRosterSections(roster: roster, workspace: workspace)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .environment(\.defaultMinListRowHeight, 10)
                .environment(\.sidebarShowsSelection, false)
                .scrollEdgeEffectStyle(.soft, for: .top)
                .overlay { state(roster) }
                .refreshable { await roster.refresh() }
            } else {
                ScrollView {
                    BotModeSetupMessage(
                        workspace: workspace,
                        feature: GatewaySetup.ID.botMode,
                        title: String(localized: "Bots"),
                        symbol: "person.2"
                    )
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .background(Theme.canvas)
    }

    private var header: some View {
        HStack {
            Text("Bots")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(Theme.primaryText)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 18)
        .padding(.top, 2)
        .padding(.bottom, 6)
        .background(Theme.canvas)
    }

    /// Before the first list: what the connection is doing; with Bots listed, the rows speak for
    /// themselves and the footer used to say the rest.
    @ViewBuilder
    private func state(_ roster: BotRoster) -> some View {
        switch roster.state {
        case .connecting, .idle:
            if !roster.hasLoaded {
                SidebarState(isLoading: true, title: String(localized: "Connecting to your Bots…"))
            }
        case .signInRequired(let message):
            SidebarState(
                symbol: "person.badge.key",
                title: String(localized: "Sign in to see your Bots"),
                message: message,
                actionTitle: String(localized: "Sign In…")
            ) {
                router?.sheet = .editGateway(workspace.bot)
            }
        case .failed(let reason) where !roster.hasLoaded:
            let refusal = workspace.accessRefusal
            SidebarState(
                symbol: "wifi.slash",
                title: String(localized: "Bots are offline"),
                message: reason.isEmpty ? String(localized: "Check that hermes serve is running on \(workspace.bot.name), then try again.") : reason,
                actionTitle: refusal == nil ? String(localized: "Retry") : refusal?.isSignIn == true ? String(localized: "Sign In…") : String(localized: "Access")
            ) {
                if refusal == nil {
                    Task { await roster.reconnectNow() }
                } else {
                    router?.sheet = .editGateway(workspace.bot)
                }
            }
        case .failed:
            EmptyView()
        case .online:
            if roster.hasLiveList, roster.profiles.isEmpty {
                SidebarState(
                    symbol: "face.smiling",
                    title: String(localized: "No Bots yet"),
                    message: String(localized: "Create one to give it a name, a face and its own chat."),
                    actionTitle: String(localized: "New Bot")
                ) {
                    roster.isCreatingBot = true
                }
            }
        }
    }
}
#endif
