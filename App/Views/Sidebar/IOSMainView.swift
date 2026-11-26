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
    /// What the bar itself shows. The compose circle is a tab in form only (iOS 27's prominent
    /// tab), so a tap on it is undone here before SwiftUI keeps it: left selected, its empty
    /// content would leave a black screen with no way back (`docs/inbox.md` §9).
    @State private var barSelection = IOSMainTab.chats
    /// Each list's pushed screen. At most one holds one: a push into one tab clears the other, so
    /// two tabs never draw the same selection.
    @State private var chatPath: [DetailRoute] = []
    @State private var botPath: [DetailRoute] = []
    /// The plus on the Bot tab opened its panel: New Bot or New Group Chat.
    @State private var isChoosingNew = false
    /// The window's width: the panel's rows wrap rather than run wider than the screen.
    @State private var windowWidth: CGFloat = 0
    /// The pencil opened its panel of profiles (`docs/inbox.md` §9).
    @State private var isChoosingProfile = false

    private var showsDetail: Bool { !chatPath.isEmpty || !botPath.isEmpty }

    var body: some View {
        tabs
            .tabBarMinimizeBehavior(.onScrollDown)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { windowWidth = $0 }
            .onChange(of: workspace.navigation.pushes) {
                // A chat opened under the panel closes it, as a popover would.
                closeComposePanels()
                pushSelection()
            }
            .onChange(of: workspace.navigation.pops) { popToRoot() }
            .onChange(of: showsDetail) { _, shows in
                workspace.setShowsDetail(shows)
                onListChanged(!shows)
            }
            .onChange(of: barSelection) { _, picked in
                pickFromBar(picked)
            }
            .onChange(of: tab) { _, newTab in
                // The panel belongs to the tab it was opened on.
                closeComposePanels()
                if barSelection != newTab { barSelection = newTab }
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
    /// bar. It stays on every tab, because taking it away moves the whole bar. On the Bot tab it
    /// is a plus, and its popover hangs from it. iOS 26 has no prominent tab, so there the button
    /// floats over the lists instead (`stack`).
    @ViewBuilder private var tabs: some View {
        if #available(iOS 27.0, *) {
            TabView(selection: $barSelection) {
                chatsTab
                botsTab
                settingsTab
                Tab(composeTitle, systemImage: composeSymbol, value: IOSMainTab.compose, role: .prominent) {
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

    /// A plus where the circle makes a Bot or a group chat, a pencil where it makes a chat.
    private var composeSymbol: String {
        tab == .bots ? "plus" : "square.and.pencil"
    }

    /// How far the panel sits from the list's edge: clear of the circle on iOS 26, which floats
    /// over the list, and just above the bar from iOS 27, where the circle is the bar's own tab.
    private var composeMenuInset: CGFloat {
        if #available(iOS 27.0, *) { return 8 }
        return 60
    }

    /// New Bot and New Group Chat, in a panel hanging by the circle. A pick closes the panel and
    /// is made at once (`IOSComposeButton.start`).
    @ViewBuilder private var newBotPanel: some View {
        ComposeMenuPanel(maxWidth: windowWidth > 0 ? windowWidth - 40 : .infinity,
                         edge: .bottom, inset: composeMenuInset, onDismiss: { isChoosingNew = false }) {
            IOSComposeButton.newBotActions(workspace) { choice in
                isChoosingNew = false
                IOSComposeButton.start(choice, in: workspace)
            }
        }
    }

    /// New Chat's profiles in a panel by the pencil, as New Bot's hangs by the plus: the most used
    /// last, nearest the thumb (`docs/inbox.md` §9).
    @ViewBuilder private var newChatPanel: some View {
        ComposeMenuPanel(maxWidth: windowWidth > 0 ? windowWidth - 40 : .infinity,
                         edge: .bottom, inset: composeMenuInset, onDismiss: { isChoosingProfile = false }) {
            IOSComposeButton.newChatActions(workspace) { profile in
                isChoosingProfile = false
                IOSComposeButton.startNewChat(in: workspace, profile: profile)
            }
        }
    }

    /// Picking the compose circle acts and leaves the bar on the tab it was on: that tab has no
    /// screen behind it, and left selected it showed a black one with no way back. The action
    /// waits a turn: run inside the selection change, the screen it pushes hides and shows the bar
    /// while the bar is still settling.
    private func pickFromBar(_ picked: IOSMainTab) {
        guard picked == .compose else {
            tab = picked
            return
        }
        barSelection = tab
        Task { compose() }
    }

    /// The compose circle: a new chat on Chats and Settings (which moves to Chats to show it), and
    /// on Bots the popover with New Bot and New Group Chat.
    private func compose() {
        // A second tap on the circle closes its panel rather than opening it again: the panel sits
        // over the only thing the person can still tap.
        if isChoosingNew {
            isChoosingNew = false
            return
        }
        if isChoosingProfile {
            isChoosingProfile = false
            return
        }
        if tab == .bots {
            isChoosingNew = true
        } else if !workspace.newChatProfiles.isEmpty {
            // The list holds every profile's chats: which one the chat starts in comes first.
            isChoosingProfile = true
        } else {
            IOSComposeButton.startNewChat(in: workspace)
        }
    }

    /// Closes the circle's panel: a tab change, or a chat opening, leaves it behind.
    private func closeComposePanels() {
        isChoosingNew = false
        isChoosingProfile = false
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
                // The circle's panels, drawn here rather than as popovers: iOS squares a popover's
                // corner above its arrow when the arrow lands near the screen's edge.
                .overlay(alignment: .bottomTrailing) {
                    if isChoosingNew {
                        newBotPanel
                    } else if isChoosingProfile {
                        newChatPanel
                    }
                }
                .animation(.snappy(duration: 0.18), value: isChoosingNew)
                .animation(.snappy(duration: 0.18), value: isChoosingProfile)
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
            if workspace.newChatProfiles.isEmpty {
                Button("New Chat", systemImage: "square.and.pencil") {
                    Self.startNewChat(in: workspace)
                }
                .labelStyle(.iconOnly)
                .buttonBorderShape(.circle)
                .controlSize(.extraLarge)
                .glassButton()
                .accessibilityIdentifier("tab.compose")
            } else {
                // A system menu opens upward from the corner, so its last row is nearest the thumb.
                Menu {
                    Self.newChatActions(workspace) { Self.startNewChat(in: workspace, profile: $0) }
                } label: {
                    Label("New Chat", systemImage: "square.and.pencil")
                        .labelStyle(.iconOnly)
                }
                .menuStyle(.button)
                .menuOrder(.fixed)
                .buttonBorderShape(.circle)
                .controlSize(.extraLarge)
                .glassButton()
                .accessibilityIdentifier("tab.compose")
            }
        case .bots:
            Menu {
                Self.newBotActions(workspace) { Self.start($0, in: workspace) }
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

    /// A new chat in `profile` (nil is the gateway's own), with that profile's model list.
    static func startNewChat(in workspace: BotWorkspace, profile: String?) {
        if workspace.sidebarMode != .chats { workspace.sidebarMode = .chats }
        workspace.startNewChat(in: profile)
    }

    /// One row per profile for New Chat, top to bottom as `BotWorkspace.newChatProfiles` orders
    /// them (the most used last), or `reversed` for a popover opening downward. `pick` gets the
    /// profile, nil for the gateway's own.
    @ViewBuilder static func newChatActions(_ workspace: BotWorkspace, reversed: Bool = false, pick: @escaping (String?) -> Void) -> some View {
        let profiles = workspace.newChatProfiles
        ForEach(reversed ? Array(profiles.reversed()) : profiles) { profile in
            Button {
                pick(workspace.isHomeProfile(profile) ? nil : profile.name)
            } label: {
                Label {
                    Text(profile.title)
                } icon: {
                    ProfileFace(workspace: workspace, profile: profile.name, size: 24)
                }
            }
            .accessibilityIdentifier("newChat.profile.\(profile.name)")
        }
    }

    /// New Bot and New Group Chat, offered and enabled as everywhere else: the Bot tab's menu
    /// here, and from iOS 27 the popover over its plus. `pick` gets the choice.
    @ViewBuilder static func newBotActions(_ workspace: BotWorkspace, pick: @escaping (IOSNewBotChoice) -> Void) -> some View {
        if let roster = workspace.roster {
            Button("New Bot", systemImage: "plus") { pick(.bot) }
                .disabled(!roster.isConnected)
            if roster.groupRooms.isAvailable {
                Button("New Group Chat", systemImage: "person.3") { pick(.group) }
                    .disabled(!roster.isConnected || roster.visibleBots.count < 2)
            }
        }
    }

    /// Opens the sheet for a choice; the root presents both (`BotSheets`).
    static func start(_ choice: IOSNewBotChoice, in workspace: BotWorkspace) {
        switch choice {
        case .bot: workspace.roster?.isCreatingBot = true
        case .group: workspace.roster?.isCreatingGroup = true
        }
    }
}

/// What the Bot tab's compose makes.
enum IOSNewBotChoice {
    case bot, group
}

/// A row of the Bot tab's popover: the symbol in a column of its own, so the titles line up,
/// then the title, at least as tall as a menu row. It lays out the row only; the panel behind it
/// is the system popover's.
struct IOSMenuRowLabelStyle: LabelStyle {
    /// As wide as the widest symbol (`person.3`) at every text size, so none reaches the title.
    @ScaledMetric(relativeTo: .body) private var symbolWidth = 32.0

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.icon
                .frame(width: symbolWidth)
            configuration.title
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(.rect)
    }
}

/// The Bot tab popover's rows, one under another, all as wide as the widest one wants but never
/// wider than `maxWidth`. The popover takes its size from them, so it hugs the rows, and at the
/// largest text sizes the titles wrap instead of running off the screen. Every row is as wide as
/// the panel, so all of it can be tapped.
nonisolated struct IOSMenuRows: Layout {
    var maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = width(offered: proposal, subviews)
        let height = subviews.reduce(0) { $0 + $1.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for subview in subviews {
            let height = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)).height
            subview.place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(width: bounds.width, height: height))
            y += height
        }
    }

    private func width(offered proposal: ProposedViewSize, _ subviews: Subviews) -> CGFloat {
        let widest = subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        return min(widest, maxWidth, proposal.width ?? .infinity)
    }
}
#endif
