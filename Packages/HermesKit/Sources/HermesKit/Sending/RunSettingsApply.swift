import Foundation

/// Sets a chat's model and reasoning effort on its gateway session before a turn, and says whether
/// the turn will really run on them (`docs/sessions-and-models.md` §4).
///
/// A stale runtime (`config.set` answers 4001) is resumed through `reattach` and the settings go
/// on the new runtime, before the caller submits its prompt: a picked model must run the very next
/// message, not the one after it. A set that didn't take is never recorded as applied, and a model
/// that will not run this message is said plainly (`notice`).
///
/// A model pick carries the chat's level, level changed or not: Hermes re-reads the level from the
/// new model's own config as it swaps the model, so one set on its own would be gone the moment
/// the pick landed.
public enum RunSettingsApply {
    /// The runtime a resume gave back, and the settings Hermes reports for it.
    public struct Reattach: Equatable, Sendable {
        public var runtime: String
        public var applied: RunSettings?
        /// What the chat wants now, when opening the resumed session changed it (another device's
        /// pick, which the chat follows). Nil keeps what was asked for.
        public var wanted: RunSettings?

        public init(runtime: String, applied: RunSettings?, wanted: RunSettings? = nil) {
            self.runtime = runtime
            self.applied = applied
            self.wanted = wanted
        }
    }

    /// What the session runs after the attempt, and what to tell the person.
    public struct Outcome: Equatable, Sendable {
        /// The runtime the prompt must go to (a resumed one after 4001).
        public var runtime: String
        /// The settings the session runs as far as this device knows. A model that didn't take is
        /// the one the chat already had, never the picked one.
        public var applied: RunSettings?
        public var modelApplied: Bool
        public var effortApplied: Bool
        /// Hermes asks the person to confirm this switch: nothing changed.
        public var confirmationMessage: String?
        /// The sentence to show when this message runs on another model than the one picked.
        public var notice: String?

        public init(
            runtime: String, applied: RunSettings?, modelApplied: Bool, effortApplied: Bool,
            confirmationMessage: String? = nil, notice: String? = nil
        ) {
            self.runtime = runtime
            self.applied = applied
            self.modelApplied = modelApplied
            self.effortApplied = effortApplied
            self.confirmationMessage = confirmationMessage
            self.notice = notice
        }
    }

    /// - Parameters:
    ///   - wanted: the chat's model and effort now.
    ///   - applied: what the session was last known to run.
    ///   - runtime: the runtime id to set them on.
    ///   - set: one `config.set`: runtime, key, value.
    ///   - reattach: resumes the chat after 4001 and says what Hermes reports for the new runtime.
    public static func run(
        wanted: RunSettings,
        applied: RunSettings?,
        runtime: String,
        set: @Sendable (_ runtime: String, _ key: String, _ value: String) async throws -> JSONValue,
        reattach: @Sendable () async throws -> Reattach
    ) async -> Outcome {
        var wanted = wanted
        var runtime = runtime
        var effective = applied ?? RunSettings()
        // No pick from this device (the chat runs the gateway's default) is nothing to set: the
        // default is not a model name, and picking it back is not a switch.
        var modelApplied = wanted.model == nil || wanted.model == effective.model
        var effortApplied = wanted.effort == effective.effort
        var confirmationMessage: String?
        var reattached = false

        func setConfig(_ key: String, _ value: String) async -> ConfigSetAnswer {
            do {
                return ConfigSetAnswer(result: try await set(runtime, key, value), error: nil)
            } catch {
                return ConfigSetAnswer(result: nil, error: error)
            }
        }

        /// A new runtime starts from what Hermes reports for it, so what this device knew about the
        /// old one is set again where it differs. One resume per send: a second 4001 is a failure.
        func resume() async -> Bool {
            guard !reattached else { return false }
            reattached = true
            guard let resumed = try? await reattach() else { return false }
            runtime = resumed.runtime
            if let updated = resumed.wanted { wanted = updated }
            effective = resumed.applied ?? RunSettings()
            modelApplied = wanted.model == nil || wanted.model == effective.model
            effortApplied = wanted.effort == effective.effort
            return true
        }

        /// Sets what differs. Returns whether it resumed the chat, so the caller can go once more
        /// on the runtime Hermes gave back.
        func applyOnce() async -> Bool {
            if !modelApplied, let model = wanted.model, confirmationMessage == nil {
                let answer = await setConfig("model", Self.switchValue(model, effort: wanted.effort))
                if case .sessionNotFound = answer, await resume() { return true }
                switch answer {
                case .applied:
                    modelApplied = true
                    effective.model = model
                    // A swap makes Hermes re-read the level from the new model's own config, so what
                    // the session ran before it says nothing about now: it runs the level that rode
                    // along, or with Auto the new model's own.
                    effective.effort = wanted.effort
                    effortApplied = true
                case .confirmRequired(let message):
                    confirmationMessage = message
                case .sessionNotFound, .failed:
                    break
                }
            }
            if !effortApplied, let effort = wanted.effort {
                let answer = await setConfig("reasoning", effort.rawValue)
                if case .sessionNotFound = answer, await resume() { return true }
                if case .applied = answer {
                    effortApplied = true
                    effective.effort = effort
                }
            }
            return false
        }

        if await applyOnce() {
            _ = await applyOnce()
        }

        var notice: String?
        if let model = wanted.model, !modelApplied, confirmationMessage == nil {
            notice = Self.notice(wanted: model, used: effective.model)
        }

        return Outcome(
            runtime: runtime, applied: effective, modelApplied: modelApplied,
            effortApplied: effortApplied, confirmationMessage: confirmationMessage, notice: notice
        )
    }

    /// The `config.set {key: "model"}` value for a pick. The chat's level rides with the model
    /// (`--reasoning <level>`, hermes-agent v0.21.6+): Hermes applies it after the swap, and
    /// together with it when the swap is queued for the next turn.
    public static func switchValue(_ model: ModelSelection, effort: ReasoningEffort?) -> String {
        var value = "\(model.model) --provider \(model.provider)"
        if let effort { value += " --reasoning \(effort.rawValue)" }
        return value
    }

    /// The sentence for a model that didn't take: the one picked, and the one the message runs on.
    public static func notice(wanted: ModelSelection, used: ModelSelection?) -> String {
        let used = used.map(\.shortName) ?? String(localized: "the model the chat already had")
        return String(localized: "Hermes didn't switch this chat to \(wanted.shortName). This message runs on \(used).")
    }
}
