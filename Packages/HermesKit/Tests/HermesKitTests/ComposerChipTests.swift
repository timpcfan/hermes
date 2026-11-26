import Foundation
import Testing
@testable import HermesKit

@Suite("Composer chip")
struct ComposerChipTests {
    // MARK: Signal

    /// The ladder the brief fixes: four whole bars, Off none, XHigh and Max all four.
    @Test func theSignalLightsWholeBars() {
        #expect(ReasoningSignal.bars(for: .off) == 0)
        #expect(ReasoningSignal.bars(for: .minimal) == 1)
        #expect(ReasoningSignal.bars(for: .low) == 1)
        #expect(ReasoningSignal.bars(for: .medium) == 2)
        #expect(ReasoningSignal.bars(for: .high) == 3)
        #expect(ReasoningSignal.bars(for: .xhigh) == 4)
        #expect(ReasoningSignal.bars(for: .max) == 4)
    }

    @Test func autoAndUnsupportedAreTheirOwnSignals() {
        #expect(ReasoningSignal(effort: nil, supported: true) == .auto)
        #expect(ReasoningSignal(effort: .high, supported: true) == .bars(3))
        #expect(ReasoningSignal(effort: .high, supported: false) == .unavailable)
        // Auto isn't offered on a model that doesn't reason: the mark says so instead.
        #expect(ReasoningSignal(effort: nil, supported: false) == .unavailable)
    }

    @Test func theVariableValueFillsWholeBars() {
        #expect(ReasoningSignal.auto.variableValue == 0)
        #expect(ReasoningSignal.unavailable.variableValue == 0)
        #expect(ReasoningSignal.bars(0).variableValue == 0)
        #expect(ReasoningSignal.bars(1).variableValue == 0.25)
        #expect(ReasoningSignal.bars(2).variableValue == 0.5)
        #expect(ReasoningSignal.bars(3).variableValue == 0.75)
        #expect(ReasoningSignal.bars(4).variableValue == 1)
    }

    // MARK: Layout

    @Test func theModeChipLeavesTheSignalAlone() {
        #expect(ComposerChipModel.layout(showsModeChip: false) == .full)
        #expect(ComposerChipModel.layout(showsModeChip: true) == .iconOnly)
    }

    // MARK: Model

    @Test func aPickedModelWinsAndKeepsItsProvider() {
        let model = ComposerChipModel.model(
            picked: ModelSelection(provider: "openrouter", model: "anthropic/claude-sonnet-4.6"),
            reported: "openai/gpt-5", profileDefault: "Hermes-4-70B", defaultProvider: "nous",
            gatewayName: "Hermes"
        )
        #expect(model.id == "anthropic/claude-sonnet-4.6")
        #expect(model.provider == "openrouter")
        #expect(model.name == "Claude Sonnet 4.6")
    }

    @Test func theChatsReportedModelComesNext() {
        let model = ComposerChipModel.model(
            picked: nil, reported: "openai/gpt-5", profileDefault: "Hermes-4-70B", defaultProvider: "nous",
            gatewayName: "Hermes"
        )
        #expect(model.id == "openai/gpt-5")
        // A row names no provider: the list finds it by the model.
        #expect(model.provider == nil)
        #expect(model.name == "GPT 5")
    }

    @Test func theProfilesDefaultComesAfterTheRow() {
        let model = ComposerChipModel.model(
            picked: nil, reported: nil, profileDefault: "Hermes-4-70B", defaultProvider: "nous",
            gatewayName: "Hermes"
        )
        #expect(model.id == "Hermes-4-70B")
        #expect(model.provider == "nous")
        #expect(model.name == "Hermes 4 70B")
    }

    @Test func anEmptyReportedModelFallsThroughToTheDefault() {
        for reported in ["", "   ", nil] {
            let model = ComposerChipModel.model(
                picked: nil, reported: reported, profileDefault: "Hermes-4-70B", defaultProvider: "nous",
                gatewayName: "Hermes"
            )
            #expect(model.id == "Hermes-4-70B")
        }
    }

    @Test func nothingKnownNamesTheGateway() {
        let model = ComposerChipModel.model(picked: nil, reported: nil, profileDefault: nil, defaultProvider: nil, gatewayName: "Studio Mac")
        #expect(model.id == nil)
        #expect(model.name == "Studio Mac")
    }

    // MARK: Reasoning support

    private static let options: ModelOptions = {
        let json = """
        {
          "model": "anthropic/claude-sonnet-4.6", "provider": "openrouter",
          "providers": [
            {"slug": "openrouter", "name": "OpenRouter", "is_current": true, "authenticated": true,
             "models": ["anthropic/claude-sonnet-4.6", "openai/gpt-5", "qwen/qwen3-coder", "anthropic/claude-opus-4.6"],
             "capabilities": {
               "openai/gpt-5": {"fast": true, "reasoning": true},
               "qwen/qwen3-coder": {"reasoning": false},
               "anthropic/claude-opus-4.6": {"reasoning": true, "can_disable_reasoning": false}
             }},
            {"slug": "nous", "name": "Nous Portal", "authenticated": true,
             "models": ["Hermes-4-70B"]}
          ]
        }
        """
        return try! JSONDecoder().decode(ModelOptions.self, from: Data(json.utf8))
    }()

    @Test func aModelTheListSaysNothingAboutReasons() {
        let support = Self.options.reasoningSupport(for: "anthropic/claude-sonnet-4.6", provider: "openrouter")
        #expect(support.isSupported)
        #expect(support.canDisable)
        #expect(Self.options.reasoningSupport(for: "Hermes-4-70B", provider: "nous") == .unknown)
    }

    @Test func aModelWithoutReasoningIsNotSupported() {
        let support = Self.options.reasoningSupport(for: "qwen/qwen3-coder", provider: nil)
        #expect(!support.isSupported)
        #expect(ReasoningSignal(effort: .high, supported: support.isSupported) == .unavailable)
    }

    @Test func aModelThatCantTurnReasoningOffSaysSo() {
        let support = Self.options.reasoningSupport(for: "anthropic/claude-opus-4.6", provider: "openrouter")
        #expect(support.isSupported)
        #expect(!support.canDisable)
    }

    @Test func theLookupMatchesAShortNameToItsFullId() {
        // A chat's row reports `gpt-5`, the list keys its capability by `openai/gpt-5`.
        #expect(Self.options.reasoningSupport(for: "gpt-5", provider: nil).isSupported)
        // And a provider named by a short model still finds its row's capability.
        let support = Self.options.reasoningSupport(for: "openai/gpt-5", provider: nil)
        #expect(support.isSupported)
    }

    @Test func anUnknownModelOrNoModelReasons() {
        #expect(Self.options.reasoningSupport(for: "made-up/model", provider: nil) == .unknown)
        #expect(Self.options.reasoningSupport(for: nil, provider: nil) == .unknown)
        #expect(Self.options.reasoningSupport(for: "  ", provider: nil) == .unknown)
    }

    @Test func aNamedProviderThatDoesntServeTheModelStillFindsItsOwner() {
        // The picker keeps a pick from another profile: the provider named no longer serves it,
        // but another row does.
        let support = Self.options.reasoningSupport(for: "openai/gpt-5", provider: "nous")
        #expect(support.isSupported)
    }
}
