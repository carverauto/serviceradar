## 1. Proposal

- [ ] 1.1 Validate with `openspec validate add-declarative-dashboards-and-mtr-device-scope --strict`.
- [ ] 1.2 Get approval before implementation.
- [ ] 1.3 Resolve the open gates in [design.md](design.md): whether `mtr_hops`
      compression is enabled on any deployed installation, whether export carries
      access grants and report schedules, and runtime vs compile-time loading of
      the definition directory.

## 2. Definition format

- [x] 2.1 Define the JSON document: mandatory `version`, dashboard identity and
      fields, ordered panels with query, visual type, bindings and `layout`.
- [x] 2.2 Validate on load and refuse with a message naming the file and the
      offending field. An unknown `version` is a refusal, never a skip.
- [x] 2.3 Reject a definition whose panels overlap in the grid or omit `layout`.
      Panels that all default to the same cell stack and render as one, which is
      how the shipped MTR dashboard showed a single panel.
- [x] 2.4 Reject a panel whose `visual_type` the resource would not accept, and a
      binding naming a field the panel's own query does not select.

## 3. Import

- [x] 3.1 Load definitions from the declared directory and create what is absent,
      matched by slug.
- [x] 3.2 **Never rewrite an existing dashboard or panel.** No title, description,
      time range, query, binding or layout is written back over a stored value.
- [x] 3.3 Create panels for a dashboard row that has none, as an interrupted
      creation.
- [x] 3.4 Reduce `SystemReports` to a loader over shipped definitions, removing the
      hardcoded `@dashboards` list while preserving the existing `new-devices`
      slug, query and metadata exactly.
- [x] 3.5 Move `new-devices` and `mtr-path-analytics` to definition files.

## 4. Export

- [ ] 4.1 Serialize an authored dashboard and its panels to the definition format.
- [ ] 4.2 Expose export to an operator holding dashboard view authority, over the
      same authorization the dashboard itself uses.
- [ ] 4.3 State in the spec which fields are outside the format — ids, timestamps,
      `dashboard_ref`, ownership, grants, schedules — so "equivalent" is defined.

## 4b. Shared package-source module (extraction)

The repository-source logic is generic but namespaced under `Plugins`. Reports are
the third consumer, so it moves once rather than being copied a third time.

- [ ] 4b.1 Extract a project-owned shared module from `Plugins.RepoUrl`,
      `Plugins.GithubImporter`, `Plugins.FirstPartyImporter` and
      `Plugins.FirstPartyReleaseClient`: repository-URL parsing and boundary
      enforcement, ref resolution, signature verification and policy, release
      listing, and index-asset reading.
- [ ] 4b.2 **Route every external fetch through `ServiceRadar.HTTP.EgressClient`.**
      `GithubImporter` currently calls `api.github.com` and
      `raw.githubusercontent.com` with raw `Req`, including a streaming artifact
      download, and no importer under `plugins/` references `EgressClient` at all.
      Per that client's own documentation the shared Finch pool bypasses the egress
      allowlist and Mint cannot tunnel through the CONNECT proxy this deployment
      runs behind -- so GitHub import cannot work in a proxied deployment today,
      and only there. Use `fetch_body/2` for API responses and
      `download_to_file/3` for artifacts.
- [ ] 4b.3 Repoint plugins and add-ons at the shared module with no behaviour
      change other than the egress fix, and keep their existing tests green as the
      evidence.
- [ ] 4b.4 A test asserting no module under the package-source namespace calls
      `Req` directly for an external host, so the violation cannot return.

## 4c. Report import sources

- [ ] 4c.1 Give a report definition the same source model as an add-on package:
      `source_type` one_of `[:upload, :github, :first_party]` with release tag,
      commit, content hash and signature provenance.
- [ ] 4c.2 `:first_party` resolves against the OSS repository's default repo URL
      and its index asset, listing the reports available to import; some ship
      enabled by default.
- [ ] 4c.3 `:github` resolves against an operator-nominated repository, subject to
      the same repo-boundary and signature policy as a plugin import.
- [ ] 4c.4 `:upload` accepts a definition directly, validated on the same path as
      one fetched from a source, so an uploaded report cannot reach the database
      under looser rules.
- [ ] 4c.5 Import is idempotent and never overwrites operator edits, exactly as for
      a shipped definition. An imported report that has been customised is not
      stomped by re-importing a newer version of it.
- [ ] 4c.6 A report needs no renderer artifact, so do NOT route it through
      `GithubImporter.fetch_dashboard/1`, which requires one.

## 5. MTR device attribution

- [x] 5.0 Configure TimescaleDB compression and retention for `mtr_hops` and
      `mtr_traces`, which had neither. Segment hops by `addr`, not by the new
      `target_ip`: that column is NULL on every existing row until the backfill,
      and segmenting on it would create one enormous NULL segment. Traces segment
      by `target_ip`, which is populated there. Verified every statement against a
      real TimescaleDB 2.24.0 hypertable.

- [x] 5.1 Elixir migration adding `target_ip` and `device_id` to
      `platform.mtr_hops`, `prefix: "platform"`, with indexes supporting a
      `target_ip` filter over a time range.
- [x] 5.2 Populate both at ingest in `MtrMetricsIngestor` from the owning trace.
      Read off the trace ROW rather than the payload, so a hop cannot disagree
      with its own trace about the target.
- [x] 5.3 Chunk-aware, batched, idempotent, resumable backfill for existing rows.
      `MtrHopAttributionBackfill` plus a dry-run-by-default mix task. Verified on a
      real hypertable: correct attribution, an orphan hop left NULL rather than
      mis-attributed, and `UPDATE 0` on a second pass so the drain loop ends.
- [x] 5.4 Handle compressed chunks. **Measured: not needed.** `UPDATE` on a
      compressed chunk succeeds and persists on TimescaleDB 2.24.0 — verified by
      compressing a 60-day-old chunk, updating it, and reading the value back.
      DML on compressed chunks is supported from 2.11. The backfill instead checks
      the extension version and refuses below 2.11 with a clear message.
- [x] 5.5 Accept `target_ip` and `device_id` as `in:mtr_hops` filters in the
      relational compiler. Wired through five sites that each drop the filter
      silently on their own: Diesel schema, row-filter dispatch, stats WHERE
      builder, row-path bind collection, and MtrHopRow's projection.
- [x] 5.6 Same filters in `starrocks.rs`, or an explicit refusal there.
      **Refusal, and it already existed.** `dataset_for/1` has no mapping for MTR
      entities, so `translate/3` returns `starrocks_unsupported_entity` -- an
      explicit refusal, not a silent partial answer. No dialect code was needed.
      Added a guard test instead, which is what would catch a future
      half-implementation: a dataset mapping added without the target_ip/device_id
      field mappings would otherwise return fleet-wide rows under a per-device
      title. MTR in the warehouse is owned by extend-starrocks-to-all-telemetry
      task 3.4.
- [x] 5.7 Add `target_ip` and `device_id` to the `mtr_hops` catalog
      `filter_fields`, so `srql/page.ex` stops rejecting them and the query builder
      offers them.

## 5b. count() parity across the MTR entities

- [x] 5b.1 Accept a zero-argument `count()` on `in:mtr_hops` as `COUNT(*)`, and
      keep `count(<column>)` working. It currently fails with
      `unsupported column ''` because the aggregation parser requires exactly one
      column argument, which blocks the trace-count panel -- the very thing that
      distinguishes a genuinely shared hop from one seen twice.
      `mtr_traces` already accepts both forms, so this is symmetry a caller can
      reasonably expect.
- [x] 5b.2 Tests for both forms on both entities, with the zero-argument case
      confirmed to fail before the fix.

## 6. Trace-level aggregation

- [x] 6.1 Replace the blanket `stats:` rejection in `mtr_traces.rs` with real
      aggregation. Reach rate needs no new function: `target_reached` is an
      aggregatable 0/1 indicator cast to int, and the mean of an indicator is the
      proportion. `loss_ratio`/`wavg` are refused here with a pointer to
      `in:mtr_hops`, since probe counters live on hops.
- [x] 6.2 Same in `starrocks.rs`, or an explicit refusal. Covered by the same
      pre-existing entity refusal and guard test as 5.6.
- [x] 6.3 Update the error text that currently advises "use `in:mtr_hops` for
      hop-level analytics". Removed with the rejection itself; the remaining
      pointer to `in:mtr_hops` is on `loss_ratio`/`wavg`, where it is correct.
- [x] 6.4 Register `mtr_traces` stats fields in the web-ng SRQL catalog.

## 7. The dashboard

- [x] 7.1 Loss by hop position, so loss that begins at a position and continues is
      distinguishable from loss at one position only.
- [x] 7.2 Loss by hop address with a trace count beside it, so a shared hop is
      distinguishable from one seen twice.
- [x] 7.3 Reach rate per target from `mtr_traces`, as the endpoint signal.
- [x] 7.4 Every panel scopeable to a device set via `target_ip`, with the default
      shipped scope documented in the definition.
- [x] 7.5 Title and caption each panel so an ICMP-rate-limiting artifact cannot be
      read as a fault, and so the AS panel is not read as fleet-wide.
- [x] 7.6 Drop or retitle panels that aggregate loss across all hop positions
      without qualification.

## 8. Tests

- [x] 8.1 Definition validation: version, missing layout, overlapping panels,
      unaccepted visual type, binding naming an unselected field. Each with a
      negative case confirmed red before green.
- [x] 8.2 Import creates when absent; does not revert an edited query, title or
      description; does not remove an operator-added panel; completes a dashboard
      with no panels; leaves other dashboards untouched. In
      `//elixir/web-ng:networks_live_db_test` against the shared SRQL fixture, as
      a `*_db_test.exs` added to that target's `srcs`.
- [ ] 8.3 Export/import round trip against the fixture database: export, import
      into a clean slug, assert equivalence over the fields the format defines.
- [x] 8.4 SRQL: `target_ip` and `device_id` filters on `mtr_hops`; `stats:` on
      `mtr_traces` grouping by target with reach counts; both dialects; parity
      guard extended.
      `mtr_hops` tests (target_ip_filter_scopes_hops_to_a_device,
      device_scoped_stats_constrain_on_the_attribution_column,
      device_id_is_filterable_and_groupable, hop_rows_project_their_attribution)
      pre-existed in mtr_hops.rs.  New in mtr_traces.rs:
      `device_id_groups_by_attribution_column` (reach rate grouped by device_id)
      and `every_trace_group_by_field_compiles_in_a_stats_query` (parity guard
      iterating TRACE_GROUP_BY_FIELDS).  StarRocks guard extended with three
      device_id/reach-rate query vectors in
      `mtr_entities_are_refused_by_the_warehouse_dialect`.
- [x] 8.5 Backfill: resumable after interruption, idempotent on a second run, and
      correct for a hop whose trace has no `device_id`.
      Five tests in `test/serviceradar/observability/mtr_hop_attribution_backfill_db_test.exs`
      (async DataCase, `transaction_owner`): attributes target_ip and device_id from
      trace; idempotent (second full run: rows_updated=0); skips already-attributed rows
      (simulates resuming after a partial run); hop with nil device_id on trace gets
      target_ip set but device_id=nil; orphan hop (no matching trace) counted in
      rows_unrecoverable, not retried. Registered in INTEGRATION_SOURCE_DISPOSITIONS.tsv
      and ASYNC_INTEGRATION_SRCS.
- [x] 8.6 A test asserting no shipped definition aggregates loss across all hop
      positions without a qualifying title, so the misleading panel cannot return.

## 9. Validation

- [ ] 9.1 `cargo check --workspace --lib --bins --tests`, `cargo fmt`, `cargo clippy` clean.
- [ ] 9.2 `bazel build //rust/...` clean.
- [ ] 9.3 `make test` green.
- [ ] 9.4 `./scripts/elixir_quality.sh --project elixir/web-ng --phoenix --lint-only` clean.
- [ ] 9.5 `mix serviceradar.db.migrate` applies the migration on a database that
      already carries hypertables, and the backfill completes.
- [ ] 9.6 Verify against real MTR data that a device-scoped panel returns only that
      device's hops, and that reach rate per target matches what
      `/diagnostics/mtr` reports for the same window.
- [ ] 9.7 Verify every panel renders, and that a second startup neither duplicates
      the dashboard nor reverts an edit.

## 10. Corrections carried by this change

- [x] 10.1 Withdraw task 10.1 of `add-mtr-path-analytics`. It records that web-ng
      has no DB-backed Bazel target and defers work on that basis. The claim is
      **false**: `//elixir/web-ng:networks_live_db_test` runs against the shared
      SRQL fixture in CI (`buildbuddy.yaml`) and already contains
      `group_access_db_test.exs` and `authored_dashboard_live_test.exs`. The
      BUILD.bazel comment cited said only that `test/integration/**` and
      `test/property/**` have no home, which was over-generalized.
- [x] 10.2 Update `add-mtr-path-analytics` to record that its panel set is
      superseded here, and why: aggregating loss across all hop positions presents
      ICMP deprioritization as fault, and none of its panels could be scoped to a
      device.
