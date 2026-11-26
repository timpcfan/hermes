# Unread and live activity

How the chat lists and the chat itself show what's new and what's happening, in the spirit of
Telegram and Grok's Bots. The design's components live in `blocks/inbox.elyx`; the screens are
`inboxChats`, `inboxBots`, `inboxUnread`, `inboxCaughtUp`, `inboxSwipe`, `inboxRowMenu`,
`chatOpenedAtNew`, `chatReadingLive`, `chatNewBelow`, `botChatTyping`, `groupChatMention`,
`chatReplyQuote`, `chatReplyQuoteSent`, `ipadInbox` and `macInbox`.

| Code | What it is |
|---|---|
| `HermesKit/Inbox` | The rules, with tests: `ReadMark`, `UnreadCounter`, `NewMessagesMarker`, `MuteList`, `JumpPill`, `InboxTime`, `ActivityLine` / `ActivityTracker`, `LastLine`, `QuotedReply` |
| `UnreadStore` | One per gateway: each row's badge, Hermes' read marks, counts, mutes, how far each chat was read and where it was left |
| `LiveActivity` | One per gateway: each chat's activity line |
| `ReadRecheck` | When to ask Hermes again about read marks, shared by the chats and the Bots (`BotRoster`) |
| `Views/Inbox` | The rows, badges, activity line, filters, swipes, the New Messages line, the jump pill, the group chat's thinking line, the reply bar and the quote block |

## 1. Read state

Hermes keeps one read mark per chat, `last_read_at`, shared by every device and Hermes Desktop
(`hermes_state_sessions.py`: `set_session_read`, `session_unread`).

| Value | Meaning |
|---|---|
| `null` | Never tracked: read, on every device. The app icon badge doesn't count its replies either, even from a notice on a sleeping iPhone, until a read marks it ([notifications.md](notifications.md) §2 Badge) |
| `0` | Marked unread by hand: the row shows a dot, not a count |
| A time | Read up to then |

Unread means `last_active > last_read_at` (with half a second of slack for Hermes' clock). Any
activity counts, your own messages and turn heartbeats included, so the app marks a chat read
again after each turn it watched end.

| Need | Call | Notes |
|---|---|---|
| Read marks for the list | The dashboard's `GET /api/sessions?order=recent&limit=100` (`BackendClient.recentSessions`) | The API server's rows (`HermesClient.sessions`) carry no `unread` or `last_read_at`, nor does the JSON-RPC `session.list`; the dashboard's do. So with Bot Mode linked, chats get Hermes' marks; without it, a watermark kept on this device (seeded on first sight), and read state doesn't sync |
| Mark read | `PATCH /api/sessions/{id} {unread: false}` on the API server (`HermesClient.setSessionFlags`) | Stamps the mark at the gateway's now. Only when the chat was unread. A gateway older than the field answers `400 unsupported_session_field`; then the dashboard's fenced `markRead` (via `mutation-snapshot`, else the plain PATCH with `profile`) |
| Mark unread | The same with `{unread: true}` | Sets the mark to 0 |
| Read elsewhere | `sessions.changed` (no payload; it fires when any session column it watches moves, `last_read_at` included, at most every 2 s, and so all through a streaming turn). The app turns it into one tick for everything that follows it (project lanes, read marks, the roster, the chat list, live lines): a quarter second after the first change, then at most every 3 s while changes keep coming, every 30 s while the Mac app is behind other apps | `ReadRecheck`: ask at once, then at most every 3 s while changes keep coming; between changes every 15 s (60 s while the Mac app is behind other apps), backing off to 2 minutes while something stays unread. The chat list itself is fetched again too (at most every 3 s), so rows move to the top |
| A mark this device just set | | Holds until Hermes' rows agree, or for 10 s, so an older page can't undo it |
| Bots | The Bot Chat's own mark (`GET /api/sessions/{id}?profile` → `last_read_at`; `BackendClient.readMark`) | `BotRoster` as before (opening a Bot Chat marks it read), plus Mark as Unread and picking up a mark of 0 from other devices (read Bots are asked at most every 30 s) |
| Group chats | none | Rooms have no read mark for the person. This device keeps the last event seen per room (`groupSeen.<gateway>`); a room's count is its members' messages after it (`groups.log`), refreshed when `latest_seq` moves. The log is read page by page from 200 events before that point (`RoomTranscript.countUnread`), so a long room counts all its news and a reply quoting the person's earlier message is still a mention; a read that fails is tried again at the next refresh. A room read on another device reaches this one through the push plugin (`read`, [notifications.md](notifications.md) §2 Reading): it's read here too unless it moved since |

### Counting

The gateway has no count; the app counts (`UnreadCounter`).

- An unread row's newest 100 messages (`GET /api/sessions/{id}/messages?limit=100&order=latest`,
  the Bot Chat's from the dashboard) are folded with `TranscriptBuilder` and counted after the
  mark.
- **Counted:** each reply that ended a turn (an answer after the steps, one however many tool calls
  it made), each Bot's message in the chat (`message_agent`, a group member), each routine delivery.
- **Not counted:** narration, tool calls and their results, reasoning, notices, run events, a reply
  that is only a silence marker (`[SILENT]`, `NO_REPLY`), compaction summaries, your own messages
  and your own commands' results. A chat whose only news is your own message (sent from another
  device), a heartbeat or a compaction shows nothing.
- **Run events:** a background process a tool started wakes the chat while it runs. Hermes stores
  each wake as an `internal_notification` row: a heartbeat (`[Background process … heartbeat #N`),
  and every process wake ends with Hermes's footer (`[INTERNAL NOTIFICATION — generated by the
  Hermes gateway…]`, `gateway/run_notifications.py`). It shows as a notice in Hermes's own words
  ("Background process output after 2m: make test", `heartbeat_display_text`), never as an
  automation's message, and the model's silent answer to it isn't news. Each one used to count, and
  so did each `[SILENT]` answer in a chat, so a reply that started a long build counted one more for
  every heartbeat (#83). The model's reply when the process ends is a message. Hermes stores a compaction's handoff summary as an ordinary message,
  the person's or its own; the app knows it as Hermes' session search does (`CompactionSummary`,
  mirroring `_is_compaction_summary` in `tools/session_search_tool.py`).
- Capped at "99+". With a mark of 0, the dot.
- A row is counted again when its `last_active` or its mark moves, at most every 2 s, and not while
  its turn runs (its row moves with every heartbeat; it's counted when the activity line ends). The
  rows are built and counted off the main actor. Counts are
  cached per gateway on the device (`inbox.<gateway>` in `UserDefaults`: ids, times and counts,
  never message text), so the list draws them at once on launch.
- A running turn shows no count until it ends (the activity line says what's happening).

### Muting

The gateway has no mute; it's on the device (`MuteList`), per gateway: For 1 Hour, For 8 Hours,
For 1 Week, Until I Turn It Back On. A swipe mutes until turned back on.

- A muted chat keeps a grey count and shows the slashed bell; it's left out of the back button's count,
  the mode switch and the app icon badge.
- The mutes are shared with the Notification Service (`PushShared.setMutes`, under the chat's key
  and its live session id). It delivers a muted chat's notices quietly (`interruptionLevel =
  .passive`, no sound). Approvals, questions, keys and mentions in group chats still alert
  (`PushNotice.quietWhenMuted`). See `docs/notifications.md`.
- Not done: syncing mutes between devices (`NSUbiquitousKeyValueStore` would need the iCloud
  key-value entitlement on every App ID).

### What this device remembers

Per chat: the last row it showed (`seenThrough`, for the New Messages line next time) and, when a
chat was left scrolled up, the row at the top (it opens there next time unless there's something
new). Each row's last message (`LastLineBook`): Hermes' list rows carry the first message, so
the app reads the last one itself and keeps it on the device (`LastLinesCache`, in Caches with the
transcripts), with the time it was written and the chat activity it was read at. A launch shows
them before the gateway answers; a line kept without its time is read again once. The list
itself is kept the same way and its first screenful is in the window's first frame, the rest
right after it ([connecting-and-voice.md](connecting-and-voice.md) §8).

- **The chats the app follows** (open, or opened this launch): the line follows the chat as it
  changes, the reply that just ended included, before Hermes stores it (`rowLastLine`: the rows,
  then the message on its way and the finished turn). It moves when the turn ends or the rows
  reload, not on each word. It stands for now while something isn't stored yet, else for its
  newest row's time, so the copy kept on the device never puts back an older line.
- **The others**: when a row's activity (the list's `last_active`, a Bot's chat's) moves past
  the activity its line was read at, by more than a second, the chat's newest 8 rows are read
  again: the Bots and the 20 newest chats as soon as the lists move, rows further down as they
  come on screen, 4 reads at a time (1 while the Mac is busy), once per activity. A chat in a
  turn shows its activity line and is read when it stops.
- **Group chats**, open or not, opened this launch or never: when a room's `latest_seq` moves, the
  list refresh reads its log's tail for the newest message, a member's or the person's
  (`RoomRowLine`, [bots-groups-skills.md](bots-groups-skills.md) §2); an open room's poll hands
  over what it read. Presence, rounds, settling and renames move `updated_at` but not the line or
  its time.
- A line read at an earlier activity never replaces one read at a later activity: reads come
  back in any order, and one asked for before the reply landed mustn't bring back the message.

## 2. The rows

On iPhone at a compact width the list is the Chat tab's own screen and its rows are drawn by
`IOSChatRow` (§10). The table below is the split view's sidebar, on iPad and the Mac and in a wide
iPad window.

Two lines: 62 pt on iPhone and iPad, 46 pt on the Mac with 13 pt type (`InboxMetrics`).

| State | Line 1 | Line 2 | Trailing |
|---|---|---|---|
| Read | Title, time grey | Last message ("You:" or a Bot's name before it) | – |
| Unread | Title semibold, time primary | Last message, brighter | Ink count |
| Marked unread | Semibold | Last message | Ink dot |
| Muted | Title, slashed bell, time | Last message | Grey count |
| Live | Still ink dot, semibold title | The activity line, shimmering | – |
| Needs you | Semibold | Orange hand + what it needs | Orange hand badge |
| Draft | Title | **Draft:** then the draft (a chat or Bot Chat opened this launch, `RowDraft`) | – |
| Failed | Title | Red triangle + "Stopped: …" until opened | – |
| Mention (group chat) | Semibold | Last message or who's working | @ badge, then the count |

- In Chats mode the list is an inbox of regions (§2a); within Main, by each row's time or the
  moment it came back, newest first; no date sections. Bots mode: pinned first, then by time
  (`RowTime.ordered`).
- **A row's time is its last line's message** (`RowTime`): the newest message a person or a Bot
  wrote (a reply: when it ended), the same one line 2 shows. It's also what the row sorts by, in
  the chats, the Bots and group chats (their log's newest message), and a search result takes its
  chat's row's ([search.md](search.md) §2). Hermes'
  `last_active` moves for more than messages, so it only stands in until the line is read:
  - it's the newer of the turn heartbeat (`last_activity_at`, stamped about once a minute by any
    turn: API calls, tools, compaction, retries) and the newest stored row of any kind, a
    compaction's summary and tool rows included (`hermes_state_common._sql_session_last_active`);
  - a Bot's `canonical_session.last_active` is its tip's heartbeat alone, and a compaction starts a
    new tip, so it moves too;
  - a Bot's `last_session` is the profile's newest session of any kind but workers, so a routine's
    run in a session of its own (`source='cron'`, also when it delivers nothing) moves the Bot's
    `last_active` without a word in its chat.

  Opening, reading, resuming or re-attaching a chat moves nothing, nor do notices ("Background
  process finished"), tool steps, titles or compaction summaries. While a turn runs in the chat the
  row stands at its activity (so it rises), and when the reply ends it settles at the reply's time.
  A row with no messages uses its creation time (a Bot's `created`). A chat opened from elsewhere
  before the list has it (the Board, a task's run) has no time until its line is read.
- The time reads "now", "2 min", "14:21", "Yesterday", "Thu", "12 Oct", "12 Oct 2025"
  (`InboxTime`), in the system's calendar and time zone, the same on every device. It redraws only
  when its words change (`InboxTime.nextChange`): each minute in the first hour, then at midnight,
  so an idle list wakes nothing.
- Bot rows (`BotInboxRow`) have the face at 44 pt (32 on the Mac) in the mood of what it's doing
  (`ActivityLine.faceMood`, `docs/bot-faces.md` §5.9). Group rows (`GroupInboxRow`) stack the
  members' faces with whoever is working in front.
- Line 2 is one line, cut at the tail.
- Only the open chat's row hides what's new (`BadgeScope.rowBadge`): it's read as it's shown. A
  chat backed out of on iPhone (or an iPad window as narrow) stays selected under the list but
  isn't open, so its row shows its count, its @ and its draft, a Bot's and a group chat's too.

### The activity line

One line per chat (`LiveActivity`), the same words on the row, the jump pill and the Live
Activity's first state.

| Source | Line |
|---|---|
| `session.active_list` status `starting` | "Starting…", shimmering |
| `working`, preview still the prompt | "Thinking…", shimmering |
| This device's message waits for the gateway, away or busy (`ConversationModel.deliveryNote`, [chat.md](chat.md) §4) | Clock + "Waiting for <Mac>…", still: nothing works on it yet, and the Bot's face rests |
| `working`, preview moved on | Writing: “the newest ~40 characters” |
| A tool running (chats the app is attached to) | The tool's glyph and what it does ("Running swift test"), with the plan's progress ("· 2 of 3") |
| Helpers running (`subagent.*`, attached chats) | "3 helpers working" |
| `waiting`, or an approval, question or key in an attached chat | Orange hand + "Waiting for your approval" / "Has a question" / "Needs a key" |
| The last turn failed (an attached chat's error, or a `failed_turn` row seen while counting) | Red triangle + "Stopped: …" until opened |
| A Bot answering another Bot (Hermes's one-shot `hermes -p <bot> chat`, not in `session.active_list`; read from its Bot Chat's stored rows, `BotRoster.runningElsewhere`) | The open call's glyph and what it does ("Running a command"), else "Thinking…" ([chat.md](chat.md), a turn going on elsewhere) |

- `session.active_list` lists the live sessions in the dashboard's gateway process (Bot Chats,
  chats run over Bot Mode, Hermes Desktop). Turns run on the API server (`/v1/runs`) by other
  devices don't appear; this device's own runs come from the chat itself. It's asked every 5 s
  while a list is on screen and 0.5 s after a `sessions.changed` tick (see below). One answer
  serves every list on screen (`ProjectsModel.activeSessions`, all that's left of projects here: a
  request under way is joined, an answer under 2 s old reused). A Mac app behind other apps asks
  every 30 s and not on changes (its list never leaves the screen, and the dashboard is often the
  busy process on that Mac); coming to the front asks at once. Hermes' `preview` is the prompt
  until the first words, then the reply; `ActivityTracker` tells them apart by watching it move.
- There is no `tool.progress` event and no step counts in Hermes' events: "212 of 240" isn't
  available; the plan's progress is.
- Attached chats update at most 4 times a second.
- Without Bot Mode the chat list is fetched again every 15 s while it's on screen.

## 2a. The inbox's regions (this fork)

Chats mode is a GTD inbox after t3code's sidebar: chats move between regions by themselves and
come back to the top of Main only when they need the person. One List, top to bottom:

1. **Pinned**: pinned chats that aren't running or settled.
2. **Main**: everything idle, finished, stopped or waiting on the person (an approval, a question, a
   key). Sorted by the later of the row's time and the moment it **came back** (below), newest
   first.
3. **Working**: chats with a turn running, sending included, pinned ones too (they keep their pin
   mark). Sorted by how long each has been working, longest turn first: a chat takes its place the
   moment it starts working and keeps it until the turn ends, so a streamed reply or a tool call
   never moves a row — the one that just started goes to the bottom. The region, header included,
   is absent while nothing runs. It folds with its header ("Working 2 ⌄"), open by default, kept
   on the device (`inbox.workingExpanded`).
4. **Settled**: chats the person marked finished, which Hermes keeps as `archived`. Folded by
   default, the header shows how many there are ("Settled 73 ›"); open, ten slim rows, then "Show
   25 more" at a time. Kept per gateway (`inbox.settledExpanded.<gateway>`). Absent while
   nothing is settled.

The rules are one function (`InboxSections.region`), in this order: settled (`archived`) wins;
then waiting on the person goes to Main (never Working); then running goes to Working; then pinned
goes to Pinned; the rest is Main. Counts, ⌥⌘↓ Next Unread, Mark All as Read and the list all read
the same result (`BotWorkspace.inboxSections`): Pinned, Main, then Working.

**Coming back to the top** (`InboxReturns`): the app records the moment it sees a chat start
waiting on the person or stop with an error (at once), or finish (after 2 s, so a turn that pauses
between tools doesn't bounce out of Working and back). Un-settling a chat counts too. The first
look at a gateway's chats is only a baseline: what already waits when the app opens returns
nothing by itself. The times are kept per gateway on the device (`inboxReturns.<gateway>`), only
for chats still listed, so a cold launch keeps Main's order.

**What it reads**: the regions are built in one pass and cached against the list's revision, two
sets from `LiveActivity` (`inbox.live`, `inbox.needsYou`), which change only when a chat starts,
stops or starts waiting (never with each streamed word, unlike `lines`), the return times,
Working's start times (`workingSince`: the moment each chat entered Working; the first look at a
gateway seeds the chats already running at their own last activity, the prompt behind the turn),
the last lines' revision and the filter. It never reads the selection, and row times read the live
set instead of each chat's line. The first frame still lists 40 rows (`ChatListSnapshot`); Working
and Settled come after them, and older pages load at the very end, below Settled.

**Settled's rows** come from the Dashboard backend only: `GET /api/sessions?archived=only&order=recent`
with `limit`/`offset`, which answers `total` (`BackendClient.archivedSessions`, `SettledChats`);
while the list holds every profile's chats, from `GET /api/profiles/sessions?archived=only` under
the Profile filter's choice (§9).
Folded, the app asks for the count alone (`limit=1`, after each list refresh) and keeps no rows;
open, pages carry a generation, so a refresh and a page on its way can't interleave
(`SettledList`). Hermes back-fills pinned chats into every page across the archived filter (its
pinned query doesn't inherit it), in both lists, so the app keeps only rows whose own `archived`
says which side they're on, and a back-filled pin shows once. Without Bot Mode's backend there is
no Settled region; Settle still archives, and search finds the chat. A settled chat whose
`last_active` moved past the newest one the person saw lights a dot on the folded header (never an
unread count); opening the region clears it.

**Working's limits**: Working knows what this device runs and what `session.active_list` lists
(Bot Mode, the gateway process's own sessions). Without Bot Mode only this device's turns show; a
`hermes chat` in a terminal, a scheduled run, or another device's `/v1/runs` turn don't, until
their reply lands and the row moves by its time. Telegram and Discord turns show when Hermes lists
them in `session.active_list` (not checked against a real gateway).

## 3. Motion

Quiet and quick; with Reduce Motion only cross-fades. Only one thing moves in a row: the activity
line's shimmer (`ShimmerText`, [chat.md](chat.md) §4a); waiting for you and stopped are solid and
still. Decorative loops hold still when the window is behind, off screen and in Low Power Mode
(`pausesDecorativeMotion`). The shimmer is a Core Animation layer (`ShimmerLayer`): with a Bot
working and the list on screen the app's CPU went from about 8% of a core to 1%. Its moving part
exists only while it moves (`DecorativeLoop`):
a `repeatForever` doesn't stop when its value is set back without an animation, and a pulsing dot
in a list row hidden for reuse kept a Mac core at 100% with the window in the back. A hidden row gets
no `onDisappear`, so the Mac sidebar starts a new list when it swaps its rows (mode, filter,
search).

| Element | Motion |
|---|---|
| Count appears / changes | Scale 0.6 → 1 (spring 0.3 / 0.7), digits roll (`.numericText`) |
| Live dot | Still: an ink dot in a soft halo |
| Activity shimmer | A soft `thinking-shimmer` band, the words' full ink, crosses them at a steady pace every 1.6 s, then rests ([chat.md](chat.md) §4a) |
| Activity text | Cross-fades when the chat does something else (thinking, a step, writing); a reply's newest words, at most 4 updates a second, switch in place. Cross-faded, a streaming chat's row was always mid-fade, and on the Mac that fade is drawn on the CPU: about a third of the app's main-thread time while an essay streamed (`ActivityLine.fadeKey`) |
| Rows | Spring to the top (0.4 / 0.85) |
| New Messages line | Fades in with the chat, out (0.3 s) |
| Jump pill | Rises 12 pt with scale 0.9 → 1; its content morphs |
| The live line before the first words | Fades in with the turn header; its words cross-fade into the running step, then "Worked for …" |
| Haptics | A tick when messages arrive below (never as they're seen), a light impact on a jump |
| Sounds | Off; Settings → Chat → Sounds plays soft sent and received sounds |

## 4. In the chat

### Opening a chat

- On iPhone the chat list is the first screen and a chat opens on top of it. A launch comes back
  where the window was, the way the system restores apps: a chat that was open is open again,
  already pushed, with the back button to the list; a window that was back on the list opens on
  the list, its last chat selected under it but not open (`BotWorkspace.openAtLaunch`).
- A chat deleted while it's open, or a Bot removed while its chat is open, goes back to the list
  rather than leave an empty screen (`CompactNavigation.dismiss`). A chat settled while it's open
  gives way to the next one in Main (§5 Settle).
- Just before a chat opens (`BotWorkspace.selection` `willSet`), the store notes how far it was
  read (`UnreadStore.noteOpening`). Opening isn't reading: what's been on screen is (below).
- Something new: the transcript finds the New Messages line (`NewMessagesMarker`): above the head
  of the first new turn (the message that started it, when that's new too), or the first new Bot
  message. A chat left half-way resumes after the last row this device showed.
- It opens with the line a quarter of the way down; when everything new fits on screen, at the
  end with the line in view. If the rows on the device stop short, it waits up to 1.2 s for the
  gateway's.
- Settings → Chat → Open chats at: First Unread (default) or Latest (the line is still drawn).
- Settings → Chat → Keep chat at bottom when sending: off (default), sending turns the page; on,
  the message you send stays at the bottom and the reply fills in below it (`docs/chat.md` §4).
- The line stays until the chat closes, and never appears for messages that arrive while it's
  open.
- Nothing new: where it was left scrolled up, else at the end.

### Marking read

- Read follows what's been on screen. On the gateway when the newest message has been on screen
  for a second, or on a jump to the end (`TranscriptView.markRead`): chats and Bot Chats alike,
  also while a Bot works on screen (at most every 10 s, `ReadThrottle`, the last carrying what came
  meanwhile). Opening a chat at its newest message reads it all at once; opening it partway up
  reads nothing until you reach the end.
- Only where someone can be reading: the app in front, on the Mac the window in front
  (`controlActiveState`) with the screen unlocked and awake (`ScreenLock`). A window behind
  another, a locked Mac and notification previews never mark anything read.
- Only the open chat (`BadgeScope.readsAsShown`). On iPhone, a chat you went back from stays
  selected under the list, its transcript still there, but what comes in then isn't seen: its row
  shows it (§2) until you open the chat again.
- Scrolled up with new messages below, the chat stays unread: Hermes' mark only means "read until
  now" (it stamps the time it lands, there's no "read up to this message"). This device remembers
  how far it got; the jump pill offers what's new below.
- A mark that doesn't reach the gateway (busy, offline) waits in the read outbox (`ReadOutbox`,
  kept on the device) and goes when it answers, after 5 s, 15 s, 45 s, up to every 5 minutes;
  marks only move forward, and a waiting mark is dropped once new messages came into its chat
  (sending it then would mark them read unseen).
- Mark as Unread (menu, swipe, ⇧⌘U); opening the chat clears it.

### The jump pill

A glass capsule 12 pt above the composer, shown once you scroll up (`JumpPillView`), while it
fits between the bars: a "/" or "@" menu that takes that room hides it ([composer.md](composer.md) §1).

| Below | Pill | Tap |
|---|---|---|
| Nothing new | The round arrow | To the end |
| A turn running | "Hermes is writing…" or the running step, shimmering | To the end, following |
| New messages | ↓ "2 new messages" | To the first (a quarter down), then to the end, following |
| A mention (group chats) | Face + @ + "Ada mentioned you" | To the mention |
| A Bot chat | The Bot's face leads | As above |

Mentions come first, then new messages, then the running turn (`JumpPill.choose`).

What counts is every message below where you got to (`NewMessagesBelow`), in the chat's order:

- Leaving the end, what's there is seen. From then on, every message that lands below counts,
  however many come in one update (a chat read again while another Hermes process held it) and
  in whatever order their replies end. A reply still running isn't seen while it runs: it counts
  once it ends, wherever its stored copy lands (above messages that came in while it ran, too),
  unless it's on screen then.
- Messages count as seen as they come on screen (`onScrollTargetVisibilityChange`), with
  everything above them, so the count only goes down as you read. Scrolling back up doesn't
  count them again.
- Where you got to is kept by the row and its neighbours, so a reply settling into the stored one
  or a reload under new ids neither counts it again nor counts the whole chat.
- The first tap goes to the first new message and the next to the end. Messages that arrive
  after the first tap, or scrolling back up above where it went, start over at the first new
  message.
- The tick sounds once per update that brings messages, never as they're seen or as rows change
  identity. Group chats count their members' messages the same way.

### Before the first words

Every chat, a Bot's included, shows the turn header's live line ("Thinking…", shimmering) from the
moment the message goes until the reply's first words. No typing bubble, no dots, no face in the
transcript. The Bot Chat's toolbar face looks up; its subtitle keeps the handle. Group chats name
who's thinking (`BotThinkingLine`): the Bot's face thinking, without dots, and "Ada is thinking…"
shimmering, one line per Bot, at most two, then "+1 more" (`RoomTranscript.thinkingMembers`).
[chat.md](chat.md) §4a has the rules.

### Reply with a quote

- **Start:** the message menu's Reply (on replies and your messages), Reply to Words… (a sheet
  where you select the words), or a swipe left on a message. Replies with code blocks or tables
  scroll sideways themselves, so they take Reply from the menu.
  - On the Mac, words selected in a finished reply quote in one step (`selectionReplyButton`).
    Reply floats 6 points under the selection's end, kept inside the reply's column, or 6 points
    above its first line when below would reach the composer or the chat's faded edges
    (`QuotedReply.SelectionPlacement`). It shows once the drag that selects ends, and steps aside
    while the selection is empty or only spaces, while the chat scrolls, while a reply streams and
    while the selection's menu is open. The selection's own menu puts Reply above the system's
    items (macOS may still add Ask Siri at the very top), and Chat → Reply to Selection (⇧⌘R)
    does the same from the keyboard; it is dimmed when no words in a finished reply are selected.
    Reply clears the selection and puts the cursor in the composer. Right-click outside the
    selection still opens the message menu. Reply to Words… stays, for picking words from the
    whole reply.
  - On iPhone and iPad, words selected in a finished reply quote in one step too. A long press on
    the words selects them in place ([chat.md](chat.md) §3), and Reply comes first in the edit
    menu, before Copy and the system's items, for a selection that isn't only spaces. Reply quotes
    the selected words from that reply, clears the selection and puts the cursor in the composer;
    selecting more and choosing Reply again adds another quote, up to three. A streaming reply and
    your own messages aren't selectable in place: their long press opens the message menu, as a
    long press off the words does (a code block, a table, an image, the margin) and as "…" and
    VoiceOver's actions do. Select Text and Reply to Words… stay in that menu.
  - On iPhone and iPad the swipe is a UIKit pan that begins only on a drag to the left
    (`SidewaysSwipe`): a SwiftUI drag on each reply took the chat's vertical drags, and the chat
    stopped scrolling under a finger that started on a reply. A drag to the right from the
    screen's edge stays the system's back swipe. The message follows the finger from where it
    touched down (`SidewaysSwipe.travel`), so it replies when let go 64 points to the left of
    there, and a shorter swipe springs back.
  - On the Mac a mouse drag to the left does it, and so does a sideways scroll: a trackpad's or a
    Magic Mouse's swipe, or a mouse that scrolls sideways (`SidewaysScroll`). SwiftUI has no
    scroll-wheel events, so the message reads them from the window before the chat does. A scroll
    that starts up or down stays the chat's, and one that starts over something scrolling sideways
    inside the message (a widget's strip of hours, a wide table) stays that one's.
- **Composing:** the reply bar ("Replying to Hermes", the quote, ✕) sits in the composer and the
  passage flashes where it is. Quoting never scrolls the chat to the passage (`QuotedReply.Flash`):
  the chat counts a row as visible only once 40% of it shows, so a tall reply read near its top
  would otherwise count as off screen. At the end of the chat, the bar's own height lifts the last
  lines by that much.
- **Several quotes:** each Reply adds a passage to the bar, up to three, in the order they were
  picked (`QuotedReply.Draft`, `replyQuotes`). The same passage of the same message is added once
  (it flashes again). Two or three show under "Replying with N quotes", each with its own ✕; on a
  short iPhone screen the list stops at 120 points and scrolls, and iPhone landscape with the
  keyboard up shows only the head. With three in the bar, Reply adds nothing and the bar says "You
  can quote up to 3 passages. Remove one to add another." (`replyQuotesLimit`) until one is
  removed. The bar says the same when a draft set aside to edit a queued message comes back to a
  bar with no room for all its quotes.
- **Sent:** each quote as its own `> quote` lines, in order, each followed by a blank line, then
  your words (`QuotedReply`, at most 280 characters per quote). Quotes go only with words of
  your own: without them they stay in the bar. Every way a message goes takes the bar's quotes
  and empties it: Send, and while Hermes works Steer, Redirect, Send Next, Ask Aside and Run in
  Background, and a queued message edited and sent again ([follow-ups.md](follow-ups.md) §1).
  Hermes needs nothing new.
- **Shown:** leading block quotes are drawn as quote blocks (`QuotedBlock`), one per quote, never
  as ">". Up to three leading block quotes separated by blank lines are read as quotes, so a
  message whose own words open with a block quote shows it as one more quote block. This device remembers each quote's author and row by a hash of the quote
  (`QuoteMemory`); tapping one goes back to its passage. Elsewhere the quotes show without an
  author.

### Mac

⌘↓ Jump to Latest, ⌥⌘↓ / ⌥⌘↑ Next / Previous Unread Chat, ⇧⌘U Mark as Read / Unread, ⇧⌘R Reply to
Selection (Chat menu).
The design also gives ⌥⌘↓ to "next mention"; in group chats the mention pill does that.

## 5. Lists: filters, menus, swipes, counts

- **Filter** (Chats mode, this fork): one filter button (`InboxFilterButton`) with a menu
  (`InboxFilterMenuContent`), kept per gateway on the device (`InboxScope`, `inboxScope.<gateway>`):
  - **Sources**, by the session's `source` (`InboxSourceGroup`): This App (no source,
    `api_server`, `desktop`, `hermes_app`), Telegram, Discord, Terminal (`cli`, `tui`), Editor
    (`acp`), Scheduled (`cron`) and Other Platforms (the rest: `kanban`, Slack…). All on but
    Scheduled: scheduled runs aren't chats (`ScheduledRuns`); runs with output show when
    Scheduled is on, and with their task in Tasks ([tasks.md](tasks.md) §5).
  - **Only Unread n, Only Needs You n**: they narrow Main only; Pinned, Working and Settled stay.
    Both on shows either.
  - **Hide Empty Chats**, on by default: a chat with no messages (opened, never used) stays out,
    unless it's pinned or a turn runs in it (a new chat has none stored until its first lands).
  - Mark All as Read, and Show Everything when anything differs from the standard filter.

  On iPhone the button leads the root's bottom toolbar, on iPad it sits in the sidebar's toolbar,
  on the Mac in the source list's titlebar and as View ▸ Filter. A filter that differs from the
  standard one fills the button and puts "Filtered: No Telegram · Unread ✕" at the top of the
  list; ✕ shows everything again. Older pages load while the end of the list is on screen, unless
  Unread or Needs You narrows it. Settled isn't narrowed by them: its count is Hermes' (the
  Profile filter does hold it, §9). Search finds every
  chat whatever the filter, scheduled runs only under its Tasks filter ([search.md](search.md) §1).
  Upstream's Show and Only (`InboxShow`) stay in HermesKit for its other readers.
- **Profile** (this fork, while the list holds every profile's chats, §9): All Profiles, or one
  profile from the rows, the gateway's own first. It holds every region, Settled included; Main
  filters on the device (`InboxScope.holds`), Settled asks the backend for that profile's page
  (`SettledChats`). The choice is kept with the filter and waits while Bot Mode is away
  (`InboxScope.withoutProfile`).
- **Empty lists** (`CaughtUpState`): Unread or Needs You with nothing left shows "You're all caught
  up" or "Nothing needs you"; sources that hold no chat, once every page is in, "No chats from
  these sources". A gateway with no chats at all shows "No chats yet" instead.
- **Mark All as Read** at the end of the Unread list and in the filter menu: every badge clears at
  once, and the gateway hears of them 4 calls at a time. A mark this device set holds over the
  gateway's until its call is back and 10 s more (or the gateway agrees), so a busy Mac's list
  read meanwhile doesn't bring a badge back.
- **Swipes:** from the leading edge Read / Unread (the main one) and Pin; from the trailing edge
  Settle (a full swipe settles) and Mute; a settled row's trailing swipe is Un-settle. Every list
  is a `List` and uses the system's swipe actions, on iPhone as on iPad and the Mac. The system
  draws their symbols white on the tint in both modes, so the main action is ink in Light Mode and
  a raised grey in Dark Mode (`Theme.swipeAction`; white ink hid its envelope), the others a
  quieter grey (`Theme.swipeActionQuiet`).
- **Settle / Un-settle** (this fork's Archive): `PATCH /api/sessions/{id} {archived: true|false}`
  (the same as `session.archive`). The row goes to the top of Settled at once and "Settled “…”
  Undo" shows for 5 s; Undo (or Un-settle) brings it back to the top of Main at once and sends its
  call after the settle's, never alongside it. Settling the chat that's open opens the next one in
  Main, else the one above it, else nothing (on iPhone, settled from the list, the list stays).
  Sending in a settled chat un-settles it first, without holding up the send; activity elsewhere
  doesn't, it lights Settled's dot instead (§2a). A settled chat opened from search, a
  notification or a link stays settled: it shows in Settled while it's open, even folded, and
  never in Main. On iPad and the Mac, Chat ▸ Settle Chat (⇧⌘S) settles or un-settles the open
  chat.
- **Menus:** Mark as Read / Unread, Pin, Mute ▸ first, then Rename…, Branch, Checkpoints…, Copy
  Session ID, Settle, Delete…; a settled row: Un-settle, Rename…, Copy Session ID, Delete…. Bot
  menus: Mark as Read / Unread, Pin, Mute ▸, then Edit Bot…, Routines…, Hide, Copy @handle.
- **Counts outside the list:**
  - iPhone's back button, over a pushed chat: unread chats (not messages) elsewhere, muted and
    open ones left out (`UnreadStore.unreadElsewhere`). Without any it shows the chevron alone.
    The system's sidebar button on iPad and the Mac has no count, as in Mail: the sidebar it
    opens shows them.
  - Chats / Bots: each segment shows the other mode's unread count: unread chats again, not
    messages, with the same rows left out. Bots and group chats count on Bots, every other chat on
    Chats (`BadgeScope.isBotsRow`).
  - A group chat's row: its members' messages since this device last read it (§1). A hidden Bot's
    news shows on its own row under "Hidden · N" and counts nowhere else (`BadgeScope`).
  - App icon and Dock: Settings → Notifications → App Icon Badge (Dock Badge on the Mac): Unread
    Chats (the default: open requests plus unread, unmuted chats, Bots and group chats) or Needs
    You (the requests only). One list of the chats it counts per gateway, in the App Group: the
    app writes it whenever its counts move, the Notification Service adds a chat as its news
    arrives, and reads anywhere take chats off; while the app is away, the push plugin sends a
    badge-only push when the number changes ([notifications.md](notifications.md) §2 Reading,
    Badge). Woken in the background, the app reads Hermes' marks with the chats before it counts
    again (`UnreadStore.catchUpMarks`), so a chat read on another device while it slept stays off.
    Set with `UNUserNotificationCenter.setBadgeCount` and `NSApp.dockTile.badgeLabel`.

### Paging

The list loads 40 rows first, then a page at a time while the end is on screen
(`BotWorkspace.listPaging`, `ChatListPaging`). The end is a row below Settled that draws nothing,
on iPhone, iPad and Mac alike. A refresh reads at most 200 chats, so on a longer list that row
comes back after each one; nothing stands below Settled meanwhile, and the next page loads when the
end comes on screen all the same. A refresh starts a new generation: a page asked for before it
lands on nothing, so its rows, read against the old list, can't come back after the fresh ones.
Every profile's list (§9) pages the same way, through the merged order: Hermes reads each profile's
newest rows and merges them, so the app asks for `limit + offset` per profile
(`BackendClient.profileSessions` over-fetches, capped at 400) and pages by the merged offset.
Settled pages on its own (`SettledList`, §2a), with the same generation rule, and shows its own
loading rows while it's open and loading.

## 6. Accessibility

- Rows read "Release notes for 1.3, 3 unread, 14:21, 23 merged PRs"; live "…, Hermes: Running
  swift test"; muted "…, muted, 12 unread"; needs you "…, waiting for your approval".
- Rows have custom actions: Mark as Read / Unread, Pin / Unpin, Mute / Unmute, Settle; settled
  rows Un-settle. Region headers are headers, with their count and Expanded / Collapsed.
- VoiceOver stays where the person put it while replies arrive: on a row of the list, and on a
  message in the open chat. A reply changes a row's words and moves it up, but never takes the
  focus with it (`VoiceOverFocusUITests`, against the mock's "slow marathon" turn).
- The New Messages line is a header; an "Unread" rotor goes between it and the new messages.
- The pill is a button that says where it goes: "2 new messages. Jump to the first one.", after
  the first tap "2 new messages. Jump to the latest.", for one message "1 new message. Jump to
  it.". The count rolls to its new value; with Reduce Motion it just changes.
- The open chat's activity line is announced at most every 10 s, never the words as they stream.
- With one quote the reply bar reads "Replying to Hermes", then the passage, and its ✕ reads
  "Stop replying". With two or three its head is a heading ("Replying with 2 quotes"), and each
  quote says where it sits, so the same words twice can be told apart: "Quote 2 of 3, from
  Hermes: the passage" and "Remove quote 2 of 3, from Hermes: the passage". The limit note reads
  as one line, and a Reply refused for the limit announces it. A sent bubble reads every quote in
  order, with whose it was when this device knows: "You, quoting Hermes, “the first passage” and
  “the second”: your words".
- Never colour alone: needs you has the hand, failed the triangle, muted the slashed bell, unread
  the weight and the count.
- At the accessibility text sizes on iPhone and iPad the list keeps everything and cuts nothing
  off: the Chats / Bots switcher stacks its two halves, a row's title wraps with its marks and time on the line below it, the New Chat, Tasks,
  Skills and settings glyphs grow with the text up to a cap, and the connection line wraps with
  the settings button below it. On iPhone the connection line leaves the subtitle under the large
  title, which the system cuts off, and is the list's first row instead
  ([design-to-swiftui.md](design-to-swiftui.md) §6).

## 7. Checks

Against the mock (`Tools/mock-hermes/backend.py --gateway-port 18642`, `inbox.py`; add
`--inbox-demo` for a chat that keeps writing and one waiting on an approval, `--inbox-gtd` for the
inbox's regions, `--cross-profile` for every profile's chats, §9) and a real Hermes:

- A reply that lands while you're away makes the row semibold with a count equal to the replies
  after `last_read_at` (seeded: Release prep 3, Morning briefing 1, Stand-up summary the dot).
- Reading it on one device clears it on the other within a few seconds (`sessions.changed`), and
  the reverse; Mark as Unread shows the dot on every device and opening clears it.
- A chat with unread opens at the New Messages line; reaching the end marks it read on the
  gateway (`curl` the dashboard's `GET /api/sessions/{id}?profile=default` for `last_read_at`).
- Scrolled up during a turn ("marathon"), the pill shows what Hermes is doing; when the turn ends
  it says "1 new message" and goes to it.
- Scrolled up in a Bot Chat, `POST /api/mock/message-agents` sends six messages from three Bots:
  the pill counts all six, goes to the first a quarter down, counts down as they come on screen,
  and the next tap goes to the end. In a group chat several `room-say` posts count one each.
- In a group chat, a mention shows the @ on the row and the mention pill in the chat (`POST
  /api/mock/room-say`).
- A group chat whose log ran past 200 events counts every member's message after the last one read
  (`backend.py --group-counts`, `room-say` into `release-log`: 4 on its row).
- A muted chat shows a grey count, isn't in the badges, and its pushes are quiet; approvals in it
  still alert.
- Rows move to the top when they get a message; pinned rows stay on top. Opening a day-old chat,
  compacting it (the mock's "Release notes draft" was compacted 12 minutes ago: it keeps its
  reply as the last line and its date, with no badge) or a Bot's silent routine run (Ada's "Weekly
  newsletter draft" ran 7 minutes ago) leaves its time and place alone.
- A reply in the open chat shows on its row within a second of ending, a Bot's included, and
  stays when Hermes stores it; a reply in another chat (`POST /api/mock/room-say`, a routine, a
  reply read on another device) shows on its row within a second of the list moving. A cold launch
  shows the last messages from the device before the gateway answers (`-HERMES_LAUNCH_LOG YES`:
  "kept last lines shown").
- The back button's count is the unread, unmuted chats other than the open one.
- On iPhone, open a group chat, go back to the list and `POST /api/mock/room-say` to it: within a
  minute its row shows the new messages' count (and the Bots count and the back button with it),
  as a chat's or a Bot's row does; opening it again clears it. A Bot's row (`POST /api/mock/deliver`
  with `researcher`) counts the same way, and both rows keep their counts and count on after
  `POST /api/mock/drop-sockets`, on iPhone and on iPad in portrait and landscape
  (`RowCountUITests` runs these steps).
- A group chat's row shows its newest message ("Ada: …") and that message's time, never "N Bots"
  or a frozen line, with the list on screen or another chat open, for a room left earlier and for
  one never opened (`room-say` with `reply`, [bots-groups-skills.md](bots-groups-skills.md) §4).
- Reduce Motion: no shimmer or slide. Light, dark and Increase Contrast match the renders.
- Fast flicks up and down that start on a reply's text, a message, a row or a row with its
  actions open all scroll the chat and the list; a swipe left on a reply still replies, and one
  right from the edge goes back to the list on iPhone. The message keeps under the finger from
  touch-down: let go 64 points left of it and it replies, short of that and it springs back.
- On the Mac, a sideways scroll to the left on a reply (trackpad, Magic Mouse, a mouse that
  scrolls sideways) quotes it in the composer, and a scroll up or down that starts on a reply
  scrolls the chat.
- Reply to three messages: the bar says "Replying with 3 quotes"; a fourth Reply shows the limit
  note, and ✕ on one removes only that one. Sent, the bubble shows the quotes in the order picked,
  each jumping back to its own passage. While a turn runs ("approve", "slow"), quote and send
  with each mode: the bar empties every time, and the queued row, the steer bubble, the aside and
  the background bubble carry the quotes.
- On iPhone and iPad, long press words in a finished reply: they select in place and Reply is
  first in the edit menu; choose it, select other words and choose it again, and the bar shows
  two quotes, in portrait and landscape (`SelectedWordsUITests` runs these steps). A long press on
  a code block, a table or the margin, and on a streaming reply or your own message, opens the
  message menu; a link opens with no preview.
- The inbox's regions (`backend.py --inbox-gtd`, its 2-minute cycle): "Deploy hk3 nginx" moves
  to Working when it starts, back to the top of Main the moment it waits for an approval, and
  stays at the top when it finishes; "Review my recent work" is pinned and sits in Working with
  its pin; Working's header goes when nothing runs. Settled reads "Settled 37" folded; opened, ten
  rows (and the pinned settled one Hermes back-fills), then Show 25 more until all 37 are in.
  Settle the open chat (⇧⌘S, or a full trailing swipe on iPhone): it tops Settled and the next
  chat in Main opens; Undo or Un-settle puts it back at the top of Main. Search "Router", open a
  settled result: it shows under Settled, not in Main; send in it and it leaves Settled for
  Working. The filter's Telegram off and Unread on: "Filtered: No Telegram · Unread ✕", Main only
  unread chats, Pinned and Working unchanged; ✕ shows everything. Quit and relaunch: Main keeps
  its order.
- Paging on iPhone, iPad and Mac (`backend.py --inbox-gtd --many-chats 150 --busy 4`, more chats
  than a refresh reads): scrolled to the end, nothing stands below "Settled 37" while the older
  chats load, and they still come in above Working, the last ones included. Opened, Settled still
  shows its own loading rows while it loads.
- Unit tests: `InboxTests` (counting, read marks null / 0 / time, mute expiry, the line with partial
  reads, pill priority, the messages below the pill, activity, quotes, row times and their order,
  compaction summaries, Bot faces, group mentions, last lines and the `LastLineBook`),
  `SidebarCountsTests` (a group chat's count read page by page, the segments' rows),
  `GroupRowSummaryTests` (a group chat's newest message and its time, opened or not),
  `SidewaysSwipeTests` (which drags a row's swipe takes, and `RowSwipe`'s geometry),
  `SidewaysScrollTests` (which Mac scrolls reply), `InboxSectionsTests` and `InboxReturnsTests`
  (regions, their order, returns and their grace), `SettledListTests` (Settled's paging and the
  back-fill filter), `InboxScopeTests` (sources, empty chats, the state filters, the stored
  filter), `ProfileRowsTests` (row keys, colliding ids, tagging, badges, the page and its paging,
  Settled across profiles, read marks, the scope's profile filter).
- Every profile's chats (`backend.py --cross-profile`, §9): rows from researcher, writer and ops
  beside the gateway's own, each with its profile badge and its repository's name where it ran in
  one; the shared id shows as two rows. Profile → writer holds only writer's rows in every region,
  Settled included; All Profiles brings the rest back. Rename, pin, settle and delete a writer row:
  the calls carry `profile=writer` and the other profile's row with the same id stays. Quit Bot
  Mode: the list is the gateway's own again, no badges, no Profile filter, and reconnecting brings
  them back.

## 8. Setup

Read marks shared between devices and Bots' unread need Bot Mode ([setup.md](setup.md) §4.1);
unread that arrives while the app is closed needs notifications and the push plugin (§4.13).

## 9. Every profile's chats (this fork)

While Bot Mode is connected, the list holds every profile's chats, not only the gateway's own
(`BotWorkspace.listsEveryProfile`): one gateway record, one list, whichever profile a chat ran in.

- **The list** comes from the backend: `GET /api/profiles/sessions?profile=all&order=recent`
  with `archived=exclude|only`, `limit`/`offset` (`BackendClient.profileSessions`). Hermes reads
  each profile's newest rows, merges them by `last_active` and pages the merged order (§5 Paging);
  each profile's pins are back-filled across the archived filter, so the app keeps rows by their
  own `archived`, as with the gateway's own list (§2a). Rows carry `profile`, `is_default_profile`
  and `git_repo_root`. The regions, read marks and Working are as everywhere else: Working still
  reads `LiveActivity`'s sets, never a row's `is_active`.
- **Row keys** (`ProfileRowKey`): the gateway's own chats keep their lineage id, so what this
  device kept for them (unread marks, cached transcripts, drafts) carries over untouched; another
  profile's take `p:<profile>:<lineage id>`, so two profiles' chats with one id never share a row.
  The list, the selection, the open chats, unread, the transcript cache and notices all key chats
  by `HermesSession.stableID`. A chat known only by its key (a restored selection, a notice) opens
  as `HermesSession.placeholder(forKey:)`.
- **Badges**: every row says whose it is, by the time (`RowProfileMark`): "money", or
  "paimon · hermesapp" when it ran in a repository (`git_repo_root`'s folder name,
  `HermesSession.projectName`; none when it ran in no repository). VoiceOver reads the mark with
  the row.
- **The filter** has Profile (§5): All Profiles by default, one profile at a time, held in
  `InboxScope.profile` and applied to every region, Settled included (its pages ask the backend
  for that profile).
- **Row actions** go to the backend under the row's profile while Bot Mode is connected:
  rename, pin, settle and delete as `PATCH`/`DELETE /api/sessions/{id}?profile=<name>`
  (`BackendClient.editSession` with its mutation snapshot, one retry on a conflict;
  `deleteSession`). Branching another profile's chat is `session.branch` with its stored id,
  `profile` and an idempotency key, so a retry lands one branch (`BotWorkspace.fork`).
- **Reading**: an aggregated row's badge reads Hermes' `last_read_at` like any row (§1); marking
  read goes through the same mutation-snapshot call under the row's profile.
- **Opening a row** runs it in its own profile: the chat reads its history from that profile's
  store (`messages?profile=<name>`, `ConversationModel.fetchPage`) and every gateway call that
  names a profile — resume, create, slash commands, path completion, audio, the in-app browser —
  takes the row's (`ConversationModel.gatewayProfile`, read from the row key, so a list refresh
  can't dirty what observes it). The turn itself, steering and approvals ride the runtime the
  resume minted, which Hermes already binds to that profile. Two profiles' chats with one id
  resume as two runtimes: the profile names whose chat opens.
- **New Chat** picks its profile (`NewChatProfileButton` beside the model picker, only while the
  chat has no session and the list holds every profile's chats): the roster's profiles with the
  gateway's own first, the last choice remembered per gateway on this device
  (`BotWorkspace.rememberNewChatProfile`). The create, the first prompt and the chat's history all
  run in the chosen profile (`ConversationModel.newChatProfile` feeds `gatewayProfile` until
  Hermes makes the chat), and the new row takes that profile's key and badge. The profile is
  captured before `session.create` is sent and reused when its answer becomes a stored row;
  neither assigning the session id nor changing the picker while the request is in flight can
  change whose chat was created. A waiting first message keeps its profile too, so a relaunch
  resumes under the same key. Bot Mode not connected,
  New Chat is as it always was: the gateway's own profile, no picker.
- **New Chat asks for the profile first** (this fork): while the list holds every profile's
  chats and Bot Mode lists more than one, the compose button (the tab bar's prominent tab, or
  the floating circle on iOS 26) opens a popover of profiles, laid out like the Bot tab's New
  menu (`IOSComposeButton.newChatActions`, `IOSMenuRows`). The chat starts in the picked profile
  (`BotWorkspace.startNewChat(in:)`) before it opens. The rows are ordered least used to most
  used by chats in the list, so the most used sits last, nearest the thumb under a menu opening
  upward; ties put the roster's earlier profiles lower, the gateway's own first
  (`ProfileRows.newChatMenuOrder`). The chat screen's own pencil (top, opening downward) offers
  the same profiles turned round, most used next to it. With one profile, or without Bot Mode,
  New Chat starts at once as before. The picker beside the model stays for changing a draft's
  profile after it opened.
- **Models follow the profile**: profiles have their own providers and defaults, so a chat in
  another profile reads that profile's list over the gateway (`model.options` with `profile`,
  `BotWorkspace.loadModelOptions(for:)`), kept per connection; the gateway's own profile keeps
  `GET /api/model/options`. The title, the model picker, `/model`, Try Again's suggestions and
  model following all read the chat's list (`ConversationModel.modelOptions`), and the picker's
  first row reads "Profile default" there. A model choice is remembered per profile
  (`BotWorkspace.preferredModel(for:)`), and changing a new chat's profile takes that profile's
  choice or its default, so a model only one profile's providers serve never rides into another.
- **Fallbacks**: Bot Mode not connected, the list is the gateway API's own profile's chats, as it
  always was: no badges, no Profile filter (the kept choice waits, `InboxScope.withoutProfile`),
  and the device's marks for other profiles' rows are dropped (`UnreadStore.forgetProfiled`). A
  Hermes without the endpoint answers 404; the app falls back the same way, silently, and doesn't
  ask again while that connection lives (`profilesRouteMissing`).
- **The mock**: `backend.py --cross-profile` seeds researcher, writer and ops chats (some in
  repositories, one settled per profile, one id shared with the gateway's own) and serves the
  endpoint; without it the endpoint answers 404 as an older Hermes does. The create transition
  also has an executable regression check, which extracts the app's Swift method and runs it:
  `python3 -m unittest discover -s Tools/mock-hermes/tests -p test_new_chat_profile.py -v`.
  It covers both cross-profile directions, home-profile controls, the main profile, a picker
  change during create, and a waiting first message restored before creation.

## 10. The iPhone's Chat tab (this fork)

At a compact width `MainView` shows `IOSMainView` instead of the split view: the system's tab bar
(`TabView` with Chats `bubble.left`, Bots `person.2` and Settings `gearshape`, no styling of its
own), which shrinks while a list scrolls down (`tabBarMinimizeBehavior(.onScrollDown)`), and a
round glass compose button beside it on the same line (from iOS 27; on iOS 26 over the
bottom-right of the Chats and Bots lists, above the bar). iPad and Mac keep the split view
unchanged. The selection still lives in `BotWorkspace`, so a notification, a search
result or a link opens the same chat here as there.

- **Chat tab** (`IOSChatList`): "Hermes" with the gateway's connection dot and name beside it, the
  search button (system glass, `magnifyingglass`), then the Profile and Sources filters as the
  system's bordered menu buttons. The list below is the same
  `workspace.inboxSections` with Pinned, Main, Working and Settled (`§2a`), and the same
  `ChatListSnapshot` first frame and paging, so a long history costs no more here than in the
  sidebar.
- **Profile** is one choice at a time (`InboxScope.profile`): All Profiles or any profile Hermes
  lists (the roster's `profiles.list`, the gateway's own first and the rest by name), chats or not;
  without a roster list (no Bot Mode, nothing read yet) the profiles the chats come from
  (`ProfileRows.filterChoices`). **Sources** toggles the source groups (`InboxScope.hiddenSources`)
  and, under Only, Unread and Needs You. A filter that narrows the list is tinted blue (`Theme.link`):
  Profile while one is picked, Sources while a group differs from the standard or Unread or Needs
  You is on (`InboxScope.sourceChanges`). Its words say the same, so the state isn't colour alone:
  "Unread", "Needs You · No Telegram", "5 sources", or "All sources" when nothing narrows it. No
  "Filtered: …" line goes above the rows in this layout; "Show Everything" stays in the Sources
  menu while anything differs from the standard. A picked profile without chats says so ("No chats
  in scout"), not that the sources hold nothing.
- **A row** (`IOSChatRow`): the profile's avatar at 44 pt on the left — its Bot's photo or drawn
  face when it has one, otherwise its initial on the name's stable colour (`ProfileMonogram`) — with
  the unread dot on its corner. The sizes are the Bots tab's (`InboxMetrics`: `.body` title,
  66 pt minimum row), so the two tabs read as one list; the small print under the title is
  `.caption`. Then the title and pin,
  at `.body` semibold and up to two lines: a long title wraps and the row grows, while the trailing
  status keeps its corner. Under it a line of source · profile · project (`ChatRowSubtitle`;
  `git_repo_root`'s folder name, absent outside a repository) in `.caption`. The device is never
  named. When Hermes serves a model or a `reasoning_effort` for the chat, the same line ends flush
  right with "qwen4-max · xhigh" in `.caption` tertiary text (`ChatRowSubtitle.modelLine`), the
  profile reading from the left edge: the provider prefix goes, a long name is cut, a missing half
  leaves nothing behind, and with neither the line ends at the profile.
- **The trailing state** (`ChatRowState`) is a dashed green ring and the running time, an orange
  mark and Needs you, or a red mark, Failed and the reason in red on its own line. An idle chat is a
  green check and Done while it is unread (the dot's rule: `UnreadStore`'s badge or a mark as
  unread); once read it shows only how long ago it ended (`ChatRowAgo`: "now", "5m", "2h", "3d",
  "2w", "4mo", "1y"), from the session's `ended_at`, else its `last_active`, and redraws only when
  those words change. A waiting first message reads as running. The running time comes from the
  attached conversation's turn (`live.turn.startedAt`), else the moment the message went out here
  (`lastSentAt` for a waiting chat), else the first sight of the chat running this launch
  (`LiveActivity.runningStart`), else the session's `last_active`; the earliest fallback wins, so a
  streaming reply doesn't restart the clock. Only a running row redraws each second
  (`TimelineView`).
- **The list's lines** (`SidebarRowDivider`): every chat row has a one-physical-pixel
  `Theme.rowSeparator` under it, running the list's whole width. Pinned's last row and each
  region's last row get a stronger `Theme.sectionSeparator` line with 6 pt of air above it when
  another region follows (Pinned → Main, then Working and Settled, whose headers stay); the list's
  last row has none. The group chats and Bots rows draw the same two lines (`showsRowDividers`): the
  breaks sit where the group chats end, where the pinned Bots end, and before Hidden. The split
  view's sidebar (iPad and Mac) passes nothing and looks as before.
- **Actions** match the sidebar's: leading swipe Read/Unread and Pin, trailing Settle (full swipe)
  and Mute, the same context menu, and the same Rename, Delete and error alerts. A waiting chat
  offers only Delete. Settled rows keep Un-settle.
- **Search** is the glass button: a page with the same `workspace.searchText`, chips and
  `SearchResultsSection` as the sidebar (`docs/search.md`). Picking a result opens its chat and
  closes the page.
- **Compose** starts a new chat with the existing flow, profile picker included. From iOS 27 it
  is the tab bar's prominent tab (`Tab(role: .prominent)`, `square.and.pencil`): the system draws
  it as a separate glass circle beside the tabs, on the same line, and shrinks it with them. It is
  a tab only in form: picking it acts a turn later and the tab stays as it was (acting inside the
  selection change left the bar centred and unlabelled after the pushed chat). On Chats and on
  Settings (which moves to Chats) it starts a new chat. On Bots its symbol turns into a plus, and
  it opens a popover right above it, the arrow pointing at the plus, with New Bot and New Group
  Chat (offered and enabled as in the sidebar). The panel, arrow and placement are the system
  popover's (`TabContent.popover`); only the rows are ours (`IOSMenuRows`): the panel is as wide as
  the longer title, and at the largest text sizes the titles wrap inside it rather than running off
  the screen. A pick closes the popover and opens its sheet once the popover has gone, and a tap
  outside closes it. The plus is dimmed while Bot Mode isn't connected. It
  stays on Settings because taking it away moves the whole bar. iOS 26 has no prominent tab, so
  there `IOSComposeButton` sits in the lists' bottom `safeAreaInset`, never covering the bar,
  with the Bot tab's menu; Settings has none. The tab bar goes away while a chat, Bot chat or
  group is pushed (`toolbar(.hidden, for: .tabBar)`); Back brings the list and the bar back. Each
  list keeps its own stack and scroll position across tab switches.
- **Bot tab** (`IOSBotList`) is the existing All Bots roster (`BotRosterSections`) with no filters;
  its compose button offers New Bot and New Group Chat. **Settings** reuses `SettingsView` without
  its Done button, and its Hermes on <bot> group adds Skills and Tasks after Apps and Tools, each
  with a count under its title like the rows around it (`HermesPageSummary`): "104 skills" from the
  list the Skills page keeps, and "5 tasks · 2 active" (active: not paused) from one read by the row,
  whose Tasks page works on the same list, so a change there shows on the way back. Before a count
  they say "Loading…" or "Not connected", as Apps and Tools does, or the page's own "Couldn't list
  skills" / "Couldn't load tasks"; nothing polls. The iPad's Settings sidebar shows the same counts.
  The sidebar's old Tasks, Skills and All Bots rows, the gateway switcher and the Chats/Bots switch
  do not appear in this layout.
- **The mock**: `backend.py --inbox-gtd --inbox-demo --cross-profile` seeds all four states
  (Working's cycle, the approval that waits, the finished rows, and "Nightly log rotation", whose
  failed turn is unread so its row says Failed), the profiles' faces and projects, and the settled
  chats.
