import Foundation

/// A chat's model and reasoning effort: what this device last set on its gateway session, so a
/// turn sends them only when they changed (`config.set`, `docs/sessions-and-models.md` §4).
public struct RunSettings: Equatable, Sendable {
    public var model: ModelSelection?
    public var effort: ReasoningEffort?

    public init(model: ModelSelection? = nil, effort: ReasoningEffort? = nil) {
        self.model = model
        self.effort = effort
    }
}

/// What one `config.set` answer says happened (`docs/sessions-and-models.md` §4).
///
/// hermes-agent `tui_gateway/model_switch.py`: a switch that took answers `applied: true`; one a
/// running turn holds back answers `applied: false, deferred: true` and takes effect as the next
/// turn starts; a selection guard answers `applied: false, confirm_required: true` with its
/// `confirm_message` and switches nothing. A gateway older than that contract answers its key and
/// value only, so a set that came back with an answer took; its fields still say otherwise when
/// they can (`deferred`, `confirm_required`).
public enum ConfigSetAnswer: Equatable, Sendable {
    /// Hermes has it now, or (deferred) takes it as the turn this message starts begins.
    case applied(deferred: Bool)
    /// Hermes wants the person to confirm first: nothing changed.
    case confirmRequired(message: String)
    /// The runtime id is stale: resume, then set it again on the new one.
    case sessionNotFound
    /// Hermes refused it, or the call failed: nothing changed.
    case failed(message: String)

    public init(result: JSONValue?, error: (any Error)?) {
        if let error {
            if let rpc = error as? GatewayRPCError, rpc.isSessionNotFound {
                self = .sessionNotFound
            } else if let rpc = error as? GatewayRPCError {
                self = .failed(message: rpc.message)
            } else {
                self = .failed(message: error.localizedDescription)
            }
            return
        }
        guard let result else {
            self = .failed(message: "")
            return
        }
        if result["confirm_required"]?.boolValue == true {
            self = .confirmRequired(
                message: result["confirm_message"]?.stringValue ?? result["warning"]?.stringValue ?? ""
            )
            return
        }
        let deferred = result["deferred"]?.boolValue == true
        if let applied = result["applied"]?.boolValue {
            if applied {
                self = .applied(deferred: deferred)
            } else if deferred {
                self = .applied(deferred: true)
            } else {
                self = .failed(message: result["warning"]?.stringValue ?? result["message"]?.stringValue ?? "")
            }
        } else {
            self = .applied(deferred: deferred)
        }
    }
}
