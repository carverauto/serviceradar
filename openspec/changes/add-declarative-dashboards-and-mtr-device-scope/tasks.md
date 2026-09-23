## 1. Proposal

- [ ] 1.1 Validate with `openspec validate add-declarative-dashboards-and-mtr-device-scope --strict`.
- [ ] 1.2 Get approval before implementation.
- [ ] 1.3 Resolve the open gates in [design.md](design.md): whether `mtr_hops`
      compression is enabled on any deployed installation, whether export carries
      access grants and report schedules, and runtime vs compile-time loading of
      the definition directory.

## 2. Definition format

- [ ] 2.1 Define the JSON document: mandatory `version`, dashboard identity and
      fields, ordered panels with query, visual type, bindings and `layout`.
- [ ] 2.2 Validate on load and refuse with a message naming the file and the
      offending field. An unknown `version` is a refusal, never a skip.
- [ ] 2.3 Reject a definition whose panels overlap in the grid or omit `layout`.
      Panels that all default to the same cell stack and render as one, which is
      how the shipped MTR dashboard showed a single panel.
- [ ] 2.4 Reject a panel whose `visual_type` the resource would not accept, and a
      binding naming a field the panel's own query does not select.

## 3. Import

- [ ] 3.1 Load definitions from the declared directory and create what is absent,
      matched by slug.
- [ ] 3.2 **Never rewrite an existing dashboard or panel.** No title, description,
      time range, query, binding or layout is written back over a stored value.
- [ ] 3.3 Create panels for a dashboard row that has none, as an interrupted
      creation.
- [ ] 3.4 Reduce `SystemReports` to a loader over shipped definitions, removing the
      hardcoded `@dashboards` list while preserving the existing `new-devices`
      slug, query and metadata exactly.
- [ ] 3.5 Move `new-devices` and `mtr-path-analytics` to definition files.

## 4. Export

- [ ] 4.1 Serialize an authored dashboard and its panels to the definition format.
- [ ] 4.2 Expose export to an operator holding dashboard view authority, over the
      same authorization the dashboard itself uses.
- [ ] 4.3 State in the spec which fields are outside the format — ids, timestamps,
      `dashboard_ref`, ownership, grants, schedules — so "equivalent" is defined.

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
- [ ] 5.2 Populate both at ingest in `MtrMetricsIngestor` from the owning trace.
- [ ] 5.3 Chunk-aware, batched, idempotent, resumable backfill for existing rows.
      Not a single `UPDATE`: `mtr_hops` is a hypertable and one statement across
      all chunks is the shape that OOM-kills a node.
- [x] 5.4 Handle compressed chunks. **Measured: not needed.** `UPDATE` on a
      compressed chunk succeeds and persists on TimescaleDB 2.24.0 — verified by
      compressing a 60-day-old chunk, updating it, and reading the value back.
      DML on compressed chunks is supported from 2.11. The backfill instead checks
      the extension version and refuses below 2.11 with a clear message.
- [ ] 5.5 Accept `target_ip` and `device_id` as `in:mtr_hops` filters in the
      relational compiler, and add them to the web-ng SRQL catalog
      `filter_fields` so the query builder and `srql/page.ex` accept them.
- [ ] 5.6 Same filters in `starrocks.rs`, or an explicit refusal there.

## 6. Trace-level aggregation

- [ ] 6.1 Replace the blanket `stats:` rejection in `mtr_traces.rs` with real
      aggregation: grouping by `target_ip`, `device_id`, `agent_id`, `protocol`,
      and counting with `target_reached` to give reach rate per target.
- [ ] 6.2 Same in `starrocks.rs`, or an explicit refusal.
- [ ] 6.3 Update the error text that currently advises "use `in:mtr_hops` for
      hop-level analytics" — advice that led nowhere, since `in:mtr_hops` could not
      name a device.
- [ ] 6.4 Register `mtr_traces` stats fields in the web-ng SRQL catalog.

## 7. The dashboard

- [ ] 7.1 Loss by hop position, so loss that begins at a position and continues is
      distinguishable from loss at one position only.
- [ ] 7.2 Loss by hop address with a trace count beside it, so a shared hop is
      distinguishable from one seen twice.
- [ ] 7.3 Reach rate per target from `mtr_traces`, as the endpoint signal.
- [ ] 7.4 Every panel scopeable to a device set via `target_ip`, with the default
      shipped scope documented in the definition.
- [ ] 7.5 Title and caption each panel so an ICMP-rate-limiting artifact cannot be
      read as a fault, and so the AS panel is not read as fleet-wide.
- [ ] 7.6 Drop or retitle panels that aggregate loss across all hop positions
      without qualification.

## 8. Tests

- [ ] 8.1 Definition validation: version, missing layout, overlapping panels,
      unaccepted visual type, binding naming an unselected field. Each with a
      negative case confirmed red before green.
- [ ] 8.2 Import creates when absent; does not revert an edited query, title or
      description; does not remove an operator-added panel; completes a dashboard
      with no panels; leaves other dashboards untouched. In
      `//elixir/web-ng:networks_live_db_test` against the shared SRQL fixture, as
      a `*_db_test.exs` added to that target's `srcs`.
- [ ] 8.3 Export/import round trip against the fixture database: export, import
      into a clean slug, assert equivalence over the fields the format defines.
- [ ] 8.4 SRQL: `target_ip` and `device_id` filters on `mtr_hops`; `stats:` on
      `mtr_traces` grouping by target with reach counts; both dialects; parity
      guard extended.
- [ ] 8.5 Backfill: resumable after interruption, idempotent on a second run, and
      correct for a hop whose trace has no `device_id`.
- [ ] 8.6 A test asserting no shipped definition aggregates loss across all hop
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

- [ ] 10.1 Withdraw task 10.1 of `add-mtr-path-analytics`. It records that web-ng
      has no DB-backed Bazel target and defers work on that basis. The claim is
      **false**: `//elixir/web-ng:networks_live_db_test` runs against the shared
      SRQL fixture in CI (`buildbuddy.yaml`) and already contains
      `group_access_db_test.exs` and `authored_dashboard_live_test.exs`. The
      BUILD.bazel comment cited said only that `test/integration/**` and
      `test/property/**` have no home, which was over-generalized.
- [ ] 10.2 Update `add-mtr-path-analytics` to record that its panel set is
      superseded here, and why: aggregating loss across all hop positions presents
      ICMP deprioritization as fault, and none of its panels could be scoped to a
      device.
