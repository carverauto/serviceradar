## 1. Mapper Observation Contract
- [ ] 1.1 Define and implement versioned topology observation envelope (v2) with typed identity/evidence fields.
- [ ] 1.2 Add mapper contract-drift diagnostics: store unknown/extra controller fields and parse-failure counters.
- [ ] 1.3 Implement SNMP flood/trunk suppression for high-fanout ifIndex observations.
- [ ] 1.4 Add mapper debug bundle export for a job run (devices, interfaces, topology evidence, parse diagnostics).

## 2. Core Reconciliation and Projection
- [ ] 2.1 Update mapper ingestor to consume v2 observation envelope and preserve immutable source endpoint IDs.
- [ ] 2.2 Reconcile observations to canonical device identity without rewriting source IDs.
- [ ] 2.3 Project canonical adjacency to AGE with idempotent upserts and freshness timestamps.
- [ ] 2.4 Add stale-edge expiry/retraction for inferred edges with no recent supporting evidence.

## 3. Web Topology Consumption
- [ ] 3.1 Remove UI-layer greedy identifier fusion from topology edge construction.
- [ ] 3.2 Render unresolved endpoints explicitly instead of guessing identity matches.
- [ ] 3.3 Add pipeline telemetry cards for raw observations, unique pairs, final edges, direct/inferred split, unresolved endpoints.

## 4. Data Cleanup and Rebuild
- [ ] 4.1 Create an operator-safe cleanup script/runbook to clear polluted topology evidence and derived AGE edges.
- [ ] 4.2 Add deterministic rebuild flow: trigger discovery, replay ingestion, verify expected adjacency invariants.
- [ ] 4.3 Add pre/post cleanup validation queries and failure gates.

## 5. Rollout Controls
- [ ] 5.1 Add feature flags for v2 contract consumption and AGE-authoritative rendering cutover.
- [ ] 5.2 Define rollout SLO gates: direct-edge minimum, inferred-edge ratio maximum, unresolved edge ceiling, edge churn ceiling.
- [ ] 5.3 Document rollback switches and recovery procedure.

## 6. Verification
- [ ] 6.1 Add synthetic fixtures for farm01/tonka01 expected uplinks (farm01 <-> USW Aggregation, AP uplinks).
- [ ] 6.2 Add integration tests for unresolved endpoint rendering and later reconciliation to canonical nodes.
- [ ] 6.3 Run `openspec validate migrate-age-authoritative-topology-pipeline --strict`.
