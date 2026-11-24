"""The performance run's mock turns and chats (docs/development.md, Performance check): "tools N"
runs N tool calls before its reply in a Hermes chat and a Bot Chat, "essay" streams its long reply
in both, "busy" keeps its 30 calls, and `--long-chat-turns` with `--long-chat-rich` seed the long
chat a scroll back reads.

    python3 -I -m unittest discover -s Tools/mock-hermes/tests -p test_perf_turns.py
"""

import importlib.util
import os
import time
import unittest

from test_sending import MockCase

HERE = os.path.dirname(os.path.abspath(__file__))


class ToolTurns(MockCase):
    def turn(self, text, seconds=60, bot=False):
        """Sends `text` in a new chat (a Bot Chat with `bot`): the tool calls it made, in order, and
        the reply."""
        ws, sid, _ = self.open_chat(**({"title": "Bot Chat"} if bot else {}))
        self.assertIn("result", self.submit(ws, sid, text))
        starts, deadline = [], time.time() + seconds
        while time.time() < deadline:
            message = ws.recv()
            self.assertIsNotNone(message, "the socket closed mid-turn")
            if not isinstance(message, dict) or message.get("method") != "event":
                continue
            kind, payload = message["params"].get("type"), message["params"].get("payload") or {}
            if kind == "tool.start":
                starts.append(payload["name"])
            if kind == "message.complete":
                return starts, payload.get("text") or ""
        self.fail(f"{text!r} didn't finish in {seconds} s")

    def test_tools_n_runs_that_many_calls_then_answers(self):
        for bot in (False, True):
            starts, reply = self.turn("tools 12 please", bot=bot)
            self.assertEqual(len(starts), 12, f"bot={bot}")
            self.assertEqual(set(starts), {"terminal", "read_file", "search_files"})
            self.assertIn("All **12 checks** are done", reply)

    def test_tools_n_is_capped(self):
        starts, _ = self.turn("tools 0")
        self.assertEqual(len(starts), 1)

    def test_essay_streams_its_long_reply_in_both(self):
        for bot in (False, True):
            starts, reply = self.turn("essay please", bot=bot)
            self.assertEqual(starts, [], f"bot={bot}")
            self.assertIn("moving the app to Swift 6", reply)

    def test_busy_keeps_its_thirty_calls_in_a_bot_chat(self):
        starts, reply = self.turn("busy morning", bot=True)
        self.assertEqual(len(starts), 30)
        self.assertIn("30 hosts", reply)


class LongChat(unittest.TestCase):
    def gateway(self):
        spec = importlib.util.spec_from_file_location("perf_gateway", os.path.join(os.path.dirname(HERE), "server.py"))
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def replies(self, gateway):
        return [m["content"] for m in gateway.MESSAGES["long_history"] if m["role"] == "assistant" and m["content"]]

    def test_the_default_long_chat_is_unchanged(self):
        gateway = self.gateway()
        gateway.seed_long_chat()
        replies = self.replies(gateway)
        self.assertEqual(len(replies), 60)
        self.assertTrue(all("```" not in reply and "##" not in reply for reply in replies))

    def test_a_longer_rich_chat_has_headings_code_and_tables(self):
        gateway = self.gateway()
        gateway.seed_long_chat(300, rich=True)
        replies = self.replies(gateway)
        self.assertEqual(len(replies), 300)
        self.assertTrue(all(reply.startswith("## Node") for reply in replies))
        self.assertTrue(any("```bash" in reply for reply in replies))
        self.assertTrue(any("|---|" in reply for reply in replies))


if __name__ == "__main__":
    unittest.main()
