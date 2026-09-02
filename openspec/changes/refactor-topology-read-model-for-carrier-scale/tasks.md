## 1. Topology Contract
- [ ] 1.1 Define the carrier-scale God-View snapshot schema for backbone projection, attachment census summaries, endpoint drill-down neighborhoods, and topology quality counters.
- [ ] 1.2 Adopt the single-scene geometry contract delivered by `refactor-god-view-elk-scene`; keep this change's backend work limited to bounded topology semantics and expansion metadata.
- [ ] 1.3 Define revisioning and cache behavior so non-structural updates do not trigger unnecessary geometry churn.

## 2. Discovery and Projection Semantics
- [ ] 2.1 Refactor canonical topology export so the default backbone includes only promotable infrastructure-to-infrastructure transport relations.
- [ ] 2.2 Quarantine unresolved sightings, null-neighbor rows, and duplicate identity fragments from the default backbone while preserving them for diagnostics.
- [ ] 2.3 Export endpoint attachments as bounded summaries and explicit drill-down neighborhoods rather than unbounded default graph leaves.

## 3. UI Reliability and Readability
- [ ] 3.1 Implement HTTP snapshot bootstrap before channel streaming, with reconnect fallback to the last good snapshot.
- [ ] 3.2 Add zoom-tier label budgets, edge-label suppression rules, and visible-node budgets for expanded endpoint neighborhoods.
- [ ] 3.3 Apply visible-member and paging budgets to the compound groups delivered by `refactor-god-view-elk-scene`, so overflow degrades to summary/paging instead of overlap chaos without adding another geometry pass.
- [ ] 3.4 Add a pure deterministic transport-forest projection with stable roots, stable tree-edge selection, and explicit non-tree cross-link metadata.
- [ ] 3.5 Add an ELK Radial overview adapter that consumes only the projected forest, preserves semantic relation bindings, rejects overlapping/invalid geometry, and remains deterministic under reversed input arrays.
- [ ] 3.6 Select one layout pipeline per atlas level, include the level and algorithm in layout/cache identity, and preserve the last compatible good scene on failure.
- [ ] 3.7 Make endpoint expansion enter a bounded focus level with stable visible-member paging/sampling instead of growing the global overview.
- [ ] 3.8 Replace anonymous-glyph label ceilings with per-level self-identification contracts, and make Fit contain the complete bounded level without a route-derived zoom floor.
- [ ] 3.9 Retain cross-link counts in overview metadata and reveal relevant cross-links only for a selected bounded neighborhood.
- [ ] 3.10 Log client layout/render failure reason and algorithm/level metadata at the LiveView boundary.

## 4. Status and Diagnostics
- [ ] 4.1 Replace heuristic three-hop `Affected` propagation with evidence-backed impact semantics.
- [ ] 4.2 Expose topology quality counters for unresolved identities, duplicate identity collisions, attachment drops, and bootstrap failures.
- [ ] 4.3 Add operator-visible diagnostics for quarantined identities without promoting them into the default backbone graph.

## 5. Verification
- [ ] 5.1 Add regression fixtures covering unresolved `sr:*` identities, duplicate-IP identity fragments, null-neighbor attachments, and dense endpoint fanout.
- [ ] 5.2 Reuse the dense geometry fixtures delivered by `refactor-god-view-elk-scene` and add synthetic high-cardinality fixtures for this change's bounded snapshot, paging, and zoom-tier budget expectations.
- [x] 5.3 Run `openspec validate refactor-topology-read-model-for-carrier-scale --strict`.
- [ ] 5.4 Add farm01 regression assertions for radial forest determinism, complete Fit, self-identifying visible glyphs, cross-link disclosure, and safe repeated cluster expansion.
- [ ] 5.5 Run local web-ng against live demo or farm01 CNPG data and capture collapsed, fitted, and expanded Playwright screenshots plus geometry diagnostics.
