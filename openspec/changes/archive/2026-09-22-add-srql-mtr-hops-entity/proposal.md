# Change: Add SRQL in:mtr_hops entity with stats aggregation

## Why
Operators investigating network pathing issues across large device fleets need to
aggregate per-hop MTR statistics by router address or ASN to identify shared-path
packet loss or latency hotspots. The existing `in:mtr_traces` entity exposes only
trace-level metadata; `platform.mtr_hops` is not queryable via SRQL at all. A
network pathing analytics dashboard requires `stats:avg(loss_pct) by addr` and
`stats:avg(avg_us) by asn` style aggregations across `mtr_hops`, which is
impossible today.

A secondary issue: `in:mtr_traces` currently silently discards `stats:` clauses
rather than returning an error, causing dashboards to appear empty with no
diagnostic message.

## What Changes
- Add `in:mtr_hops` as a new first-class SRQL entity backed by `platform.mtr_hops`.
  Supported filters: `trace_id`, `addr`, `hostname`, `asn`, `asn_org`, `hop_number`,
  `time`. Supported stats aggregations: `avg`, `min`, `max`, `sum`, `count` on
  `loss_pct`, `avg_us`, `min_us`, `max_us`, `jitter_us`; `by` grouping on `addr`,
  `asn`, `asn_org`, `hop_number`.
- Fix `in:mtr_traces` to return `InvalidRequest` when a `stats:` clause is present
  instead of silently ignoring it.
- Add an MTR network pathing analytics dashboard at `/analytics` that uses
  `in:mtr_hops stats:...` queries to surface hop-level loss and latency aggregates.
- Register `mtr_hops` in the SRQL catalog and RBAC entity-access list.

## Impact
- Affected specs: `srql`, `mtr-diagnostics`
- Affected code:
  - `rust/srql/src/schema.rs` — add `mtr_hops` Diesel table definition
  - `rust/srql/src/parser/entity.rs` — add `MtrHops` variant
  - `rust/srql/src/models/observability.rs` — add `MtrHopRow` struct
  - `rust/srql/src/query/mtr_hops.rs` — new query module (filter + stats)
  - `rust/srql/src/query/viz/observability.rs` — viz metadata for hops
  - `rust/srql/src/query/mod.rs` — route `MtrHops` to new module
  - `rust/srql/src/query/mtr_traces.rs` — reject `stats:` with error
  - `elixir/web-ng/lib/serviceradar_web_ng_web/srql/catalog.ex` — register `mtr_hops`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/srql/entity_access.ex` — RBAC grant
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/analytics_live/` — new LiveView
