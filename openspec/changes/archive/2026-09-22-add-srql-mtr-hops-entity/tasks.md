## 1. Proposal
- [x] 1.1 Validate OpenSpec proposal with strict mode.
- [x] 1.2 Get approval before implementation.

## 2. Rust SRQL Backend
- [x] 2.1 Add `mtr_hops` Diesel table definition to `rust/srql/src/schema.rs`.
- [x] 2.2 Add `MtrHopRow` struct to `rust/srql/src/models/observability.rs` with `Queryable`/`Selectable` derives and `into_json` projection.
- [x] 2.3 Add `MtrHops` variant to `rust/srql/src/parser/entity.rs` and ensure the parser maps `"mtr_hops"` to it.
- [x] 2.4 Create `rust/srql/src/query/mtr_hops.rs` with `execute` and `to_sql_and_params` functions supporting time-range filtering, field filters (`trace_id`, `addr`, `hostname`, `asn`, `asn_org`, `hop_number`), stats aggregation (`avg`/`min`/`max`/`sum`/`count` on loss and latency columns) grouped by `addr`, `asn`, `asn_org`, or `hop_number`.
- [x] 2.5 Add viz metadata for `mtr_hops` in `rust/srql/src/query/viz/observability.rs`.
- [x] 2.6 Route `Entity::MtrHops` in `rust/srql/src/query/mod.rs` (or the engine dispatch function) to the new module.
- [x] 2.7 Fix `rust/srql/src/query/mtr_traces.rs` to return `InvalidRequest` when a `stats:` clause is present.
- [x] 2.8 Write unit tests in `mtr_hops.rs` covering: time-range predicate, addr filter, stats-by-addr, stats-by-asn, rejection of unsupported fields.
- [x] 2.9 Run `cargo check --workspace --lib --bins --tests` and `bazel build //rust/...` clean. Verified by BazelCI on the merge of the implementation branch, which builds `//...`.

## 3. Elixir Web-NG Catalog And Access
- [x] 3.1 Register `mtr_hops` entry in the SRQL catalog (`elixir/web-ng/lib/serviceradar_web_ng_web/srql/catalog.ex`).
- [x] 3.2 Add RBAC grant for `mtr_hops` in `elixir/web-ng/lib/serviceradar_web_ng_web/srql/entity_access.ex`.

## 4. MTR Network Pathing Analytics Dashboard

**Superseded by `add-mtr-path-analytics`.** Not implemented here, for two reasons
found while attempting it:

- The panel queries specified below are statistically wrong. `avg(loss_pct)` is a
  mean of ratios where loss is a ratio of sums, and `avg(avg_us)` is unweighted;
  both disagree with the correct figure whenever the hops in a group sent unequal
  probe counts, which is the normal case. `mtr_data.ex:541-556` already computes
  both correctly in raw SQL. The `loss_ratio` and `wavg` aggregates needed to
  express them did not exist in SRQL.
- Task 4.1 cannot be implemented as written. `/analytics` is already bound to
  `AuthoredDashboardLive.Index` in `router.ex`, and `live/analytics_live/index.ex`
  is an unrelated pre-existing page with no MTR content. The dashboard needs no
  new route: it is seeded as a public authored dashboard through the existing
  `SystemReports` mechanism.

- [x] 4.1 Superseded: no new route or LiveView. See `add-mtr-path-analytics` section 7.
- [x] 4.2 Superseded: loss panel uses `loss_ratio(sent, received)`.
- [x] 4.3 Superseded: latency panel uses `wavg(avg_us, received)`.
- [x] 4.4 Superseded: ASN panel uses `loss_ratio(sent, received)`.
- [x] 4.5 Superseded: time-window selector and drill-down move with the dashboard.
- [x] 4.6 Superseded: no new LiveView to compile.

## 5. Validation
- [x] 5.1 Run `make test` (Bazel unit shards). Green on the implementation branch.
- [x] 5.2 Verify `in:mtr_hops stats:` returns aggregated rows via the SRQL service. Covered by unit tests; the panel-facing aggregates are verified in `add-mtr-path-analytics` section 9.
- [x] 5.3 Verify `in:mtr_traces stats:count() by device_id` returns a clear error (not silent empty).
- [x] 5.4 Superseded: dashboard rendering moves to `add-mtr-path-analytics` section 9.
