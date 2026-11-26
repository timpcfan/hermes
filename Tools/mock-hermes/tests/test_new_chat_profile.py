"""Exercise the app's actual create transition, without building its UI target."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[3]


def declaration(source, signature):
    start = source.index(signature)
    cursor = source.index("{", start) + 1
    depth = 1
    while depth:
        char = source[cursor]
        depth += (char == "{") - (char == "}")
        cursor += 1
    return source[start:cursor]


class NewChatProfileTests(unittest.TestCase):
    def test_creation_keeps_the_requested_profile(self):
        source = (ROOT / "App/Model/ConversationModel.swift").read_text()
        rows = (ROOT / "Packages/HermesKit/Sources/HermesKit/Inbox/ProfileRows.swift").read_text()
        members = "\n".join(declaration(source, signature) for signature in [
            "    private var gatewayProfile: String? {",
            "    private func ensureChatRuntime() async throws -> String {",
        ])
        helpers = "\n".join(declaration(rows, signature) for signature in [
            "public enum ProfileRowKey {", "public enum ProfileRows {",
        ])
        program = STUBS + helpers + "\nfinal class Probe {\n" + PROBE + members + "\n}\n" + RUN
        with tempfile.TemporaryDirectory(prefix="profile-create-", dir=os.environ.get("TMPDIR")) as temp:
            path = Path(temp) / "main.swift"
            path.write_text(program)
            result = subprocess.run(["xcrun", "swift", str(path)], capture_output=True, text=True, timeout=90)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        scenarios = json.loads(result.stdout)
        self.assertEqual(len(scenarios), 8)
        for scenario in scenarios:
            with self.subTest(**scenario):
                self.assertEqual(scenario["requested"], scenario["chosen"])
                self.assertEqual(scenario["after"], scenario["chosen"])
                self.assertEqual(scenario["badge"], scenario["chosen"])
                self.assertEqual(scenario["row_key"], scenario["expected_key"])
                self.assertEqual(scenario["adopted_key"], scenario["expected_key"])
                self.assertEqual(scenario["create_count"], 1)
                self.assertEqual(scenario["resumed"], scenario["chosen"])


STUBS = r'''
import Foundation
public struct HermesSession {
    public var id: String
    public var profile: String?
    public var keyProfile: String?
    public var isDefaultProfile: Bool?
    public var stableID: String { ProfileRowKey.key(profile: keyProfile, lineageID: id) }
}
indirect enum JSONValue {
    case string(String), object([String: JSONValue])
    var stringValue: String? { if case .string(let value) = self { return value }; return nil }
    subscript(key: String) -> JSONValue? { if case .object(let value) = self { return value[key] }; return nil }
}
struct Configuration { var profileName: String? }
final class Workspace {
    var bot: Configuration
    let id = UUID()
    var adopted: HermesSession?
    init(_ home: String?) { bot = Configuration(profileName: home) }
    func adopt(_ probe: Probe, session: HermesSession) { adopted = session }
}
struct Waiting { var profile: String? }
struct Selection { var model: String; var provider: String }
struct Effort { var rawValue: String }
struct RunSettings { var model: Selection?; var effort: Effort? }
struct ModelFollow { func sent(_ model: Selection?) {} }
struct Inspector { func restore(chatKey: String, workspaceID: UUID) {} }
struct LiveWorkspace { init?(info: JSONValue?) { return nil } }
struct PreviewBridge { static let sessionSource = "desktop" }
enum GatewaySocket { enum Failure: Error { case notConnected } }
enum HermesError: Error { case invalidResponse(String) }
enum Event { case sessionChanged(String) }
final class Roster {
    var requested: String?
    var creates = 0
    var onCreate: (() -> Void)?
    func request(_ method: String, _ params: [String: JSONValue]) async throws -> [String: JSONValue] {
        creates += 1
        requested = params["profile"]?.stringValue
        onCreate?()
        return ["session_id": .string("runtime"), "stored_session_id": .string("stored")]
    }
    func attach(_ probe: Probe) {}
}
'''

PROBE = r'''
    var workspace: Workspace?
    var botName: String?
    var stableKey: String?
    var sessionID: String?
    var newChatProfile: String?
    var waitingChat: Waiting?
    var gatewayRoster: Roster?
    var model: Selection?
    var reasoningEffort: Effort?
    let newChatCreateKey = "local-test-only"
    var runtimeSessionID: String?
    var lastAppliedSeq: Int?
    var appliedRunSettings: RunSettings?
    var modelFollow = ModelFollow()
    var inspectorStore: Inspector?
    var liveWorkspace: LiveWorkspace?
    init(home: String?, picked: String?, waiting: Bool) {
        workspace = Workspace(home)
        gatewayRoster = Roster()
        if waiting { waitingChat = Waiting(profile: picked) }
        else { newChatProfile = picked }
    }
    var profile: String? { gatewayProfile }
    func create() async throws { _ = try await ensureChatRuntime() }
    func attachForSend() async throws -> String { gatewayProfile ?? "default" }
    func resume() async throws -> String { try await ensureChatRuntime() }
    func waitingChatCreated(_ stored: String) { waitingChat = nil }
    func sessionReported(_ info: JSONValue?) {}
    func apply(_ event: Event) {}
'''

RUN = r'''
Task {
    var results: [[String: Any]] = []
    let cases: [(String?, String?)] = [("work", "paimon"), ("paimon", "work"),
        ("paimon", "paimon"), ("work", "work"), (nil, "paimon"), ("work", "default")]
    for (index, pair) in cases.enumerated() {
        let (home, chosen) = pair
        let probe = Probe(home: home, picked: chosen, waiting: false)
        // The picker may change while session.create is awaiting its response.
        if index < 2 { probe.gatewayRoster!.onCreate = { probe.newChatProfile = home } }
        try await probe.create()
        let row = probe.workspace!.adopted!
        let expected = ProfileRowKey.key(storedID: "stored", profile: chosen, home: home)
        results.append(["home": home ?? "default", "chosen": chosen!,
            "requested": probe.gatewayRoster!.requested ?? "default", "after": probe.profile ?? "default",
            "badge": ProfileRows.profileName(of: row, home: home), "row_key": probe.stableKey!,
            "expected_key": expected, "adopted_key": row.stableID,
            "create_count": probe.gatewayRoster!.creates, "resumed": try await probe.resume()])
    }
    for (home, chosen) in [("work", "paimon"), ("paimon", "work")] {
        let probe = Probe(home: home, picked: chosen, waiting: true)
        try await probe.create()
        let row = probe.workspace!.adopted!
        results.append(["home": home, "chosen": chosen,
            "requested": probe.gatewayRoster!.requested!, "after": probe.profile!,
            "badge": ProfileRows.profileName(of: row, home: home), "row_key": probe.stableKey!,
            "expected_key": ProfileRowKey.key(storedID: "stored", profile: chosen, home: home),
            "adopted_key": row.stableID, "create_count": probe.gatewayRoster!.creates,
            "resumed": try await probe.resume()])
    }
    print(String(decoding: try JSONSerialization.data(withJSONObject: results), as: UTF8.self))
    exit(0)
}
dispatchMain()
'''


if __name__ == "__main__":
    unittest.main()
