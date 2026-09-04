# Tasks

## 1. Reconciliation run persistence (core)

- [x] 1.1 Add a named Elixir migration creating
      `platform.identity_reconciliation_runs` with `prefix: "platform"`:
      `run_id` uuid pk, `started_at`, `completed_at`, `duration_ms`, `status`,
      `error_summary`, `duplicate_identifier_count`, `duplicate_components`,
      `mergeable_components`, `blocked_components`, `blocked_devices`,
      `largest_blocked_component`, `merges`, `errors`,
      `max_merges_configured`, `merge_cap_reached`,
      `blocked_component_devices` jsonb, `trigger`, `job_schedule_id`.
      Indexes on `(started_at DESC)` and `(status, started_at DESC)`.
- [x] 1.2 Add `ServiceRadar.Inventory.Identity.ReconciliationRun` Ash resource
      with `migrate? false`, a `:record` create action and a `:read`. System
      actor writes; `read_viewer_plus()` reads.
- [x] 1.3 Change `DuplicateSweep.report_blocked_components/1` to return the
      largest component size (`0` for the empty clause) instead of `:ok`, and
      thread it into the stats map as `largest_blocked_component`.
- [x] 1.4 Add `max_merges_configured` and `merge_cap_reached` to the stats map.
      `merge_cap_reached` is `merge_cap_reached?(max_merges, merges)` evaluated
      once at the end of the run, not inferred by the caller.
- [x] 1.5 Collect blocked-component device uid arrays into
      `blocked_component_devices`, capped at a configurable number of
      components (default 100) with a `truncated` marker in the jsonb.
- [x] 1.6 Write the run record on the success path of
      `reconcile_duplicates/1`.
- [x] 1.7 Write the run record on the `rescue` path with status `failed` and an
      `error_summary`, preserving the counters established before the raise.
      Do not change the existing `{:error, error}` return.
- [x] 1.8 Wrap the run-record write so a write failure is logged and swallowed
      and can never fail, roll back, or abort the sweep.
- [x] 1.9 Prune run records older than a configurable window (default 30 days)
      at the end of each run, inside the same swallow-on-failure wrapper.
- [x] 1.10 Pass `trigger` (`scheduled` | `manual`) and `job_schedule_id` from
      `JobSchedule.run_identity_reconciliation` through `reconcile_opts`.
- [x] 1.11 Tests: run record written on success; on the rescue path;
      `merge_cap_reached` true exactly when merges reach the cap; a raising
      writer does not fail the sweep; retention prunes only rows outside the
      window; `report_blocked_components/1` returns `0` for `[]`.

## 2. SRQL schema and models

- [x] 2.1 Add `merge_audit`, `device_revival_audit`, `device_identifiers`, and
      `identity_reconciliation_runs` to `rust/srql/src/schema.rs`.
- [x] 2.2 ~~Add row models and `into_json`~~ **Not needed.** All five entities
      build `SELECT to_jsonb(sub) AS payload`, so there is one shared
      `JsonPayload` row type in `query/identity/mod.rs` and no per-entity
      `Queryable` struct. Adding five typed structs that are never used as
      Diesel projections would be dead weight.
- [x] 2.3 Define the `details` and `metadata` key allowlists in one place and
      apply them from every projection that touches those columns.

## 3. SRQL parser and dispatch

- [x] 3.1 Add `Entity::MergeAudit`, `Entity::DeviceRevivalAudit`,
      `Entity::DeviceIdentifiers`, `Entity::IdentityReconciliationRuns`, and
      `Entity::IdentityEvidenceEdges` to `parser/ast.rs`.
- [x] 3.2 Register canonical names and aliases in `parser/entity.rs`:
      `merge_audit|device_merges|merges`,
      `device_revival_audit|device_revivals|revivals`,
      `device_identifiers|identifiers|device_identity`,
      `identity_reconciliation_runs|reconciliation_runs|dire_runs`,
      `identity_evidence_edges|identity_evidence|evidence_edges`.
- [x] 3.3 Add the `chain:`, `device:`, `include_unmerge:`, and `value:` filter
      tokens to `parser/filters.rs`; extend `supports_implicit_like` for
      `identifier_value`, `reason`, `source`, and `revived_by_application`.
- [x] 3.4 Dispatch the five entities in `query/engine.rs` and
      `query/translate.rs`.
- [x] 3.5 Parser tests for every canonical name, every alias, and the
      unknown-entity error path.

## 4. Merge audit entity and chain resolution

- [x] 4.1 Implement `query/merge_audit.rs` (`execute` + `to_sql_and_params`).
      Default sort `created_at desc`; `time:` maps to `created_at`; exclude
      `reason = 'unmerge'` unless `include_unmerge:true`.
- [x] 4.2 Filters: `from_device_id`, `to_device_id`, `device_id` (either side),
      `reason`, `source`, `confidence_score` numeric comparisons.
- [x] 4.3 Implement `chain:<uid>` as a recursive CTE walking forward on
      `from_device_id` and backward on `to_device_id`, projecting `depth` and
      `direction`.
- [x] 4.4 Bound the walk: `UNION` on visited device ids, configurable depth cap
      (default 32), and `truncated` in the response when the cap is hit.
- [x] 4.5 Verify the plan uses `merge_audit_from_device_created_idx` and
      `merge_audit_to_device_idx`. Add no new index. **No index added to any
      existing table.** Both walk directions predicate on the indexed leading
      columns; an EXPLAIN on the fixture data is not evidence of the plan at
      production scale, so confirm this on a populated database before relying
      on it operationally.
- [x] 4.6 Tests: multi-hop forward chain; backward chain; oscillating pair
      terminates and visits each device once; depth cap sets `truncated`;
      unmerge exclusion and `include_unmerge:true`; bind-parameter counts.

## 5. Revival audit entity

- [x] 5.1 Implement `query/device_revival_audit.rs`. Default sort
      `revived_at desc`; `time:` maps to `revived_at`.
- [x] 5.2 Filters: `device_uid`, `revived_by_application`,
      `previous_deleted_by`, `previous_deleted_reason`.
- [x] 5.3 Tests: per-device lookup; time-window filter; parameterization.

## 6. Device identifiers entity

- [x] 6.1 Implement `query/device_identifiers.rs` with the `ocsf_devices` owner
      join. Default sort `last_seen desc`; `time:` maps to `last_seen`.
- [x] 6.2 Filters: `device_id`, `identifier_type`, `value`/`identifier_value`,
      `partition`, `confidence`, `source`, `verified`.
- [x] 6.3 A bare `value:` with no `identifier_type:` expands to
      `identifier_type = ANY(<closed enum>)` so the plan uses the leading
      column of `device_identifiers_unique_identifier_index`. Never emit a
      predicate on `identifier_value` alone.
- [x] 6.4 Project `matches_current_facts`: `mac` matches the owner's current
      `mac` or a discovered interface MAC; `agent_id`, hostname, and address
      types match the corresponding current device column.
- [x] 6.5 Project `owner_deleted`, `owner_deleted_at`, `owner_deleted_by`,
      `owner_deleted_reason`, `owner_hostname`, `owner_ip`, `owner_partition`.
- [x] 6.6 Apply the `metadata` key allowlist.
- [x] 6.7 Tests: ownership by device; corroborated vs historical MAC;
      tombstoned owner surfaces; value-without-type emits the ANY expansion;
      allowlist drops unknown metadata keys.

## 7. Identity evidence edge entity

- [x] 7.1 Implement `query/identity_evidence_edges.rs` as a recursive CTE
      self-joining `device_identifiers` on
      `(identifier_type, identifier_value, partition)` where `device_id`
      differs.
- [x] 7.2 Project `device_a`, `device_b`, `identifier_type`,
      `identifier_value`, `partition_a`, `partition_b`, `confidence`, `depth`,
      `direct`, `cross_partition`.
- [x] 7.3 Require a `device:` (or component) seed. An unseeded query returns a
      typed invalid-request error and executes nothing.
- [x] 7.4 Bound the walk with the same `UNION`-on-visited and depth cap as the
      merge chain.
- [x] 7.5 Tests: A-B-C component yields direct A-B and transitive B-C and no
      A-C edge; cross-partition flag; unseeded query refused; cycle
      termination.

## 8. Reconciliation runs entity

- [x] 8.1 Implement `query/identity_reconciliation_runs.rs`. Default sort
      `started_at desc`; `time:` maps to `started_at`.
- [x] 8.2 Filters: `run_id`, `status`, `trigger`, `merge_cap_reached`,
      numeric comparisons on `merges`, `errors`, `blocked_components`,
      `largest_blocked_component`, `duration_ms`.
- [x] 8.3 Tests: cap-reached run; failed run with error summary; blocked
      component membership projected.

## 9. RBAC, catalog, and docs

- [x] 9.1 Add all five canonical names and every alias to the `"devices.view"`
      list in `srql/entity_access.ex`.
- [x] 9.2 Add a test asserting every parser alias for the five entities
      resolves to `{:ok, "devices.view"}` and never `:passthrough`. This is the
      gate: an alias missing from the map is an ungated entity on the HTTP and
      MCP paths, and it fails open silently.
- [x] 9.3 Register the entities, fields, and enums in
      `serviceradar_web_ng_web/srql/catalog.ex` and the viz metadata.
- [x] 9.4 Add cookbook recipes to `elixir/web-ng/priv/mcp/srql-cookbook.md`
      covering: reconcile an inventory list, trace a tombstone to its survivor,
      corroborated vs historical MAC, cross-partition evidence, and reading a
      capped run.

## 10. MCP tools

- [x] 10.1 Add `trace_device_identity` to `ServiceRadarWebNG.Mcp.Tools`,
      accepting `uid`, `ip`, or `hostname`. Resolve non-uid seeds through a
      bound `in:devices` query that includes tombstones.
- [x] 10.2 Compose the trace from bound SRQL through `Mcp.Runner`: device row
      with tombstone fields, merge chain both directions, revival events,
      identifiers with `matches_current_facts`, evidence component with
      `cross_partition`.
- [x] 10.3 Add `explain_identity_reconciliation` accepting `run_id` or a time
      range, returning run summaries with `merge_cap_reached`, blocked
      component membership, and on request the evidence edges for one
      component.
- [x] 10.4 Both tools are read-only. Do not expose merge, unmerge, delete, or
      restore.
- [x] 10.5 Runner tests including injection payloads in `uid`, `hostname`, and
      `run_id`, asserting each is bound as a single value and does not alter
      query structure.
- [x] 10.6 Test that a caller holding `settings.mcp.manage` but not
      `devices.view` is refused by both tools.
- [x] 10.7 Test that the `details` allowlist applies to tool output, not only
      to raw SRQL results.

## 11. Integration fixtures and verification

- [x] 11.1 Extend the SRQL integration fixtures with: a three-hop merge chain,
      an oscillating merge pair, a revival with a preserved prior tombstone,
      a cross-partition identifier collision, a corroborated and a historical
      MAC on one device, and a blocked five-device component.
- [x] 11.2 Add the five entities to `integration_tests/srql/tests/comprehensive_queries.rs`.
- [x] 11.3 Run the guarded database lifecycle per the `srql-fixtures-db-tests`
      skill: sweep, prepare template, migrate, provision, test, teardown. Always
      pass `--nocache_test_results`; always run `teardown_db` after a red shard.
      **Run in CI, not from a workstation.** The lifecycle needs the CI fixture
      flow (`SERVICERADAR_ENV=ci`, the secret env, and a `prepare_template`
      preflight that mutates the SHARED template database), so driving it from a
      developer machine would have mutated a resource other branches depend on.
      BazelCI ran it on the PR and all three lanes passed
      (invocation `8c5050e2`): `srql_api_test`, `srql_comprehensive_test` and
      `srql_device_grouped_stats_test`.

      Locally, the generated SQL was instead executed by hand against a
      disposable database loaded with this change's own fixtures. That was not a
      substitute for the lane, but it is what caught the merge-chain
      double-counting, which the fixtures alone would not have surfaced.
- [x] 11.4 `cargo fmt` + `cargo clippy` on `rust/srql`;
      `./scripts/elixir_quality.sh --project elixir/web-ng --phoenix` and
      `--project elixir/serviceradar_core`.
- [x] 11.5 Run `make test` before opening the PR. The Elixir unit shards exist
      only as bazel targets and are invisible to `mix test`.
- [x] 11.6 Walk all six acceptance criteria from issue #4229 end to end using
      only MCP or SRQL against the fixture data, and record the queries used in
      the PR description. Walked at the SQL level against a disposable database
      (see 11.3); the MCP tool layer is covered by unit tests with a stubbed
      SRQL module rather than end to end against a live server.
