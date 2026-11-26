import Foundation

/// The composer's model-and-reasoning chip (`docs/composer.md` §1): what the next turn will send
/// with, in one control beside the field.
public enum ComposerChipModel {
    /// The chip's shape. While a turn runs the send-mode chip takes the words beside it
    /// (`docs/follow-ups.md` §2), so the model chip keeps only its signal.
    public enum Layout: Equatable, Sendable {
        case full
        case iconOnly
    }

    /// The model the next turn sends with.
    public struct Model: Equatable, Sendable {
        /// The model id, nil when the chat names none and the chip names the gateway instead.
        public var id: String?
        /// The provider slug, when it is known (`ModelSelection`): a reported model doesn't carry
        /// one, so the capability lookup finds its provider by the model.
        public var provider: String?
        /// What the chip reads: "Claude Sonnet 4.6", or the gateway's name.
        public var name: String

        public init(id: String?, provider: String?, name: String) {
            self.id = id
            self.provider = provider
            self.name = name
        }
    }

    public static func layout(showsModeChip: Bool) -> Layout {
        showsModeChip ? .iconOnly : .full
    }

    /// The model the chat will send with: what this device picked for it, else what its row
    /// reports, else the profile's default, else the gateway's name.
    public static func model(
        picked: ModelSelection?, reported: String?, profileDefault: String?,
        defaultProvider: String?, gatewayName: String
    ) -> Model {
        if let picked {
            return Model(id: picked.model, provider: picked.provider, name: ModelNames.display(picked.model))
        }
        if let reported = trimmed(reported) {
            return Model(id: reported, provider: nil, name: ModelNames.display(reported))
        }
        if let profileDefault = trimmed(profileDefault) {
            return Model(id: profileDefault, provider: defaultProvider, name: ModelNames.display(profileDefault))
        }
        return Model(id: nil, provider: nil, name: gatewayName)
    }

    private static func trimmed(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}

/// The reasoning mark the composer chip carries (`docs/composer.md` §1): `cellularbars` with whole
/// bars lit, `a.circle` for Auto, and a model that doesn't reason gets no lit bar.
public enum ReasoningSignal: Equatable, Sendable {
    /// The gateway decides the effort.
    case auto
    /// A level is set: how many of the four bars are lit (Off is none).
    case bars(Int)
    /// The model doesn't reason at all.
    case unavailable

    public static let totalBars = 4

    public init(effort: ReasoningEffort?, supported: Bool) {
        if !supported {
            self = .unavailable
        } else if let effort {
            self = .bars(Self.bars(for: effort))
        } else {
            self = .auto
        }
    }

    /// How many of `cellularbars`' four bars are lit. The one place the ladder is written, so a
    /// change of ladder is a change here (and in its test).
    public static func bars(for effort: ReasoningEffort) -> Int {
        switch effort {
        case .off: 0
        case .minimal, .low: 1
        case .medium: 2
        case .high: 3
        case .xhigh, .max: 4
        }
    }

    /// The symbol's variable value: `bars` whole bars out of four, in `.color` mode.
    public var variableValue: Double {
        switch self {
        case .auto, .unavailable: 0
        case .bars(let count): Double(count) / Double(Self.totalBars)
        }
    }
}

/// What the gateway says about reasoning for a model (`capabilities` in `/api/model/options`).
/// A model it says nothing about is assumed to reason, and to be able to turn it off.
public struct ModelReasoningSupport: Equatable, Sendable {
    public var isSupported: Bool
    public var canDisable: Bool

    public init(isSupported: Bool = true, canDisable: Bool = true) {
        self.isSupported = isSupported
        self.canDisable = canDisable
    }

    /// Nothing said about the model, or no list yet.
    public static let unknown = ModelReasoningSupport()
}

extension ModelOptions {
    /// The capability entry for `model`, whichever provider serves it: the one `provider` names
    /// when it's known, else the first that lists the model. Ids match whole or by their last
    /// path segment, since a chat's row reports the model without its provider.
    public func reasoningSupport(for model: String?, provider: String?) -> ModelReasoningSupport {
        guard let model = model?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty else {
            return .unknown
        }
        let short = Self.shortName(model)
        func serves(_ row: ModelProvider) -> Bool {
            row.models.contains { $0 == model || Self.shortName($0) == short }
        }
        let named = provider.flatMap { $0.isEmpty ? nil : $0 }
        let candidates = named.map { name in providers.filter { $0.matches(provider: name) } } ?? providers
        guard let owner = candidates.first(where: serves) ?? providers.first(where: serves) else {
            return .unknown
        }
        let capability = owner.capabilities?[model] ?? owner.capabilities?.first { key, _ in
            Self.shortName(key) == short
        }?.value
        guard let capability else { return .unknown }
        return ModelReasoningSupport(isSupported: capability.reasoning ?? true,
                                     canDisable: capability.canDisableReasoning ?? true)
    }

    private static func shortName(_ id: String) -> String {
        id.split(separator: "/").last.map(String.init) ?? id
    }
}
