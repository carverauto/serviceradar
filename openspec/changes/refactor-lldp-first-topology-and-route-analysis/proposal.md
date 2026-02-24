# Change: Refactor topology pipeline to LLDP-first with deterministic route analysis

## Why
Current topology behavior is unstable in live environments: nodes/edges flap across runs, routers can appear as islands, inferred links can fan out incorrectly, and endpoint visibility is inconsistent. The current pipeline applies overlapping heuristics in mapper ingestion, AGE projection, and UI shaping, which makes outcomes non-deterministic and hard to debug.

We also need first-class route-path analysis similar to `topo-lldp` so operators can answer: “How should traffic route from A to B based on observed routing data?”

## What Changes
- Rework discovery contracts to make LLDP/CDP/verified controller adjacency the authoritative source for infrastructure topology.
- Add explicit LLDP capability in `serviceradar-agent`:
  - robust SNMP LLDP ingestion normalization across vendors
  - optional host-level LLDP frame collection mode for deployments that can grant required privileges
- Split topology evidence into strict classes (`direct`, `inferred`, `endpoint-attachment`) with hard projection rules.
- Remove multi-layer edge decision drift by making Core projection the single source of topology truth and reducing UI-side edge mutation logic.
- Add deterministic route-analysis capability:
  - collect route snapshots (LPM-compatible)
  - compute recursive next-hop paths with loop and blackhole detection
  - support ECMP branch reporting
- Persist unresolved evidence as typed observations for later reconciliation, not as direct backbone edges.
- Add endpoint attachment visibility from switch/AP observations with confidence/freshness semantics and explicit UI filtering controls.
- Add a synthetic replay harness to validate expected topology and route outputs before deployment.

## Impact
- Affected specs:
  - `network-discovery`
  - `age-graph`
  - `device-inventory`
  - `build-web-ui`
- Affected code:
  - `pkg/mapper/*` (LLDP normalization, route snapshot collection, evidence typing)
  - `elixir/serviceradar_core/lib/serviceradar/network_discovery/*` (ingestion/reconciliation/projection)
  - `elixir/web-ng/lib/serviceradar_web_ng/topology/*` (filtering + route analysis UI API)
  - tests/fixtures for synthetic topology and route validation
