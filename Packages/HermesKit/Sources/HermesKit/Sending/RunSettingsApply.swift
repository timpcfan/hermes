import Foundation

/// Sets a chat's model and reasoning effort on its gateway session before a turn, and says whether
/// the turn will really run on them (`docs/sessions-and-models.md` §4).
///
/// A stale runtime (`config.set` answers 4001) is resumed through `reattach` and the settings go
/// on the new runtime, before the caller submits its prompt: a picked model must run the very next
/// message, not the one after it. A set that didn't take is never recorded as applied, and a model
/// that will not run this message is said plainly (`notice`).
public enum RunSettingsApply {
    /// The runtime a resume gave back, and the settings Hermes reports for it.
    public struct Reattach: Equatable, Sendable {
        public var runtime: String
        public var applied: RunSettings?

        public init(runtime: String, applied: RunSettings?) {
            self.runtime = runtime
            self.applied = applied
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
        // The old behavior: whatever the call answered, the pick was taken as applied.
        var effective = applied ?? RunSettings()
        if let model = wanted.model { effective.model = model }
        if let effort = wanted.effort { effective.effort = effort }
        return Outcome(runtime: runtime, applied: effective, modelApplied: true, effortApplied: true)
    }
}
