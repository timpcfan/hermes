"""The performance check (`docs/development.md`, Performance check): times streaming, scrolling and
opening a chat in Hermes Dev on the iPhone simulator or the Mac, against the mock, and fails on a
broken invariant or a regression.

    python3 -I perf_run.py --udid <sim> --app <Hermes Dev.app> --out <dir>                  # one build
    python3 -I perf_run.py --udid <sim> --app <A.app> --app-b <B.app> --out <dir>           # A against B
    python3 -I perf_run.py --udid <sim> --ref main --ref-b HEAD --out <dir>                 # build both
    python3 -I perf_run.py --mac --app <Hermes Dev.app> --out <dir> …

Each scenario launches the app with launch flags against a fresh mock, waits for its last mark, and
reads the frame log's spans (`FRAMESPAN`, `SCROLLSPAN`). Invariants are absolute (no jumps, the
chat held within 2 pt); regressions compare B with A run on the same machine, interleaved
(A B B A A B …), by the median of each. `perf_budgets.json` holds both. The report is
`<out>/report.json`; the exit status is 0 for PASS, 1 for FAIL, 2 when a run couldn't measure (a
sheet over the chat, a covered Mac window, a mark that never came).

Stdlib only. Starts its own mock (21219/21742, or `HERMES_PERF_PORTS=<backend>,<gateway>`) for each
run and stops it after.
"""

import argparse
import datetime
import json
import os
import re
import shutil
import signal
import statistics
import subprocess
import sys
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
BACKEND, GATEWAY = (int(p) for p in (os.environ.get("HERMES_PERF_PORTS") or "21219,21742").split(","))
KEY = "dev-key-0123456789abcdef"
BUNDLE = "co.caffeinatedcode.hermes.dev"
# The Mac copy runs under its own bundle id and home, so it never meets the Hermes Dev in use.
MAC_BUNDLE = "co.caffeinatedcode.hermes.dev.perf"
BASE_FLAGS = ["-HERMES_PASTEBOARD", "none", "-HERMES_WHATS_NEW", "NO", "-HERMES_TIPS", "hide", "-push.primeDeclines", "2",
              "-HERMES_BOOTSTRAP_URL", f"http://127.0.0.1:{GATEWAY}", "-HERMES_BOOTSTRAP_KEY", KEY,
              "-HERMES_BOOTSTRAP_BACKEND", f"http://127.0.0.1:{BACKEND}", "-HERMES_FRAME_LOG", "YES"]
LONG_CHAT = "long_history"
SHORT_CHAT = "api_1760_welcome"

# ------------------------------------------------------------------ scenarios
# What each launches with, the mark it ends on (and how many of them), and the windows it reads:
# each a run of spans from the first span starting at `from` to the first after it ending at `to`
# (every such run with `every`). Marks match by prefix.

PROBE = ["-HERMES_SCROLL_PROBE", "YES"]
OPEN_LONG = ["-HERMES_RESTORE", f"session:{LONG_CHAT}"]


def send_here(text):
    # The chat has shown and settled about a second after launch: 5 s leaves it idle a few more.
    return ["-HERMES_SEND_HERE", text, "-HERMES_SEND_HERE_ROUNDS", "1", "-HERMES_SEND_HERE_AFTER", "5"]


# `turn` is the whole turn from the send; `stream` starts once the sent message glides up, so it is
# the reply streaming in with the chat held; `settled` is the two seconds after the reply ends.
STREAM_WINDOWS = {"turn": ("send-here: sending", "reply ended"), "stream": ("send: glide starts", "reply ended"),
                  "settled": ("reply ended", "reply settled")}
SCENARIOS = {
    # A long reply streamed into the long chat: the page turns, then nothing should move.
    "stream": {"flags": OPEN_LONG + PROBE + send_here("essay please"), "until": "reply settled", "timeout": 120,
               "windows": STREAM_WINDOWS},
    # The same with Keep chat at bottom when sending: the chat follows the reply to its end.
    "stream_follow": {"flags": OPEN_LONG + PROBE + send_here("essay please") + ["-keepChatAtBottom", "YES"],
                      "until": "reply settled", "timeout": 120,
                      "windows": {"turn": STREAM_WINDOWS["turn"], "settled": STREAM_WINDOWS["settled"]}},
    # Tool-heavy turns: a heavy user's 90th percentile and their longest.
    "tools40": {"flags": OPEN_LONG + PROBE + send_here("tools 40 please"), "until": "reply settled", "timeout": 150,
                "windows": STREAM_WINDOWS},
    "tools130": {"flags": OPEN_LONG + PROBE + send_here("tools 130 please"), "until": "reply settled", "timeout": 240,
                 "windows": STREAM_WINDOWS},
    # Reading a long chat back to its first message and down again, a step a frame. 120 turns are
    # a dozen pages each way, and take a third of the time 300 did at the same cost a frame.
    "scroll": {"flags": OPEN_LONG + PROBE + ["-HERMES_SCROLL_RUN", "1", "-HERMES_SCROLL_SPEED", "3000", "-HERMES_SCROLL_AFTER", "6"],
               "turns": 120, "until": "scroll 1: end", "timeout": 240,
               "windows": {"scroll": ("scroll 1: up from the end", "scroll 1: end"),
                           "up": ("scroll 1: up from the end", "scroll 1: top"), "down": ("scroll 1: top", "scroll 1: end")}},
    # Opening the long chat from a short one, twice (each open's CPU varies by a few percent).
    "open": {"flags": ["-HERMES_OPEN_CYCLE", f"chat:{SHORT_CHAT},chat:{LONG_CHAT}", "-HERMES_OPEN_CYCLE_ROUNDS", "2"],
             "until": f"cycle: settled chat:{LONG_CHAT}", "count": 2, "timeout": 120,
             "windows": {"open": (f"cycle: open chat:{LONG_CHAT}", f"cycle: settled chat:{LONG_CHAT}")}, "every": True},
}
DEFAULT_SCENARIOS = ["stream", "stream_follow", "tools40", "tools130", "scroll", "open"]
# Each build's unmeasured first launch: loading a new binary is slow once, so it's paid here.
WARMUP = {"flags": OPEN_LONG, "until": "chat showing", "timeout": 60, "windows": {}}

# ------------------------------------------------------------------ the log


FIELD = re.compile(r'(\w+)=("([^"]*)"|\S+)')


def fields(line):
    out = {}
    for name, raw, quoted in FIELD.findall(line):
        if raw.startswith('"'):
            out[name] = quoted
        else:
            try:
                out[name] = int(raw) if re.fullmatch(r"-?\d+", raw) else float(raw)
            except ValueError:
                out[name] = raw
    return out


def parse_spans(text):
    """The frame log's spans in order: each `FRAMESPAN` line's fields, with the `SCROLLSPAN` line
    right after it (the probe's, when on) under `scroll`."""
    spans = []
    for line in text.splitlines():
        if line.startswith("FRAMESPAN "):
            spans.append(fields(line))
        elif line.startswith("SCROLLSPAN ") and spans and "scroll" not in spans[-1]:
            spans[-1]["scroll"] = fields(line)
    return spans


def windows(spans, start, end, every=False):
    """Runs of spans from one starting at the mark `start` to the first after it ending at `end`."""
    found, i = [], 0
    while i < len(spans):
        if spans[i].get("from", "").startswith(start):
            for j in range(i, len(spans)):
                if spans[j].get("to", "").startswith(end):
                    found.append(spans[i:j + 1])
                    i = j
                    break
            else:
                break
            if not every:
                break
        i += 1
    return found


def aggregate(runs):
    """One set of numbers over every span in `runs` (lists of spans): times and counts add up,
    the longest frame and the biggest jump are the largest, the chat's end is the last read."""
    spans = [span for run in runs for span in run]
    if not spans:
        return None
    total = lambda key: sum(span.get(key, 0) for span in spans)
    wall, cpu, frames, over, missed = total("wall_ms"), total("cpu_ms"), total("frames"), total("over_budget"), total("missed")
    refresh = [span["refresh_ms"] for span in spans if span.get("refresh_ms")]
    out = {
        "wall_ms": round(wall, 1), "cpu_ms": round(cpu, 1), "cpu_ms_each": round(cpu / len(runs), 1),
        "cpu_pct": round(100 * cpu / wall, 2) if wall else 0.0,
        "frames": frames, "over_budget": over, "missed": missed,
        "over_budget_pct": round(100 * over / frames, 2) if frames else 0.0,
        "dropped_pct": round(100 * missed / (frames + missed), 2) if frames + missed else 0.0,
        "longest_ms": max(span.get("longest_ms", 0) for span in spans),
        "refresh_ms": min(refresh) if refresh else None,
        "spans": len(spans), "runs": len(runs),
    }
    # Instructions the whole process ran (`instr_m`, millions): builds from before the frame log
    # printed them have none.
    if all("instr_m" in span for span in spans):
        out["instr_m"] = round(total("instr_m"), 1)
        out["instr_m_each"] = round(out["instr_m"] / len(runs), 1)
    if any(span.get("window") == "covered" for span in spans):
        out["covered"] = True
    if any(span.get("sheet") == "shown" for span in spans):
        out["sheet"] = True
    scrolls = [span["scroll"] for span in spans if "scroll" in span]
    if scrolls:
        out.update({
            "samples": sum(s.get("samples", 0) for s in scrolls),
            "moved_pt": round(sum(s.get("moved_pt", 0) for s in scrolls), 1),
            "largest_step_pt": max(s.get("largest_step_pt", 0) for s in scrolls),
            "teleports": sum(s.get("teleports", 0) for s in scrolls),
            "long_steps": sum(s.get("long_steps", 0) for s in scrolls),
            "checked": sum(s.get("checked", 0) for s in scrolls),
            "largest_drift_pt": max(s.get("largest_drift_pt", 0) for s in scrolls),
        })
        ends = [s["from_end_pt"] for s in scrolls if "from_end_pt" in s]
        if ends:
            out["from_end_pt"] = ends[-1]
    return out


def measure(text, scenario):
    """Each window's numbers from one run's log; None for a window the log doesn't hold."""
    spans = parse_spans(text)
    spec = SCENARIOS[scenario] if isinstance(scenario, str) else scenario
    return {name: aggregate(windows(spans, start, end, spec.get("every", False)))
            for name, (start, end) in spec["windows"].items()}

# ------------------------------------------------------------------ grading


def metric(measured, path):
    """`window.metric` out of one run's numbers."""
    window, _, name = path.partition(".")
    return (measured.get(window) or {}).get(name)


def check(value, rule):
    """None when `value` keeps `rule` ({max|min|equals}), else why not."""
    if value is None:
        return "missing"
    if "equals" in rule and value != rule["equals"]:
        return f"{value} (want {rule['equals']})"
    if "max" in rule and value > rule["max"]:
        return f"{value} > {rule['max']}"
    if "min" in rule and value < rule["min"]:
        return f"{value} < {rule['min']}"
    return None


def grade_invariants(runs, rules):
    """Every run must keep every invariant: one jump in one run is a jump."""
    failures = []
    for path, rule in rules.items():
        for index, measured in enumerate(runs):
            why = check(metric(measured, path), rule)
            if why:
                failures.append(f"{path}: run {index + 1}: {why}")
    return failures


def spread(values):
    """Median, and the range around it as a share of the median (the run-to-run noise)."""
    values = [v for v in values if v is not None]
    if not values:
        return None, None
    middle = statistics.median(values)
    return middle, (round((max(values) - min(values)) / middle, 4) if middle else 0.0)


def compare(runs_a, runs_b, rules):
    """B against A by each metric's median: a regression is worse by more than its share AND its
    floor (a share of a tiny number is noise). Higher is worse for every metric graded. A metric
    only B reports (A is a build from before it was added) isn't compared."""
    rows, failures = [], []
    for path, rule in rules.items():
        a, a_spread = spread([metric(m, path) for m in runs_a])
        b, b_spread = spread([metric(m, path) for m in runs_b])
        row = {"metric": path, "a": a, "b": b, "a_spread": a_spread, "b_spread": b_spread}
        if a is None and b is not None:
            row["result"] = "not in A"
        elif a is None or b is None:
            row["result"] = "missing"
            failures.append(f"{path}: missing")
        else:
            change = b - a
            row["change"] = round(change, 3)
            row["change_pct"] = round(100 * change / a, 2) if a else None
            worse = change > rule.get("floor", 0) and (a == 0 or change / a > rule["share"])
            row["result"] = "FAIL" if worse else "pass"
            if worse:
                failures.append(f"{path}: {a} -> {b} (+{row['change_pct']}%, over {int(rule['share'] * 100)}% and {rule.get('floor', 0)})")
        rows.append(row)
    return rows, failures


def order(rounds):
    """A B B A A B …: each build runs as often first as second, so a machine warming up or slowing
    down over the run weighs on both alike."""
    pattern = []
    for index in range(rounds):
        pattern += ["a", "b"] if index % 2 == 0 else ["b", "a"]
    return pattern

# ------------------------------------------------------------------ the machine


def cpu_seconds():
    """Every process's CPU time so far, by pid, with its command (`ps`)."""
    out = subprocess.run(["ps", "-A", "-o", "pid=,time=,comm="], capture_output=True, text=True).stdout
    seconds = {}
    for line in out.splitlines():
        parts = line.split(None, 2)
        if len(parts) < 3:
            continue
        total = 0.0
        try:
            for piece in parts[1].split(":"):
                total = total * 60 + float(piece)
            seconds[int(parts[0])] = (total, parts[2])
        except ValueError:
            continue
    return seconds


# What the run itself keeps busy: the simulator's processes and the window server draw the app.
OWN_WORK = ("CoreSimulator", "WindowServer")


def outside_work(before, after, wall, ours):
    """How many cores everything else on the machine kept busy, on average, between two
    `cpu_seconds()`, and the busiest of it: other work lowers the main thread's CPU time for the
    same frames (the cores clock up), so a run beside it isn't comparable."""
    busy = []
    for pid, (seconds, command) in after.items():
        if pid in ours or any(part in command for part in OWN_WORK) or command.endswith("/ps") or command == "ps":
            continue
        used = seconds - before.get(pid, (0.0, ""))[0]
        if used > 0:
            busy.append((used, os.path.basename(command)))
    if wall <= 0:
        return 0.0, []
    busy.sort(reverse=True)
    return round(sum(used for used, _ in busy) / wall, 2), [[round(used / wall, 2), name] for used, name in busy[:3]]


def outside_cores(before, after, wall, ours):
    return outside_work(before, after, wall, ours)[0]

# ------------------------------------------------------------------ the mock


class Mock:
    def __init__(self, out, turns):
        self.out, self.turns, self.process = out, turns, None

    def start(self, name, turns=None):
        for port in (BACKEND, GATEWAY):
            if subprocess.run(["lsof", "-nP", f"-iTCP:{port}", "-sTCP:LISTEN"], capture_output=True).stdout:
                raise SystemExit(f"port {port} is taken: set HERMES_PERF_PORTS=<backend>,<gateway>")
        self.log = open(os.path.join(self.out, f"{name}.mock.log"), "w")
        self.process = subprocess.Popen(
            [sys.executable, "-I", os.path.join(REPO, "Tools/mock-hermes/backend.py"), "--port", str(BACKEND),
             "--gateway-port", str(GATEWAY), "--gateway-key", KEY, "--push-relay", "none", "--app-plugins", "current",
             "--quiet-world",
             "--long-chat", "--long-chat-turns", str(turns or self.turns), "--long-chat-rich"],
            stdout=self.log, stderr=subprocess.STDOUT)
        for _ in range(150):
            try:
                urllib.request.urlopen(f"http://127.0.0.1:{GATEWAY}/health", timeout=1)
                urllib.request.urlopen(f"http://127.0.0.1:{BACKEND}/", timeout=1)
                return
            except urllib.error.HTTPError:
                return
            except OSError:
                if self.process.poll() is not None:
                    break
                time.sleep(0.2)
        raise SystemExit("the mock didn't start")

    def stop(self):
        if self.process and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.process.kill()
        self.process = None
        if getattr(self, "log", None):
            self.log.close()

# ------------------------------------------------------------------ the app


class Simulator:
    name = "ios-simulator"

    def __init__(self, udid):
        self.udid, self.pid = udid, None

    def sh(self, *command, check=False):
        return subprocess.run(command, capture_output=True, text=True, check=check)

    def describe(self):
        devices = json.loads(self.sh("xcrun", "simctl", "list", "devices", "-j").stdout or "{}").get("devices", {})
        for runtime, entries in devices.items():
            for device in entries:
                if device.get("udid") == self.udid:
                    return {"device": device.get("name"), "runtime": runtime.rsplit(".", 1)[-1], "state": device.get("state")}
        raise SystemExit(f"no simulator {self.udid}")

    def prepare(self, app):
        """A fresh install: no kept chats or settings from an earlier run."""
        self.sh("xcrun", "simctl", "terminate", self.udid, BUNDLE)
        self.sh("xcrun", "simctl", "uninstall", self.udid, BUNDLE)
        self.sh("xcrun", "simctl", "install", self.udid, app, check=True)

    def launch(self, app, flags, log):
        env = {**os.environ, "SIMCTL_CHILD_NSUnbufferedIO": "YES"}
        launched = subprocess.run(["xcrun", "simctl", "launch", "--terminate-running-process", f"--stdout={log}", f"--stderr={log}.err",
                                   self.udid, BUNDLE, *BASE_FLAGS, *flags], env=env, capture_output=True, text=True, check=True)
        # It answers "<bundle id>: <pid>".
        tail = launched.stdout.strip().rsplit(":", 1)[-1].strip()
        self.pid = int(tail) if tail.isdigit() else None

    def alive(self):
        return True

    def screenshot(self, path):
        self.sh("xcrun", "simctl", "io", self.udid, "screenshot", path)

    def stop(self):
        self.sh("xcrun", "simctl", "terminate", self.udid, BUNDLE)

    def finish(self, booted_here):
        if booted_here:
            self.sh("xcrun", "simctl", "shutdown", self.udid)


class Mac:
    """Runs a copy of the app under its own bundle id and an empty home of its own, started
    straight from its binary so its PID is known and only that process is ever stopped."""
    name = "mac"

    def __init__(self, out):
        self.out, self.process, self.copies = out, None, {}
        self.home = os.path.join(out, "mac-home")

    def describe(self):
        version = subprocess.run(["sw_vers", "-productVersion"], capture_output=True, text=True).stdout.strip()
        return {"device": "Mac", "runtime": f"macOS {version}"}

    def copy(self, app):
        if app not in self.copies:
            target = os.path.join(self.out, f"mac-app-{len(self.copies) + 1}", "Hermes Perf.app")
            shutil.rmtree(os.path.dirname(target), ignore_errors=True)
            os.makedirs(os.path.dirname(target))
            subprocess.run(["ditto", app, target], check=True)
            plist = os.path.join(target, "Contents/Info.plist")
            subprocess.run(["plutil", "-replace", "CFBundleIdentifier", "-string", MAC_BUNDLE, plist], check=True)
            subprocess.run(["codesign", "--force", "--deep", "--sign", "-", target], check=True, capture_output=True)
            self.copies[app] = target
        return self.copies[app]

    def prepare(self, app):
        self.copy(app)
        shutil.rmtree(self.home, ignore_errors=True)
        os.makedirs(self.home)
        subprocess.run(["defaults", "delete", MAC_BUNDLE], capture_output=True)

    def launch(self, app, flags, log):
        copy = self.copy(app)
        executable = os.path.join(copy, "Contents/MacOS", plist_value(copy, "CFBundleExecutable"))
        env = {k: v for k, v in os.environ.items() if k != "ELECTRON_RUN_AS_NODE"}
        env.update({"CFFIXED_USER_HOME": self.home, "NSUnbufferedIO": "YES"})
        self.output = open(log, "w")
        self.process = subprocess.Popen([executable, *BASE_FLAGS, *flags], stdout=self.output, stderr=subprocess.STDOUT, env=env)

    @property
    def pid(self):
        return self.process.pid if self.process else None

    def alive(self):
        return self.process is not None and self.process.poll() is None

    def screenshot(self, path):
        # The app's own windows, by their number (`screencapture -l`), so nothing else on the
        # screen is captured.
        script = ('ObjC.import("CoreGraphics"); const list = ObjC.castRefToObject($.CGWindowListCopyWindowInfo(1, 0));'
                  f'const ids = []; for (let i = 0; i < list.count; i++) {{ const w = list.objectAtIndex(i);'
                  f' if (w.objectForKey("kCGWindowOwnerPID").js === {self.process.pid} && w.objectForKey("kCGWindowLayer").js === 0)'
                  ' ids.push(w.objectForKey("kCGWindowNumber").js); } ids.join(",")')
        found = subprocess.run(["osascript", "-l", "JavaScript", "-e", script], capture_output=True, text=True).stdout.strip()
        if found:
            subprocess.run(["screencapture", "-x", "-o", f"-l{found.split(',')[0]}", path], capture_output=True)

    def finish(self, booted_here):
        # The copy's settings live under its own bundle id; nothing of them is kept.
        subprocess.run(["defaults", "delete", MAC_BUNDLE], capture_output=True)

    def stop(self):
        if self.process and self.process.poll() is None:
            self.process.send_signal(signal.SIGTERM)
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=10)
        self.process = None
        if getattr(self, "output", None):
            self.output.close()


def plist_value(app, key):
    return subprocess.run(["plutil", "-extract", key, "raw", os.path.join(app, "Contents/Info.plist")],
                          capture_output=True, text=True, check=True).stdout.strip()


def screen_locked():
    out = subprocess.run(["ioreg", "-n", "Root", "-d1"], capture_output=True, text=True).stdout
    return '"CGSSessionScreenIsLocked"=Yes' in out

# ------------------------------------------------------------------ building refs


def build_ref(ref, platform, out):
    """Builds `ref` in a worktree of its own, as the docs measure: Debug (the launch flags need it)
    at -O. Returns the app."""
    sha = subprocess.run(["git", "-C", REPO, "rev-parse", "--short=10", ref], capture_output=True, text=True, check=True).stdout.strip()
    tree = os.path.join(REPO, "build", "perf-refs", sha)
    if not os.path.exists(tree):
        subprocess.run(["git", "-C", REPO, "worktree", "add", "--detach", tree, sha], check=True, capture_output=True)
    mac = platform == "mac"
    derived = os.path.join(tree, "build", "DerivedData-mac" if mac else "DerivedData")
    products = os.path.join(derived, "Build/Products", "Debug" if mac else "Debug-iphonesimulator")
    log = os.path.join(out, f"build-{sha}-{platform}.log")
    print(f"building {ref} ({sha}) for {platform}…", flush=True)
    command = ["xcodebuild", "-project", "Hermes.xcodeproj", "-scheme", "Hermes", "-configuration", "Debug",
               "-destination", "platform=macOS" if mac else "generic/platform=iOS Simulator", "-derivedDataPath", derived,
               "CODE_SIGN_STYLE=Manual", "CODE_SIGN_IDENTITY=-", "DEVELOPMENT_TEAM=", "PROVISIONING_PROFILE_SPECIFIER=",
               "SWIFT_OPTIMIZATION_LEVEL=-O", "SWIFT_COMPILATION_MODE=wholemodule", "build"]
    with open(log, "w") as output:
        result = subprocess.run(command, cwd=tree, stdout=output, stderr=subprocess.STDOUT)
    if result.returncode:
        raise SystemExit(f"{ref} didn't build: {log}")
    apps = [name for name in os.listdir(products) if name.endswith(".app")]
    return {"app": os.path.join(products, apps[0]), "ref": ref, "sha": sha}

# ------------------------------------------------------------------ the run


def read(path):
    if not os.path.exists(path):
        return ""
    with open(path, errors="replace") as handle:
        return handle.read()


def run_once(device, mock, app, scenario, out, tag, shot=False, busy_limit=None):
    """One launch of one scenario: its log's numbers, or an error. With `shot`, a screenshot two
    seconds into the scenario's first window (which costs the run a little: not for numbers)."""
    spec = SCENARIOS[scenario] if isinstance(scenario, str) else scenario
    log = os.path.join(out, f"{tag}.log")
    device.prepare(app)
    mock.start(tag, spec.get("turns"))
    shot_at = None
    before, began = cpu_seconds(), time.time()
    try:
        try:
            device.launch(app, spec["flags"], log)
        except (OSError, subprocess.CalledProcessError) as error:
            return {"error": f"the app didn't launch: {error}", "log": log}
        deadline, needed = time.time() + spec["timeout"], spec.get("count", 1)
        first = next(iter(spec["windows"].values()), (None,))[0]
        while time.time() < deadline:
            time.sleep(0.25)
            spans = parse_spans(read(log))
            if sum(1 for span in spans if span.get("to", "").startswith(spec["until"])) >= needed:
                break
            if shot and first and shot_at is None and any(span.get("to", "").startswith(first) for span in spans):
                shot_at = time.time() + 2
            if shot_at and time.time() >= shot_at:
                os.makedirs(os.path.join(out, "shots"), exist_ok=True)
                device.screenshot(os.path.join(out, "shots", f"{tag}.png"))
                shot_at = float("inf")
            if not device.alive():
                return {"error": "the app quit", "log": log}
        else:
            return {"error": f"no \"{spec['until']}\" within {spec['timeout']} s", "log": log}
        others, busiest = outside_work(before, cpu_seconds(), time.time() - began,
                                       {os.getpid(), getattr(mock.process, "pid", None), device.pid})
    finally:
        device.stop()
        mock.stop()
    if busy_limit is not None and others > busy_limit:
        return {"error": f"the machine was busy: other work kept {others} cores busy on average (over {busy_limit}): {busiest}",
                "log": log, "outside_cores": others, "outside_busiest": busiest, "busy": True}
    measured = measure(read(log), spec)
    missing = [name for name, numbers in measured.items() if numbers is None]
    if missing:
        return {"error": f"no window {', '.join(missing)} in the log", "log": log}
    if any(numbers.get("covered") for numbers in measured.values()):
        return {"error": "the window was covered: a covered Mac window gets no frames", "log": log}
    if any(numbers.get("sheet") for numbers in measured.values()):
        return {"error": "a sheet was over the chat: the run measured the sheet", "log": log}
    return {"measured": measured, "log": log, "outside_cores": others, "outside_busiest": busiest}


def load_load():
    return round(os.getloadavg()[0], 2)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    target = parser.add_mutually_exclusive_group(required=True)
    target.add_argument("--udid", help="the simulator to run on (booted or not)")
    target.add_argument("--mac", action="store_true", help="run on this Mac")
    parser.add_argument("--app", help="the build to measure (A): a Debug Hermes Dev .app")
    parser.add_argument("--app-b", help="a second build (B), compared with A")
    parser.add_argument("--ref", help="a git ref to build as A instead of --app")
    parser.add_argument("--ref-b", help="a git ref to build as B instead of --app-b")
    parser.add_argument("--out", required=True)
    parser.add_argument("--rounds", type=int, default=3, help="measured runs of each build per scenario (3)")
    parser.add_argument("--only", default=",".join(DEFAULT_SCENARIOS), help="scenarios, comma-separated")
    parser.add_argument("--budgets", default=os.path.join(HERE, "perf_budgets.json"))
    parser.add_argument("--long-chat-turns", type=int, default=300)
    parser.add_argument("--no-warmup", action="store_true", help="skip each build's unmeasured first launch")
    parser.add_argument("--shots", action="store_true",
                        help="a screenshot in each scenario's first run, to see what it measured (costs that run a little)")
    args = parser.parse_args()
    if not (args.app or args.ref):
        parser.error("give --app or --ref")
    names = [name for name in args.only.split(",") if name]
    unknown = [name for name in names if name not in SCENARIOS]
    if unknown:
        parser.error(f"unknown scenario {', '.join(unknown)} (have {', '.join(SCENARIOS)})")
    # simctl writes the app's output to absolute paths only.
    args.out = os.path.abspath(args.out)
    os.makedirs(args.out, exist_ok=True)
    platform = "mac" if args.mac else "ios-simulator"
    if args.mac and screen_locked():
        raise SystemExit("the screen is locked: a Mac window off screen draws no frames, so nothing would measure")
    with open(args.budgets) as handle:
        budgets = json.load(handle)
    limits = budgets["platforms"][platform]
    device = Mac(args.out) if args.mac else Simulator(args.udid)
    # A simulator this run boots, it shuts down again at the end.
    booted_here = False
    if not args.mac and device.describe()["state"] != "Booted":
        subprocess.run(["xcrun", "simctl", "boot", args.udid], check=True)
        subprocess.run(["xcrun", "simctl", "bootstatus", args.udid, "-b"], check=True, capture_output=True)
        booted_here = True
    builds = {"a": build_ref(args.ref, platform, args.out) if args.ref else {"app": os.path.abspath(args.app)}}
    if args.ref_b or args.app_b:
        builds["b"] = build_ref(args.ref_b, platform, args.out) if args.ref_b else {"app": os.path.abspath(args.app_b)}
    mock = Mock(args.out, args.long_chat_turns)
    began = time.time()
    report = {"started": datetime.datetime.now().isoformat(timespec="seconds"), "platform": platform,
              "device": device.describe(), "builds": builds, "rounds": args.rounds, "scenarios": {}}
    runs = {name: {key: [] for key in builds} for name in names}
    errors = []
    try:
        if not args.no_warmup:
            # The first launch after a build pays for loading it: one unmeasured run of each.
            for key, build in builds.items():
                print(f"warming up {key}…", flush=True)
                run_once(device, mock, build["app"], WARMUP, args.out, f"warmup-{key}")
        for name in names:
            for index, key in enumerate(order(args.rounds) if "b" in builds else ["a"] * args.rounds):
                tag = f"{name}-{index + 1:02d}-{key}"
                load = load_load()
                # Other work comes and goes: a run it overlapped goes again after a pause, twice.
                for attempt in range(3):
                    result = run_once(device, mock, builds[key]["app"], name, args.out, tag, shot=args.shots and index == 0,
                                      busy_limit=budgets.get("outside_cores_max"))
                    if not result.get("busy") or attempt == 2:
                        break
                    print(f"{tag}: {result['error']}; again in 30 s", flush=True)
                    time.sleep(30)
                result["load"] = load
                print(f"{tag}: " + (result.get("error") or f"outside {result['outside_cores']} cores {result['outside_busiest']} " + json.dumps({w: {k: v for k, v in (m or {}).items() if k in (
                    "cpu_pct", "instr_m", "over_budget_pct", "longest_ms", "teleports", "long_steps", "largest_drift_pt", "from_end_pt")}
                    for w, m in result["measured"].items()})), flush=True)
                if "error" in result:
                    errors.append(f"{tag}: {result['error']}")
                else:
                    # The load average as the run began: other work on the machine moves the
                    # readings, so a run measured beside it can be told apart afterwards.
                    runs[name][key].append({**result["measured"], "load": load, "outside_cores": result["outside_cores"],
                                              "outside_busiest": result["outside_busiest"], "run": tag})
    finally:
        device.stop()
        mock.stop()
        device.finish(booted_here)
    failures = []
    for name in names:
        rules = limits.get(name, {})
        entry = {"runs": runs[name]}
        # The candidate keeps the invariants: B when comparing, else the one build.
        candidate = "b" if "b" in builds else "a"
        entry["invariants"] = grade_invariants(runs[name][candidate], rules.get("invariants", {}))
        failures += [f"{name}: {why}" for why in entry["invariants"]]
        entry["medians"] = {key: {path: spread([metric(m, path) for m in runs[name][key]])[0]
                                  for path in rules.get("report", [])} for key in builds}
        if "b" in builds:
            regression = {path: {**budgets["regression"][path.partition(".")[2]], **rules.get("regression_override", {}).get(path, {})}
                          for path in rules.get("regression", [])}
            entry["compare"], why = compare(runs[name]["a"], runs[name]["b"], regression)
            failures += [f"{name}: {line}" for line in why]
        report["scenarios"][name] = entry
    report["finished"] = datetime.datetime.now().isoformat(timespec="seconds")
    report["minutes"] = round((time.time() - began) / 60, 1)
    report["errors"] = errors
    report["failures"] = failures
    report["result"] = "ERROR" if errors and not failures else ("FAIL" if failures else "PASS")
    with open(os.path.join(args.out, "report.json"), "w") as handle:
        json.dump(report, handle, indent=2)
    for line in failures + errors:
        print(f"  {line}")
    print(f"{report['result']}: {os.path.join(args.out, 'report.json')}")
    sys.exit({"PASS": 0, "FAIL": 1}.get(report["result"], 2))


if __name__ == "__main__":
    main()
