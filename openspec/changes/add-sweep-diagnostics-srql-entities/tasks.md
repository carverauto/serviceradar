# Tasks: Expose sweep diagnostics through SRQL and MCP

## 1. Persist per-port coverage

- [ ] 1.1 Migration in `elixir/serviceradar_core/priv/repo/migrations`, schema
      `platform`: add `scanned_ports bigint[] NOT NULL DEFAULT '{}'`,
      `agent_id text` and `sweep_group_id uuid` to `sweep_host_results`.
      Backfill is not attempted; historical rows keep an empty scanned set.
- [ ] 1.2 Add the attributes to the `SweepHostResult` Ash resource, public and
      read-only to operators.
- [ ] 1.3 In `sweep_results_ingestor.ex`, derive the scanned port set from the
      per-port outcomes already in the payload (`port_results`,
      `port_scan_results`, `portScanResults`), keeping `open_ports/1` behavior
      unchanged. Reuse the existing port parsing and validity helpers.
- [ ] 1.4 Populate `agent_id` and `sweep_group_id` on the host result from the
      execution at ingest, including the batch upsert path.
- [ ] 1.5 Unit tests: mixed open/closed host, all-closed host, ICMP-only host
      (empty scanned set), malformed port entries, and an upsert that must not
      clear a previously written scanned set.

## 2. Coverage rollup

- [ ] 2.1 Migration: create `platform.sweep_coverage_daily` keyed by
      `(day, device_uid, ip, sweep_group_id, agent_id)` with execution,
      available, unavailable and error counts, first and last seen timestamps,
      unioned scanned and open ports, unioned requested and observed modes,
      last status and last response time. Unique index on the grain key.
- [ ] 2.2 Add the rollup worker beside `sweep_data_cleanup_worker.ex`: daily,
      idempotent upsert on the grain key, string-keyed args, batched.
- [ ] 2.3 Schedule the rollup before cleanup, and make the cleanup worker's
      cutoff respect the rolled-up watermark so no day is deleted unrolled.
- [ ] 2.4 Add rollup retention (default 400 days) to the cleanup worker config.
- [ ] 2.5 Tests: idempotent re-run does not double-count, two groups on one
      device and agent produce two rows, a day is rolled up before it becomes
      cleanup-eligible, and rollup survives raw deletion.

## 3. SRQL entities

For each of `sweep_groups`, `sweep_profiles`, `sweep_executions`,
`sweep_results`, `sweep_coverage`, `device_sweep_overlap` and
`sweep_compiled_config`, follow the established entity pattern.

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
- [ ] 3.7 `device_sweep_overlap`: view reporting every sweep group, agent and
      profile targeting a device, plus the group and execution that currently
      own the `device_agent_availability` row.
- [ ] 3.8 `sweep_compiled_config`: named-column allowlist over sweep config
      instances only. The `compiled_config` document is never projected.
- [ ] 3.9 `sweep_profiles`: expose banner grab as `enabled` and `protocols`
      only; omit the timeout, concurrency and rate tuning fields.
- [ ] 3.10 Update Bazel `BUILD.bazel` for every new Rust source file. A green
      `cargo test` does not prove the Bazel build.
- [ ] 3.11 Rust tests: parser alias coverage, translation, and an entry in
      `query/tests/entity_examples.rs` per entity.

## 4. Authorization

- [ ] 4.1 Gate `sweep_compiled_config` to administrative scope from the start,
      not deferred to the RBAC catalog change.
- [ ] 4.2 Define catalog keys for all seven entities so
      `fix-srql-query-rbac-catalog` (GitHub #4088) maps them when it lands.
      Record the dependency in that change rather than duplicating its work.
- [ ] 4.3 Test asserting the compiled config entity's exposed column set equals
      the allowlist exactly, so widening the projection fails a gate.
- [ ] 4.4 Test asserting no sweep entity returns a `compiled_config` document or
      credential-bearing field.

## 5. Catalog and MCP docs

- [ ] 5.1 Register the entities and their fields in
      `elixir/web-ng/lib/serviceradar_web_ng_web/srql/catalog.ex`.
- [ ] 5.2 State the 7 day raw retention in the `sweep_results` catalog entry and
      point to `sweep_coverage` for older history.
- [ ] 5.3 Add cookbook recipes to `elixir/web-ng/priv/mcp/srql-cookbook.md`:
      which groups target this device, was TCP requested or dropped during
      compilation, which agent last wrote availability, where do groups overlap.
- [ ] 5.4 Catalog test covering the new entities.

## 6. Verification

- [ ] 6.1 Database-backed integration tests for the entities and the overlap
      view using the `srql-fixtures-db-tests` skill lifecycle.
- [ ] 6.2 `make test` green before opening the PR.
- [ ] 6.3 Reproduce the reported symptom end to end: confirm the entities show
      whether the `rids` TCP ports were compiled, delivered and attempted, and
      record the finding on GitHub issue #4167.
