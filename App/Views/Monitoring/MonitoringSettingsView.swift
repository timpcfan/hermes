import HermesKit
import SwiftUI

/// Settings → Monitoring → Xunxin link (`docs/monitoring.md` §5). It edits one app-wide
/// connection, never a gateway's. An enabled connection saves only after a usable test; a
/// disabled one saves offline; a failed save leaves the saved configuration and the draft alone.
/// Settings → Monitoring → Xunxin link, on iPhone. It sits outside the per-gateway section: the
/// monitor link is the app's, and works with no gateway at all.
struct MonitoringSettingsRow: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        NavigationLink {
            MonitoringSettingsView(model: app.monitoring)
        } label: {
            SettingsRowLabel(symbol: "chart.bar.xaxis", localizedTitle: statsString("Xunxin link"), summary: summary)
        }
        .accessibilityHint(statsString("The monitor service Stats reads"))
        .accessibilityIdentifier("settings.monitoring")
    }

    private var summary: String {
        guard app.monitoring.settings.enabled else { return statsString("Off") }
        return app.monitoring.isConfigured ? app.monitoring.displayName : statsString("Needs setting up")
    }
}

struct MonitoringSettingsView: View {
    @State private var editor: MonitoringSettingsEditor
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case name, address, token
    }

    init(model: MonitoringModel) {
        _editor = State(initialValue: MonitoringSettingsEditor(model: model))
    }

    var body: some View {
        @Bindable var editor = editor
        Form {
            Section {
                Toggle(statsString("Monitor this link"), isOn: $editor.draft.enabled)
                TextField(statsString("Name"), text: $editor.draft.name)
                    .focused($focusedField, equals: .name)
                TextField(statsString("Service address"), text: $editor.draft.baseURL)
                    .focused($focusedField, equals: .address)
                    #if os(iOS)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                Picker(statsString("Authentication"), selection: $editor.draft.auth) {
                    Text(statsString("None")).tag(MonitoringAuthMode.none)
                    Text(statsString("Bearer token")).tag(MonitoringAuthMode.bearer)
                }
                if editor.draft.auth == .bearer {
                    SecureField(
                        editor.hasStoredToken
                            ? statsString("Saved token (leave blank to keep)")
                            : statsString("Access token"),
                        text: $editor.draft.token
                    )
                    .focused($focusedField, equals: .token)
                    #if os(iOS)
                    .textContentType(.password)
                    #endif
                    .autocorrectionDisabled()
                }
            } header: {
                Text(statsString("Xunxin link"))
            } footer: {
                Text(statsString("This is the monitor service itself, not a Hermes gateway. One link is used by the whole app, whichever gateway or Bot is open."))
            }

            if editor.isPlainHTTP {
                Section {
                    Label {
                        Text(statsString("This address is plain HTTP. The token and the statistics cross the network unencrypted."))
                            .font(.caption)
                            .foregroundStyle(Theme.warning)
                    } icon: {
                        Image(systemName: "lock.open")
                            .foregroundStyle(Theme.warning)
                    }
                }
            }

            if let problem = editor.validationProblem {
                Section {
                    Text(statsError(problem))
                        .font(.caption)
                        .foregroundStyle(Theme.danger)
                }
            }

            Section {
                Button {
                    Task { await editor.test() }
                } label: {
                    HStack {
                        Text(statsString("Test Connection"))
                        Spacer()
                        if editor.isTesting { Spinner() }
                    }
                }
                .disabled(!editor.canTest)

                if let error = editor.testError {
                    testLine(state: .failed, title: statsString("The test couldn't run"), detail: error)
                }
                if let check = editor.check {
                    testLine(state: check.snapshot.state == .ok ? .ok : check.snapshot.state, title: statsString("Snapshot structure"), detail: check.snapshot.statsDetail)
                    testLine(state: check.recent.state == .ok ? .ok : check.recent.state, title: statsString("Requests list"), detail: check.recent.statsDetail)
                    testLine(state: check.stream.state == .ok ? .ok : check.stream.state, title: statsString("Live updates"), detail: check.stream.statsDetail)
                    Text(check.statsSummary)
                        .font(.caption)
                        .foregroundStyle(check.isUsable ? Theme.secondaryText : Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text(statsString("Connection test"))
            } footer: {
                Text(editor.draft.enabled
                     ? statsString("An enabled connection needs a working snapshot and requests list. If live updates fail, the app saves it in polling mode and reads a snapshot every 10 seconds.")
                     : statsString("Monitoring is off. You can save a blank address; the app won't connect to anything."))
            }

            if let error = editor.saveError {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(statsString("Couldn't save"), systemImage: "exclamationmark.triangle")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.danger)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(statsString("Your previous saved configuration is unchanged."))
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
            }

            if editor.saved {
                Section {
                    Label(statsString("Saved"), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Theme.success)
                        .accessibilityIdentifier("stats.settings.saved")
                }
            }

            Section {
                Button {
                    focusedField = nil
                    Task { await editor.save() }
                } label: {
                    HStack {
                        Text(editor.draft.enabled ? statsString("Save") : statsString("Save Without Connecting"))
                        Spacer()
                        if editor.isSaving { Spinner() }
                    }
                }
                .disabled(!editor.canSave)
                .accessibilityIdentifier("stats.settings.save")

                if let hint = editor.saveHint {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(statsString("Monitoring service"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .accessibilityIdentifier("stats.settings.form")
        .onAppear { editor.model.reloadSettings() }
    }

    private func testLine(state: MonitoringCheckStep.State, title: String, detail: String?) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol(state))
                .foregroundStyle(color(state))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(Theme.primaryText)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(statsString("\(title): \(stateText(state))\(detail.map { ". \($0)" } ?? "")")))
    }

    private func symbol(_ state: MonitoringCheckStep.State) -> String {
        switch state {
        case .ok: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .timedOut: "clock.badge.exclamationmark"
        }
    }

    private func color(_ state: MonitoringCheckStep.State) -> Color {
        switch state {
        case .ok: Theme.success
        case .failed: Theme.danger
        case .timedOut: Theme.warning
        }
    }

    private func stateText(_ state: MonitoringCheckStep.State) -> String {
        switch state {
        case .ok: statsString("OK")
        case .failed: statsString("Failed")
        case .timedOut: statsString("Timed out")
        }
    }
}
