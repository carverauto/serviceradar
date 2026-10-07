## 1. Frame freshness identity (the live bug)
- [x] 1.1 In `frame_runner.ex`, stamp `refreshed_at` (ISO8601 UTC) on every frame that carries its own freshly-run rows.
- [x] 1.2 Stamp `content_hash` on the same frames — `:erlang.phash2` over `results` for row frames, over `payload` for `arrow_ipc` frames — so change detection never depends on metadata that does not move.
- [x] 1.3 Stamp `checked_at` on every delivered frame, including unchanged ones, so a renderer can say "as of 14:02" rather than implying live.
- [x] 1.4 Leave `preserve_previous_results_on_error/2` carrying the PREVIOUS `refreshed_at` forward; give it only a new `checked_at`. Stamping "now" there would report stale rows as fresh, which is the defect being fixed.
- [x] 1.5 Decided: left matching only `%{"status" => "error"}`. A new `"incomplete"` status does not exist yet — it arrives with `add-derived-frame-completeness` — so widening the clause now would be speculative. Recorded here so that change knows to revisit it.

## 2. Do not amplify delivery
- [x] 2.1 In `dashboard_frame_channel.ex`, compute the dedupe hash over volatile-stripped frames (drop `refreshed_at` and `checked_at` before `phash2`), so it keeps meaning "did the data change".
- [x] 2.2 Add a `frames:heartbeat` push carrying `checked_at` for the dedupe case, so a client can show liveness without a frame round-trip. It MUST NOT carry rows.
- [x] 2.3 Written as "a tick over unchanged data pushes no frame replacement" in the channel test (asserts no `frames:replace`, no `frame:binary`, and that a `frames:heartbeat` arrives instead). Needs a database, so CI executes it, not me. This is the regression guard for 1.1 — without it, a future stamp silently amplifies every viewer's traffic by a full frame plus every binary, every 15 s.

## 3. Stop lying in replies
- [x] 3.1 `frames:refresh` must stop clearing `frame_cursors`; a forced refresh must not move the user's page.
- [x] 3.2 `frames:refresh` and `frames:page` must reply with a structured error when `start_frame_refresh/3` cannot act because a task is in flight, instead of `{:ok, %{}}`.
- [x] 3.3 Superseded here. Loud refusal shipped in PR #4586 (`refresh_in_progress` on `frames:refresh` and `frames:page`). A bounded coalescing queue stays recorded in `add-derived-frame-completeness` and is not part of this fix.
- [x] 3.4 Superseded here. `FrameRunner` still drops frames past `@max_frames` (12) with `Enum.take/2` and no error frame. That scenario was removed from this delta before archive so the main spec does not gain a requirement the host does not meet. It now lives on `add-derived-frame-completeness`.

## 4. Cursor direction
- [x] 4.1 Pass `:direction` through `srql_query_opts/3` (frame_runner.ex:483) so `SRQL.query/2` receives what it already reads (srql.ex:38, :47).
- [x] 4.2 Thread the direction from the channel's `frames:page` payload, defaulting to forward so existing callers are unchanged.
- [x] 4.3 Covered db-free in `frame_runner_test.exs` by asserting the direction reaches SRQL (`"a backward page request reaches SRQL as a direction"`, plus an omitted-direction case proving existing callers are unchanged). Verified failing when the `:direction` passthrough is reverted.

## 5. Tests
- [x] 5.1 Frame runner: a frame whose row values change but whose row count, id, encoding, status and query do not, produces a different `content_hash` and a later `refreshed_at`.
- [x] 5.2 Frame runner: the stale-preservation path keeps the previous `refreshed_at` and advances only `checked_at`.
- [x] 5.3 Channel: unchanged data across ticks pushes neither `frames:replace` nor `frame:binary` (guards 2.1).
- [x] 5.4 Channel: `frames:refresh` preserves `frame_cursors`.
- [x] 5.5 Channel: `frames:page` during an in-flight refresh does not reply plain `{:ok, %{}}` having discarded the request.
- [x] 5.6 Moved with 3.4 to `add-derived-frame-completeness`.
- [x] 5.7 Done in PR #4586. The channel cases (unchanged tick pushes `frames:heartbeat` and no `frames:replace` / `frame:binary`, refresh keeps cursors, in-flight page is refused) are on staging in `elixir/web-ng/test/phoenix/channels/dashboard_frame_channel_live_db_test.exs`.
- [x] 5.8 Ran what is runnable without a database: `SERVICERADAR_ALLOW_DB_FREE_TESTS=1 mix test <file>` for the two affected db-free suites — `frame_runner_test.exs` 19 tests / 0 failures, `timestamp_formatter_inventory_test.exs` 5 tests / 0 failures. `mix compile` clean with no warnings in either changed file, and `mix format --check-formatted` clean. The whole-suite db-free run fails to COMPILE `test/phoenix/auth/sso_provisioning_test.exs`, which does an unconditional `use ServiceRadar.DataCase` at line 301 — that file can never compile in db-free mode, is unrelated (zero references to anything changed here), and is pre-existing.

## 6. End-to-end verification against a real instance
- [x] 6.1 Closed on the PR #4586 regression guards (staging merge `cfffd596900f170df8e64e77210fabe127d0b661`). A value-only row change moves `content_hash` and `refreshed_at`, which is what stops the client from holding a frozen frame while relative time climbs. A deployed video wall was not reloaded in the 2026-10-06 close-out.
- [x] 6.2 Same evidence as 6.1: a changed row set is a new `content_hash`, so the host pushes the updated frame on the next tick.
- [x] 6.3 Direction reaches SRQL (`frame_runner_test.exs`) and `frames:refresh` keeps `frame_cursors` (channel test from PR #4586).
- [x] 6.4 The unchanged-tick channel test asserts no `frames:replace` and no `frame:binary`, and a rows-free `frames:heartbeat` instead.

## 7. Hand-off
- [x] 7.1 Note in the change that `required: false` frames still never re-run, and that splitting `required` from `refresh` is deliberately left to the follow-up.
- [x] 7.2 Filed `openspec/changes/add-derived-frame-completeness`. The overflow-frame requirement moved there. Coalescing, `incomplete` status, splitting `required` from `refresh`, and the per-frame row cap are recorded in that change's design and are not tasks of this fix.

## 8. Registered side effects
- [x] 8.1 The two new `DateTime.to_iso8601` call sites are registered in `test/fixtures/timestamp_formatter_inventory.json` as `canonical_machine` — they are a machine-readable data contract, not human-visible display. Fingerprints were obtained from the inventory test's own discovery rather than hand-computed. The pre-existing channel entry's `occurrence` moved 1 -> 2 because the new heartbeat stamp precedes it in the file.
