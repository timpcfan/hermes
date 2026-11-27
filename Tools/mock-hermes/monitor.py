#!/usr/bin/env python3
"""A mock Xunxin monitor service for developing Stats without a real deployment.

It speaks the scoped monitoring contract v1 in `_brief/INTERFACES.md`:

    GET /api/snapshot?scope=xunxin
    GET /api/stream?scope=xunxin      SSE `event: snapshot`
    GET /api/recent?scope=xunxin&...  filters, sorting, paging and the frozen `upto`

    python3 -I Tools/mock-hermes/monitor.py --port 48081

Scenarios (`--scenario`):
  healthy     a day of mixed models, failures, a 499, unknown prices and latencies,
              two in-flight requests, three exits and events
  stale       the same rows, with trace/probe/usage freshness older than its limits
  empty       a day with no requests
  legacy      an old unscoped payload (no schema_version/scope): the app must refuse it
  wrong-scope a schema-1 payload whose scope is `global`: the app must refuse it
  html        HTML on /api/snapshot: the address answers, but not with monitoring data

`--no-sse` makes /api/stream answer 503, so a connection test proves snapshot and
recent work while live updates don't (the app saves it in polling mode). `--grow`
adds one completed request every three stream frames, so a frozen Requests list can
show "N new requests". `--token` requires `Authorization: Bearer <token>`.

Every timestamp is in the service's +08:00 business day. The mock keeps its data in
memory, never reads a real monitor's state and never makes an outbound request.

Every snapshot also carries the account `quota` object (whole Xunxin account, USD,
60-second refresh). `--scenario stale` dates it past its 180-second window so Stats
must keep the last amounts but stop calling them current.
"""

import argparse
import datetime
import json
import math
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

SCOPE = "xunxin"
SCHEMA_VERSION = 1
TIMEZONE = "+08:00"
TZ = datetime.timezone(datetime.timedelta(hours=8))
BUCKET_HOURS = list(range(0, 24, 3))


def iso(epoch):
    return datetime.datetime.fromtimestamp(epoch, TZ).isoformat(timespec="seconds")


def percentile(values, q):
    values = sorted(v for v in values if v is not None)
    if not values:
        return None
    return round(values[min(len(values) - 1, int(len(values) * q))], 1)


def hit_rate(uncached, cache_read, cache_write):
    total = (uncached or 0) + (cache_read or 0) + (cache_write or 0)
    return round((cache_read or 0) / total, 4) if total else None


def model_key(model):
    # The account is part of the key, as the real scoped collector keeps it: a direct
    # request that happens to use the same model name is another key, never merged.
    return "xunxin-default/" + model


class Fixture:
    def __init__(self, scenario, grow):
        self.scenario = scenario
        self.grow = grow
        self.lock = threading.RLock()
        self.created = time.time()
        self.extra = 0
        self.frames = 0
        self.base = self._make_day(scenario)
        self.inflight = self._make_inflight(scenario)
        self._positions = {flight["id"]: index for index, flight in enumerate(self.base)}
        self.next_position = 1000 + len(self.base)

    def _make_day(self, scenario):
        if scenario == "empty":
            return []
        now = time.time()
        local = datetime.datetime.fromtimestamp(now, TZ)
        start = local.replace(hour=0, minute=0, second=0, microsecond=0).timestamp()
        span = max(3600.0, now - start - 900)
        models = [
            ("claude-sonnet-4.6", "Claude Sonnet 4.6"),
            ("gpt-5.4", "GPT-5.4"),
            ("gemini-3-pro", "Gemini 3 Pro"),
            ("grok-5", "Grok 5"),
        ]
        agents = ["hermes", "claude", "hermes", "codex"]
        providers = ["xunxin-default", "xunxin-cc", "xunxin-happy", "xunxin-default"]
        exits = ["blue", "green", "blue", None]
        rows = []
        for index in range(28):
            model, model_name = models[index % len(models)]
            occurred = start + span * (index + 1) / 28
            status = 499 if index % 9 == 4 else (500 if index % 11 == 7 else 200)
            ok = status == 200
            canceled = status == 499
            known_latency = index % 13 != 10
            milliseconds = (1200 + index * 137) if known_latency else None
            ttft = (180 + index * 27) if (ok and known_latency) else None
            tps = round(28 + (index * 3.7) % 52, 1) if (ok and known_latency) else None
            cost = None if (not ok or index % 8 == 5) else round(0.0018 + index * 0.00073, 6)
            input_tokens = None if index % 13 == 10 else 800 + index * 63
            cache_read = None if input_tokens is None else 300 + index * 41
            rows.append({
                "id": "req-%02d" % (index + 1),
                "src": "usage",
                "t": iso(occurred),
                "start": occurred - (milliseconds or 0) / 1000.0,
                "end": occurred,
                "agent": agents[index % len(agents)],
                "agent_raw": agents[index % len(agents)],
                "provider": providers[index % len(providers)],
                "pname": {"xunxin-default": "Xunxin Default", "xunxin-cc": "Xunxin CC",
                          "xunxin-happy": "Xunxin Happy"}[providers[index % len(providers)]],
                "req_model": model,
                "model": model,
                "served": model_name,
                "effort": ["low", "medium", "high"][index % 3],
                "stop": "end_turn" if ok else None,
                "done": True,
                "status": status,
                "ok": ok,
                "err": "provider returned 500" if status == 500 else None,
                "ms": milliseconds,
                "ttft": ttft,
                "in": input_tokens,
                "out": None if input_tokens is None else 120 + index * 17,
                "cache": cache_read,
                "cache_write": None if input_tokens is None else 20 + index * 3,
                "reasoning": 0,
                "hit": hit_rate(input_tokens, cache_read, 20 + index * 3),
                "cost": cost,
                "cost_mode": ("failed" if not ok else None) if cost is None
                             else ("ratio" if index % 2 else "expr"),
                "cost_parts": None if cost is None else {
                    "in": round(cost * 0.45, 8), "out": round(cost * 0.4, 8),
                    "cache_read": round(cost * 0.1, 8), "cache_write": round(cost * 0.05, 8),
                },
                "tps": tps,
                "tps_floor": False,
                "tps_now": None,
                "tps_live": False,
                "answering": False,
                "exit": exits[index % len(exits)],
                "detour": ["blue"] if exits[index % len(exits)] == "green" else [],
                "_pos": 1000 + index,
                "_model": model,
                "_occurred": occurred,
            })
        return rows

    def _make_inflight(self, scenario):
        if scenario == "empty":
            return []
        now = time.time()
        return [
            {
                "id": "live-1", "src": "trace", "t": iso(now), "start": now - 42,
                "end": None, "agent": "claude", "provider": "xunxin-cc",
                "pname": "Xunxin CC", "req_model": "claude-sonnet-4.6",
                "model": "claude-sonnet-4.6", "served": "Claude Sonnet 4.6",
                "effort": "high", "done": False, "ok": None, "status": None,
                "ms": None, "ttft": 610, "tps": 45.1, "tps_now": 48.2,
                "tps_floor": False, "tps_live": True, "answering": True,
                "exit": "green", "detour": ["blue"],
            },
            {
                "id": "live-2", "src": "trace", "t": iso(now), "start": now - 7,
                "end": None, "agent": "hermes", "provider": "xunxin-default",
                "pname": "Xunxin Default", "req_model": "gpt-5.4",
                "model": "gpt-5.4", "served": "GPT-5.4", "effort": "medium",
                "done": False, "ok": None, "status": None, "ms": None, "ttft": None,
                "tps": None, "tps_now": None, "tps_floor": False, "tps_live": False,
                "answering": False, "exit": "blue", "detour": [],
            },
            {
                "id": "live-3", "src": "trace", "t": iso(now), "start": now - 19,
                "end": None, "agent": "codex", "provider": "xunxin-happy",
                "pname": "Xunxin Happy", "req_model": "grok-5", "model": "grok-5",
                "served": "Grok 5", "effort": "low", "done": False, "ok": None,
                "status": None, "ms": None, "ttft": 920, "tps": 31.7,
                "tps_now": 29.4, "tps_floor": True, "tps_live": True,
                "answering": True, "exit": "green", "detour": ["blue"],
            },
        ]

    def grow_one(self):
        with self.lock:
            self.extra += 1
            now = time.time()
            model = ["claude-sonnet-4.6", "gpt-5.4"][self.extra % 2]
            row = {
                "id": "req-live-%d" % self.extra, "src": "usage", "t": iso(now),
                "start": now - 3.4, "end": now, "agent": "hermes",
                "provider": "xunxin-default", "pname": "Xunxin Default",
                "req_model": model, "model": model, "served": model,
                "effort": "medium", "stop": "end_turn", "done": True,
                "status": 200, "ok": True, "err": None, "ms": 3400, "ttft": 520,
                "in": 1200, "out": 310, "cache": 800, "cache_write": 40,
                "reasoning": 0, "hit": hit_rate(1200, 800, 40),
                "cost": 0.0064, "cost_mode": "ratio",
                "cost_parts": {"in": 0.0029, "out": 0.0026, "cache_read": 0.0006,
                               "cache_write": 0.0003},
                "tps": 91.2, "tps_floor": False, "tps_now": None, "tps_live": False,
                "answering": False, "exit": "blue", "detour": [],
                "_pos": self.next_position, "_model": model, "_occurred": now,
            }
            self.next_position += 1
            self.base.append(row)

    # -- aggregates -------------------------------------------------------

    def completed(self):
        with self.lock:
            return list(self.base)

    def snapshot(self):
        with self.lock:
            rows = list(self.base)
            now = time.time()
            day = datetime.datetime.fromtimestamp(now, TZ).date().isoformat()
            stale = self.scenario == "stale"
            freshness_at = now - 180 if stale else now
            usage_at = now - 1200 if stale else now
            view = {
                "schema_version": SCHEMA_VERSION,
                "scope": SCOPE,
                "day": day,
                "timezone": TIMEZONE,
                "snapshot_at": now,
                "capabilities": ["scoped_snapshot", "scoped_recent", "sse_snapshot",
                                 "source_freshness"],
                "freshness": {
                    "trace": {"ok": True, "last_success_at": freshness_at,
                              "last_attempt_at": freshness_at, "error": None},
                    "probes": {"ok": True, "last_success_at": freshness_at,
                               "last_attempt_at": freshness_at, "error": None},
                    "usage": {"ok": True, "last_success_at": usage_at,
                              "last_attempt_at": usage_at, "error": None},
                },
                "now": now,
                "trace": {"ok": True, "err": None},
                "failover": {"reachable": True, "last_used": "blue", "tunnels": 2},
                "exits": self._exits(rows, now, stale),
                "today": self._today(rows),
                "models": self._models(rows),
                "quota": self._quota(now, stale),
                "pricing": {"at": iso(now - 3600), "err": None, "n": 42},
                "inflight": self._inflight(now) if self.scenario != "empty" else [],
                "recent": [wire(row) for row in sorted(
                    rows, key=lambda item: item["_pos"], reverse=True)[:8]],
                "recent_day": {"day": day, "n": len(rows),
                               "upto": max((row["_pos"] for row in rows), default=0)},
                "events": self._events(now),
            }
            if self.scenario == "legacy":
                # What a service that ignores `scope` answers: the website's global payload,
                # with no contract fields. The app must never show this as Xunxin.
                view.pop("schema_version", None)
                view.pop("scope", None)
                view.pop("capabilities", None)
                view.pop("freshness", None)
            elif self.scenario == "wrong-scope":
                view["scope"] = "global"
            return view

    def _quota(self, now, stale):
        """A synthetic whole-account balance; the stale scenario keeps the last success but ages it."""
        updated = now - 600 if stale else now - 12
        return {
            "source": "xunxin_account", "scope": "account", "currency": "USD",
            "balance_usd": 128.402, "used_usd": 2332.507,
            "updated_at": updated, "last_attempt_at": updated,
            "ok": True, "stale": stale, "error": None,
            "refresh_seconds": 60, "stale_after_seconds": 180,
        }

    def _inflight(self, now):
        rows = []
        for row in self.inflight:
            copy = dict(row)
            copy["t"] = iso(now)
            if copy["answering"]:
                copy["tps_now"] = round(copy.get("tps_now") or 0, 1)
            rows.append(copy)
        return rows

    def _today(self, rows):
        ttft = [row["ttft"] for row in rows if row["status"] == 200 and row["ttft"]]
        tps = [row["tps"] for row in rows if row["status"] == 200 and row["tps"]
               and not row["tps_floor"]]
        costs = [row["cost"] for row in rows if row["cost"] is not None]
        return {
            "requests": len(rows),
            "ok": sum(1 for row in rows if row["status"] == 200),
            "err": sum(1 for row in rows if row["status"] not in (200, 499)),
            "canceled": sum(1 for row in rows if row["status"] == 499),
            "failovers": 2,
            "in": sum(row["in"] or 0 for row in rows),
            "out": sum(row["out"] or 0 for row in rows),
            "cache_read": sum(row["cache"] or 0 for row in rows),
            "cache_write": sum(row["cache_write"] or 0 for row in rows),
            "reasoning": 0,
            "cost": round(sum(costs), 6) if costs else None,
            "cost_n": len(costs),
            "cost_miss": sum(1 for row in rows if row["cost"] is None),
            "ttft_p50": percentile(ttft, 0.5),
            "tps_p50": percentile(tps, 0.5),
            "tps_n": len(tps),
        }

    def _models(self, rows):
        by_model = {}
        for row in rows:
            by_model.setdefault(row["_model"], []).append(row)
        items = []
        for model, model_rows in sorted(by_model.items(), key=lambda pair: -len(pair[1])):
            costs = [row["cost"] for row in model_rows if row["cost"] is not None]
            ttft = [row["ttft"] for row in model_rows if row["status"] == 200 and row["ttft"]]
            tps = [row["tps"] for row in model_rows if row["status"] == 200 and row["tps"]
                   and not row["tps_floor"]]
            buckets = []
            for hour in BUCKET_HOURS:
                bucket_rows = [row for row in model_rows
                               if datetime.datetime.fromtimestamp(row["_occurred"], TZ).hour // 3 * 3 == hour]
                if not bucket_rows:
                    continue
                bucket_costs = [row["cost"] for row in bucket_rows if row["cost"] is not None]
                bucket_ttft = [row["ttft"] for row in bucket_rows
                               if row["status"] == 200 and row["ttft"]]
                bucket_tps = [row["tps"] for row in bucket_rows
                              if row["status"] == 200 and row["tps"] and not row["tps_floor"]]
                buckets.append({
                    "hour": hour,
                    "n": len(bucket_rows),
                    "ok": sum(1 for row in bucket_rows if row["status"] == 200),
                    "err": sum(1 for row in bucket_rows if row["status"] not in (200, 499)),
                    "canceled": sum(1 for row in bucket_rows if row["status"] == 499),
                    "cost": round(sum(bucket_costs), 6) if bucket_costs else None,
                    "cost_n": len(bucket_costs),
                    "ttft_p50": percentile(bucket_ttft, 0.5),
                    "ttft_p90": percentile(bucket_ttft, 0.9),
                    "tps_p50": percentile(bucket_tps, 0.5),
                    "tps_p90": percentile(bucket_tps, 0.9),
                })
            items.append({
                "key": model_key(model), "name": model,
                "n": len(model_rows),
                "ok": sum(1 for row in model_rows if row["status"] == 200),
                "err": sum(1 for row in model_rows if row["status"] not in (200, 499)),
                "cxl": sum(1 for row in model_rows if row["status"] == 499),
                "cost": round(sum(costs), 6) if costs else None,
                "cost_n": len(costs),
                "cost_miss": sum(1 for row in model_rows if row["cost"] is None),
                "ttft_p50": percentile(ttft, 0.5),
                "ttft_p90": percentile(ttft, 0.9),
                "tps_p50": percentile(tps, 0.5),
                "tps_p90": percentile(tps, 0.9),
                "hit": hit_rate(
                    sum(row["in"] or 0 for row in model_rows),
                    sum(row["cache"] or 0 for row in model_rows),
                    sum(row["cache_write"] or 0 for row in model_rows),
                ),
                "buckets": buckets,
            })
        return {"buckets": 8, "bucket_hours": BUCKET_HOURS, "items": items}

    def _exits(self, rows, now, stale):
        blue_served = sum(1 for row in rows if row["exit"] == "blue")
        green_served = sum(1 for row in rows if row["exit"] == "green")
        blue_hist = []
        green_hist = []
        for index in range(18):
            at = now - (18 - index) * 95
            blue_hist.append([round(at, 3), None if stale and index > 14 else 74 + (index * 7) % 38])
            green_hist.append([round(at, 3), 108 + (index * 11) % 64])
        return [
            {"name": "blue", "role": "primary", "egress": "direct", "host": "relay-a",
             "addr": "10.0.0.4:443", "ok": True, "ms": 88, "consec_fail": 0,
             "last_change": now - 7200, "tunnels": 1, "served_today": blue_served,
             "hist": blue_hist},
            {"name": "green", "role": "secondary", "egress": "direct", "host": "relay-b",
             "addr": "10.0.0.5:443", "ok": True, "ms": 121, "consec_fail": 0,
             "last_change": now - 3600, "tunnels": 1, "served_today": green_served,
             "hist": green_hist},
            {"name": "backup", "role": "backup", "egress": "proxy", "host": "relay-c",
             "addr": "10.0.0.6:443", "ok": False, "ms": None, "consec_fail": 3,
             "last_change": now - 900, "tunnels": 0, "served_today": 0,
             "hist": [[round(now - (8 - index) * 120, 3), None if index > 3 else 240 + index * 9]
                      for index in range(8)]},
        ]

    def _events(self, now):
        if self.scenario == "empty":
            return []
        return [
            {"kind": "failover", "t": iso(now - 1500), "epoch": now - 1500,
             "exit": "green", "msg": "blue missed two probes; traffic moved to green"},
            {"kind": "recover", "t": iso(now - 900), "epoch": now - 900,
             "exit": "blue", "msg": "blue answered again; traffic returned"},
            {"kind": "probe", "t": iso(now - 300), "epoch": now - 300,
             "exit": "backup", "msg": "backup failed three probes in a row"},
        ]

    # -- /api/recent ------------------------------------------------------

    def recent(self, query):
        with self.lock:
            rows = list(self.base)
            now = time.time()
            day = datetime.datetime.fromtimestamp(now, TZ).date().isoformat()
            requested_day = query.get("day", [None])[0]
            if requested_day and requested_day != day:
                rows = []
            point = int(query.get("upto", [str(max((r["_pos"] for r in rows), default=0))])[0])
            within = [row for row in rows if row["_pos"] <= point]
            newer_all = [row for row in rows if row["_pos"] > point]
            filtered = [row for row in within if matches(row, query)]
            sort = query.get("sort", ["new"])[0]
            filtered = sort_rows(filtered, sort)
            size = max(0, min(200, int(query.get("size", ["50"])[0] or 50)))
            page = max(1, int(query.get("page", ["1"])[0] or 1))
            pages = max(1, math.ceil(len(filtered) / size)) if size else 1
            start = (page - 1) * size
            page_rows = filtered[start:start + size] if size else []
            costs = [row["cost"] for row in filtered if row["cost"] is not None]
            day_costs = [row["cost"] for row in within if row["cost"] is not None]
            view = {
                "schema_version": SCHEMA_VERSION,
                "scope": SCOPE,
                "timezone": TIMEZONE,
                "day": day,
                "n_day": len(within),
                "n_now": len(rows),
                "upto": point,
                "newer": sum(1 for row in newer_all if matches(row, query)),
                "newer_all": len(newer_all),
                "total": len(filtered),
                "cost_sum": round(sum(costs), 6) if costs else None,
                "cost_n": len(costs),
                "cost_none": sum(1 for row in filtered if row["cost"] is None),
                "day_cost": round(sum(day_costs), 6) if day_costs else None,
                "page": page,
                "size": size,
                "pages": pages,
                "sort": sort,
                "items": [wire(row) for row in page_rows],
                "ms": round((time.time() - now) * 1000, 1),
            }
            if self.scenario == "legacy":
                view.pop("schema_version", None)
                view.pop("scope", None)
            elif self.scenario == "wrong-scope":
                view["scope"] = "global"
            return view


def wire(row):
    return {key: value for key, value in row.items() if not key.startswith("_")}


def matches(row, query):
    text = (query.get("q", [""])[0] or "").strip().lower()
    if text:
        haystack = " ".join(str(row.get(key) or "") for key in (
            "id", "agent", "provider", "pname", "model", "served", "exit", "err"
        )).lower()
        if text not in haystack:
            return False
    status = query.get("st", ["any"])[0]
    if status == "ok" and row["status"] != 200:
        return False
    if status == "err" and row["status"] in (200, 499):
        return False
    if status == "cxl" and row["status"] != 499:
        return False
    cost = query.get("cost", ["any"])[0]
    if cost == "priced" and row["cost"] is None:
        return False
    # `none` is what the table draws as —: unpriced, or a failed call with no charge.
    if cost == "none" and not (row["cost"] is None or row.get("cost_mode") == "failed"):
        return False
    if cost == "unpriced" and row["cost"] is not None:
        return False
    try:
        minimum = float(query["cmin"][0]) if query.get("cmin", [""])[0] else None
        maximum = float(query["cmax"][0]) if query.get("cmax", [""])[0] else None
    except ValueError:
        return False
    if minimum is not None and (row["cost"] is None or row["cost"] < minimum):
        return False
    if maximum is not None and (row["cost"] is None or row["cost"] > maximum):
        return False
    return True


def sort_rows(rows, sort):
    """The server's sort: newest/oldest by append position, cost with priced rows first,
    duration longest first with unknown durations last. Python's sort is stable, so equal
    keys keep the newest first as the baseline's do."""
    newest = sorted(rows, key=lambda row: row["_pos"], reverse=True)
    if sort == "old":
        return sorted(rows, key=lambda row: row["_pos"])
    if sort in ("cost", "cost_asc"):
        priced = [row for row in newest if row["cost"] is not None]
        unpriced = [row for row in newest if row["cost"] is None]
        priced.sort(key=lambda row: row["cost"], reverse=(sort == "cost"))
        return priced + unpriced
    if sort == "ms":
        return sorted(newest, key=lambda row: row.get("ms") if row.get("ms") is not None else -1,
                      reverse=True)
    return newest


class Handler(BaseHTTPRequestHandler):
    server_version = "MockXunxinMonitor/1.0"
    fixture = None
    token = None
    no_sse = False

    def log_message(self, fmt, *args):
        if getattr(self.server, "verbose", False):
            super().log_message(fmt, *args)

    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path == "/api/health":
            self.send_json({"ok": True})
            return
        if not self.authorized():
            self.send_json({"error": "unauthorized"}, status=401)
            return
        query = parse_qs(parsed.query, keep_blank_values=True)
        if parsed.path.endswith("/api/snapshot"):
            self.scoped_or_error(query, self.snapshot)
        elif parsed.path.endswith("/api/recent"):
            self.scoped_or_error(query, self.recent)
        elif parsed.path.endswith("/api/stream"):
            self.stream(query)
        else:
            self.send_json({"error": "not found"}, status=404)

    def authorized(self):
        if not self.token:
            return True
        return self.headers.get("Authorization", "") == "Bearer " + self.token

    def scoped_or_error(self, query, make):
        scope = query.get("scope", [None])[0]
        if self.fixture.scenario == "html" and make == self.snapshot:
            body = b"<!doctype html><html><body><h1>Monitor</h1></body></html>"
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if scope not in (None, SCOPE) and self.fixture.scenario not in ("legacy", "wrong-scope"):
            self.send_json({"error": "invalid scope"}, status=400)
            return
        self.send_json(make(query))

    def snapshot(self, query):
        return self.fixture.snapshot()

    def recent(self, query):
        return self.fixture.recent(query)

    def stream(self, query):
        scope = query.get("scope", [None])[0]
        if scope not in (None, SCOPE) and self.fixture.scenario not in ("legacy", "wrong-scope"):
            self.send_json({"error": "invalid scope"}, status=400)
            return
        if self.no_sse:
            self.send_json({"error": "live updates are unavailable"}, status=503)
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "keep-alive")
        self.end_headers()
        try:
            self.wfile.write(b"retry: 3000\n\n")
            self.wfile.flush()
            while True:
                if self.fixture.grow and self.fixture.frames >= 2:
                    self.fixture.grow_one()
                self.fixture.frames += 1
                payload = json.dumps(self.fixture.snapshot(), ensure_ascii=False)
                self.wfile.write(b"event: snapshot\ndata: " + payload.encode("utf-8") + b"\n\n")
                self.wfile.flush()
                time.sleep(3)
        except (BrokenPipeError, ConnectionResetError, OSError):
            return

    def send_json(self, value, status=200):
        body = json.dumps(value, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def main():
    parser = argparse.ArgumentParser(description="Mock Xunxin monitor service")
    parser.add_argument("--port", type=int, default=48081)
    parser.add_argument("--scenario", default="healthy",
                        choices=["healthy", "stale", "empty", "legacy", "wrong-scope", "html"])
    parser.add_argument("--token", default=None, help="require this Bearer token")
    parser.add_argument("--no-sse", action="store_true", help="/api/stream answers 503")
    parser.add_argument("--grow", action="store_true",
                        help="add a completed request every three stream frames")
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()

    Handler.fixture = Fixture(args.scenario, args.grow)
    Handler.token = args.token
    Handler.no_sse = args.no_sse
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    server.daemon_threads = True
    server.verbose = args.verbose
    print(json.dumps({"pid": __import__("os").getpid(), "port": args.port,
                      "scenario": args.scenario, "sse": not args.no_sse}), flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
