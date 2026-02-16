## 1. Discovery and Evidence Contracts
- [x] 1.1 Define typed topology evidence classes (`direct`, `inferred`, `endpoint-attachment`) in mapper payloads.
- [ ] 1.2 Implement LLDP normalization hardening for SNMP/controller payloads with required neighbor identity fields.
- [ ] 1.3 Add optional host-level LLDP frame collection mode in agent with capability checks and clear telemetry.
- [ ] 1.4 Add route snapshot collection (LPM-compatible routes and next-hop sets) for managed routing devices.

## 2. Core Ingestion and Projection
- [x] 2.1 Persist typed evidence records and unresolved observations separately from canonical backbone edges.
- [x] 2.2 Make Core projection the single canonical edge selector; remove conflicting edge policy from downstream layers.
- [x] 2.3 Restrict default infrastructure `CONNECTS_TO` projection to `direct` evidence.
- [x] 2.4 Project inferred and endpoint-attachment relationships as separate edge types with TTL and freshness handling.

## 3. Route Analysis Engine
- [x] 3.1 Implement route analyzer service with LPM, recursive next-hop traversal, ECMP branch support, loop detection, and blackhole detection.
- [x] 3.2 Expose route analysis API for source node + destination IP and include hop-by-hop rationale.
- [ ] 3.3 Add caching and invalidation tied to route snapshot freshness.

## 4. UI and Operator Controls
- [x] 4.1 Add topology layer filters: backbone only, inferred links, endpoint attachments.
- [ ] 4.2 Add route analyzer UI (source node, destination IP, path tree, loop/blackhole status, ECMP branches).
- [ ] 4.3 Add evidence provenance panel so each rendered edge shows protocol/source/confidence/last_seen.

## 5. Validation and Regression Safety
- [ ] 5.1 Build synthetic topology fixtures that include routers, switches, APs, endpoints, and wireguard links.
- [ ] 5.2 Build synthetic route fixtures with normal paths, ECMP, loops, and blackholes.
- [ ] 5.3 Add replay tests that assert deterministic graph output and route analysis output.
- [ ] 5.4 Add quality gates (missing neighbor identity thresholds, edge churn thresholds, unresolved evidence thresholds).
