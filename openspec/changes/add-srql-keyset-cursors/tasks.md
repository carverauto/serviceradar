## 1. SRQL (Rust)

- [ ] 1.1 `pagination.rs`: add the v3 keyset cursor (entity, column, direction,
      key) with its own HMAC domain; keep v2 encode/decode unchanged; a decode
      entry point that returns either an offset or a keyset position.
- [ ] 1.2 Entity keyset declarations: `uid` for `devices` and `agents`.
- [ ] 1.3 `plan.rs`: decide keyset eligibility from the effective order
      (collapsing repeated identical sort keys), record it on `QueryPlan`, and
      accept v2 offsets, accept matching v3 positions, reject mismatched v3
      cursors and `prev` with a v3 cursor. No offset ceiling for v3.
- [ ] 1.4 Devices and agents builders: emit `uid > $key` / `uid < $key` and no
      `OFFSET` for an eligible plan.
- [ ] 1.5 `translate.rs`: for an eligible plan, return
      `pagination.keyset = {entity, column, direction}` and no offset-based
      `next_cursor` / `prev_cursor`.
- [ ] 1.6 `engine.rs`: mint the v3 cursor from the last row of a full page.
- [ ] 1.7 NIF: export `keyset_cursor(entity, column, direction, key)` signing
      with the configured secret.
- [ ] 1.8 Rust tests: cursor round trip and tamper rejection; eligible and
      ineligible orders; mismatched-cursor and `prev` rejection; v2-on-eligible
      compatibility; walk past `max_cursor_offset`.

## 2. Executors (Elixir)

- [ ] 2.1 `SRQLRunner.next_cursor`: when `pagination.keyset` is present and the
      page is full, mint the cursor from the last row's key through the NIF.
- [ ] 2.2 `ServiceRadarWebNG.SRQL.next_cursor`: same branch.
- [ ] 2.3 Tests at each executor: a full eligible page yields a cursor that
      resumes after the last row; a short page yields none.

## 3. Walkers

- [ ] 3.1 `SweepCompiler.fetch_target_query_pages`: page by `sort:uid:asc`.
- [ ] 3.2 `EphemeralDeviceExpiry.collect_excluded`: page by `sort:uid:asc`.
- [ ] 3.3 `CompositeChecks.Scope`: page by `sort:uid:asc`.
- [ ] 3.4 `MtrAutomationDispatcher.collect_target_contexts`: page by
      `sort:uid:asc`.
- [ ] 3.5 `SRQLInputResolver`: drop the cursor-window error for device and agent
      selections (keyset has no window); keep it for other entities.
- [ ] 3.6 Per-walker test that the query it sends is uid-ordered.

## 4. Verification

- [ ] 4.1 `cd rust/srql && cargo test`; `cargo fmt`; `cargo clippy`.
- [ ] 4.2 `make test`.
- [ ] 4.3 On the demo deployment after rollout: `pg_stat_statements` shows the
      walkers' device page statements without `OFFSET` and with a mean under
      50 ms; a walk of every device completes with no temp-file writes.
- [ ] 4.4 `openspec validate add-srql-keyset-cursors --strict`.
