import Foundation
import Testing
@testable import HermesKit

/// The error envelopes the gateways actually send: the API server's OpenAI-shaped `error`
/// object, FastAPI's `detail` (a token, a sentence, or a validation list), and a plain 404.
@Suite("Hermes error envelopes")
struct HermesErrorTests {
    private func mapped(status: Int, body: String, contentType: String = "application/json") -> HermesError {
        HermesError.from(status: status, body: Data(body.utf8), contentType: contentType)
    }

    private func server(_ error: HermesError) -> (Int, String?, String?) {
        if case let .server(status, code, message) = error { return (status, code, message) }
        Issue.record("not a server error: \(error)")
        return (-1, nil, nil)
    }

    /// `{"detail": "revision_conflict"}` — the fenced-write conflict: the token is the code.
    @Test func aDetailTokenIsTheCode() {
        let mapped = mapped(status: 409, body: #"{"detail":"revision_conflict"}"#)
        #expect(server(mapped) == (409, "revision_conflict", "revision_conflict"))
    }

    /// `{"detail": "client_upgrade_required: …"}` — a sentence: the token before the colon is
    /// the code, the whole sentence the message (the dialog shows Hermes' words, not a generic one).
    @Test func aSentenceDetailKeepsHermesWords() {
        let sentence = "client_upgrade_required: this app is out of sync (different versions) with the Hermes backend; update the app to edit sessions"
        let mapped = mapped(status: 409, body: #"{"detail":"\#(sentence)"}"#)
        let parts = server(mapped)
        #expect(parts.0 == 409)
        #expect(parts.1 == "client_upgrade_required")
        #expect(parts.2 == sentence)
    }

    /// A pydantic validation refusal (a bad `expected_revision`): the first problem's words.
    @Test func aValidationListYieldsTheFirstProblem() {
        let mapped = mapped(
            status: 422,
            body: #"{"detail":[{"type":"int_parsing","loc":["body","expected_revision"],"msg":"Input should be a valid integer"}]}"#)
        #expect(server(mapped).1 == "int_parsing")
        #expect(server(mapped).2 == "Input should be a valid integer")
    }

    /// The API server's OpenAI-shaped envelope still parses as before: `error.code`, `error.message`.
    @Test func theOpenAIErrorEnvelopeIsUntouched() {
        let mapped = mapped(
            status: 409,
            body: #"{"error":{"message":"Session was deleted; its id cannot be reused: abc","type":"invalid_request_error","code":"session_deleted"}}"#)
        #expect(server(mapped) == (409, "session_deleted", "Session was deleted; its id cannot be reused: abc"))
    }

    /// A route the gateway doesn't have (the pre-fence `mutation-snapshot`, the API server's
    /// plain-text 404): a `.notFound` the fenced write falls back on.
    @Test func aPlainText404IsNotFound() {
        let mapped = mapped(status: 404, body: "Not Found", contentType: "text/html")
        #expect(mapped == HermesError.notFound(message: "Not Found"))
    }

    /// A FastAPI 404 (a JSON `detail`) is a `.notFound` too.
    @Test func aJSON404IsNotFound() {
        let mapped = mapped(status: 404, body: #"{"detail":"No such API endpoint: /api/sessions/x/mutation-snapshot"}"#)
        #expect(mapped == HermesError.notFound(
            message: "No such API endpoint: /api/sessions/x/mutation-snapshot"))
    }
}
