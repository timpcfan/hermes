#if os(iOS)
import HermesKit
import SwiftUI

/// The iPhone's root (BRIEF ios-tab-layout): the system's tab bar with Chats, Bots and Settings,
/// and the compose button beside it. iPad and Mac keep the split view in `MainView`; this file is
/// only compiled for iOS and only shown at a compact width.
///
/// The tab bar is the system's own, untouched: it shrinks as a list scrolls down and hides under a
/// pushed screen. A picked chat, Bot chat, group or page pushes over its tab's list with the
/// system's back button and swipe (`docs/design-to-swiftui.md` §6). The selection itself stays in
/// `BotWorkspace`, so notifications, search and links open screens exactly as they do on iPad and
/// Mac.
struct IOSMainView: View {
    @Bindable var workspace: BotWorkspace
    /// The window was left on the list (not in a pushed screen), kept with the window.
    var onListChanged: (Bool) -> Void = { _ in }

    @State private var tab = IOSMainTab.chats
    /// Each list's pushed screen. At most one holds one: a push into one tab clears the other, so
    /// two tabs never draw the same selection.
    @State private var chatPath: [DetailRoute] = []
    @State private var botPath: [DetailRoute] = []
    /// The compose circle on the Bot tab asked whether to make a Bot or a group chat.
    @State private var isChoosingNew = false

    private var showsDetail: Bool { !chatPath.isEmpty || !botPath.isEmpty }

    var body: some View {
        tabs
            .tabBarMinimizeBehavior(.onScrollDown)
            .confirmationDialog("New", isPresented: $isChoosingNew, titleVisibility: .hidden) {
                IOSComposeButton.newBotActions(workspace)
            }
            .onChange(of: workspace.navigation.pushes) { pushSelection() }
            .onChange(of: workspace.navigation.pops) { popToRoot() }
            .onChange(of: showsDetail) { _, shows in
                workspace.setShowsDetail(shows)
                onListChanged(!shows)
            }
            .onChange(of: tab) { _, newTab in
                // The first screen's mode follows the tab the person picked, so iPad and Mac open
                // where it was. A deep link into a Bot chat doesn't change it (the chat is the same
                // screen in both modes, and the mode's remembered selection must not replace it).
                guard !showsDetail else { return }
                switch newTab {
                case .chats where workspace.sidebarMode != .chats: workspace.sidebarMode = .chats
                case .bots where workspace.sidebarMode != .bots: workspace.sidebarMode = .bots
                default: break
                }
                Keyboard.dismiss()
            }
            .onAppear {
                guard !showsDetail else { return }
                workspace.setShowsDetail(false)
                onListChanged(true)
            }
    }

    /// From iOS 27 the compose button is the bar's own prominent tab: the system draws it as a
    /// separate glass circle beside the tabs, on the same line, and shrinks and hides it with the
    /// bar. It stays on every tab, because taking it away moves the whole bar. iOS 26 has no
    /// prominent tab, so there the button floats over the lists instead (`stack`).
    @ViewBuilder private var tabs: some View {
        if #available(iOS 27.0, *) {
            TabView(selection: pickingCompose) {
                chatsTab
                botsTab
                settingsTab
                Tab(composeTitle, systemImage: "square.and.pencil", value: IOSMainTab.compose, role: .prominent) {
                    // Never shown: picking the circle acts instead (`pickingCompose`).
                    Color.clear
                }
                .disabled(tab == .bots && workspace.roster?.isConnected != true)
            }
        } else {
            TabView(selection: $tab) {
                chatsTab
                botsTab
                settingsTab
            }
        }
    }

    private var chatsTab: some TabContent<IOSMainTab> {
        Tab("Chats", systemImage: "bubble.left", value: IOSMainTab.chats) {
            stack(.chats, path: $chatPath) { IOSChatList(workspace: workspace) }
        }
    }

    private var botsTab: some TabContent<IOSMainTab> {
        Tab("Bots", systemImage: "person.2", value: IOSMainTab.bots) {
            stack(.bots, path: $botPath) { IOSBotList(workspace: workspace) }
        }
    }

    private var settingsTab: some TabContent<IOSMainTab> {
        Tab("Settings", systemImage: "gearshape", value: IOSMainTab.settings) {
            // Settings brings its own NavigationStack; a second one around it would nest.
            SettingsView(allowsDismiss: false)
        }
    }

    /// What the compose circle makes on this tab, for VoiceOver.
    private var composeTitle: LocalizedStringResource {
        tab == .bots ? "New" : "New Chat"
    }

    /// The tab selection, except that picking the compose circle acts and leaves the tab as it was.
    /// The action waits a turn: run inside the selection change, the screen it pushes hides and
    /// shows the bar while the bar is still settling, and the bar comes back centred and unlabelled.
    private var pickingCompose: Binding<IOSMainTab> {
        Binding {
            tab
        } set: { picked in
            guard picked == .compose else {
                tab = picked
                return
            }
            Task { compose() }
        }
    }

    /// The compose circle: a new chat on Chats and Settings (which moves to Chats to show it), and
    /// on Bots the choice of a new Bot or group chat.
    private func compose() {
        if tab == .bots {
            isChoosingNew = true
        } else {
            IOSComposeButton.startNewChat(in: workspace)
        }
    }

    /// A list and the screens pushed over it. The tab bar steps aside for a pushed screen, as the
    /// system's own apps do; the list keeps its own header in place of a navigation bar.
    private func stack(_ list: IOSMainTab, path: Binding<[DetailRoute]>, @ViewBuilder root: () -> some View) -> some View {
        NavigationStack(path: path) {
            root()
                .toolbar(.hidden, for: .navigationBar)
                .safeAreaInset(edge: .bottom, alignment: .trailing, spacing: 0) {
                    if #available(iOS 27.0, *) {
                        // The compose circle is the bar's prominent tab (`tabs`).
                        EmptyView()
                    } else {
                        IOSComposeButton(tab: list, workspace: workspace)
                            .padding(.trailing, 16)
                            .padding(.bottom, 8)
                    }
                }
                .navigationDestination(for: DetailRoute.self) { _ in
                    DetailView(workspace: workspace)
                        .toolbar(.hidden, for: .tabBar)
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
        if tab == .bots {
            chatPath.removeAll()
            push(route, on: &botPath)
        } else {
            botPath.removeAll()
            push(route, on: &chatPath)
        }
    }

    private func push(_ route: DetailRoute, on path: inout [DetailRoute]) {
        if path.isEmpty {
            path = [route]
        } else {
            path[path.count - 1] = route
        }
    }

    /// The screen on show went away under the person (its chat deleted or archived): back to the
    /// list, as a collapsed split view does.
    private func popToRoot() {
        if !chatPath.isEmpty { chatPath.removeAll() }
        if !botPath.isEmpty { botPath.removeAll() }
    }
}

/// The tabs, in the order the bar shows them. `compose` is the round button beside the bar from
/// iOS 27: a tab only in form, so it is never the selection.
enum IOSMainTab: Hashable {
    case chats, bots, settings, compose
}

/// The round button over a list's bottom-right corner, above the tab bar, on iOS 26 (from iOS 27
/// the bar's prominent tab takes its place): New Chat on Chats, and on Bots a menu with New Bot and
/// New Group Chat. Settings has nothing to create, so it has none. System glass, nothing drawn by
/// hand.
struct IOSComposeButton: View {
    let tab: IOSMainTab
    let workspace: BotWorkspace

    var body: some View {
        switch tab {
        case .chats:
            Button("New Chat", systemImage: "square.and.pencil") {
                Self.startNewChat(in: workspace)
            }
            .labelStyle(.iconOnly)
            .buttonBorderShape(.circle)
            .controlSize(.extraLarge)
            .glassButton()
            .accessibilityIdentifier("tab.compose")
        case .bots:
            Menu {
                Self.newBotActions(workspace)
            } label: {
                Label("New", systemImage: "plus")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.button)
            .buttonBorderShape(.circle)
            .controlSize(.extraLarge)
            .glassButton()
            .disabled(workspace.roster?.isConnected != true)
            .accessibilityIdentifier("tab.compose")
        case .settings, .compose:
            EmptyView()
        }
    }

    /// Starts a new chat with the existing flow. The draft is a Chats-mode screen: make sure the
    /// mode agrees before the detail resolves its route.
    static func startNewChat(in workspace: BotWorkspace) {
        if workspace.sidebarMode != .chats { workspace.sidebarMode = .chats }
        workspace.startNewChat()
    }

    /// New Bot and New Group Chat: the Bot tab's menu here, and its choice under the compose circle.
    @ViewBuilder static func newBotActions(_ workspace: BotWorkspace) -> some View {
        if let roster = workspace.roster {
            Button("New Bot", systemImage: "plus") { roster.isCreatingBot = true }
                .disabled(!roster.isConnected)
            if roster.groupRooms.isAvailable {
                Button("New Group Chat", systemImage: "person.3") { roster.isCreatingGroup = true }
                    .disabled(!roster.isConnected || roster.visibleBots.count < 2)
            }
        }
    }
}
#endif
