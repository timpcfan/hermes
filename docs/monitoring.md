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
