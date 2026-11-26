## 1. SRQL (Rust)

- [x] 1.1 `pagination.rs`: add the v3 keyset cursor (entity, column, direction,
      key). Sign with HMAC-SHA256 over the canonical JSON of
      `{v, entity, col, dir, key}`: compact UTF-8, keys in that order, `key` a
      JSON string or, later, a JSON array of strings. Keep v2 encode/decode
      unchanged. A decode entry point returns either an offset or a keyset
      position.
- [x] 1.2 Entity keyset declarations: `uid` for `devices` and `agents`.
- [x] 1.3 `plan.rs`: decide keyset eligibility from the effective order
      (collapsing repeated identical sort keys), record it on `QueryPlan`, and
      accept v2 offsets, accept matching v3 positions, reject mismatched v3
      cursors and `prev` with a v3 cursor. No offset ceiling for v3.
- [x] 1.4 Devices and agents builders: emit `uid > $key` / `uid < $key` and no
      `OFFSET` for an eligible plan.
- [x] 1.5 `translate.rs`: for an eligible plan, return
      `pagination.keyset = {entity, column, direction}` and no offset-based
      `next_cursor` / `prev_cursor`.
- [x] 1.6 `engine.rs`: mint the v3 cursor from the last row of a full page.
- [x] 1.7 NIF: export `keyset_cursor(entity, column, direction, key)` signing
      with the configured secret.
- [x] 1.8 Rust tests: cursor round trip and tamper rejection; eligible and
      ineligible orders; mismatched-cursor and `prev` rejection; v2-on-eligible
      compatibility; walk past `max_cursor_offset`.

## 2. Executors (Elixir)

- [x] 2.1 `SRQLRunner.next_cursor`: when `pagination.keyset` is present and the
      page is full, mint the cursor from the last row's key through the NIF.
- [x] 2.2 `ServiceRadarWebNG.SRQL.next_cursor`: same branch.
- [x] 2.3 Tests at each executor: a full eligible page yields a cursor that
      resumes after the last row; a short page yields none.

## 3. Walkers

- [x] 3.1 `SweepCompiler.fetch_target_query_pages`: page by `sort:uid:asc`.
- [x] 3.2 `EphemeralDeviceExpiry.collect_excluded`: page by `sort:uid:asc`.
- [x] 3.3 `CompositeChecks.Scope`: page by `sort:uid:asc`.
- [x] 3.4 `MtrAutomationDispatcher.collect_target_contexts`: page by
      `sort:uid:asc`.
- [x] 3.5 Per-walker test that the query it sends is uid-ordered.

`SRQLInputResolver.reduce_page` keeps its generic fail-closed check: a full
page without `next_cursor` is an error. Keyset walks never reach it, because a
full eligible page always carries a cursor. Do not drop that check for device
or agent selections, and do not replace an operator-supplied sort.

## 4. Verification

- [x] 4.1 `cd rust/srql && cargo test`; `cargo fmt`; `cargo clippy`.
- [ ] 4.2 `make test`.
- [ ] 4.3 On the demo deployment after rollout: `pg_stat_statements` shows the
      walkers' device page statements without `OFFSET` and with a mean under
      50 ms; a walk of every device completes with no temp-file writes.
- [x] 4.4 `openspec validate add-srql-keyset-cursors --strict`.
