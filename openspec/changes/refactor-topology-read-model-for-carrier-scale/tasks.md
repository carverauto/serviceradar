## 1. Topology Contract
- [ ] 1.1 Define the carrier-scale God-View snapshot schema for backbone projection, attachment census summaries, endpoint drill-down neighborhoods, and topology quality counters.
- [ ] 1.2 Remove split layout authority so the frontend is the only author of visible topology geometry, with the backend limited to bounded topology semantics and expansion metadata.
- [ ] 1.3 Define revisioning and cache behavior so non-structural updates do not trigger unnecessary geometry churn.

## 2. Discovery and Projection Semantics
- [ ] 2.1 Refactor canonical topology export so the default backbone includes only promotable infrastructure-to-infrastructure transport relations.
- [ ] 2.2 Quarantine unresolved sightings, null-neighbor rows, and duplicate identity fragments from the default backbone while preserving them for diagnostics.
- [ ] 2.3 Export endpoint attachments as bounded summaries and explicit drill-down neighborhoods rather than unbounded default graph leaves.

## 3. UI Reliability and Readability
- [ ] 3.1 Implement HTTP snapshot bootstrap before channel streaming, with reconnect fallback to the last good snapshot.
- [ ] 3.2 Add zoom-tier label budgets, edge-label suppression rules, and visible-node budgets for expanded endpoint neighborhoods.
- [ ] 3.3 Ensure the default view remains readable when multiple endpoint groups are expanded and that budget overflow degrades to summary/paging instead of overlap chaos.

## 4. Status and Diagnostics
- [ ] 4.1 Replace heuristic three-hop `Affected` propagation with evidence-backed impact semantics.
- [ ] 4.2 Expose topology quality counters for unresolved identities, duplicate identity collisions, attachment drops, and bootstrap failures.
- [ ] 4.3 Add operator-visible diagnostics for quarantined identities without promoting them into the default backbone graph.

## 5. Verification
- [ ] 5.1 Add regression fixtures covering unresolved `sr:*` identities, duplicate-IP identity fragments, null-neighbor attachments, and dense endpoint fanout.
- [ ] 5.2 Validate representative demo-style topologies and synthetic high-cardinality fixtures against bounded snapshot and readability expectations.
- [ ] 5.3 Run `openspec validate refactor-topology-read-model-for-carrier-scale --strict`.
