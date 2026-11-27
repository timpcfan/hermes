import Foundation
import HermesKit
import Observation

/// Settings → Monitoring → Xunxin link's draft (`docs/monitoring.md` §5). The test result belongs
/// to the exact address and token it ran on: changing either drops it, so Save can't claim a
/// connection nobody checked.
@MainActor
@Observable
final class MonitoringSettingsEditor {
    struct Draft: Equatable {
        var enabled = false
        var name = "Xunxin monitor"
        var baseURL = ""
        var auth: MonitoringAuthMode = .none
        var token = ""

        init(_ settings: MonitoringSettings) {
            enabled = settings.enabled
            // The core's default name is English; the form shows it in the app's language until
            // someone renames the link (saving keeps what the field shows).
            name = settings.name == MonitoringSettings.initial.name
                ? statsString("Xunxin monitor")
                : settings.name
            baseURL = settings.baseURL
            auth = settings.auth
        }
    }

    let model: MonitoringModel

    var draft: Draft {
        didSet {
            guard draft != oldValue else { return }
            invalidateTest()
            saved = false
        }
    }

    private(set) var check: MonitoringConnectionCheck?
    private(set) var isTesting = false
    private(set) var isSaving = false
    private(set) var testError: String?
    private(set) var saveError: String?
    private(set) var saved = false

    private var testedConnection: MonitoringConnection?
    private var testGeneration = 0

    init(model: MonitoringModel) {
        self.model = model
        draft = Draft(model.settings)
    }

    var hasStoredToken: Bool { model.hasStoredToken }

    var settings: MonitoringSettings {
        MonitoringSettings(
            enabled: draft.enabled, name: draft.name, baseURL: draft.baseURL, auth: draft.auth,
            liveUpdates: model.settings.liveUpdates
        )
    }

    var validationProblem: MonitoringSettingsProblem? {
        MonitoringSettingsValidation.problem(
            settings, typedToken: draft.token, hasStoredToken: model.hasStoredToken
        )
    }

    /// A plain-HTTP address sends the token and the data unencrypted; the form says so.
    var isPlainHTTP: Bool {
        draft.enabled && MonitoringAddress.isPlainHTTP(draft.baseURL)
    }

    var connectionProblem: String? {
        guard !draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return statsString("Enter the monitor service's address.")
        }
        do {
            _ = try model.connection(baseURL: draft.baseURL, auth: draft.auth, typedToken: draft.token)
            if draft.auth == .bearer, draft.token.isEmpty, !model.hasStoredToken {
                return MonitoringSettingsProblem.tokenMissing.errorDescription
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    var canTest: Bool { !isTesting && connectionProblem == nil }

    /// Save follows "test then save": an enabled connection needs a usable check for this exact
    /// address and token. A disabled one saves offline with a blank address.
    var canSave: Bool {
        guard !isSaving, validationProblem == nil else { return false }
        guard draft.enabled else { return true }
        guard let check, check.isUsable, let testedConnection else { return false }
        return testedConnection == (try? model.connection(
            baseURL: draft.baseURL, auth: draft.auth, typedToken: draft.token
        ))
    }

    var saveHint: String? {
        if let validationProblem { return validationProblem.errorDescription }
        guard draft.enabled else { return nil }
        if isTesting { return statsString("Testing the connection…") }
        guard let check else { return statsString("Test the connection before saving.") }
        if !check.isUsable { return check.summary }
        return nil
    }

    // MARK: - Actions

    func test() async {
        guard canTest else { return }
        testGeneration += 1
        let generation = testGeneration
        isTesting = true
        testError = nil
        check = nil
        testedConnection = nil
        do {
            let used = try model.connection(
                baseURL: draft.baseURL, auth: draft.auth, typedToken: draft.token
            )
            let result = try await model.check(
                baseURL: draft.baseURL, auth: draft.auth, typedToken: draft.token
            )
            guard generation == testGeneration else { return }
            check = result
            testedConnection = used
            isTesting = false
        } catch is CancellationError {
            guard generation == testGeneration else { return }
            isTesting = false
        } catch {
            guard generation == testGeneration else { return }
            testError = error.localizedDescription
            isTesting = false
        }
    }

    /// Returns whether the save went through. A failure keeps the draft and the previous saved
    /// configuration exactly as they were.
    @discardableResult
    func save() async -> Bool {
        guard canSave else { return false }
        isSaving = true
        saveError = nil
        do {
            var newSettings = settings
            if newSettings.enabled, let check {
                newSettings.liveUpdates = check.mode == .live
            }
            try model.save(newSettings, token: draft.token)
            isSaving = false
            saved = true
            return true
        } catch {
            isSaving = false
            saveError = error.localizedDescription
            return false
        }
    }

    /// The address, auth mode or token changed: the old test no longer describes this draft.
    private func invalidateTest() {
        testGeneration += 1
        check = nil
        testedConnection = nil
        testError = nil
        isTesting = false
    }
}
