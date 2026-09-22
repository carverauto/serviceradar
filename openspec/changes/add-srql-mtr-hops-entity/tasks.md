## 1. Proposal
- [ ] 1.1 Validate OpenSpec proposal with strict mode.
- [ ] 1.2 Get approval before implementation.

## 2. Rust SRQL Backend
- [ ] 2.1 Add `mtr_hops` Diesel table definition to `rust/srql/src/schema.rs`.
- [ ] 2.2 Add `MtrHopRow` struct to `rust/srql/src/models/observability.rs` with `Queryable`/`Selectable` derives and `into_json` projection.
- [ ] 2.3 Add `MtrHops` variant to `rust/srql/src/parser/entity.rs` and ensure the parser maps `"mtr_hops"` to it.
- [ ] 2.4 Create `rust/srql/src/query/mtr_hops.rs` with `execute` and `to_sql_and_params` functions supporting time-range filtering, field filters (`trace_id`, `addr`, `hostname`, `asn`, `asn_org`, `hop_number`), stats aggregation (`avg`/`min`/`max`/`sum`/`count` on loss and latency columns) grouped by `addr`, `asn`, `asn_org`, or `hop_number`.
- [ ] 2.5 Add viz metadata for `mtr_hops` in `rust/srql/src/query/viz/observability.rs`.
- [ ] 2.6 Route `Entity::MtrHops` in `rust/srql/src/query/mod.rs` (or the engine dispatch function) to the new module.
- [ ] 2.7 Fix `rust/srql/src/query/mtr_traces.rs` to return `InvalidRequest` when a `stats:` clause is present.
- [ ] 2.8 Write unit tests in `mtr_hops.rs` covering: time-range predicate, addr filter, stats-by-addr, stats-by-asn, rejection of unsupported fields.
- [ ] 2.9 Run `cargo check --workspace --lib --bins --tests` and `bazel build //rust/...` clean.

## 3. Elixir Web-NG Catalog And Access
- [ ] 3.1 Register `mtr_hops` entry in the SRQL catalog (`elixir/web-ng/lib/serviceradar_web_ng_web/srql/catalog.ex`).
- [ ] 3.2 Add RBAC grant for `mtr_hops` in `elixir/web-ng/lib/serviceradar_web_ng_web/srql/entity_access.ex`.

## 4. MTR Network Pathing Analytics Dashboard
- [ ] 4.1 Create `/analytics` LiveView route and module under `elixir/web-ng/lib/serviceradar_web_ng_web/live/analytics_live/`.
- [ ] 4.2 Implement hop-level loss aggregation panel: `in:mtr_hops time:<window> stats:avg(loss_pct) as avg_loss by addr sort:avg_loss:desc`.
- [ ] 4.3 Implement latency heatmap panel: `in:mtr_hops time:<window> stats:avg(avg_us) as avg_latency by addr sort:avg_latency:desc`.
- [ ] 4.4 Implement ASN-grouped loss panel for shared-path analysis: `in:mtr_hops time:<window> stats:avg(loss_pct) as avg_loss by asn sort:avg_loss:desc`.
- [ ] 4.5 Add time-window selector (last 1h, 6h, 24h, 7d) and optional `trace_id` / `addr` drill-down filter.
- [ ] 4.6 Compile and verify no warnings on the new LiveView.

## 5. Validation
- [ ] 5.1 Run `make test` (Bazel unit shards).
- [ ] 5.2 Verify `in:mtr_hops stats:avg(loss_pct) as avg_loss by addr` returns aggregated rows via SRQL service.
- [ ] 5.3 Verify `in:mtr_traces stats:count() by device_id` returns a clear error (not silent empty).
- [ ] 5.4 Verify the `/analytics` dashboard loads and renders with synthetic MTR data.
