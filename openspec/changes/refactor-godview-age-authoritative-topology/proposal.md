# Change: Make AGE/backend authoritative for GodView topology shape

## Why
GodView still relies on frontend-side edge pairing, interface attribution, and fallback heuristics to compensate for mixed mapper evidence. This causes regressions where topology exists but directional packet flow disappears per edge. The topology contract must move fully backend-side so AGE query output is already in render-ready shape.

## What Changes
- Introduce a canonical backend topology edge shape (directional interface attribution + directional telemetry fields) as the sole GodView input contract.
- Move pair selection and edge confidence arbitration to backend reconciliation (mapper/core + AGE projection).
- Require AGE queries to return fully resolved edge attributes (`source`, `target`, `if_index_ab`, `if_index_ba`, `flow_pps_ab`, `flow_pps_ba`, `flow_bps_ab`, `flow_bps_ba`, `capacity_bps`, `telemetry_eligible`, evidence metadata).
- Remove frontend topology inference/candidate-selection behavior from GodView rendering path; frontend only renders provided nodes/edges and UI-only clustering.
- Add reconciliation diagnostics for dropped/rejected evidence and unresolved interface attribution so missing animation is debuggable from backend telemetry.
- Define migration gates to ensure no topology/animation regressions during cutover.

## Impact
- Affected specs:
  - `network-discovery`
  - `age-graph`
- Affected code (expected):
  - `go/pkg/mapper/snmp_polling.go`
  - `go/pkg/mapper/discovery.go`
  - `elixir/serviceradar_core/lib/serviceradar/network_discovery/mapper_results_ingestor.ex`
  - `elixir/serviceradar_core/lib/serviceradar/topology/topology_graph.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng/topology/god_view_stream.ex`
  - `elixir/web-ng/assets/js/lib/god_view/*`
