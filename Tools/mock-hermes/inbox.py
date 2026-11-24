"""Unread and live activity for the combined mock (docs/inbox.md).

- The dashboard's `GET /api/sessions` (hermes_cli/web_routers/sessions.py): the default profile's
  chats with their read marks (`last_read_at`, `unread`, `last_active`). The API server's rows
  (server.py) don't carry them, as in Hermes.
- `session.active_list` like tui_gateway/server.py's `_session_live_item`: every live session in
  this process with its status (starting, working, waiting, idle) and preview (a queued prompt,
  else the reply being written, else the prompt before its first words, else the last thing said).
- `--inbox-demo`: two seeded chats look live without a turn (one working and writing, one waiting
  for an approval), for screenshots and the acceptance checks.
- `--inbox-gtd`: the inbox's regions (docs/inbox.md §2a): settled (archived) chats, one of them
  pinned, chats from every source and an empty one, and three that look live on a cycle: a deploy
  that works for 15 s, then waits for an approval for 45 s, then finishes and rests; a pinned
  review and a migration that keep working.
"""

import time

B = None  # backend.py globals
G = None  # server.py module
DEMO = {"on": False, "gtd": False, "started": time.time()}


def install(backend_globals, gateway_module, demo=False, gtd=False):
    global B, G
    B, G = backend_globals, gateway_module
    DEMO["on"] = demo
    DEMO["gtd"] = gtd
    DEMO["started"] = time.time()
    if gtd:
        with G.LOCK:
            seed_gtd()
    B["HTTP_ROUTES"][("GET", "/api/sessions")] = list_sessions
    B["HTTP_ROUTES"][("POST", "/api/mock/inbox/reset")] = reset
    B["METHODS"]["session.active_list"] = active_list
    wrap_turns()


def reset(query, body):
    """Mock-only: the seeded read marks again, for UI tests (`docs/inbox.md` §7)."""
    with G.LOCK:
        G.seed_read_marks()
    return 200, {"ok": True}


# ---------------------------------------------------------------- the dashboard's rows


def list_sessions(query, body):
    def arg(name, default=None):
        return (query.get(name) or [default])[0]
    try:
        limit = int(arg("limit", "20"))
        offset = int(arg("offset", "0"))
    except ValueError:
        return 422, {"detail": [{"loc": ["query", "limit"], "msg": "Input should be a valid integer"}]}
    if limit < 1 or limit > 100:
        return 422, {"detail": [{"loc": ["query", "limit"], "msg": "Input should be less than or equal to 100"}]}
    profile = arg("profile", "default") or "default"
    if profile != "default":
        return 200, {"sessions": [], "total": 0, "limit": limit, "offset": offset, "storage": {}}
    archived = arg("archived", "exclude")
    now = time.time()
    with G.LOCK:
        rows = []
        for s in G.SESSIONS.values():
            if s.get("hidden") and not s.get("pinned"):
                continue
            if archived == "exclude" and s.get("archived") and not s.get("pinned"):
                continue
            if archived == "only" and not s.get("archived"):
                continue
            rows.append(dashboard_row(s, now))
    key = "last_active" if arg("order", "created") == "recent" else "started_at"
    rows.sort(key=lambda r: r.get(key) or 0, reverse=True)
    page = rows[offset:offset + limit]
    # list_sessions_rich(include_pinned=True): every pin the page missed follows it, newest first.
    # Hermes' back-fill doesn't inherit the archived filter (hermes_state_sessions.py, "Do not
    # inherit the archived constraint"): pinned chats from the other side come along too, with
    # their own `archived`, so a client never takes a page for one side only.
    on_page = {r["id"] for r in page}
    with G.LOCK:
        pins = [dashboard_row(s, now) for s in G.SESSIONS.values()
                if s.get("pinned") and not s.get("hidden") and s["id"] not in on_page]
    page += sorted(pins, key=lambda r: r.get("started_at") or 0, reverse=True)
    return 200, {"sessions": page, "total": len(rows), "limit": limit, "offset": offset, "storage": {}}


def dashboard_row(s, now):
    """hermes_state_sessions.py's row plus what the router adds; `unread` is session_unread()."""
    row = {k: v for k, v in s.items() if not k.startswith("_")}
    read = s.get("_last_read_at")
    last = s["_last"]
    row.update({
        "last_active": last, "last_activity_at": last, "last_read_at": read, "preview": s["_preview"] or "",
        "unread": False if read is None else last > read, "is_active": s.get("ended_at") is None and now - last < 300,
        "profile": "default", "is_default_profile": True,
    })
    return row


# ---------------------------------------------------------------- live sessions


def wrap_turns():
    """Remembers each turn's prompt and the words written so far, for active_list's preview."""
    emit, start_turn = B["emit"], B["start_turn"]

    def tracking_emit(sid, kind, payload):
        runtime = B["RUNTIME"].get(sid)
        if runtime is not None:
            if kind == "message.start":
                runtime["live_text"] = ""
            elif kind == "message.delta":
                runtime["live_text"] = (runtime.get("live_text") or "") + (payload.get("text") or "")
            elif kind in ("message.complete", "error"):
                runtime["live_text"] = ""
        emit(sid, kind, payload)

    def tracking_start(sid, text, runner):
        runtime = B["RUNTIME"].get(sid)
        if runtime is not None:
            runtime["prompt"] = text
            runtime["live_text"] = ""
        start_turn(sid, text, runner)

    B["emit"] = tracking_emit
    B["start_turn"] = tracking_start


def flat(text, limit=160):
    words = " ".join((text or "").split())
    return words[-limit:] if len(words) > limit else words


def active_list(params):
    params = params or {}
    now = time.time()
    out = []
    with B["LOCK"]:
        live = [(sid, dict(r)) for sid, r in B["RUNTIME"].items() if r.get("stored")]
    open_sids = {request["sid"] for request in B["PENDING"].values()} if "PENDING" in B else set()
    for sid, r in live:
        stored = r["stored"]
        running = bool(r.get("running"))
        if sid in open_sids:
            status = "waiting"
        elif running and now - (r.get("turn_started") or 0) < 1.0:
            status = "starting"
        elif running:
            status = "working"
        else:
            status = "idle"
        if r.get("queue"):
            preview = flat(r["queue"][0] if isinstance(r["queue"][0], str) else r["queue"][0].get("text", ""))
        elif running and r.get("live_text"):
            preview = flat(r["live_text"])
        elif running and r.get("prompt"):
            preview = flat(r["prompt"])
        else:
            preview = last_said(stored)
        with G.LOCK:
            s = G.SESSIONS.get(stored) or {}
        out.append({"current": sid == params.get("current_session_id"), "id": sid, "session_key": stored, "status": status,
                    "title": s.get("title"), "preview": preview, "message_count": s.get("message_count", 0),
                    "model": s.get("model"), "started_at": s.get("started_at"), "last_active": s.get("_last")})
    if DEMO["on"]:
        out += demo_rows(now)
    if DEMO["gtd"]:
        out += gtd_rows(now)
    return {"sessions": out}


def last_said(stored):
    with G.LOCK:
        rows = list(G.MESSAGES.get(stored, []))
    for row in reversed(rows):
        text = row.get("content")
        if isinstance(text, str) and text.strip():
            return flat(text)
    return ""


DEMO_REPLY = ("The socket reconnects with a backoff of up to five seconds now, and the Mac's wake "
              "notification reopens it at once instead of waiting for the next ping.")


def demo_rows(now):
    """`--inbox-demo`: Swift 6 migration plan works through a 40 s cycle (starting, thinking, writing,
    then a rest), and the NAS chat waits for an approval."""
    phase = (now - DEMO["started"]) % 40
    rows = []
    if phase < 30:
        if phase < 2:
            status, preview = "starting", "Fix the reconnect after sleep"
        elif phase < 8:
            status, preview = "working", "Fix the reconnect after sleep"
        else:
            words = int((phase - 8) / 22 * len(DEMO_REPLY.split())) + 1
            status, preview = "working", " ".join(DEMO_REPLY.split()[:words])
        rows.append(demo_row("api_1760_welcome", status, preview))
    rows.append(demo_row("cli_2026_1011", "waiting", "docker system prune -af"))
    return rows


def demo_row(stored, status, preview):
    with G.LOCK:
        s = G.SESSIONS.get(stored) or {}
    return {"current": False, "id": f"demo-{stored}", "session_key": stored, "status": status, "title": s.get("title"),
            "preview": preview, "message_count": s.get("message_count", 0), "model": s.get("model"),
            "started_at": s.get("started_at"), "last_active": time.time()}


# ---------------------------------------------------------------- --inbox-gtd

GTD_SETTLED = ["Quarterly tax notes", "Router firmware update", "Holiday photos backup", "Kitchen renovation quotes",
               "Rust borrow checker question", "Dentist appointment", "Flight to Lisbon", "Old laptop wipe",
               "Newsletter draft", "Podcast transcript cleanup", "Spreadsheet macro", "Car insurance renewal"]
GTD_SOURCES = [("tg_gtd_1", "Groceries for the weekend", "telegram"), ("dc_gtd_1", "Raid night schedule", "discord"),
               ("cli_gtd_1", "Rotate the nginx logs", "cli"), ("acp_gtd_1", "Refactor the parser", "acp")]


def seed_gtd():
    """Settled chats (archived: 37, the last one pinned, which Hermes back-fills into every page),
    chats from each source, an empty one, and the three the cycle makes live (`gtd_rows`)."""
    now, hour = G.NOW, G.HOUR
    for i in range(37):
        sid = f"settled_{i:02d}"
        title = GTD_SETTLED[i % len(GTD_SETTLED)] + ("" if i < len(GTD_SETTLED) else f" {i // len(GTD_SETTLED) + 1}")
        started = now - (i + 3) * 9 * hour
        G.session_row(sid, title, "api_server", started, started + 300, "")
        G.add_message(sid, "user", f"Can you help with {title.lower()}?", timestamp=started)
        G.add_message(sid, "assistant", "Done. Everything is in order now.", timestamp=started + 300)
        G.SESSIONS[sid]["archived"] = True
    G.SESSIONS["settled_36"]["pinned"] = True
    for k, (sid, title, source) in enumerate(GTD_SOURCES):
        started = now - (k + 2) * 2 * hour
        G.session_row(sid, title, source, started, started + 60, "")
        G.add_message(sid, "user", f"{title}, please.", timestamp=started)
        G.add_message(sid, "assistant", "On it, here is what I found.", timestamp=started + 60)
    G.session_row("empty_gtd", None, "api_server", now - 3 * hour, now - 3 * hour, "")
    for k, (sid, title) in enumerate([("gtd_deploy", "Deploy hk3 nginx"), ("gtd_review", "Review my recent work"),
                                      ("gtd_migrate", "Migrate the board to Swift 6")]):
        started = now - (k + 1) * 30 * 60
        G.session_row(sid, title, "api_server", started, started + 120, "")
        G.add_message(sid, "user", f"{title}.", timestamp=started)
        G.add_message(sid, "assistant", "Starting on it.", timestamp=started + 120)
    G.SESSIONS["gtd_review"]["pinned"] = True


def gtd_rows(now):
    """The deploy works for 15 s, waits for an approval for 45 s, then rests for 60 s (finished);
    the pinned review and the migration keep working."""
    phase = (now - DEMO["started"]) % 120
    rows = [demo_row("gtd_review", "working", "Reading the last week of commits"),
            demo_row("gtd_migrate", "working", "Updating the card views")]
    if phase < 15:
        rows.append(demo_row("gtd_deploy", "working", "Checking the nginx config"))
    elif phase < 60:
        rows.append(demo_row("gtd_deploy", "waiting", "sudo systemctl reload nginx"))
    return rows
