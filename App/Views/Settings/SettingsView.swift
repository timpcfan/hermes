import HermesKit
import SwiftUI

/// Settings (`docs/settings.md` in the design project): on iPhone a grouped list in a sheet
/// (`settings`), on iPad a page sheet with a sidebar and the selected page beside it
/// (`ipadSettings`). The Mac has its own window (`MacSettingsView`).
struct SettingsView: View {
    /// A sheet closes with Done. The iPhone tab keeps Settings on screen, so there it draws no
    /// Done button (there is nothing to dismiss to).
    var allowsDismiss = true

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    var body: some View {
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .pad, sizeClass == .regular {
            SettingsSplitView(allowsDismiss: allowsDismiss)
        } else {
            SettingsList(allowsDismiss: allowsDismiss)
        }
        #else
        SettingsList(allowsDismiss: allowsDismiss)
        #endif
    }

    static var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}

/// iPhone (and an iPad window too narrow for two columns): every section in one list, pages
/// pushed in (`settings`, `settingsScrolled`, `settingsAX5`).
private struct SettingsList: View {
    var allowsDismiss = true

    @Environment(AppModel.self) private var app
    @Environment(WindowRouter.self) private var router: WindowRouter?
    @Environment(\.dismiss) private var dismiss
    @State private var editing: BotConfiguration?
    @State private var isAddingBot = false
    /// `-HERMES_APPS_TOOLS <tab>[:<item>]` opens Apps and Tools (screenshots).
    @State private var opensAppsAndTools = DebugFlags.appsAndTools != nil
    /// `-HERMES_MEMORY …` opens Memory (screenshots).
    @State private var opensMemory = DebugFlags.memory != nil
    /// `-HERMES_SETTINGS_SETUP …` opens Setup (screenshots).
    @State private var opensSetup = DebugFlags.setup != nil
    /// `-HERMES_BROWSER …` opens Browser (screenshots).
    @State private var opensBrowser = DebugFlags.browser != nil
    /// `-HERMES_PASSWORDS …` opens Passwords (screenshots).
    @State private var opensPasswords = DebugFlags.passwords != nil
    /// A voice fallback note's Set Up… opens Voice & Audio.
    @State private var opensVoice = false

    var body: some View {
        NavigationStack {
            Form {
                GatewaysSection(editing: $editing, isAddingBot: $isAddingBot)

                if let workspace = app.currentWorkspace {
                    Section("Hermes on \(workspace.bot.name)") {
                        SetupSettingsRow(workspace: workspace)
                        AppsAndToolsSettingsRow(model: workspace.appsAndTools)
                        #if os(iOS)
                        // The iPhone's new layout has no sidebar, so the pages it used to list there
                        // live here, each with its count (`docs/inbox.md` §10).
                        SkillsSettingsRow(workspace: workspace)
                        TasksSettingsRow(workspace: workspace)
                            .id(workspace.id)
                        #endif
                        MemorySettingsRow(workspace: workspace)
                        PasswordsSettingsRow(workspace: workspace)
                        BrowserSettingsRow(workspace: workspace)
                    }
                }

                AppearanceSection()
                ChatSettingsSection()

                // The Xunxin monitor link is the app's own, so it's here even with no gateway
                // (`docs/monitoring.md` §5).
                Section(header: Text(statsString("Monitoring service"))) {
                    MonitoringSettingsRow()
                }

                // Talk, voice messages, Listen and dictation (`docs/voice.md` §6).
                Section {
                    VoiceSettingsRow(workspace: app.currentWorkspace)
                }

                WidgetDeveloperSection()

                #if HERMES_PUSH && os(iOS)
                Section("Notifications") {
                    NotificationsSettingsRow()
                }
                #endif

                AboutSection()
            }
            .formStyle(.grouped)
            .onAppear {
                if router?.pluginInstallRequest != nil || router?.opensAppsAndTools == true { opensAppsAndTools = true }
                router?.opensAppsAndTools = false
                if router?.opensVoiceSettings == true { opensVoice = true }
                router?.opensVoiceSettings = false
            }
            .navigationDestination(isPresented: $opensAppsAndTools) {
                if let workspace = app.currentWorkspace { AppsAndToolsView(model: workspace.appsAndTools) }
            }
            .navigationDestination(isPresented: $opensVoice) {
                VoiceSettingsView(workspace: app.currentWorkspace)
            }
            .navigationDestination(isPresented: $opensMemory) {
                if let workspace = app.currentWorkspace { DebugMemoryPage(workspace: workspace) }
            }
            .navigationDestination(isPresented: $opensBrowser) {
                if let workspace = app.currentWorkspace { DebugBrowserPage(workspace: workspace) }
            }
            .navigationDestination(isPresented: $opensPasswords) {
                if let workspace = app.currentWorkspace { DebugPasswordsPage(workspace: workspace) }
            }
            .navigationDestination(isPresented: $opensSetup) {
                if let workspace = app.currentWorkspace { SetupOverviewView(workspace: workspace) }
            }
            .navigationTitle("Settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if allowsDismiss {
                    ToolbarItem(placement: .confirmationAction) {
                        SettingsDoneButton { dismiss() }
                    }
                }
            }
            #endif
            .gatewaySheets(editing: $editing, isAddingBot: $isAddingBot)
        }
        #if os(macOS)
        .frame(width: 520, height: 560)
        #endif
    }
}

#if os(iOS)
/// A page of iPad Settings, picked in the sidebar.
private enum SettingsPane: Hashable {
    case setup, apps, skills, tasks, memory, passwords, browser
    case monitoring
    case general, chat, voice, notifications, developer

    /// The page a `-HERMES_*` flag opens (screenshots).
    static var debugPane: SettingsPane? {
        if DebugFlags.setup != nil { return .setup }
        if DebugFlags.appsAndTools != nil { return .apps }
        if DebugFlags.memory != nil { return .memory }
        if DebugFlags.passwords != nil { return .passwords }
        if DebugFlags.browser != nil { return .browser }
        return nil
    }
}

/// The Hermes on <gateway> pages' models: made once per gateway while Settings is open, so a
/// sidebar row's summary and its page read the same one.
private struct HermesPages {
    let botID: UUID
    let memory: MemoryModel
    let passwords: PasswordsModel
    let browser: BrowserSettingsModel
    /// Read by the Tasks row itself, on the gateway rather than Bot Mode.
    let tasks = TasksModel()

    init(workspace: BotWorkspace) {
        botID = workspace.bot.id
        memory = MemoryModel(workspace: workspace, scope: .hermes, newInChat: workspace.currentConversation.memorySaves)
        passwords = PasswordsModel(workspace: workspace)
        browser = BrowserSettingsModel(workspace: workspace)
    }

    func load() async {
        async let memory: Void = memory.load(includingPending: true)
        async let passwords: Void = passwords.load()
        async let browser: Void = browser.load()
        _ = await (memory, passwords, browser)
    }

    /// After the gateway comes back: whatever didn't load while it was away.
    func reloadMissing() async {
        if memory.isOnline, memory.list == nil { await memory.load() }
        if passwords.isOnline, !passwords.hasLoaded { await passwords.load() }
        if browser.isOnline, !browser.hasLoaded { await browser.load() }
    }
}

/// iPad (`ipadSettings`, `ipadSettingsPortrait`, `ipadSettingsAX5`): the iPhone's sections in a
/// sidebar, the selected page beside it. Both columns stay in portrait and at the largest sizes,
/// where the sidebar widens. ↑ and ↓ move through the sidebar; Escape and ⌘. close it.
private struct SettingsSplitView: View {
    var allowsDismiss = true

    @Environment(AppModel.self) private var app
    @Environment(WindowRouter.self) private var router: WindowRouter?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var pane: SettingsPane? = SettingsPane.debugPane ?? .general
    @State private var columns = NavigationSplitViewVisibility.all
    @State private var isLandscape = true
    @State private var pages: HermesPages?
    @State private var editing: BotConfiguration?
    @State private var isAddingBot = false

    /// 330 pt in landscape, 300 in portrait, 480 at the accessibility sizes.
    private var sidebarWidth: CGFloat {
        typeSize.isAccessibilitySize ? 480 : isLandscape ? 330 : 300
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            sidebar
                .toolbar(removing: .sidebarToggle)
                // Last, and pinned: under the toolbar change, or as a width alone, the split view
                // kept its own 320 pt.
                .navigationSplitViewColumnWidth(min: sidebarWidth, ideal: sidebarWidth, max: sidebarWidth)
        } detail: {
            NavigationStack {
                page
                    .toolbar {
                        if allowsDismiss {
                            ToolbarItem(placement: .confirmationAction) {
                                SettingsDoneButton { dismiss() }
                            }
                        }
                    }
            }
            .id(pane)
        }
        .navigationSplitViewStyle(.balanced)
        // Nothing hides the sidebar: there's no toggle, and portrait keeps both columns.
        .onChange(of: columns) { if columns != .all { columns = .all } }
        .onGeometryChange(for: Bool.self) { $0.size.width > $0.size.height } action: { isLandscape = $0 }
        .onAppear {
            if router?.pluginInstallRequest != nil || router?.opensAppsAndTools == true { pane = .apps }
            router?.opensAppsAndTools = false
            if router?.opensVoiceSettings == true { pane = .voice }
            router?.opensVoiceSettings = false
        }
        .task(id: app.currentWorkspace?.bot.id) {
            guard let workspace = app.currentWorkspace else { pages = nil; return }
            let made = HermesPages(workspace: workspace)
            pages = made
            await made.load()
        }
        .onChange(of: app.currentWorkspace?.roster?.isConnected) {
            if let pages { Task { await pages.reloadMissing() } }
        }
        .gatewaySheets(editing: $editing, isAddingBot: $isAddingBot)
    }

    private var sidebar: some View {
        List(selection: $pane) {
            GatewaysSection(editing: $editing, isAddingBot: $isAddingBot, inSidebar: true)
                .listRowBackground(Theme.sheetCell)

            if let workspace = app.currentWorkspace {
                Section("Hermes on \(workspace.bot.name)") {
                    SettingsRowLabel(symbol: "checklist", title: "Setup", summary: workspace.setup.summary, compact: true)
                        .task(id: workspace.roster?.isConnected) { await workspace.setup.check() }
                        .accessibilityHint("What on this gateway and this device needs setting up")
                        .settingsSidebarRow(SettingsPane.setup, selection: pane)
                    SettingsRowLabel(
                        symbol: "puzzlepiece.extension", title: "Apps and Tools",
                        summary: AppsAndToolsSettingsRow.summary(workspace.appsAndTools), compact: true)
                        .task(id: workspace.appsAndTools.isOnline) {
                            if workspace.appsAndTools.isOnline, !workspace.appsAndTools.hasLoaded { await workspace.appsAndTools.load() }
                        }
                        .accessibilityHint("What Hermes can reach on this gateway")
                        .settingsSidebarRow(SettingsPane.apps, selection: pane)
                    SettingsRowLabel(
                        symbol: "book.closed", title: "Skills",
                        summary: SkillsSettingsRow.summary(workspace), compact: true)
                        .task(id: workspace.connection.isOnline) { await workspace.loadSkills() }
                        .accessibilityHint("What this Hermes knows how to do")
                        .settingsSidebarRow(SettingsPane.skills, selection: pane)
                    SettingsRowLabel(
                        symbol: "calendar.badge.clock", title: "Tasks",
                        summary: tasks(of: workspace).map { TasksSettingsRow.summary($0, workspace: workspace) },
                        compact: true)
                        .task(id: TasksSettingsRow.Trigger(workspace: workspace, model: tasks(of: workspace))) {
                            if let model = tasks(of: workspace) { await TasksSettingsRow.load(model, workspace: workspace) }
                        }
                        .accessibilityHint("What this Hermes runs on a schedule")
                        .settingsSidebarRow(SettingsPane.tasks, selection: pane)
                    SettingsRowLabel(
                        symbol: "brain", title: "Memory",
                        summary: pages?.memory.summary ?? String(localized: "What Hermes knows about you"), compact: true)
                        .accessibilityHint("What Hermes remembers about you and your setup")
                        .settingsSidebarRow(SettingsPane.memory, selection: pane)
                    SettingsRowLabel(
                        symbol: "key.fill", title: "Passwords",
                        summary: pages?.passwords.summary ?? String(localized: "Logins Hermes can use"), compact: true)
                        .accessibilityHint("Where Hermes finds logins, cards and addresses")
                        .settingsSidebarRow(SettingsPane.passwords, selection: pane)
                    SettingsRowLabel(
                        symbol: "safari", title: "Browser",
                        summary: pages?.browser.summary ?? String(localized: "Where Hermes browses"), compact: true)
                        .accessibilityHint("Where Hermes browses the web for new chats")
                        .settingsSidebarRow(SettingsPane.browser, selection: pane)
                }
            }

            Section(header: Text(statsString("Monitoring service"))) {
                SettingsRowLabel(symbol: "chart.bar.xaxis", title: statsString("Xunxin link"))
                    .accessibilityHint(statsString("The monitor service Stats reads"))
                    .settingsSidebarRow(SettingsPane.monitoring, selection: pane)
            }

            Section {
                SettingsRowLabel(symbol: "gearshape", title: "General")
                    .settingsSidebarRow(SettingsPane.general, selection: pane)
                SettingsRowLabel(symbol: "bubble.left", title: "Chat")
                    .settingsSidebarRow(SettingsPane.chat, selection: pane)
                SettingsRowLabel(symbol: "waveform", title: "Voice & Audio")
                    .settingsSidebarRow(SettingsPane.voice, selection: pane)
                #if HERMES_PUSH
                SettingsRowLabel(symbol: "bell", title: "Notifications")
                    .settingsSidebarRow(SettingsPane.notifications, selection: pane)
                #endif
                SettingsRowLabel(symbol: "hammer", title: "Developer")
                    .settingsSidebarRow(SettingsPane.developer, selection: pane)
            }
        }
        .listStyle(.insetGrouped)
        // The design's sidebar is the sheet's own grouped page, white cards on it, rather than
        // the system's tinted sidebar.
        .scrollContentBackground(.hidden)
        .background(Theme.sheetBackground)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// The Tasks list this gateway's sidebar row counts and its page shows, once Settings has made
    /// the pages.
    private func tasks(of workspace: BotWorkspace) -> TasksModel? {
        guard let pages, pages.botID == workspace.bot.id else { return nil }
        return pages.tasks
    }

    /// The selected page. A Hermes on <gateway> page falls back to General while no gateway is
    /// open.
    @ViewBuilder private var page: some View {
        switch (pane ?? .general, app.currentWorkspace) {
        case (.setup, let workspace?):
            SetupOverviewView(workspace: workspace)
        case (.apps, let workspace?):
            AppsAndToolsView(model: workspace.appsAndTools)
        case (.skills, let workspace?):
            SkillsView(workspace: workspace)
        case (.tasks, let workspace?):
            // Another list (Settings made its pages, or another gateway) is another page, so the
            // page and its sidebar row never count different lists.
            let model = tasks(of: workspace)
            TasksView(workspace: workspace, model: model)
                .id(model.map(ObjectIdentifier.init))
        case (.memory, let workspace?):
            if DebugFlags.memory != nil {
                DebugMemoryPage(workspace: workspace)
            } else if let pages, pages.botID == workspace.bot.id {
                MemoryView(model: pages.memory)
            }
        case (.passwords, let workspace?):
            if let pages, pages.botID == workspace.bot.id { PasswordsView(model: pages.passwords) }
        case (.browser, let workspace?):
            if let pages, pages.botID == workspace.bot.id { BrowserSettingsView(model: pages.browser) }
        case (.chat, _):
            Form { ChatSettingsSection(showsHeader: false) }
                .formStyle(.grouped)
                .navigationTitle("Chat")
                .navigationBarTitleDisplayMode(.inline)
        case (.monitoring, _):
            MonitoringSettingsView(model: app.monitoring)
        case (.voice, _):
            VoiceSettingsView(workspace: app.currentWorkspace)
        #if HERMES_PUSH
        case (.notifications, _):
            NotificationSettingsView()
        #endif
        case (.developer, _):
            Form { WidgetDeveloperSection() }
                .formStyle(.grouped)
                .navigationTitle("Developer")
                .navigationBarTitleDisplayMode(.inline)
        default:
            Form {
                AppearanceSection()
                AboutSection()
            }
            .formStyle(.grouped)
            .navigationTitle("General")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
#endif

/// Done (✓) on Settings' toolbar. Escape presses it from a hardware keyboard.
private struct SettingsDoneButton: View {
    let action: () -> Void

    var body: some View {
        // Ink, as the design draws it and as the app's other sheets confirm.
        Button("Done", systemImage: "checkmark", action: action)
            .buttonStyle(.glassProminent)
            .tint(Theme.ink)
            .keyboardShortcut(.cancelAction)
    }
}

#if os(iOS)
/// Settings → Hermes on <gateway>: a page the app already has, with Setup's tile, title and
/// summary line, pushed in on iPhone (`mockup-v2.html`, after Apps and Tools).
private struct SettingsPageRow<Page: View>: View {
    let symbol: String
    let title: LocalizedStringKey
    var summary: String?
    let hint: LocalizedStringKey
    @ViewBuilder let page: () -> Page

    var body: some View {
        NavigationLink {
            page()
        } label: {
            SettingsRowLabel(symbol: symbol, title: title, summary: summary)
        }
        .accessibilityHint(hint)
    }
}

/// Settings → Hermes on <gateway> → Skills: how many skills Hermes has, from the list the Skills
/// page keeps, read once per gateway (`docs/inbox.md` §10).
private struct SkillsSettingsRow: View {
    let workspace: BotWorkspace

    var body: some View {
        SettingsPageRow(symbol: "book.closed", title: "Skills", summary: Self.summary(workspace),
                        hint: "What this Hermes knows how to do") {
            SkillsView(workspace: workspace)
        }
        .task(id: workspace.connection.isOnline) { await workspace.loadSkills() }
    }

    /// "104 skills", or why there's no count yet.
    static func summary(_ workspace: BotWorkspace) -> String {
        HermesPageSummary.skills(workspace.skillCatalog, from: workspace.bot.baseURL,
                                 isLoading: workspace.isLoadingSkills, isOnline: workspace.connection.isOnline)
    }
}

/// Settings → Hermes on <gateway> → Tasks: how many tasks there are and how many aren't paused.
/// The row reads the list once, and again when the gateway comes online without one; the Tasks
/// page it opens works on the same list, so a change there shows here on the way back. Nothing
/// polls (`docs/inbox.md` §10).
private struct TasksSettingsRow: View {
    let workspace: BotWorkspace
    @State private var model = TasksModel()

    var body: some View {
        SettingsPageRow(symbol: "calendar.badge.clock", title: "Tasks",
                        summary: Self.summary(model, workspace: workspace),
                        hint: "What this Hermes runs on a schedule") {
            TasksView(workspace: workspace, model: model)
        }
        .task(id: Trigger(workspace: workspace, model: model)) { await Self.load(model, workspace: workspace) }
    }

    /// "5 tasks · 2 active", or why there's no count yet.
    static func summary(_ model: TasksModel, workspace: BotWorkspace) -> String {
        HermesPageSummary.tasks(model.hasLoaded ? model.jobs : nil, failed: model.loadError != nil,
                                isOnline: workspace.connection.isOnline)
    }

    static func load(_ model: TasksModel, workspace: BotWorkspace) async {
        guard workspace.connection.isOnline, !model.hasLoaded, !model.isLoading else { return }
        await model.load(client: workspace.client)
    }

    /// What the row reads for: the list it counts (the iPad's arrives once Settings has made it)
    /// and the gateway coming online.
    struct Trigger: Equatable {
        let model: ObjectIdentifier?
        let isOnline: Bool

        init(workspace: BotWorkspace, model: TasksModel?) {
            self.model = model.map(ObjectIdentifier.init)
            isOnline = workspace.connection.isOnline
        }
    }
}
#endif

/// A Settings row's leading part: its ink tile, its title and, for Hermes on <gateway>, a one-line
/// summary ("2 things to set up"). `compact` is the iPad sidebar's smaller summary.
struct SettingsRowLabel: View {
    let symbol: String
    let title: Text
    var summary: String?
    var compact = false

    init(symbol: String, title: LocalizedStringKey, summary: String? = nil, compact: Bool = false) {
        self.symbol = symbol
        self.title = Text(title)
        self.summary = summary
        self.compact = compact
    }

    /// A title already read from a table (Stats' own copy comes from `Stats`).
    init(symbol: String, title: String, summary: String? = nil, compact: Bool = false) {
        self.symbol = symbol
        self.title = Text(verbatim: title)
        self.summary = summary
        self.compact = compact
    }

    var body: some View {
        HStack(spacing: 12) {
            GlyphTile(symbol: symbol, ink: true, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                title.foregroundStyle(Theme.primaryText)
                if let summary {
                    Text(summary)
                        .font(compact ? .caption2 : .caption)
                        .foregroundStyle(Theme.secondaryText)
                        .contentTransition(.numericText())
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Hermes Gateways: a row per gateway (Edit on tap), Add Gateway… and the Keychain footer.
private struct GatewaysSection: View {
    @Environment(AppModel.self) private var app
    @Binding var editing: BotConfiguration?
    @Binding var isAddingBot: Bool
    var inSidebar = false

    var body: some View {
        Section {
            ForEach(app.bots) { bot in
                Button {
                    editing = bot
                } label: {
                    GatewayRow(bot: bot, workspace: app.workspaces[bot.id], inSidebar: inSidebar)
                }
                .buttonStyle(.plain)
            }
            Button("Add Gateway…", systemImage: "plus") {
                isAddingBot = true
            }
        } header: {
            Text("Hermes Gateways")
        } footer: {
            Text("API keys are stored in the Keychain on this device.")
        }
    }
}

/// Appearance: Theme as a segmented control, or a list of choices at the accessibility sizes
/// (`settingsAX5`), where three segments can't fit their words.
private struct AppearanceSection: View {
    @AppStorage(PreferenceKey.appearance) private var appearance = AppearancePreference.system
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Section("Appearance") {
            if typeSize.isAccessibilitySize {
                Picker("Theme", selection: $appearance) { options }
                    .pickerStyle(.inline)
            } else {
                // A segmented picker hides its label in a list; the design names the row.
                HStack(spacing: 16) {
                    Text("Theme")
                    Picker("Theme", selection: $appearance) { options }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                }
            }
        }
    }

    @ViewBuilder private var options: some View {
        ForEach(AppearancePreference.allCases) { option in
            Text(option.title).tag(option)
        }
    }
}

/// Chat: how chats open, send and sound. iPad's Chat page draws it without the header.
private struct ChatSettingsSection: View {
    var showsHeader = true
    @AppStorage(PreferenceKey.sendWithReturn) private var sendWithReturn = true
    @AppStorage(PreferenceKey.expandAgentActivity) private var expandAgentActivity = false
    @AppStorage(PreferenceKey.haptics) private var haptics = true
    @AppStorage(PreferenceKey.showUsage) private var showUsage = false
    @AppStorage(PreferenceKey.openChatsAt) private var openChatsAt = OpenChatsAt.firstUnread
    @AppStorage(PreferenceKey.chatSounds) private var chatSounds = false
    @AppStorage(PreferenceKey.keepChatAtBottom) private var keepChatAtBottom = SendScroll.keepsAtBottomByDefault

    var body: some View {
        Section {
            Toggle("Show agent steps while working", isOn: $expandAgentActivity)
            FollowUpDefaultPicker()
            Toggle("Show usage under replies", isOn: $showUsage)
            Toggle("Send with Return", isOn: $sendWithReturn)
            Picker("Open chats at", selection: $openChatsAt) {
                ForEach(OpenChatsAt.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            Toggle("Keep chat at bottom when sending", isOn: $keepChatAtBottom)
            #if os(iOS)
            Toggle("Haptics", isOn: $haptics)
            #endif
            Toggle("Sounds", isOn: $chatSounds)
        } header: {
            if showsHeader { Text("Chat") }
        } footer: {
            Text("A chat with new messages opens at the first one, or at the latest. With Keep chat at bottom when sending on, the message you send stays at the bottom and the reply fills in below it. With Send with Return on, Shift-Return starts a new line on a hardware keyboard.")
        }
    }
}

/// About: the version and the links that leave the app, each ending in an arrow.
private struct AboutSection: View {
    var body: some View {
        Section {
            AboutVersionRow(version: SettingsView.versionString)
            AboutLinkRow(title: "Source code on GitHub", symbol: "curlybraces", url: URL(string: "https://github.com/vburojevic/hermes")!)
            AboutLinkRow(title: "Hermes Agent documentation", symbol: "book", url: URL(string: "https://hermes-agent.nousresearch.com/docs/")!)
            AboutLinkRow(
                title: "Hermes Agent on GitHub", symbol: "chevron.left.forwardslash.chevron.right",
                url: URL(string: "https://github.com/NousResearch/hermes-agent")!)
        } header: {
            Text("About")
        } footer: {
            Text("An independent app by Caffeinated Code for Hermes Agent, the open-source agent by Nous Research. Not affiliated with Nous Research.")
        }
    }
}

/// A link that leaves the app: its ink tile, its title and ↗ at the end.
private struct AboutLinkRow: View {
    let title: LocalizedStringKey
    let symbol: String
    let url: URL

    var body: some View {
        Link(destination: url) {
            HStack(spacing: 12) {
                GlyphTile(symbol: symbol, ink: true, size: 30)
                Text(title).foregroundStyle(Theme.primaryText)
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.tertiaryText)
                    .accessibilityHidden(true)
            }
        }
    }
}

private extension View {
    /// Add Gateway and a gateway's editor, over Settings.
    func gatewaySheets(editing: Binding<BotConfiguration?>, isAddingBot: Binding<Bool>) -> some View {
        sheet(isPresented: isAddingBot) {
            NavigationStack {
                BotEditorView(mode: .add) { isAddingBot.wrappedValue = false }
            }
            #if os(macOS)
            .frame(width: 520).frame(minHeight: 420, idealHeight: 540)
            #endif
        }
        .sheet(item: editing) { bot in
            NavigationStack {
                BotEditorView(mode: .edit(bot)) { editing.wrappedValue = nil }
            }
            #if os(macOS)
            .frame(width: 520).frame(minHeight: 420, idealHeight: 540)
            #endif
        }
    }
}

/// A gateway in Settings (`settings`): its name, its address with the Hermes version, and a status
/// dot with one short word, so nothing is cut off. The status is the sidebar's, Bot Mode's in Bots
/// mode. At the accessibility text sizes (`settingsAX5`) and in iPad's sidebar
/// (`ipadSettingsPortrait`) the version and the status go under the address, which wraps but
/// never inside its port. VoiceOver reads "Studio Mac, Connected, Hermes 0.9.2".
private struct GatewayRow: View {
    let bot: BotConfiguration
    let workspace: BotWorkspace?
    /// iPad's sidebar: the avatar beside the lines, and no chevron (the row opens a sheet).
    var inSidebar = false
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let status = workspace.map(ConnectionStatus.init)
        Group {
            if inSidebar {
                HStack(spacing: 12) {
                    BotAvatar(bot: bot, size: 34)
                    stackedLines(status)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if typeSize.isAccessibilitySize {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        BotAvatar(bot: bot, size: 34)
                        stackedLines(status)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    chevron
                }
            } else {
                HStack(spacing: 12) {
                    BotAvatar(bot: bot, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(bot.name)
                            .foregroundStyle(Theme.primaryText)
                        addressLines(status)
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryText)
                    }
                    Spacer(minLength: 8)
                    if let status {
                        statusLabel(status)
                            .font(.footnote)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    chevron
                }
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel(status))
    }

    /// The name, then the address, version and status one under the other.
    private func stackedLines(_ status: ConnectionStatus?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(bot.name)
                .foregroundStyle(Theme.primaryText)
            Group {
                if let stopped = workspace?.botModeStopLine {
                    Text(stopped)
                        .foregroundStyle(Theme.warning)
                } else {
                    Text(bot.wrappingDisplayAddress)
                    if let detail = status?.detail {
                        Text(detail)
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(Theme.secondaryText)
            if let status {
                statusLabel(status)
                    .font(.caption)
                    .padding(.top, 2)
            }
        }
    }

    @ViewBuilder private func addressLines(_ status: ConnectionStatus?) -> some View {
        if let stopped = workspace?.botModeStopLine {
            // Bot Mode's sign-in was refused: that, in place of the address, until it's fixed
            // (`docs/setup.md` §4.1).
            Text(stopped)
                .foregroundStyle(Theme.warning)
        } else {
            // The address and version share a line when they fit; otherwise the version moves
            // under the address, so neither is cut short.
            ViewThatFits(in: .horizontal) {
                Text(([bot.displayAddress] + [status?.detail].compactMap(\.self)).joined(separator: " · "))
                VStack(alignment: .leading, spacing: 2) {
                    Text(bot.displayAddress)
                        .truncationMode(.middle)
                    if let detail = status?.detail {
                        Text(detail)
                    }
                }
            }
            .lineLimit(1)
        }
    }

    private func statusLabel(_ status: ConnectionStatus) -> some View {
        HStack(spacing: 6) {
            StatusDot(color: status.color)
            Text(status.title)
        }
        .foregroundStyle(Theme.secondaryText)
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(Theme.tertiaryText)
    }

    private func spokenLabel(_ status: ConnectionStatus?) -> String {
        [bot.name, workspace?.botModeStopLine ?? status?.title, status?.detail]
            .compactMap(\.self)
            .joined(separator: ", ")
    }
}

/// Settings → About's version row, tagged Beta while Hermes is in public beta. Drop the tag here
/// when it leaves the beta.
struct AboutVersionRow: View {
    let version: String

    var body: some View {
        LabeledContent("Version") {
            HStack(spacing: 6) {
                Text(version)
                TagLabel(title: String(localized: "Beta"))
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// `-HERMES_MEMORY …`: Memory with a model of its own (screenshots).
private struct DebugMemoryPage: View {
    @State private var model: MemoryModel

    init(workspace: BotWorkspace) {
        let route = DebugFlags.memory ?? ""
        let scope: MemoryModel.Scope = route.hasPrefix("bot:") ? .bot(String(route.dropFirst(4))) : .hermes
        _model = State(initialValue: MemoryModel(workspace: workspace, scope: scope, newInChat: workspace.currentConversation.memorySaves))
    }

    var body: some View {
        MemoryView(model: model)
    }
}

/// Settings → Hermes on <gateway> → Memory: "6 things about you · 14 notes · 2 to review". The
/// page it opens shares this row's model, made when Settings opens and dropped with it.
struct MemorySettingsRow: View {
    let workspace: BotWorkspace
    var scope: MemoryModel.Scope = .hermes
    @State private var model: MemoryModel?

    private var title: String {
        if case .bot(let name) = scope, let bot = workspace.roster?.bot(named: name) {
            return String(localized: "What \(bot.title) Remembers")
        }
        return String(localized: "Memory")
    }

    var body: some View {
        NavigationLink {
            if let model { MemoryView(model: model).settingsPage(back: String(localized: "Back")) }
        } label: {
            HStack(spacing: 12) {
                if scope == .hermes {
                    GlyphTile(symbol: "brain", ink: true, size: 30)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(Theme.primaryText)
                    Text(model?.summary ?? String(localized: "What Hermes knows about you"))
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                        .contentTransition(.numericText())
                }
            }
        }
        .onAppear {
            if model == nil {
                // "New in this chat": what the open chat saved.
                let saves: [String] = switch scope {
                case .hermes: workspace.currentConversation.memorySaves
                case .bot(let name): workspace.roster?.conversation(for: name).memorySaves ?? []
                }
                let created = MemoryModel(workspace: workspace, scope: scope, newInChat: saves)
                model = created
                Task { await created.load(includingPending: scope == .hermes) }
            }
        }
        .onChange(of: workspace.roster?.isConnected) {
            if let model, model.isOnline, model.list == nil { Task { await model.load() } }
        }
        .accessibilityHint("What Hermes remembers about you and your setup")
    }
}

/// Settings → Hermes on <gateway> → Apps and Tools: a count, plus "1 needs you" when something
/// expired or failed.
struct AppsAndToolsSettingsRow: View {
    let model: AppsAndToolsModel

    var body: some View {
        NavigationLink {
            AppsAndToolsView(model: model)
        } label: {
            HStack(spacing: 12) {
                GlyphTile(symbol: "puzzlepiece.extension", ink: true, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Apps and Tools").foregroundStyle(Theme.primaryText)
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                }
            }
        }
        .task(id: model.isOnline) {
            if model.isOnline, !model.hasLoaded { await model.load() }
        }
        .accessibilityHint("What Hermes can reach on this gateway")
    }

    private var summary: String { Self.summary(model) }

    /// "4 apps · 4 MCP servers · 2 suggested": a suggestion is plain text, never a badge or ink
    /// (`docs/plugins.md` §3.2).
    static func summary(_ model: AppsAndToolsModel) -> String {
        let suggested = model.workspace?.pluginHub.suggestedCount ?? 0
        guard model.hasLoaded, suggested > 0 else { return model.summary }
        return model.summary + " · " + String(localized: "\(suggested) suggested")
    }
}

#if os(iOS)
extension View {
    /// A Settings sidebar row: tagged for the list's selection, which keeps ↑↓ and VoiceOver's
    /// selected trait, and drawn with the design's quiet wash rather than the accent fill.
    fileprivate func settingsSidebarRow(_ pane: SettingsPane, selection: SettingsPane?) -> some View {
        tag(pane)
            .listRowBackground(
                Theme.sheetCell.overlay(selection == pane ? Theme.rowSelected : .clear)
            )
    }
}
#endif
