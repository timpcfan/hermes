# Stats monitoring

Stats uses one app-wide Xunxin monitor connection, independent of chat gateways and windows.
`MonitoringModel` owns the settings and shared `MonitoringSession`. Visible foreground consumers
hold stable demand tokens; the final consumer leaving stops the session. Source values come from
scoped snapshot, recent and SSE endpoints; a failed connection retains accepted data.

## 1. Overview and freshness

Retained data is qualified by transport state, elapsed receipt age and each source's freshness.
Receipt aging uses monotonic uptime; source timestamps use the service clock. A retained successful
probe or an empty inflight array cannot independently prove a current result.

Stats covers only its own window's chat reading demand. Another visible uncovered window on the
same gateway can keep reading. Coverage and window-recency callbacks do not reopen an unchanged
chat or clear an intentional unread reminder. Queued Bot reads recheck reading demand when they
wake; see [inbox.md §4](inbox.md#4-in-the-chat).

### Account balance

The overview's first card is the whole Xunxin account's real deducted balance, not today's Magpie
estimate and not one provider's balance. The backend reads `GET /api/user/self` once every 60
seconds and shares one cached `quota` object with snapshot and SSE; opening Stats or receiving a
snapshot never asks upstream. The app also never derives a weekly ratio or a reset time from the
balance and account spend.

`balance_usd` and `used_usd` arrive as quota units divided by 500,000. Only finite JSON numbers are
amounts: booleans, strings, null, NaN and infinity leave the amount unknown, while a real zero or a
negative balance is shown as reported. A missing or malformed `quota` (including an unsupported
source, scope or currency) makes only this card unknown; the rest of an older snapshot still
decodes. Before the first success both amounts stay unknown rather than zero.

A reading is current only while the service reports success, the service's 180-second freshness
window holds, and this receipt's transport and age are also current. A failed read keeps the last
successful amounts and marks them stale; a first failure shows unavailable. The card names a
credential, auth, timeout, availability or invalid-response problem by local error kind and never
shows the upstream body.

### Usage, pace and the balance trend

The same card adds the account's real spend today, the average of the window's complete days before
today, the service's projected emptying day and the balance's path. `today` carries the service's
day, `used_usd` since 00:00, `tokens`, `requests` and the epoch of the successful usage read;
`avg_daily_usd` and `forecast` (`window_days`, `avg_daily_usd`, `days_left`, `projected_empty_at`)
come from the service, never from the app's own estimate. A partial today never enters the average,
and `days_left` is zero when the balance is at or below zero. `usage_error` names a failed usage
read while `today` and `forecast` keep the last success; a balance read's own failure does not
clear them. Only the contract's error codes are typed, and the card never shows the upstream body.

Every new value is optional: a missing or malformed one is unknown and reads `—`, never zero. An
older service sends none of these fields, and the card then shows only the balance. With no
complete day to average, `forecast` is null and the card says there is no forecast rather than
inventing a pace.

`trend` holds the recorded days (`points`: `day`, `balance_usd`, `spent_usd`), the service's forward
days (`projection`: `day`, `balance_usd`) and `depletion_day`. The card draws the recorded days as
a solid line, the projection as a dashed continuation from the last recorded day, and marks the
depletion day only when a projection gives the line an end; it also says when the balance is
expected to run out. `topup_detected` adds a note that the history isn't one continuous drawdown.
An empty or missing history draws nothing at all, and a malformed point is dropped rather than
guessed. The vertical scale starts at zero and follows the window's own peak.

## 2. Requests

The default first page follows accepted snapshot high-water changes. Search, filters, sorting and
paging freeze the list to the authoritative loaded page's business day and append position. Show
Newer obtains a new authoritative recent response, then freezes that result.

Hiding Requests cancels pending work and rejects late responses. If the selected page or query has
not finished, returning resumes that load once; a successfully loaded frozen page stays retained.
A business-day rollover abandons pending old-day Show Newer intent, restarts page one, and shows
the rollover notice. The default query then continues following new-day snapshots.

The summary's “live” suffix is separate from the query's follow policy. It requires a successful
accepted page, no unfinished refresh or load error, a current transport and usage source, and fresh
snapshot and recent-page receipts. The receipt limits are ten seconds for streaming and twenty
seconds for polling. Offline or stale rows remain readable without the suffix; successful fresh
snapshot and recent results restore it. Request details retain the request selected when opened.

## 3. Models

Models show the scoped day's aggregates and eight three-hour buckets in a native chart. Unknown
measurements remain unknown; compact axis labels do not change bucket identity or values.

## 4. Exits

Exit reachability combines probe-source freshness with the cached exit result. The last history
sample remains the latest sample even when it failed. Inferred exits stay qualified, and an absent
exit does not establish a direct route.

## 5. Settings and checks

Monitoring settings are app-wide. Check validates snapshot, recent and a bounded SSE handshake;
usable polling remains saveable. Connection replacement invalidates old snapshot and request data
before new results publish. A DEBUG address override is disposable and never inherits a saved
credential. Deterministic App regressions exercise cancellation, rollover, read callbacks, queued
reads and localized summary output; cross-platform builds and native interactions are separate gates.
