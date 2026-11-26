import Foundation
import Testing
@testable import HermesKit

/// A picked model runs the very next message (`docs/sessions-and-models.md` §4): `config.set`'s
/// receipt is read, a stale runtime is resumed and set again before the prompt, and a set that
/// didn't take is never recorded as applied.
@Suite("Run settings")
struct RunSettingsTests {
    private let sonnet = ModelSelection(provider: "anthropic", model: "claude-sonnet-4-6")
    private let gpt = ModelSelection(provider: "openrouter", model: "openai/gpt-5")

    private var gptValue: String { "openai/gpt-5 --provider openrouter" }

    private actor Events {
        enum Event: Equatable, Sendable {
            case set(runtime: String, key: String, value: String)
            case reattach
        }

        private(set) var events: [Event] = []

        func add(_ event: Event) { events.append(event) }
    }

    // MARK: - The receipt

    @Test func aReceiptWithAppliedSaysWhatHermesDid() {
        #expect(ConfigSetAnswer(result: .object(["applied": .bool(true)]), error: nil) == .applied(deferred: false))
        #expect(ConfigSetAnswer(result: .object(["applied": .bool(true), "deferred": .bool(false)]), error: nil)
            == .applied(deferred: false))
        #expect(ConfigSetAnswer(result: .object(["applied": .bool(false), "deferred": .bool(true)]), error: nil)
            == .applied(deferred: true))
        #expect(ConfigSetAnswer(result: .object(["applied": .bool(false)]), error: nil) == .failed(message: ""))
        #expect(ConfigSetAnswer(result: .object(["applied": .bool(false), "message": .string("nope")]), error: nil)
            == .failed(message: "nope"))
    }

    @Test func anOlderGatewayWithoutAppliedIsReadByItsFields() {
        // No `applied`: an answer is a set that took, unless `deferred` or `confirm_required` says so.
        #expect(ConfigSetAnswer(result: .object(["key": .string("model"), "value": .string(gptValue)]), error: nil)
            == .applied(deferred: false))
        #expect(ConfigSetAnswer(result: .object(["deferred": .bool(true)]), error: nil) == .applied(deferred: true))
        let confirm = JSONValue.object([
            "confirm_required": .bool(true),
            "confirm_message": .string("It costs more."),
            "warning": .string("It costs more."),
        ])
        #expect(ConfigSetAnswer(result: confirm, error: nil) == .confirmRequired(message: "It costs more."))
        // A selection guard with no message still refuses: the person's pick is never taken.
        #expect(ConfigSetAnswer(result: .object(["confirm_required": .bool(true)]), error: nil)
            == .confirmRequired(message: ""))
    }

    @Test func anErrorIsNeverApplied() {
        #expect(ConfigSetAnswer(result: nil, error: GatewayRPCError(code: 5001, message: "config write failed"))
            == .failed(message: "config write failed"))
        #expect(ConfigSetAnswer(result: nil, error: GatewayRPCError(code: 5032, message: "compute host unavailable"))
            == .failed(message: "compute host unavailable"))
        #expect(ConfigSetAnswer(result: nil, error: GatewayRPCError(code: 4001, message: "session not found"))
            == .sessionNotFound)
        #expect(ConfigSetAnswer(result: nil, error: URLError(.timedOut)) != .applied(deferred: false))
    }

    // MARK: - Applying

    @Test func aDeferredSwitchCountsForThisMessage() async {
        let events = Events()
        let outcome = await RunSettingsApply.run(
            wanted: RunSettings(model: gpt, effort: nil),
            applied: RunSettings(model: sonnet, effort: nil),
            runtime: "runtime-1",
            set: { runtime, key, value in
                await events.add(.set(runtime: runtime, key: key, value: value))
                return .object(["applied": .bool(false), "deferred": .bool(true)])
            },
            reattach: {
                await events.add(.reattach)
                return .init(runtime: "runtime-2", applied: RunSettings(model: sonnet, effort: nil))
            }
        )
        #expect(outcome.modelApplied)
        #expect(outcome.applied?.model == gpt)
        #expect(outcome.notice == nil)
        #expect(outcome.runtime == "runtime-1")
        #expect(await events.events == [.set(runtime: "runtime-1", key: "model", value: gptValue)])
    }

    @Test func aConfirmationIsNeverTaken() async {
        let events = Events()
        let outcome = await RunSettingsApply.run(
            wanted: RunSettings(model: gpt, effort: nil),
            applied: RunSettings(model: sonnet, effort: nil),
            runtime: "runtime-1",
            set: { runtime, key, value in
                await events.add(.set(runtime: runtime, key: key, value: value))
                return .object([
                    "applied": .bool(false), "confirm_required": .bool(true),
                    "confirm_message": .string("It costs more."),
                ])
            },
            reattach: {
                await events.add(.reattach)
                return .init(runtime: "runtime-2", applied: RunSettings(model: sonnet, effort: nil))
            }
        )
        #expect(!outcome.modelApplied)
        // The chat keeps the model it had, and the card carries Hermes's question.
        #expect(outcome.applied?.model == sonnet)
        #expect(outcome.confirmationMessage == "It costs more.")
        #expect(outcome.notice == nil)
        #expect(outcome.runtime == "runtime-1")
        #expect(await events.events == [.set(runtime: "runtime-1", key: "model", value: gptValue)])
    }

    @Test func aFailedSwitchIsNotRecordedAndSaysSo() async {
        let events = Events()
        let outcome = await RunSettingsApply.run(
            wanted: RunSettings(model: gpt, effort: nil),
            applied: RunSettings(model: sonnet, effort: nil),
            runtime: "runtime-1",
            set: { runtime, key, value in
                await events.add(.set(runtime: runtime, key: key, value: value))
                throw GatewayRPCError(code: 5001, message: "config write failed")
            },
            reattach: {
                await events.add(.reattach)
                return .init(runtime: "runtime-2", applied: RunSettings(model: sonnet, effort: nil))
            }
        )
        #expect(!outcome.modelApplied)
        // Never the pick: the chat goes back to the model the session really has.
        #expect(outcome.applied?.model == sonnet)
        #expect(outcome.runtime == "runtime-1")
        let notice = try? #require(outcome.notice)
        #expect(notice?.contains("gpt-5") == true)
        #expect(notice?.contains("claude-sonnet-4-6") == true)
        #expect(await events.events == [.set(runtime: "runtime-1", key: "model", value: gptValue)])
    }

    @Test func aDeadRuntimeIsResumedAndTheModelSetBeforeTheMessage() async {
        let events = Events()
        let outcome = await RunSettingsApply.run(
            wanted: RunSettings(model: gpt, effort: .high),
            applied: RunSettings(model: sonnet, effort: nil),
            runtime: "runtime-1",
            set: { runtime, key, value in
                await events.add(.set(runtime: runtime, key: key, value: value))
                guard runtime == "runtime-2" else {
                    throw GatewayRPCError(code: 4001, message: "session not found")
                }
                return .object(["applied": .bool(true)])
            },
            reattach: {
                await events.add(.reattach)
                return .init(runtime: "runtime-2", applied: RunSettings(model: sonnet, effort: nil))
            }
        )
        #expect(outcome.runtime == "runtime-2")
        #expect(outcome.modelApplied)
        #expect(outcome.effortApplied)
        #expect(outcome.applied == RunSettings(model: gpt, effort: .high))
        #expect(await events.events == [
            .set(runtime: "runtime-1", key: "model", value: gptValue),
            .reattach,
            .set(runtime: "runtime-2", key: "model", value: gptValue),
            .set(runtime: "runtime-2", key: "reasoning", value: "high"),
        ])
    }

    @Test func aResumedSessionThatAlreadyRunsThePickIsNotSetTwice() async {
        let events = Events()
        let outcome = await RunSettingsApply.run(
            wanted: RunSettings(model: gpt, effort: nil),
            applied: RunSettings(model: sonnet, effort: nil),
            runtime: "runtime-1",
            set: { runtime, key, value in
                await events.add(.set(runtime: runtime, key: key, value: value))
                throw GatewayRPCError(code: 4001, message: "session not found")
            },
            reattach: {
                await events.add(.reattach)
                // Another device's switch landed before the runtime went: the resumed session runs it.
                return .init(runtime: "runtime-2", applied: RunSettings(model: gpt, effort: nil))
            }
        )
        #expect(outcome.runtime == "runtime-2")
        #expect(outcome.modelApplied)
        #expect(outcome.applied?.model == gpt)
        #expect(await events.events == [
            .set(runtime: "runtime-1", key: "model", value: gptValue),
            .reattach,
        ])
    }

    @Test func aResumeThatReportsAnotherPickFollowsIt() async {
        let events = Events()
        let gemini = ModelSelection(provider: "openrouter", model: "google/gemini-3-pro")
        let outcome = await RunSettingsApply.run(
            wanted: RunSettings(model: gpt, effort: nil),
            applied: RunSettings(model: sonnet, effort: nil),
            runtime: "runtime-1",
            set: { runtime, key, value in
                await events.add(.set(runtime: runtime, key: key, value: value))
                throw GatewayRPCError(code: 4001, message: "session not found")
            },
            reattach: {
                await events.add(.reattach)
                // Opening the resumed session took another device's pick: that's what the chat wants now.
                return .init(
                    runtime: "runtime-2", applied: RunSettings(model: gemini, effort: nil),
                    wanted: RunSettings(model: gemini, effort: nil)
                )
            }
        )
        #expect(outcome.runtime == "runtime-2")
        #expect(outcome.modelApplied)
        #expect(outcome.applied?.model == gemini)
        #expect(await events.events == [
            .set(runtime: "runtime-1", key: "model", value: gptValue),
            .reattach,
        ])
    }

    @Test func aFailedEffortIsNotRecordedAndDoesNotHoldTheMessage() async {
        let events = Events()
        let outcome = await RunSettingsApply.run(
            wanted: RunSettings(model: sonnet, effort: .high),
            applied: RunSettings(model: sonnet, effort: .low),
            runtime: "runtime-1",
            set: { runtime, key, value in
                await events.add(.set(runtime: runtime, key: key, value: value))
                throw GatewayRPCError(code: 5001, message: "config write failed")
            },
            reattach: {
                await events.add(.reattach)
                return .init(runtime: "runtime-2", applied: RunSettings(model: sonnet, effort: nil))
            }
        )
        // The model is the one wanted, so the message runs on it; only the effort stays behind.
        #expect(outcome.modelApplied)
        #expect(!outcome.effortApplied)
        #expect(outcome.applied == RunSettings(model: sonnet, effort: .low))
        #expect(outcome.notice == nil)
        #expect(await events.events == [.set(runtime: "runtime-1", key: "reasoning", value: "high")])
    }

    @Test func aChatOnTheGatewaysDefaultSetsNoModel() async {
        let events = Events()
        // No pick from this device: the session's reported model is not a pick that could fail.
        let outcome = await RunSettingsApply.run(
            wanted: RunSettings(model: nil, effort: nil),
            applied: RunSettings(model: sonnet, effort: nil),
            runtime: "runtime-1",
            set: { runtime, key, value in
                await events.add(.set(runtime: runtime, key: key, value: value))
                return .object(["applied": .bool(true)])
            },
            reattach: {
                await events.add(.reattach)
                return .init(runtime: "runtime-2", applied: RunSettings(model: sonnet, effort: nil))
            }
        )
        #expect(outcome.modelApplied)
        #expect(outcome.applied?.model == sonnet)
        #expect(outcome.notice == nil)
        #expect(await events.events.isEmpty)
    }

    @Test func nothingChangedMakesNoCalls() async {
        let events = Events()
        let outcome = await RunSettingsApply.run(
            wanted: RunSettings(model: gpt, effort: .high),
            applied: RunSettings(model: gpt, effort: .high),
            runtime: "runtime-1",
            set: { runtime, key, value in
                await events.add(.set(runtime: runtime, key: key, value: value))
                return .object(["applied": .bool(true)])
            },
            reattach: {
                await events.add(.reattach)
                return .init(runtime: "runtime-2", applied: nil)
            }
        )
        #expect(outcome.runtime == "runtime-1")
        #expect(outcome.modelApplied)
        #expect(outcome.effortApplied)
        #expect(outcome.applied == RunSettings(model: gpt, effort: .high))
        #expect(await events.events.isEmpty)
    }
}
