#if os(iOS)
import HermesKit
import SwiftUI

/// The iPhone's root (BRIEF ios-tab-layout): three tabs, a floating capsule bar and a separate
/// compose button. iPad and Mac keep the split view in `MainView`; this file is only compiled for
/// iOS and only shown at a compact width.
///
/// The chat list is the first screen; a picked chat, Bot chat, group or page pushes over it with
/// the system's back button and swipe, and the bar goes away (`docs/design-to-swiftui.md` §6).
/// The selection itself stays in `BotWorkspace`, so notifications, search and links open screens
/// exactly as they do on iPad and Mac.
struct IOSMainView: View {
    @Bindable var workspace: BotWorkspace
    /// The window was left on the list (not in a pushed screen), kept with the window.
    var onListChanged: (Bool) -> Void = { _ in }

    @State private var tab = IOSMainTab.chats
    @State private var path: [DetailRoute] = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .bottom) {
            content
                // The floating bar sits over the content; rows end above it instead of under it.
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if path.isEmpty { Color.clear.frame(height: 70) }
                }
            if path.isEmpty {
                IOSTabBar(tab: $tab, workspace: workspace)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(Theme.canvas)
        .animation(reduceMotion ? nil : Theme.snappy, value: path.isEmpty)
        .onChange(of: workspace.navigation.pushes) { pushSelection() }
        .onChange(of: workspace.navigation.pops) { popToRoot() }
        .onChange(of: path) { _, newPath in
            let shows = !newPath.isEmpty
            workspace.setShowsDetail(shows)
            onListChanged(!shows)
        }
        .onChange(of: tab) { _, newTab in
            // The first screen's mode follows the tab the person picked, so iPad and Mac open
            // where it was. A deep link into a Bot chat doesn't change it (the chat is the same
            // screen in both modes, and the mode's remembered selection must not replace it).
            guard path.isEmpty else { return }
            switch newTab {
            case .chats where workspace.sidebarMode != .chats: workspace.sidebarMode = .chats
            case .bots where workspace.sidebarMode != .bots: workspace.sidebarMode = .bots
            default: break
            }
            Keyboard.dismiss()
        }
        .onAppear {
            guard path.isEmpty else { return }
            workspace.setShowsDetail(false)
            onListChanged(true)
        }
    }

    @ViewBuilder
    private var content: some View {
        if tab == .settings {
            // Settings brings its own NavigationStack; a second one around it would nest.
            SettingsView(allowsDismiss: false)
        } else {
            NavigationStack(path: $path) {
                Group {
                    switch tab {
                    case .chats: IOSChatList(workspace: workspace)
                    case .bots: IOSBotList(workspace: workspace)
                    case .settings: EmptyView()
                    }
                }
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: DetailRoute.self) { _ in
                    DetailView(workspace: workspace)
                }
            }
        }
    }

    /// A selection asked to be seen (`CompactNavigation.pushes`): New Chat, a row, a search result,
    /// a notification or a link.
    private func pushSelection() {
        let route = workspace.detailRoute(compact: true)
        // Bots mode with nothing picked is the Bot tab's own list, not a screen over it.
        if route == .botsHome {
            tab = .bots
            popToRoot()
            return
        }
        if tab == .settings {
            switch workspace.selection {
            case .bot, .group: tab = .bots
            default: tab = .chats
            }
        }
        if path.isEmpty {
            path = [route]
        } else {
            path[path.count - 1] = route
        }
    }

    /// The screen on show went away under the person (its chat deleted or archived): back to the
    /// list, as a collapsed split view does.
    private func popToRoot() {
        guard !path.isEmpty else { return }
        path.removeAll()
    }
}

/// The tabs, in the order the bar draws them.
enum IOSMainTab: String, CaseIterable, Identifiable {
    case chats, bots, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chats: String(localized: "Chats")
        case .bots: String(localized: "Bots")
        case .settings: String(localized: "Settings")
        }
    }
}

/// The floating bar: a glass capsule with the three tabs, and the round compose button beside it.
struct IOSTabBar: View {
    @Binding var tab: IOSMainTab
    let workspace: BotWorkspace

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                ForEach(IOSMainTab.allCases) { item in
                    tabButton(item)
                }
            }
            .padding(5)
            .frame(height: 54)
            .glassEffect(.regular, in: .capsule)

            compose
                .frame(width: 54, height: 54)
                .glassEffect(.regular, in: .circle)
        }
        .accessibilityElement(children: .contain)
    }

    private func tabButton(_ item: IOSMainTab) -> some View {
        let isSelected = tab == item
        return Button {
            tab = item
        } label: {
            icon(item)
                .frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(isSelected ? Theme.link : Theme.secondaryText)
                .background {
                    if isSelected {
                        Capsule().fill(Theme.controlFill)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private func icon(_ item: IOSMainTab) -> some View {
        switch item {
        case .chats:
            Image(systemName: "bubble.left")
                .font(.system(size: 21, weight: .regular))
        case .bots:
            // The mock's robot; SF Symbols has no robot, so it is drawn (antenna, head, eyes).
            RobotGlyph(size: 22, color: tab == .bots ? Theme.link : Theme.secondaryText)
        case .settings:
            Image(systemName: "gearshape")
                .font(.system(size: 21, weight: .regular))
        }
    }

    /// New Chat, or in Bots mode New Bot / New Group Chat. Settings has nothing to create, so the
    /// button is there but dimmed.
    @ViewBuilder
    private var compose: some View {
        switch tab {
        case .chats:
            Button {
                // The new-chat draft is a Chats-mode screen: make sure the mode agrees before the
                // detail resolves its route.
                if workspace.sidebarMode != .chats { workspace.sidebarMode = .chats }
                workspace.startNewChat()
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 21, weight: .regular))
                    .foregroundStyle(Theme.primaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("New Chat")
        case .bots:
            Menu {
                if let roster = workspace.roster {
                    Button("New Bot", systemImage: "plus") { roster.isCreatingBot = true }
                        .disabled(!roster.isConnected)
                    if roster.groupRooms.isAvailable {
                        Button("New Group Chat", systemImage: "person.3") { roster.isCreatingGroup = true }
                            .disabled(!roster.isConnected || roster.visibleBots.count < 2)
                    }
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(Theme.primaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .disabled(workspace.roster?.isConnected != true)
            .accessibilityLabel("New")
        case .settings:
            Image(systemName: "square.and.pencil")
                .font(.system(size: 21, weight: .regular))
                .foregroundStyle(Theme.tertiaryText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityHidden(true)
        }
    }
}

/// A robot head for the Bot tab: rounded head with two eyes, a mouth and an antenna. SF Symbols
/// has no robot; the design's tab icon is this shape (`mockup-v2.html`).
struct RobotGlyph: View {
    var size: CGFloat = 22
    var color: Color = .primary

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.16, style: .continuous)
                .strokeBorder(color, lineWidth: size * 0.085)
                .frame(width: size * 0.68, height: size * 0.54)
                .offset(y: size * 0.08)
            Capsule()
                .fill(color)
                .frame(width: size * 0.085, height: size * 0.15)
                .offset(y: -size * 0.33)
            Circle()
                .fill(color)
                .frame(width: size * 0.13, height: size * 0.13)
                .offset(y: -size * 0.44)
            HStack(spacing: size * 0.17) {
                Circle().fill(color).frame(width: size * 0.12, height: size * 0.12)
                Circle().fill(color).frame(width: size * 0.12, height: size * 0.12)
            }
            .offset(y: size * 0.02)
            Capsule()
                .fill(color)
                .frame(width: size * 0.2, height: size * 0.065)
                .offset(y: size * 0.22)
            HStack(spacing: size * 0.74) {
                Capsule().fill(color).frame(width: size * 0.1, height: size * 0.08)
                Capsule().fill(color).frame(width: size * 0.1, height: size * 0.08)
            }
            .offset(y: size * 0.1)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
#endif
