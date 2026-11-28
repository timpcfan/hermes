"""The session delete route's revision fence, shaped like Hermes' (`web_routers/sessions.py`):
the fence rides the URL's query (the delete route reads it there, the edit route the body),
a plain delete is refused on a fenced mock, and a pre-fence (`--plain-edits`) mock takes the
plain delete.

    python3 -I -m unittest discover -s Tools/mock-hermes/tests -p test_session_delete.py
"""

import subprocess
import sys
import unittest

from test_sending import BACKEND, KEY, MockCase, TOKEN, wait_for


class FencedDelete(MockCase):
    """The default mock, like Hermes from 2026-10-16 on: fenced session writes."""

    def setUp(self):
        super().setUp()
        self.socket, self.runtime, self.stored = self.open_chat()

    def snapshot(self):
        status, body = self.call("GET", f"/api/sessions/{self.stored}/mutation-snapshot")
        self.assertEqual(status, 200)
        return body

    def delete(self, query):
        return self.call("DELETE", f"/api/sessions/{self.stored}{query}")

    def test_a_plain_delete_is_refused(self):
        status, body = self.delete("")
        self.assertEqual(status, 409)
        self.assertIn("client_upgrade_required", body["detail"])
        status, _ = self.call("GET", f"/api/sessions/{self.stored}")
        self.assertEqual(status, 200)  # the chat survived

    def test_a_partial_fence_is_refused(self):
        for query in ("?request_id=req_1", "?expected_revision=0"):
            status, body = self.call("DELETE", f"/api/sessions/{self.stored}{query}")
            self.assertEqual(status, 409)
            self.assertEqual(body["detail"], "mutation_identity_required")

    def test_a_stale_revision_conflicts(self):
        status, body = self.delete("?request_id=req_1&expected_revision=999")
        self.assertEqual(status, 409)
        self.assertEqual(body["detail"], "revision_conflict")

    def test_the_current_revision_deletes(self):
        snapshot = self.snapshot()
        query = f"?request_id=req_1&expected_revision={snapshot['runtime_revision']}"
        if snapshot.get("runtime_generation") is not None:
            query += f"&expected_generation={snapshot['runtime_generation']}"
        status, body = self.delete(query)
        self.assertEqual(status, 200)
        self.assertTrue(body["deleted"])
        status, _ = self.call("GET", f"/api/sessions/{self.stored}")
        self.assertEqual(status, 404)  # the row is gone
        self.assertEqual(self.snapshot()["exists"], False)


class PlainDelete(MockCase):
    """The mock's `--plain-edits`: Hermes before the fence takes the plain delete."""

    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        # The default mock is fenced; this class needs the pre-fence one (no snapshot route).
        cls.server.terminate()
        cls.server.wait(timeout=10)
        cls.server = subprocess.Popen(
            [sys.executable, "-I", BACKEND, "--port", str(cls.port), "--gateway-port", str(cls.gateway), "--token", TOKEN,
             "--quiet-world", "--push-relay", cls.relay, "--gateway-key", KEY, "--plain-edits"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        wait_for(f"http://127.0.0.1:{cls.port}/", cls.server)

    def test_no_snapshot_route_and_a_plain_delete(self):
        self.socket, self.runtime, self.stored = self.open_chat()
        status, body = self.call("GET", f"/api/sessions/{self.stored}/mutation-snapshot")
        self.assertEqual(status, 404)
        self.assertIn("No such API endpoint", body["detail"])
        status, body = self.call("DELETE", f"/api/sessions/{self.stored}")
        self.assertEqual(status, 200)
        self.assertTrue(body["deleted"])


if __name__ == "__main__":
    unittest.main()
