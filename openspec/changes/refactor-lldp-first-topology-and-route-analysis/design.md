## Context
The current topology flow has policy in three places (ingestion, projection, and UI), leading to unstable graph state when data arrives out of order or partially. We need deterministic contracts and one authoritative projection step.

In parallel, operators need route-path analysis that uses actual routing evidence (not visual guesswork), including LPM and recursive hop behavior.

## Goals / Non-Goals
- Goals:
  - Deterministic topology graph output for the same evidence set.
  - LLDP-first adjacency with explicit inferred/evidence separation.
  - Stable identity handling for multi-interface routers (single canonical device identity).
  - Route analyzer API + UI with recursive tracing and ECMP branch output.
  - Endpoint attachment visibility without polluting backbone adjacency.
- Non-Goals:
  - Replacing existing DIRE identity model.
  - Building a packet-level network emulator.

## Decisions
- Decision: Introduce a strict topology evidence model.
  - `direct`: LLDP/CDP/controller-verified uplink/wireguard-derived
  - `inferred`: correlation-only infrastructure hypotheses
  - `endpoint-attachment`: client/endpoint seen behind infra ports/APs
- Decision: Only `direct` edges are eligible for infrastructure `CONNECTS_TO` backbone projection by default.
- Decision: `inferred` and `endpoint-attachment` are projected as separate typed relationships and surfaced via UI filters.
- Decision: Core projection is the only component that chooses canonical edges. UI may filter/aggregate but must not re-infer topology.
- Decision: Add route snapshot ingestion + LPM/recursive route tracer in Core, with ECMP branch enumeration and loop/blackhole status.
- Decision: Add optional host-level LLDP frame collector mode in agent for environments where SNMP/controller LLDP is incomplete.

## Architecture
1. Mapper collects interface, topology, and route evidence with normalized identity fields.
2. Ingestor writes typed evidence records and resolves canonical device IDs.
3. TopologyGraph projects deterministic graph edges by evidence class.
4. Route analyzer reads route snapshots + topology context and computes path DAGs.
5. UI renders backbone by default, with toggles for inferred and endpoint-attachment layers.

## Risks / Trade-offs
- LLDP frame capture mode may require elevated capabilities in some deployments.
  - Mitigation: keep SNMP/controller LLDP as default path; frame mode is optional.
- Endpoint inclusion can increase graph size/noise.
  - Mitigation: default endpoint-hidden mode + strict filtering and TTL aging.
- Route analysis introduces compute overhead.
  - Mitigation: bounded hop depth, cache path results, and invalidate on route snapshot updates.

## Migration Plan
1. Add typed evidence schema and dual-write from current mapper output.
2. Add deterministic projection path behind feature flag.
3. Add UI filters and route analyzer API/UI.
4. Run synthetic replay acceptance suite in CI.
5. Switch default to deterministic projection and deprecate legacy inference path.

## Open Questions
- Should LLDP frame capture be enabled per job, per agent, or globally?
- Should route snapshots come from SNMP only first, or include CLI/API adapters in the first release?
