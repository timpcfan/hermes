"""M1 ablation driver for the Mac streaming check (BRIEF-MAC §2).

Reuses perf_run.py's Mac/Mock/measure machinery, but reproduces the heavy user's shape:
a long rich chat (300 turns) + hundreds of chats + a streaming reply + a running background
process chip + expanded steps + a large window. One build, one ablation variant per run
(`-HERMES_PERF_ABLATE`), interleaved so machine drift weighs on all variants alike.

    python3 -I mac_ablate.py --app <Hermes Dev.app> --out <dir> \
        --variants none,motion,timers,chat,sidebar,composer --rounds 2

Stdlib only. Run under `caffeinate -dimsu` with the whole-machine lock held; the screen must
be unlocked. Not part of the gate: no pass/fail, just numbers per variant.
"""

import argparse
import datetime
import json
import os
import statistics
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import perf_run as P  # noqa: E402

# The heavy shape: long rich chat, 300 ordinary chats beside it, steps expanded, a big window.
# --perf-process puts one watcher already running in the long chat, so the chip shows a single
# process (its 30 s clock) while the turn works and streams. "tools 130" is the heavy user's
# longest turn: ~26 s of tool steps (the 1 s step clock), then a rich reply streaming in.
MANY_CHATS = 300
BIG_WINDOW = "frame 1500 950"
SCENARIO = {
    "flags": P.OPEN_LONG + P.PROBE + P.send_here("tools 130 please")
    + ["-HERMES_EXPAND_STEPS", "turns", "-HERMES_MAC_DRIVE", f"wait 2; {BIG_WINDOW}; window"],
    "until": "reply settled", "timeout": 150,
    "windows": P.STREAM_WINDOWS,
}


class AblateMock(P.Mock):
    """perf_run's mock plus --many-chats and --perf-process: hundreds of chats in the sidebar,
    one running process in the measured chat."""

    def start(self, name, turns=None):
        for port in (P.BACKEND, P.GATEWAY):
            if subprocess.run(["lsof", "-nP", f"-iTCP:{port}", "-sTCP:LISTEN"], capture_output=True).stdout:
                raise SystemExit(f"port {port} is taken")
        self.log = open(os.path.join(self.out, f"{name}.mock.log"), "w")
        self.process = subprocess.Popen(
            [sys.executable, "-I", os.path.join(P.REPO, "Tools/mock-hermes/backend.py"), "--port", str(P.BACKEND),
             "--gateway-port", str(P.GATEWAY), "--gateway-key", P.KEY, "--push-relay", "none", "--app-plugins", "current",
             "--quiet-world", "--long-chat", "--long-chat-turns", str(turns or self.turns), "--long-chat-rich",
             "--many-chats", str(MANY_CHATS), "--perf-process"],
            stdout=self.log, stderr=subprocess.STDOUT)
        import urllib.error
        import urllib.request
        for _ in range(200):
            try:
                urllib.request.urlopen(f"http://127.0.0.1:{P.GATEWAY}/health", timeout=1)
                urllib.request.urlopen(f"http://127.0.0.1:{P.BACKEND}/", timeout=1)
                return
            except urllib.error.HTTPError:
                return
            except OSError:
                if self.process.poll() is not None:
                    break
                time.sleep(0.2)
        raise SystemExit("the mock didn't start")


def run_variant(device, mock, app, variant, out, tag, busy_limit):
    # `noprobe` is a driver-side ablation: the scroll probe's per-row geometry readers come off,
    # everything else stays. It measures what the instrument itself costs.
    base = [f for f in SCENARIO["flags"] if f not in P.PROBE] if variant == "noprobe" else SCENARIO["flags"]
    # `a+b` turns off two suspects at once; the flag itself takes commas.
    flags = base + (["-HERMES_PERF_ABLATE", variant.replace("+", ",")] if variant not in ("none", "noprobe") else [])
    spec = {**SCENARIO, "flags": flags}
    return P.run_once(device, mock, app, spec, out, tag, busy_limit=busy_limit)


def run_build(device, mock, app, out, tag, busy_limit):
    # A real build, no ablation flag: the M2 A/B compares two compiled cuts of the same shape.
    return P.run_once(device, mock, app, SCENARIO, out, tag, busy_limit=busy_limit)


def median(values):
    values = [v for v in values if v is not None]
    return round(statistics.median(values), 2) if values else None


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--app", required=True)
    parser.add_argument("--app-b", default=None,
                        help="a second real build; A/B them on the same shape (no ablation flags)")
    parser.add_argument("--out", required=True)
    parser.add_argument("--variants", default="none,motion,timers,chat,sidebar,composer")
    parser.add_argument("--rounds", type=int, default=2)
    parser.add_argument("--long-chat-turns", type=int, default=300)
    parser.add_argument("--no-warmup", action="store_true")
    args = parser.parse_args()
    args.out = os.path.abspath(args.out)
    os.makedirs(args.out, exist_ok=True)
    if P.screen_locked():
        raise SystemExit("the screen is locked: nothing would measure")
    variants = [v for v in args.variants.split(",") if v]
    device = P.Mac(args.out)
    mock = AblateMock(args.out, args.long_chat_turns)
    app = os.path.abspath(args.app)
    began = time.time()
    # A/B mode: two real builds, no ablation flags, A B B A … (perf_run.order) so drift weighs alike.
    ab = bool(args.app_b)
    if ab:
        app_b = os.path.abspath(args.app_b)
        report = {"started": datetime.datetime.now().isoformat(timespec="seconds"), "app": app, "app_b": app_b,
                  "mode": "ab", "rounds": args.rounds, "shape": {"many_chats": MANY_CHATS, "window": BIG_WINDOW},
                  "runs": {"a": [], "b": []}, "errors": []}
        order = [(side, r) for r, side in enumerate(P.order(args.rounds))]
    else:
        report = {"started": datetime.datetime.now().isoformat(timespec="seconds"), "app": app,
                  "variants": variants, "rounds": args.rounds, "shape": {"many_chats": MANY_CHATS, "window": BIG_WINDOW},
                  "runs": {v: [] for v in variants}, "errors": []}
        # Interleave: each round runs every variant once, rotating who goes first.
        order = []
        for r in range(args.rounds):
            order += [(v, r) for v in variants[r % len(variants):] + variants[:r % len(variants)]]
    try:
        if not args.no_warmup:
            print("warming up…", flush=True)
            P.run_once(device, mock, app, P.WARMUP, args.out, "warmup")
        for i, (key, r) in enumerate(order):
            run_app = app if not ab else (app if key == "a" else app_b)
            tag = f"{key}-{r + 1:02d}" if ab else f"{key}-{r + 1:02d}"
            load = P.load_load()
            for attempt in range(3):
                result = (run_build(device, mock, run_app, args.out, tag, busy_limit=1.0) if ab
                          else run_variant(device, mock, run_app, key, args.out, tag, busy_limit=1.0))
                if not result.get("busy") or attempt == 2:
                    break
                print(f"{tag}: {result['error']}; again in 30 s", flush=True)
                time.sleep(30)
            result["load"] = load
            if "error" in result:
                report["errors"].append(f"{tag}: {result['error']}")
                print(f"{tag}: ERROR {result['error']}", flush=True)
            else:
                report["runs"][key].append({**result["measured"], "load": load,
                                            "outside_cores": result["outside_cores"], "run": tag})
                brief = {w: {k: v for k, v in (m or {}).items() if k in ("cpu_pct", "instr_m", "over_budget_pct", "longest_ms")}
                         for w, m in result["measured"].items()}
                print(f"{tag}: outside {result['outside_cores']} cores {json.dumps(brief)}", flush=True)
    finally:
        device.stop()
        mock.stop()
        device.finish(False)
    # Medians per build/variant, and the change against the baseline (`a` for A/B, `none` otherwise).
    table = {}
    base_key = "a" if ab else "none"
    keys = ["a", "b"] if ab else variants
    base = report["runs"].get(base_key, [])
    for key in keys:
        runs = report["runs"][key]
        row = {}
        for window in SCENARIO["windows"]:
            for metric in ("cpu_pct", "instr_m", "over_budget_pct", "longest_ms"):
                values = [(m.get(window) or {}).get(metric) for m in runs]
                row[f"{window}.{metric}"] = median(values)
                if key != base_key and base:
                    b = median([(m.get(window) or {}).get(metric) for m in base])
                    v = row[f"{window}.{metric}"]
                    row[f"{window}.{metric}_vs_a_pct"] = round(100 * (v - b) / b, 1) if (v is not None and b) else None
        table[key] = row
    report["table"] = table
    report["minutes"] = round((time.time() - began) / 60, 1)
    out_name = "ab.json" if ab else "ablate.json"
    with open(os.path.join(args.out, out_name), "w") as handle:
        json.dump(report, handle, indent=2)
    print(f"done in {report['minutes']} min: {os.path.join(args.out, out_name)}", flush=True)
    print(json.dumps(table, indent=2), flush=True)


if __name__ == "__main__":
    main()