# Change: Stop dashboards rendering stale frames as live

## Why

A dashboard package receives its data frames once and then shows them forever,
while the relative-time text on screen keeps counting up. The result is a display
that is confidently wrong rather than visibly broken.

Observed in production on `com.ual.rids` (RIDS ramp displays, ~400 devices swept
every 5 minutes): every reachable device read `7m ago`, then `8m ago`, climbing
past the sweep interval it can never exceed. A browser reload showed the truth.
A device that goes down keeps rendering green, its age quietly increasing, until
someone happens to reload — which nobody does on a video wall.

The refresh machinery is not missing. It works. The client discards its output.

**The chain, verified end to end:**

1. `dashboard_frame_channel.ex` re-runs required frames on a tick
   (`@default_refresh_ms 15_000`) and pushes `frames:replace`. It correctly skips
   the push when nothing changed, via `hash = :erlang.phash2(frames)` (line 174).
2. That push carries `"generated_at"` on the **envelope** (line 188). The host JS
   assigns it to `data_provider` (`DashboardWasmHost.js`), not onto any frame.
3. The SDK decides whether anything changed with `frameDigest(frame)`
   (`@carverauto/serviceradar-dashboard-sdk/src/frames.js`), whose inputs are
   `id, encoding, row_count, refreshed_at, generated_at, status, query` plus
   payload length. **Row data is not an input.**
4. Nothing under `elixir/web-ng/lib/serviceradar_web_ng/dashboards/` ever sets
   `refreshed_at` — it appears nowhere in that tree — and
   `prepare_frame_transport/1` adds no timestamp. `row_count` is not on a frame at
   all; it exists only in `frame_summary/1` (channel line 399). `payload` is null
   for `json_rows`.

So for a `json_rows` frame the digest reduces to `id|encoding|||status|query` — a
**literal constant** after first delivery. `reconcile` therefore returns its cached
array, `setFrames` no-ops, and — because `reconcile` substitutes the cached frame
object for any matching digest — the fresh rows are discarded even if an unrelated
re-render occurs. The climbing text is `Date.now()` advancing inside unrelated
re-renders over frozen data.

This is deterministic, not fleet-size-dependent. Any `json_rows` dashboard on any
instance has never once shown refreshed data without a reload.

The SDK is holding up its end of a contract the host never fulfilled: `refreshed_at`
is already in the digest, waiting to be moved.

## What Changes

The fix is host-side and needs no SDK release and no republishing, because
`frames.js` already reads `frame.refreshed_at`. Already-deployed bundles start
updating the moment this ships.

- **Stamp each frame that carries its own fresh rows** with `refreshed_at`, and
  add `content_hash` (`:erlang.phash2` over `results`, or over `payload` for arrow
  frames) so change detection stops depending on metadata that does not move.
- **Stamp `checked_at` on every frame**, including ones whose content did not
  change, so a renderer can distinguish "this data is from 14:02" from "we last
  looked at 14:17 and it was unchanged". This is what lets a UI say *as of 14:02*
  instead of implying live.
- **Do not stamp `refreshed_at` on the stale-preservation path.**
  `preserve_previous_results_on_error/2` (line 366) merges the *previous* frame's
  rows into an error frame. Stamping "now" there would report stale rows as fresh —
  the exact defect being fixed. That path carries the previous `refreshed_at`
  forward and gets only a new `checked_at`.
- **Fix the dedupe hash in the same commit.** `phash2` over whole frames would see
  a fresh timestamp every tick, so a naive stamp turns a correct no-op into a full
  `frames:replace` plus a re-push of every arrow binary, every 15 s, per viewer,
  and makes every client re-decode. The hash must be computed over
  volatile-stripped frames (`refreshed_at`, `checked_at` removed) so it continues to
  mean "did the data change".
- **Push a `frames:heartbeat`** carrying `checked_at` when a refresh dedupes, so a
  client can show liveness without a frame round-trip.

Four further defects found in the same code while tracing this. All are small,
all are in these two files, and all are invisible to a caller today:

- **`frames:refresh` is destructive and does nothing.** It clears
  `last_frame_hash`, `frame_cursors` and `deferred_frame_sent`, then calls
  `start_frame_refresh/3`, which returns the socket unchanged when a task is in
  flight — and replies `{:ok, %{}}`. So the documented way to force a refresh can
  destroy dedupe state and the user's paging position, do no work, and report
  success. It must not clear cursors, and must reply with an error when it cannot
  act.
- **`frames:page` silently drops the request** for the same reason: the same
  in-flight guard, the same `{:ok, %{}}`. A user clicking "next" during a tick gets
  nothing and no error.
- **`prev()` pages forward.** `srql_query_opts/3` (frame_runner.ex:483) builds
  `%{scope:, limit:}` plus an optional `:cursor` and never passes `:direction`,
  while `SRQL.query/2` reads `opts[:direction]` (srql.ex:38, :47). Backward paging
  has never worked; it re-fetches the next page.
- **Frames past the twelfth vanish.** `Enum.take(@max_frames)` drops them with no
  error, no log, and nothing in the manifest to prevent declaring thirteen.

## Non-goals

- Removing `@max_frame_limit 2_000`, deriving frame completeness, or exposing
  `execute()`. Those belong to the follow-up change
  `add-derived-frame-completeness`, which this one deliberately unblocks rather
  than contains. Shipping the staleness fix must not wait on a redesign.
- Widening `refresh_data_frames/1`. `required: false` frames are never re-run,
  which is a real defect, but `required` is overloaded — `com.ual.armis.composite`
  uses it for host-feature degradation, and the required-only filter is asserted by
  a named test (`dashboard_frame_channel_test.exs:220`, "refresh ticks keep cached
  optional frames without re-running them"). Splitting `required` from `refresh` is
  a deliberate change, not a drive-by.
- Any change to `frames:replace` payload shape, `pending_binary_frame_ids`, or the
  `DFB1` binary encoding. Adding fields to frames is additive; the transport is
  untouched.

## Impact

- Affected specs: `dashboard-sdk`
- Affected code:
  - `elixir/web-ng/lib/serviceradar_web_ng/dashboards/frame_runner.ex` — stamp
    `refreshed_at` / `content_hash` / `checked_at`; pass `:direction` through
    `srql_query_opts/3`; turn the `@max_frames` overflow into error frames.
  - `elixir/web-ng/lib/serviceradar_web_ng_web/channels/dashboard_frame_channel.ex`
    — volatile-stripped dedupe hash; `frames:heartbeat`; stop `frames:refresh`
    clearing cursors; typed error replies for `frames:refresh` and `frames:page`
    when a task is in flight; carry previous `refreshed_at` on the stale path.
  - `elixir/web-ng/test/serviceradar_web_ng/dashboards/frame_runner_test.exs` and
    the channel test — new cases per defect.
- Risk: low and contained. Every change is additive to the frame map or corrects a
  reply that is currently a lie. The one genuine hazard — a stamp defeating the
  dedupe and amplifying push traffic 1×/15 s/viewer into a full re-push including
  binaries — is addressed in the same commit and must be covered by a test that
  fails if the hash starts seeing the timestamp.
- Consumers: no SDK bump, no republish, no manifest change. `com.ual.rids@0.1.3`
  and `com.ual.armis.composite@0.3.0` benefit as deployed.

## Note on OpenSpec conventions

`openspec/AGENTS.md` says to skip a proposal for a bug fix that restores intended
behaviour. This is filed as a change because it establishes a contract rather than
only repairing a defect: frames gain three timestamp/identity fields that the SDK
and any future renderer are expected to rely on, and the meaning of the dedupe hash
is pinned. Those belong in the `dashboard-sdk` spec. The four secondary defects are
ordinary bug fixes carried along because they live in the same two functions.
