import HermesKit
import SwiftUI

/// The chat's top bar (`docs/chat.md` §4): where the person is, in the chat's name and the profile
/// it runs in. The model and reasoning are the composer's chip; nothing here is a control.
struct ChatHeaderTitle: View {
    @Bindable var conversation: ConversationModel
    let workspace: BotWorkspace

    private var session: HermesSession? {
        guard let key = conversation.stableKey else { return nil }
        return workspace.session(forKey: key)
    }

    /// The chat's row's name, else its first message, else a draft's "New chat".
    private var title: String {
        ChatHeader.title(of: session, fallback: String(localized: "New chat"))
    }

    /// The profile the chat runs in, named as its row in the chat list is; a draft names the one
    /// it will be created in.
    private var profile: String {
        ChatHeader.profile(of: conversation.modelProfile, home: workspace.bot.profileName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.headline.weight(.bold))
                .foregroundStyle(Theme.primaryText)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(profile)
                .font(.caption2)
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
        }
        .multilineTextAlignment(.leading)
        // Every platform reads the chat's name from the leading edge, where the chat itself starts.
        #if os(iOS)
        // The bar sizes its title by the title's ideal width and centres it: asking for more than
        // the bar has makes it give the title all the room between the buttons, so a short name
        // starts at the leading edge too, not only one long enough to fill the bar.
        .frame(idealWidth: Self.greedyWidth, maxWidth: .infinity, alignment: .leading)
        #else
        // The Mac's toolbar gives a leading item its ideal width: a long name stops short of the
        // trailing buttons and is cut at its tail rather than pushed into the » overflow.
        .frame(maxWidth: Self.macMaxWidth, alignment: .leading)
        // Room between the sidebar's edge (or its button) and the name, as the iPhone's back
        // button has.
        .padding(.leading, Self.macLeadingInset)
        #endif
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(title), \(profile)"))
        .accessibilityIdentifier("chatHeaderTitle")
    }

    #if os(iOS)
    /// Wider than any bar, so the bar clamps the title to the room it has (`body`).
    private static let greedyWidth: CGFloat = 2_000
    #else
    /// The widest the Mac's title gets, about the transcript's half.
    private static let macMaxWidth: CGFloat = 380
    /// The Mac's title's room from the sidebar's edge, on top of the toolbar's own few points.
    private static let macLeadingInset: CGFloat = 12
    #endif
}

/// The composer's model-and-reasoning chip (`docs/composer.md` §1, `docs/sessions-and-models.md`
/// §4): the model the next turn sends with, its reasoning as whole signal bars, and the picker
/// behind them. While a turn runs the send-mode chip takes the words' place, so the chip keeps
/// only its signal.
struct ComposerModelChip: View {
    @Bindable var conversation: ConversationModel
    let workspace: BotWorkspace
    /// A turn runs and the send-mode chip shows beside it (`ComposerChipModel.layout`).
    let isCondensed: Bool

    @State private var isPresented = false
    @Environment(\.composerChipSizing) private var composerSizing

    private var model: ComposerChipModel.Model { conversation.chipModel }
    private var layout: ComposerChipModel.Layout { ComposerChipModel.layout(showsModeChip: isCondensed) }
    private var support: ModelReasoningSupport { conversation.chipReasoningSupport }
    private var signal: ReasoningSignal {
        ReasoningSignal(effort: conversation.reasoningEffort, supported: support.isSupported)
    }

    var body: some View {
        Button {
            isPresented = true
        } label: {
            ChipLabel(
                title: layout == .full ? model.name : nil,
                // A model that doesn't reason shows no bars beside its name; with the name gone
                // while a turn runs, the bars stay, unlit, so the chip is never an empty capsule.
                icon: support.isSupported || layout == .iconOnly ? AnyView(reasoningIcon) : nil,
                isActive: conversation.reasoningEffort != nil && support.isSupported
            )
        }
        .buttonStyle(.plain)
        // After the process chip, the first to give up room so the microphone and Send stay put.
        .layoutPriority(-0.5)
        .help("Model and reasoning")
        .accessibilityLabel(Text("Model: \(model.name)"))
        .accessibilityValue(Text(reasoningValue))
        .accessibilityHint(Text("Choose the model and how hard Hermes thinks"))
        .accessibilityShowsLargeContentViewer {
            Label(model.name, systemImage: "cellularbars")
        }
        #if os(macOS)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            ModelPickerView(conversation: conversation, workspace: workspace) { isPresented = false }
        }
        #else
        .sheet(isPresented: $isPresented) {
            ModelPickerView(conversation: conversation, workspace: workspace) { isPresented = false }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        #endif
        // Its own profile's list (`docs/inbox.md` §9), read again when a new chat changes profile.
        .task(id: conversation.modelProfile ?? "") {
            await workspace.loadModelOptions(for: conversation.modelProfile)
        }
    }

    /// The bars at the chip's size: whole bars lit in `.color` mode, the platform's Auto mark for
    /// Auto, and unlit, dimmed bars for a model that doesn't reason (drawn only while a turn runs
    /// and the chip has no name to show).
    @ViewBuilder private var reasoningIcon: some View {
        switch signal {
        case .auto:
            Image(systemName: "a.circle")
                .font(.system(size: composerSizing?.chipGlyph(13) ?? 13, weight: .medium))
                .foregroundStyle(Theme.primaryText)
        case .bars:
            Image(systemName: "cellularbars", variableValue: signal.variableValue)
                .symbolVariableValueMode(.color)
                .font(.system(size: composerSizing?.chipGlyph(13) ?? 13, weight: .medium))
                .foregroundStyle(Theme.primaryText)
        case .unavailable:
            Image(systemName: "cellularbars", variableValue: 0)
                .symbolVariableValueMode(.color)
                .font(.system(size: composerSizing?.chipGlyph(13) ?? 13, weight: .medium))
                .foregroundStyle(Theme.tertiaryText)
        }
    }

    private var reasoningValue: String {
        guard support.isSupported else { return String(localized: "Not available") }
        return conversation.reasoningEffort.map(ReasoningNames.title(for:)) ?? String(localized: "Auto")
    }
}

extension ConversationModel {
    /// The model the composer's chip names, in the order the top bar used (`docs/composer.md` §1):
    /// this device's pick, the chat row's report, the profile's default, the gateway's name.
    var chipModel: ComposerChipModel.Model {
        ComposerChipModel.model(
            picked: model,
            reported: stableKey.flatMap { workspace?.session(forKey: $0)?.model },
            profileDefault: modelOptions?.model,
            defaultProvider: modelOptions?.provider,
            gatewayName: workspace?.bot.name ?? gatewayName
        )
    }

    /// What the gateway says about reasoning for the chip's model.
    var chipReasoningSupport: ModelReasoningSupport {
        modelOptions?.reasoningSupport(for: chipModel.id, provider: chipModel.provider) ?? .unknown
    }
}

struct ModelPickerView: View {
    @Bindable var conversation: ConversationModel
    let workspace: BotWorkspace
    let onDone: () -> Void

    @State private var query = ""
    @State private var expandedProviders: Set<String> = []

    /// This chat's profile's list (`docs/inbox.md` §9), not the gateway's own.
    private var options: ModelOptions? { conversation.modelOptions }
    private var defaultModelName: String? { workspace.defaultModelName(for: conversation.modelProfile) }
    private func refresh() async { await workspace.loadModelOptions(for: conversation.modelProfile, refresh: true) }
    /// "Gateway default", or "Profile default" in another profile, whose own default it is.
    private var defaultTitle: String {
        conversation.runsInAnotherProfile ? String(localized: "Profile default") : String(localized: "Gateway default")
    }

    private var providers: [ModelProvider] {
        options?.usableProviders ?? []
    }

    /// Providers Hermes reports without credentials (`authenticated: false`): shown, not hidden,
    /// with the way to give them a key (`docs/setup.md` §4.3).
    private var needingKeys: [ModelProvider] {
        options?.providers.filter { $0.authenticated == false } ?? []
    }

    @State private var addingKeyFor: ModelProvider?

    var body: some View {
        Group {
            #if os(macOS)
            macBody
            #else
            listBody
            #endif
        }
        .sheet(item: $addingKeyFor) { provider in
            ProviderKeySheet(problem: ProviderProblem(kind: .key(envVar: nil), provider: provider.slug, providerLabel: provider.name),
                             gatewayName: workspace.bot.name) { key in
                try await workspace.saveProviderKey(key, slug: provider.slug)
            }
        }
    }

    /// A provider without a key: its name, and Add Key… when Bot Mode can take one.
    private func needsKeyRow(_ provider: ModelProvider) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.name).foregroundStyle(Theme.primaryText)
                Text(provider.warning ?? String(localized: "No key on \(workspace.bot.name)"))
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
            }
            Spacer()
            if workspace.roster?.isConnected == true {
                Button("Add Key…") { addingKeyFor = provider }
                    .cardButton()
                    .controlSize(.small)
            }
        }
    }

    #if os(macOS)
    /// The Mac's compact popover (`screens/mac/sheets.elyx` `macModelPicker`): the models on the
    /// left, the reasoning ladder on the right (`docs/composer.md` §1).
    private var macBody: some View {
        HStack(spacing: 0) {
            macModelList
            Divider()
            reasoningColumn
        }
    }

    /// Search, then the models with their provider and price.
    private var macModelList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Theme.tertiaryText)
                TextField("Search models", text: $query)
                    .textFieldStyle(.plain)
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Theme.controlFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(8)
            ScrollView {
                VStack(spacing: 2) {
                    macRow(title: defaultTitle, subtitle: defaultModelName, isSelected: conversation.model == nil) {
                        select(nil)
                    }
                    ForEach(providers) { provider in
                        let models = visibleModels(for: provider)
                        if !models.isEmpty {
                            Divider().padding(.vertical, 4)
                            ForEach(models, id: \.self) { model in
                                macRow(
                                    title: ModelNames.display(model),
                                    model: model,
                                    subtitle: [provider.name, provider.isCurrent && model == options?.model ? String(localized: "Default") : nil, provider.pricing?[model].flatMap(shortPrice)].compactMap { $0 }.joined(separator: " · "),
                                    isSelected: conversation.model == ModelSelection(provider: provider.slug, model: model),
                                    isDisabled: provider.isUnavailable(model)
                                ) {
                                    select(ModelSelection(provider: provider.slug, model: model))
                                }
                            }
                            if query.isEmpty && provider.models.count > models.count {
                                Button("Show all \(provider.models.count)") { expandedProviders.insert(provider.slug) }
                                    .buttonStyle(.plain)
                                    .font(.caption)
                                    .foregroundStyle(Theme.secondaryText)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                            }
                        }
                    }
                    if !needingKeys.isEmpty {
                        Divider().padding(.vertical, 4)
                        ForEach(needingKeys) { provider in
                            needsKeyRow(provider)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                        }
                    }
                    if options == nil, let error = workspace.modelOptionsError, !conversation.runsInAnotherProfile {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(error).font(.caption).foregroundStyle(Theme.secondaryText)
                            Button("Try Again") { Task { await refresh() } }
                                .controlSize(.small)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                    } else if options == nil {
                        SkeletonRows(count: 3).padding(10)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            }
            Divider()
            HStack {
                Text(providers.isEmpty ? String(localized: "No other models on this gateway") : String(localized: "\(providers.reduce(0) { $0 + $1.models.count }) models"))
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
                Spacer()
                Button {
                    Task { await refresh() }
                } label: {
                    if workspace.isRefreshingModels {
                        Spinner(size: .mini)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.secondaryText)
                .help("Refresh models from all providers")
                .disabled(workspace.isRefreshingModels)
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
        }
        .frame(width: 320, height: 380)
    }

    /// One row of the popover's model column. `model` is the id the gateway sends with
    /// (`anthropic/claude-sonnet-4.6`), under the name it's read as, so the Mac shows what the
    /// iPhone has always shown and the person can tell two models apart whose names read alike.
    private func macRow(
        title: String, model: String? = nil, subtitle: String?,
        isSelected: Bool, isDisabled: Bool = false, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.bold))
                    .opacity(isSelected ? 1 : 0)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.callout)
                        .foregroundStyle(isDisabled ? Theme.tertiaryText : Theme.primaryText)
                    if let model, !model.isEmpty, model != title {
                        Text(model)
                            .font(.caption)
                            .foregroundStyle(isDisabled ? Theme.tertiaryText : Theme.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(Theme.tertiaryText)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(isSelected ? Theme.rowSelected : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func shortPrice(_ pricing: ModelProvider.Pricing) -> String? {
        if pricing.free == true { return String(localized: "Free") }
        guard let input = pricing.input, let output = pricing.output else { return nil }
        return "\(input) / \(output)"
    }

    /// The popover's second column (`docs/composer.md` §1): Auto and the ladder, one level at a
    /// time. A level picked here leaves the popover open; a model picked on the left closes it.
    private var reasoningColumn: some View {
        let support = conversation.chipReasoningSupport
        return VStack(alignment: .leading, spacing: 0) {
            Text("Reasoning")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.secondaryText)
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 4)
            ScrollView {
                VStack(spacing: 2) {
                    macRow(title: String(localized: "Auto"), subtitle: nil,
                           isSelected: conversation.reasoningEffort == nil,
                           isDisabled: !support.isSupported) {
                        conversation.reasoningEffort = nil
                    }
                    Divider().padding(.vertical, 4)
                    ForEach(ReasoningEffort.allCases) { level in
                        macRow(title: ReasoningNames.title(for: level), subtitle: nil,
                               isSelected: conversation.reasoningEffort == level,
                               isDisabled: !support.isSupported || (level == .off && !support.canDisable)) {
                            conversation.reasoningEffort = level
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            }
            if let note = reasoningNote(support) {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
        }
        .frame(width: 168, height: 380)
    }
    #endif

    private var listBody: some View {
        NavigationStack {
            List {
                Section {
                    row(
                        title: defaultTitle,
                        subtitle: defaultModelName,
                        isSelected: conversation.model == nil
                    ) {
                        select(nil)
                    }
                }
                ForEach(providers) { provider in
                    let models = visibleModels(for: provider)
                    if !models.isEmpty {
                        Section {
                            ForEach(models, id: \.self) { model in
                                row(
                                    title: ModelNames.display(model),
                                    subtitle: model.contains("/") ? model : provider.pricing?[model].flatMap(priceLabel),
                                    isSelected: conversation.model == ModelSelection(provider: provider.slug, model: model),
                                    isDisabled: provider.isUnavailable(model)
                                ) {
                                    select(ModelSelection(provider: provider.slug, model: model))
                                }
                            }
                            if query.isEmpty && provider.models.count > models.count {
                                Button("Show all \(provider.models.count)") {
                                    expandedProviders.insert(provider.slug)
                                }
                                .font(.footnote.weight(.medium))
                            }
                        } header: {
                            HStack {
                                Text(provider.name)
                                if provider.isCurrent {
                                    Text("Default")
                                        .font(.caption2.weight(.semibold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Theme.surfaceRaised, in: Capsule())
                                }
                            }
                        } footer: {
                            if let warning = provider.warning {
                                Text(warning)
                            }
                        }
                    }
                }
                if !needingKeys.isEmpty {
                    Section {
                        ForEach(needingKeys) { provider in
                            needsKeyRow(provider)
                        }
                    } header: {
                        Text("Needs a key")
                    } footer: {
                        Text("Hermes on \(workspace.bot.name) has no key for these. Or add one there with `hermes model`.")
                    }
                }
                if options == nil, let error = workspace.modelOptionsError, !conversation.runsInAnotherProfile {
                    Section {
                        Text(error).foregroundStyle(Theme.secondaryText)
                        Button("Try Again") { Task { await refresh() } }
                    }
                } else if options == nil {
                    Section { SkeletonRows(count: 3) }
                } else if providers.isEmpty {
                    Section {
                        Text("Hermes didn't report any other models. Configure providers with `hermes model` on the gateway.")
                            .font(.footnote)
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
            }
            #if os(macOS)
            .listStyle(.inset)
            #else
            .listStyle(.insetGrouped)
            #endif
            // The reasoning controls stay under the list while it scrolls (`docs/composer.md` §1).
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ReasoningSheetBar(conversation: conversation)
            }
            #if os(iOS)
            // Under the title, not at the bottom: the reasoning controls own the bottom edge.
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search models")
            #else
            .searchable(text: $query, prompt: "Search models")
            #endif
            .navigationTitle("Model")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone)
                }
                ToolbarItem(placement: Self.refreshPlacement) {
                    Button {
                        Task { await refresh() }
                    } label: {
                        if workspace.isRefreshingModels {
                            Spinner()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .help("Refresh models from all providers")
                    .accessibilityLabel("Refresh models")
                    .disabled(workspace.isRefreshingModels)
                }
            }
        }
    }

    private static var refreshPlacement: ToolbarItemPlacement {
        #if os(iOS)
        .topBarLeading
        #else
        .automatic
        #endif
    }

    private func visibleModels(for provider: ModelProvider) -> [String] {
        if !query.isEmpty {
            return provider.models.filter {
                $0.localizedCaseInsensitiveContains(query) || provider.name.localizedCaseInsensitiveContains(query)
            }
        }
        if expandedProviders.contains(provider.slug) {
            return provider.models
        }
        let featured = (provider.featuredModels ?? []).filter(provider.models.contains)
        var shortlist = featured.isEmpty ? Array(provider.models.prefix(6)) : featured
        if let selected = conversation.model, selected.provider == provider.slug, !shortlist.contains(selected.model) {
            shortlist.insert(selected.model, at: 0)
        }
        return shortlist
    }

    private func priceLabel(_ pricing: ModelProvider.Pricing) -> String? {
        if pricing.free == true { return String(localized: "Free") }
        guard let input = pricing.input, let output = pricing.output else { return nil }
        return String(localized: "\(input) in · \(output) out per 1M")
    }

    private func select(_ selection: ModelSelection?) {
        conversation.pickModel(selection)
        workspace.rememberModelChoice(selection, effort: conversation.reasoningEffort, profile: conversation.modelProfile)
        onDone()
    }

    private func row(title: String, subtitle: String?, isSelected: Bool, isDisabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(isDisabled ? Theme.tertiaryText : Theme.primaryText)
                    if let subtitle, subtitle != title {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(Theme.tertiaryText)
                            .lineLimit(1)
                    }
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.primaryText)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The iPhone's reasoning controls, pinned under the model list (`docs/composer.md` §1): Auto,
/// and the seven-tick ladder for the next turn. Picking a level leaves the sheet open.
private struct ReasoningSheetBar: View {
    @Bindable var conversation: ConversationModel

    /// The last level picked here, so turning Auto off returns to it rather than a default.
    @State private var lastLevel: ReasoningEffort = .medium

    private static let levels = ReasoningEffort.allCases
    /// The slider's thumb is a capsule 35 pt wide (measured on iOS 26), so its centre travels
    /// the track inset by half that at each end; the marks sit under those centres.
    private static let thumbWidth: CGFloat = 35

    private var support: ModelReasoningSupport { conversation.chipReasoningSupport }
    private var isAuto: Bool { conversation.reasoningEffort == nil }
    private var currentLevel: ReasoningEffort { conversation.reasoningEffort ?? lastLevel }

    private var auto: Binding<Bool> {
        Binding(
            get: { conversation.reasoningEffort == nil },
            set: { on in conversation.reasoningEffort = on ? nil : lastLevel }
        )
    }

    /// The slider's seven steps, Off…Max, as the ladder's order.
    private var index: Binding<Double> {
        Binding(
            get: { Double(Self.levels.firstIndex(of: conversation.reasoningEffort ?? lastLevel) ?? 3) },
            set: { value in
                var position = min(max(Int(value.rounded()), 0), Self.levels.count - 1)
                // A model that can't turn reasoning off stops at Minimal.
                if position == 0, !support.canDisable { position = 1 }
                let level = Self.levels[position]
                lastLevel = level
                conversation.reasoningEffort = level
            }
        )
    }

    /// The ladder's seven stops, under the track at the positions the thumb takes: its centre
    /// stops half a thumb short of each end of the track.
    private var tickMarks: some View {
        GeometryReader { proxy in
            let inset = Self.thumbWidth / 2
            let span = max(proxy.size.width - inset * 2, 1)
            ForEach(0..<Self.levels.count, id: \.self) { step in
                Capsule()
                    .fill(Theme.tertiaryText)
                    .frame(width: 2, height: 5)
                    .position(
                        x: inset + span * CGFloat(step) / CGFloat(Self.levels.count - 1),
                        y: 2.5
                    )
            }
        }
        .frame(height: 5)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Reasoning")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.primaryText)
                if !isAuto, support.isSupported {
                    Text(ReasoningNames.title(for: currentLevel))
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                }
                Spacer()
                Text("Auto")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
                Toggle("Auto", isOn: auto)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .tint(Theme.ink)
                    // `labelsHidden` takes the switch's own name with the words drawn beside it.
                    .accessibilityLabel(Text("Auto"))
                    .disabled(!support.isSupported)
            }
            // Seven stops, Off…Max; Off is where a model that can't turn reasoning off stops
            // (`index` clamps it). The marks under the track are drawn here: this SDK's stepped
            // slider leaves them out (its `ticks:` labels don't show on iOS either).
            Slider(value: index, in: 0...Double(Self.levels.count - 1), step: 1) {
                Text("Reasoning")
            }
            .tint(Theme.ink)
            .disabled(isAuto || !support.isSupported)
            .accessibilityLabel(Text("Reasoning effort"))
            .accessibilityValue(Text(reasoningValue))
            tickMarks
            HStack {
                Text("Off")
                Spacer()
                Text("Max")
            }
            .font(.caption2)
            .foregroundStyle(Theme.tertiaryText)
            .padding(.top, -4)
            if let note = reasoningNote(support) {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.bar)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
        }
        .onAppear {
            if let level = conversation.reasoningEffort { lastLevel = level }
        }
        .onChange(of: conversation.reasoningEffort) { _, level in
            if let level { lastLevel = level }
        }
    }

    private var reasoningValue: String {
        guard support.isSupported else { return String(localized: "Not available") }
        return isAuto ? String(localized: "Auto") : ReasoningNames.title(for: currentLevel)
    }
}

/// Why the reasoning controls can't be used, when they can't.
private func reasoningNote(_ support: ModelReasoningSupport) -> String? {
    if !support.isSupported { return String(localized: "This model doesn't reason.") }
    if !support.canDisable { return String(localized: "This model can't turn reasoning off.") }
    return nil
}
