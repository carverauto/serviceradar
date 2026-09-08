# Tasks: Expose sweep diagnostics through SRQL and MCP

## 1. Persist per-port coverage

- [x] 1.1 Migration in `elixir/serviceradar_core/priv/repo/migrations`, schema
      `platform`: add `scanned_ports bigint[] NOT NULL DEFAULT '{}'`,
      `agent_id text` and `sweep_group_id uuid` to `sweep_host_results`.
      Backfill is not attempted; historical rows keep an empty scanned set.
- [x] 1.2 Add the attributes to the `SweepHostResult` Ash resource, public and
      read-only to operators.
- [x] 1.3 In `sweep_results_ingestor.ex`, derive the scanned port set from the
      per-port outcomes already in the payload (`port_results`,
      `port_scan_results`, `portScanResults`), keeping `open_ports/1` behavior
      unchanged. Reuse the existing port parsing and validity helpers.
- [x] 1.4 Populate `agent_id` and `sweep_group_id` on the host result from the
      execution at ingest, including the batch upsert path.
- [x] 1.5 Unit tests: mixed open/closed host, all-closed host, ICMP-only host
      (empty scanned set), malformed port entries, and an upsert that must not
      clear a previously written scanned set.

## 2. Coverage rollup

- [x] 2.1 Migration: create `platform.sweep_coverage_daily` keyed by
      `(day, device_uid, ip, sweep_group_id, agent_id)` with execution,
      available, unavailable and error counts, first and last seen timestamps,
      unioned scanned and open ports, unioned requested and observed modes,
      last status and last response time. Unique index on the grain key.
- [x] 2.2 Add the rollup worker beside `sweep_data_cleanup_worker.ex`: daily,
      idempotent upsert on the grain key, string-keyed args, batched.
- [x] 2.3 Schedule the rollup before cleanup, and make the cleanup worker's
      cutoff respect the rolled-up watermark so no day is deleted unrolled.
- [x] 2.4 Add rollup retention (default 400 days) to the cleanup worker config.
- [x] 2.5 Tests: idempotent re-run does not double-count, two groups on one
      device and agent produce two rows, a day is rolled up before it becomes
      cleanup-eligible, and rollup survives raw deletion.

## 3. SRQL entities

For each of `sweep_groups`, `sweep_profiles`, `sweep_executions`,
`sweep_results`, `sweep_coverage`, `device_sweep_overlap` and
`sweep_compiled_config`, follow the established entity pattern.

The shared bullets below stay unticked until the LAST entity satisfies them.
Six of the seven have landed -- the five typed-table entities in #4303 and
`device_sweep_overlap` in #4314. `sweep_compiled_config` (3.8) is the only one
outstanding, so 3.1-3.6 and 3.11 are complete for every entity except that one.
Read an unticked shared bullet as "sweep_compiled_config still owes this", not
as "no work has landed".

- [ ] 3.1 `rust/srql/src/schema.rs`: diesel table definitions for the new and
      newly exposed tables.
- [ ] 3.2 `rust/srql/src/parser/entity.rs`: entity ids and aliases
      (`scanner_profiles` for profiles, `sweep_group_executions` for executions,
      `sweep_host_results` for results).
- [ ] 3.3 `rust/srql/src/parser/ast.rs`: `Entity` variants.
- [ ] 3.4 `rust/srql/src/models/`: row models and field mappings.
- [ ] 3.5 `rust/srql/src/query/<entity>.rs` plus `translate.rs`, `mod.rs` and
      `engine.rs` wiring.
- [ ] 3.6 `rust/srql/src/query/viz/`: column metadata.
- [x] 3.7 `device_sweep_overlap`: a view reporting, per device, which sweep
      groups were DECLARED to target it (from the compiled config's resolved
      `targets` / `device_targets`) versus which actually produced results, plus
      the group and execution that currently own the `device_agent_availability`
      row. Declared-but-not-observed is the diagnostic that proves or kills the
      reported symptom. Follow the `addon_fleet` view pattern: created by raw
      `execute` in an Ecto migration, read through `diesel::sql_query` with a
      `to_jsonb(alias) AS payload` projection, and deliberately NOT added to
      `schema.rs`, which holds real tables only.
      Also: the view MASKS `scanner_profile_name` and `profile_id` when the
      group's scanner profile is `admin_only`, rather than dropping the row.
      `networks.sweeps.view` is granted to every role, so projecting the profile
      would have handed every authenticated user the identity of a profile that
      `in:sweep_profiles` correctly hides. The row survives because the alert is
      the operator's business either way.
- [ ] 3.8 `sweep_compiled_config`: named-column allowlist over sweep config
      instances only. The `compiled_config` document is never projected.
- [ ] 3.9 `sweep_profiles`: expose banner grab as `enabled` and `protocols`
      only; omit the timeout, concurrency and rate tuning fields.
- [ ] 3.10 No Bazel edit is needed for new `.rs` files: `rust/srql/BUILD.bazel`
      uses `srcs = glob(["src/**/*.rs"])`, and the NIF and web-ng test globs
      behave the same way. Only a NEW crate dependency requires touching the
      root `Cargo.toml` and the crate graph. Still run `bazel build //rust/...`,
      because a green `cargo check` does not prove the Bazel build.
- [ ] 3.11 Rust tests: parser alias coverage, translation, and an entry in
      `query/tests/entity_examples.rs` per entity.

## 4. Authorization

- [ ] 4.1 Close the `EntityAccess.extract_entity/1` token-order bypass: the gate
      anchors on `^in:` while the parser accepts `in:` at any position, so
      `limit:1 in:<entity>` passes through ungated. Extract the entity the same
      way the parser does rather than by anchored regex. Regression test with
      the entity token in first, middle and last position.
- [ ] 4.2 Add a new admin-default RBAC catalog permission for compiled sweep
      config. `settings.networks.manage` is operator plus admin and cannot be
      reused. No migration: `RoleProfileSeeder` re-syncs on boot.
- [ ] 4.3 Map all seven entities and every parser alias in
      `EntityAccess.@permission_entities`. This is mandatory, not optional:
      `entity_access_test.exs` fails on any unmapped catalog entity, and an
      unmapped entity is `:passthrough`, meaning allowed.
- [ ] 4.4 Test asserting the compiled config entity's exposed column set equals
      the allowlist exactly, so widening the projection fails a gate.
- [ ] 4.5 Test asserting no sweep entity returns a `compiled_config` document or
      credential-bearing field.
- [ ] 4.6 Assert the MCP denial shape, which differs from HTTP: MCP returns
      JSON-RPC 200 with `isError: true` and body text "forbidden", not a 403.

## 4b. Query window and aggregation

- [ ] 4b.1 Admit `sweep_coverage` to `max_time_range_days_for_ast` so a query
      spanning the rollup's 400-day retention is not rejected by the 90-day cap
      that applies to every non-CAGG entity.
- [ ] 4b.2 Implement the time predicate in BOTH the row builder and the stats
      builder for every entity that supports `stats:`. A predicate present in
      only one silently ignores the window in the other.
- [ ] 4b.3 Implement per-entity `stats:` support for `sweep_results` and
      `sweep_coverage` following the `composite_results` two-module pattern, so
      grouping by agent and sweep group works. Nothing about `stats:` is
      automatic per entity.
- [ ] 4b.4 Confirm `bucket:` is rejected for these entities rather than silently
      ignored: downsample dispatch precedes the per-entity match and rejects
      every non-metric entity.

## 5. Catalog and MCP docs

- [ ] 5.1 Register the entities and their fields in
      `elixir/web-ng/lib/serviceradar_web_ng_web/srql/catalog.ex`.
- [ ] 5.2 State the 7 day raw retention in the `sweep_results` catalog entry and
      point to `sweep_coverage` for older history.
- [ ] 5.3 Add cookbook recipes to `elixir/web-ng/priv/mcp/srql-cookbook.md`:
      which groups target this device, was TCP requested or dropped during
      compilation, which agent last wrote availability, where do groups overlap.
      The "where do groups overlap" recipe landed with `device_sweep_overlap`
      (#4314), including the two behaviors an operator would otherwise mis-read:
      a masked profile means restricted, not absent, and a time window is
      refused rather than ignored. "Was TCP requested or dropped during
      compilation" still waits on `sweep_compiled_config`.
- [ ] 5.4 Catalog test covering the new entities. The `device_sweep_overlap`
      entry is covered (#4314), including a regression test pinning its blank
      `default_sort_field`: naming one there makes the visual builder emit a
      `sort:` token on every query, which replaces the alert-first default and
      buries every `declared_not_observed` row behind a prefix longer than
      `max_cursor_offset`.

## 6. Verification

- [ ] 6.1 Database-backed integration tests for the entities and the overlap
      view using the `srql-fixtures-db-tests` skill lifecycle.
- [ ] 6.2 `make test` green before opening the PR.
- [ ] 6.3 Reproduce the reported symptom end to end: confirm the entities show
      whether the `rids` TCP ports were compiled, delivered and attempted, and
      record the finding on GitHub issue #4167.
