# Change: Move canonical edge telemetry enrichment to backend projection

## Why
GodView still computes edge telemetry enrichment in `web-ng` (`GodViewStream`). That creates a view-specific topology contract and prevents API/SRQL consumers from getting the same canonical edge telemetry shape without reimplementing enrichment. Topology shape and telemetry must be produced once in backend canonical graph/read-model paths and consumed as-is by all clients.

## What Changes
- Define backend-owned canonical edge telemetry as part of `CANONICAL_TOPOLOGY` read shape, including directional and aggregate telemetry fields.
- Move edge telemetry enrichment from `web-ng` presentation pipeline into backend reconciliation/projection pipeline.
- Require runtime graph reads to return pre-enriched canonical edges (topology + telemetry) without UI-side telemetry computation.
- Keep UI responsibilities limited to rendering and presentation-only behavior (layout/animation), using backend fields directly.
- Add diagnostics and validation counters in backend for telemetry attribution coverage, staleness, and fallback usage.
- Keep SRQL/API endpoint expansion out of scope for this change, but ensure backend canonical shape is query-ready for those consumers.

## Impact
- Affected specs:
  - `age-graph`
  - `network-discovery`
- Affected code (expected):
  - `elixir/serviceradar_core/lib/serviceradar/network_discovery/topology_graph.ex`
  - `elixir/serviceradar_core/lib/serviceradar/network_discovery/mapper_results_ingestor.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng/topology/runtime_graph.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng/topology/god_view_stream.ex`
  - `elixir/web-ng/native/god_view_nif/src/core/utils.rs`
  - `elixir/web-ng/native/god_view_nif/src/types/graph.rs`
- Data model impact:
  - `CANONICAL_TOPOLOGY` relationships carry authoritative telemetry fields (`flow_pps`, `flow_bps`, `capacity_bps`, `flow_pps_ab`, `flow_pps_ba`, `flow_bps_ab`, `flow_bps_ba`, `telemetry_source`, freshness metadata).
  - `web-ng` no longer computes telemetry from `timeseries_metrics` for topology edges.
