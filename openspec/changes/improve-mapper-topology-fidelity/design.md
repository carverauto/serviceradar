## Context
The current mapper pipeline reliably emits LLDP observations from a small subset of devices, but it does not resolve enough neighbor identity to build complete routed/L2 topology in AGE or to promote downstream devices into inventory. The observed behavior indicates three systemic gaps:
1. Discovery traversal coverage and cross-interface seed normalization are incomplete.
2. Neighbor payload normalization is insufficient (`neighbor_mgmt_addr` absent, weak identifier fallback).
3. Projection contracts are ambiguous about device-level vs interface-level edges.

In farm01, `192.168.2.1` is a valid interface on the same router identity. Discovery must unify multi-interface identities (`192.168.1.1`/`192.168.2.1`) instead of treating seed-interface choice as topology scope.

## Goals / Non-Goals
- Goals:
  - Produce consistent device-level topology for known farm01/tonka01 segments from configured seed routers.
  - Preserve interface-level evidence while enforcing deterministic device adjacency projection.
  - Promote discovered downstream endpoints/switches into inventory even when they lack direct SNMP availability.
  - Add a synthetic topology harness that can replay deterministic mapper evidence and validate expected graph output.
  - Add measurable quality gates and telemetry for mapper topology output.
- Non-Goals:
  - Implementing multipath/ECMP probing algorithms (covered by separate multipath change work).
  - Building new UI graph rendering paradigms.

## Decisions
- Decision: Introduce bounded recursive discovery expansion from configured seeds into discovered routed subnets and L2 neighbors.
  - Rationale: narrow polling misses reachable domains and downstream switch/client segments.
- Decision: Define a canonical neighbor identity object in mapper output (`neighbor_identity`) with ordered resolution keys.
  - Resolution priority: management IP > explicit device ID > chassis ID + port ID > MAC/ARP evidence.
- Decision: Normalize seed interfaces to canonical device identity so multi-interface routers are treated as one node.
  - Rationale: farm01 can be seeded via `192.168.1.1` or `192.168.2.1` and should yield the same topology root.
- Decision: Keep `CONNECTS_TO` as device-to-device only; store interface/link evidence separately and derive device edges from it.
  - Rationale: current ambiguity allows interface-only adjacency that underrepresents device graph quality.
- Decision: Add unresolved-neighbor persistence and periodic reconciliation.
  - Rationale: avoids data loss when identity cannot be resolved in first pass.
- Decision: Promote endpoint sightings from bridge/CAM/ARP evidence into low-confidence inventory records with freshness timestamps.
  - Rationale: captures devices like `192.168.10.96` observed indirectly from managed switches.
- Decision: Build a synthetic topology fixture and replay runner for regression testing.
  - Rationale: reproducible topology tests are faster and safer than relying only on live lab state.

## Risks / Trade-offs
- Increased poll breadth can increase runtime and SNMP load.
  - Mitigation: max-depth, max-targets-per-run, and adaptive backoff/time budgets.
- More aggressive endpoint promotion may increase noisy inventory records.
  - Mitigation: confidence thresholds, stale aging, and source-tagged records.
- Tightened projection semantics may break assumptions in existing graph queries.
  - Mitigation: transitional dual-write period and query compatibility shim if needed.

## Migration Plan
1. Add mapper payload fields and ingestor support while preserving backward compatibility.
2. Enable dual projection (existing + new semantics) behind a feature flag for one release.
3. Add synthetic topology replay test coverage and verify farm01/tonka01 fixture assertions in CI.
4. Validate quality metrics in demo.
5. Switch default projection semantics and remove compatibility path after verification.

## Open Questions
- Should dynamic recursion depth be job-level configurable or globally bounded only?
- Should unmanaged endpoint promotion create full OCSF device records immediately or staged candidates first?
