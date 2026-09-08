## 1. Mapper Discovery Scope and Payload
- [ ] 1.1 Implement bounded recursive target expansion from configured seeds into discovered routed and L2-neighbor targets.
- [ ] 1.2 Add canonical `neighbor_identity` fields to mapper topology output with deterministic resolution order.
- [ ] 1.3 Populate neighbor management IP and fallback identity evidence (chassis/port/MAC/ARP) whenever available.
- [ ] 1.4 Normalize multi-interface seed addresses to canonical device identity (for example `192.168.1.1` and `192.168.2.1` for farm01).
- [ ] 1.5 Add mapper quality counters (`topology_neighbors_total`, `topology_neighbors_with_mgmt_ip`, `topology_neighbors_unresolved_total`).

## 2. Core Ingestion and Reconciliation
- [ ] 2.1 Update mapper ingestion to resolve neighbor observations to canonical device IDs in a single ingestion transaction.
- [ ] 2.2 Persist unresolved observations for delayed reconciliation instead of dropping them.
- [ ] 2.3 Implement periodic reconciliation to backfill unresolved neighbor/device links when new inventory signals arrive.

## 3. AGE Projection Semantics
- [ ] 3.1 Enforce device-to-device semantics for `CONNECTS_TO` projection.
- [ ] 3.2 Preserve interface-level evidence as separate nodes/edges and map it to parent device adjacency.
- [ ] 3.3 Add stale-edge lifecycle handling for inferred links that are no longer observed.

## 4. Inventory Promotion for Downstream Endpoints
- [ ] 4.1 Promote downstream endpoint observations (ARP/bridge/CAM) into inventory candidate or device records with confidence and last-seen.
- [ ] 4.2 Ensure indirect sightings can surface devices in subnets reachable via seed routers (for example Aruba behind tonka01).

## 5. Synthetic Topology Harness and Verification
- [ ] 5.1 Build a synthetic topology fixture generator for router/switch/AP/endpoint adjacency and multi-subnet links.
- [ ] 5.2 Add replay tests that feed synthetic mapper outputs through ingestor + AGE projection and assert expected graph edges.
- [ ] 5.3 Add fixture assertions for farm01/tonka01 expected adjacency and visibility of `192.168.10.154` and `192.168.10.96`.
- [ ] 5.4 Add integration assertions for quality thresholds (minimum neighbor management-IP population and edge completeness).
