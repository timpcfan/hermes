"""The performance check's reading and grading (`matrix/perf_run.py`, docs/development.md,
Performance check): spans parsed from the frame log, windows between marks added up, invariants
kept by every run, and B compared with A by medians, past both a share and a floor.

    python3 -I -m unittest discover -s Tools/mock-hermes/tests -p test_perf_run.py
"""

import importlib.util
import os
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("perf_run", os.path.join(os.path.dirname(HERE), "matrix", "perf_run.py"))
perf = importlib.util.module_from_spec(spec)
spec.loader.exec_module(perf)


def span(start, end, wall=1000.0, cpu=100.0, frames=60, over=0, missed=0, longest=16.7, scroll=None, extra=""):
    line = (f"FRAMESPAN wall_ms={wall} cpu_ms={cpu} cpu_pct={100 * cpu / wall:.2f} frames={frames} over_budget={over} "
            f"over_budget_pct=0.00 missed={missed} dropped_pct=0.00 longest_ms={longest} refresh_ms=16.67 "
            f'from="{start}" to="{end}"{extra}')
    if scroll:
        line += "\nSCROLLSPAN " + " ".join(f"{k}={v}" for k, v in scroll.items())
    return line


STREAM_LOG = "\n".join([
    "FRAMELOG   1200.0ms launch: first frame (main cpu since last mark 0.0ms, in all 300.0ms)",
    span("launch: first frame", "chat showing", wall=900, cpu=700, frames=8, over=7, missed=40, longest=300.3),
    span("chat showing", "send-here: sending", wall=11000, cpu=200, frames=660),
    "FRAMELOG  13000.0ms busy frame: main cpu 9.1ms (wall 16.7ms)",
    span("send-here: sending", "send: landing begins", wall=30, cpu=25, frames=0),
    span("send: landing begins", "send: glide starts", wall=240, cpu=80, frames=2, over=2, missed=16, longest=283.2,
         scroll={"samples": 2, "moved_pt": 3141.0, "largest_step_pt": 2386.0, "teleports": 0, "checked": 0,
                 "largest_drift_pt": 0.0, "from_end_pt": 0.0}),
    span("send: glide starts", "reply ended", wall=11800, cpu=1780, frames=696, over=1, missed=13, longest=41.3,
         scroll={"samples": 696, "moved_pt": 12.7, "largest_step_pt": 1.7, "teleports": 0, "checked": 663,
                 "largest_drift_pt": 0.03, "from_end_pt": 1917.0}),
    span("reply ended", "reply settled", wall=2000, cpu=240, frames=120, over=2, missed=6, longest=86.6,
         scroll={"samples": 120, "moved_pt": 0.0, "largest_step_pt": 0.0, "teleports": 0, "checked": 120,
                 "largest_drift_pt": 0.0, "from_end_pt": 1923.0}),
])


class Reading(unittest.TestCase):
    def test_spans_carry_their_marks_numbers_and_scroll_line(self):
        spans = perf.parse_spans(STREAM_LOG)
        self.assertEqual(len(spans), 6)
        self.assertEqual((spans[0]["from"], spans[0]["to"]), ("launch: first frame", "chat showing"))
        self.assertEqual(spans[0]["missed"], 40)
        self.assertNotIn("scroll", spans[0])
        self.assertEqual(spans[4]["scroll"]["checked"], 663)

    def test_a_window_adds_up_the_spans_between_its_marks(self):
        stream = perf.measure(STREAM_LOG, "stream")["turn"]
        self.assertEqual(stream["spans"], 3)
        self.assertEqual(stream["wall_ms"], 12070.0)
        self.assertEqual(stream["cpu_ms"], 1885.0)
        self.assertEqual(stream["cpu_pct"], round(100 * 1885 / 12070, 2))
        self.assertEqual((stream["frames"], stream["over_budget"], stream["missed"]), (698, 3, 29))
        self.assertEqual(stream["longest_ms"], 283.2)
        # The landing's jump to the end isn't held, so it isn't a teleport.
        self.assertEqual(stream["teleports"], 0)
        self.assertEqual(stream["largest_step_pt"], 2386.0)
        self.assertEqual(stream["from_end_pt"], 1917.0)

    def test_the_stream_starts_with_the_glide_and_settled_reads_the_end(self):
        measured = perf.measure(STREAM_LOG, "stream")
        self.assertEqual(measured["stream"]["spans"], 1)
        self.assertEqual(measured["stream"]["largest_drift_pt"], 0.03)
        self.assertEqual(measured["settled"]["from_end_pt"], 1923.0)

    def test_a_window_the_log_lacks_is_none(self):
        self.assertIsNone(perf.measure(span("a", "b"), "stream")["turn"])

    def test_every_open_adds_up(self):
        log = "\n".join([
            span("cycle: open chat:api_1760_welcome", "cycle: settled chat:api_1760_welcome", cpu=50),
            span("cycle: settled chat:api_1760_welcome", "cycle: open chat:long_history", cpu=5),
            span("cycle: open chat:long_history", "selection changed", cpu=200, longest=90),
            span("selection changed", "cycle: settled chat:long_history", cpu=100),
            span("cycle: settled chat:long_history", "cycle: open chat:api_1760_welcome", cpu=5),
            span("cycle: open chat:long_history", "cycle: settled chat:long_history", cpu=150, longest=40),
        ])
        opened = perf.measure(log, "open")["open"]
        self.assertEqual(opened["runs"], 2)
        self.assertEqual(opened["cpu_ms"], 450)
        self.assertEqual(opened["cpu_ms_each"], 225)
        self.assertEqual(opened["longest_ms"], 90)

    def test_a_covered_mac_window_is_flagged(self):
        log = "\n".join([span("send-here: sending", "reply ended", extra=" window=covered")])
        self.assertTrue(perf.measure(log, {"windows": {"w": ("send-here", "reply ended")}})["w"]["covered"])

    def test_instructions_add_up_when_every_span_has_them(self):
        log = "\n".join([
            span("cycle: open chat:long_history", "selection changed", extra=" instr_m=900.5"),
            span("selection changed", "cycle: settled chat:long_history", extra=" instr_m=100.0"),
            span("cycle: settled chat:long_history", "cycle: open chat:long_history", extra=" instr_m=50.0"),
            span("cycle: open chat:long_history", "cycle: settled chat:long_history", extra=" instr_m=1000.0"),
        ])
        opened = perf.measure(log, "open")["open"]
        self.assertEqual((opened["instr_m"], opened["instr_m_each"]), (2000.5, 1000.2))
        # A build whose frame log doesn't count them reads none, rather than a part.
        self.assertNotIn("instr_m", perf.measure(span("send: glide starts", "reply ended"), "stream")["stream"])

    def test_a_sheet_over_the_chat_is_flagged(self):
        log = "\n".join([span("send: glide starts", "reply ended", extra=" sheet=shown"),
                         span("reply ended", "reply settled")])
        measured = perf.measure(log, "stream")
        self.assertTrue(measured["stream"]["sheet"])
        self.assertNotIn("sheet", measured["settled"])

    def test_a_scroll_runs_long_steps_add_up_apart_from_its_jumps(self):
        log = "\n".join([
            span("scroll 1: up from the end", "scroll 1: top", longest=150.0,
                 scroll={"samples": 900, "moved_pt": 60000.0, "largest_step_pt": 450.0, "teleports": 0, "long_steps": 3,
                         "checked": 900, "largest_drift_pt": 0.5}),
            span("scroll 1: top", "scroll 1: end", longest=140.0,
                 scroll={"samples": 900, "moved_pt": 60000.0, "largest_step_pt": 420.0, "teleports": 0, "long_steps": 2,
                         "checked": 900, "largest_drift_pt": 1.0}),
        ])
        scroll = perf.measure(log, "scroll")["scroll"]
        self.assertEqual((scroll["teleports"], scroll["long_steps"], scroll["largest_drift_pt"]), (0, 5, 1.0))
        # A log from before long steps were counted reads none.
        self.assertEqual(perf.measure(span("scroll 1: up from the end", "scroll 1: end", scroll={"teleports": 4}), "scroll")
                         ["scroll"]["long_steps"], 0)


class Grading(unittest.TestCase):
    def run_with(self, **numbers):
        return {"stream": dict(numbers)}

    def test_every_run_keeps_every_invariant(self):
        runs = [self.run_with(teleports=0, largest_drift_pt=0.4), self.run_with(teleports=1, largest_drift_pt=2.5)]
        failures = perf.grade_invariants(runs, {"stream.teleports": {"equals": 0}, "stream.largest_drift_pt": {"max": 2}})
        self.assertEqual(failures, ["stream.teleports: run 2: 1 (want 0)", "stream.largest_drift_pt: run 2: 2.5 > 2"])
        self.assertEqual(perf.grade_invariants([self.run_with()], {"stream.teleports": {"equals": 0}}),
                         ["stream.teleports: run 1: missing"])

    def test_a_regression_must_pass_both_its_share_and_its_floor(self):
        rule = {"stream.cpu_pct": {"share": 0.10, "floor": 1.0}}
        a = [self.run_with(cpu_pct=v) for v in (15.0, 15.4, 14.8)]
        # 15.0 -> 17.0: 13% and 2 points worse.
        rows, failures = perf.compare(a, [self.run_with(cpu_pct=v) for v in (17.0, 16.8, 17.3)], rule)
        self.assertEqual(rows[0]["result"], "FAIL")
        self.assertEqual(len(failures), 1)
        # 15.0 -> 16.2: 8%, within the share.
        rows, failures = perf.compare(a, [self.run_with(cpu_pct=v) for v in (16.2, 16.0, 16.5)], rule)
        self.assertEqual((rows[0]["result"], failures), ("pass", []))
        # 2.0 -> 2.8: 40% worse, but under a point.
        small = [self.run_with(cpu_pct=v) for v in (2.0, 2.1, 1.9)]
        rows, failures = perf.compare(small, [self.run_with(cpu_pct=v) for v in (2.8, 2.7, 2.9)], rule)
        self.assertEqual((rows[0]["result"], failures), ("pass", []))

    def test_better_is_never_a_regression_and_spread_is_reported(self):
        rule = {"stream.longest_ms": {"share": 0.10, "floor": 17}}
        rows, failures = perf.compare([self.run_with(longest_ms=v) for v in (100, 120, 110)],
                                      [self.run_with(longest_ms=v) for v in (40, 50, 45)], rule)
        self.assertEqual(failures, [])
        self.assertEqual((rows[0]["a"], rows[0]["b"], rows[0]["a_spread"]), (110, 45, round(20 / 110, 4)))

    def test_a_metric_missing_from_b_fails(self):
        rows, failures = perf.compare([self.run_with(cpu_pct=1)], [self.run_with()], {"stream.cpu_pct": {"share": 0.1}})
        self.assertEqual(rows[0]["result"], "missing")
        self.assertEqual(failures, ["stream.cpu_pct: missing"])

    def test_a_metric_only_b_reports_isnt_compared(self):
        # A is a build from before the metric was added.
        rows, failures = perf.compare([self.run_with()], [self.run_with(long_steps=3)], {"stream.long_steps": {"share": 1.0}})
        self.assertEqual((rows[0]["result"], failures), ("not in A", []))

    def test_long_steps_fail_only_well_past_the_noise(self):
        rule = {"stream.long_steps": {"share": 1.0, "floor": 10}}
        a = [self.run_with(long_steps=v) for v in (14, 7, 36)]
        # 14 -> 25: within twice as many.
        self.assertEqual(perf.compare(a, [self.run_with(long_steps=v) for v in (25, 20, 30)], rule)[1], [])
        # 14 -> 40: more than twice as many, and more than 10 more.
        self.assertEqual(perf.compare(a, [self.run_with(long_steps=v) for v in (40, 38, 45)], rule)[0][0]["result"], "FAIL")
        # None -> 9: under the floor.
        none = [self.run_with(long_steps=0)] * 3
        self.assertEqual(perf.compare(none, [self.run_with(long_steps=9)] * 3, rule)[1], [])

    def test_scenarios_wait_only_as_long_as_they_need(self):
        # The send comes 5 s after launch, the scroll run 6 s after, over a 120-turn chat.
        stream = perf.SCENARIOS["stream"]["flags"]
        self.assertEqual(stream[stream.index("-HERMES_SEND_HERE_AFTER") + 1], "5")
        scroll = perf.SCENARIOS["scroll"]
        self.assertEqual(scroll["flags"][scroll["flags"].index("-HERMES_SCROLL_AFTER") + 1], "6")
        self.assertEqual(scroll["turns"], 120)
        self.assertEqual(perf.WARMUP["windows"], {})
        opening = perf.SCENARIOS["open"]
        self.assertEqual((opening["flags"][opening["flags"].index("-HERMES_OPEN_CYCLE_ROUNDS") + 1], opening["count"]), ("2", 2))

    def test_outside_work_counts_everything_but_the_run_itself(self):
        before = {1: (10.0, "/usr/libexec/logd"), 2: (5.0, "/Applications/Other.app/Contents/MacOS/Other"),
                  3: (1.0, "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer"), 4: (0.0, "Hermes")}
        after = {1: (10.5, "/usr/libexec/logd"), 2: (9.0, "/Applications/Other.app/Contents/MacOS/Other"),
                 3: (6.0, "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer"), 4: (8.0, "Hermes"),
                 5: (1.5, "/Users/me/Library/Developer/CoreSimulator/Devices/X/data/Hermes Dev"), 6: (0.5, "/usr/bin/yes")}
        # logd 0.5 + Other 4 + a new process 0.5 over 10 s; the window server, the simulator and
        # the app (pid 4) are the run's own.
        self.assertEqual(perf.outside_cores(before, after, 10.0, {4}), 0.5)
        self.assertEqual(perf.outside_work(before, after, 10.0, {4})[1], [[0.4, "Other"], [0.05, "yes"], [0.05, "logd"]])

    def test_the_builds_alternate(self):
        self.assertEqual(perf.order(3), ["a", "b", "b", "a", "a", "b"])
        self.assertEqual(perf.order(4).count("a"), 4)

    def test_the_budgets_name_only_scenarios_and_windows_that_exist(self):
        import json
        with open(os.path.join(os.path.dirname(HERE), "matrix", "perf_budgets.json")) as handle:
            budgets = json.load(handle)
        for platform, scenarios in budgets["platforms"].items():
            for name, rules in scenarios.items():
                self.assertIn(name, perf.SCENARIOS, platform)
                paths = list(rules.get("invariants", {})) + rules.get("regression", []) + rules.get("report", [])
                for path in paths:
                    self.assertIn(path.partition(".")[0], perf.SCENARIOS[name]["windows"], f"{platform} {name} {path}")
                for path in rules.get("regression", []):
                    self.assertIn(path.partition(".")[2], budgets["regression"], f"{platform} {name} {path}")


if __name__ == "__main__":
    unittest.main()
