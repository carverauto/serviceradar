## Delivery status for #4774

The semantic-level and transport requirements below are specified; checked contract tasks are not evidence of implemented or measured wire behavior. The independent server foundation now reads complete canonical relations, publishes the SQL cache and completeness markers atomically with serialized writers, builds immutable `Atlas` indexes, and serves bounded pages and revision watches through `AtlasStore`. Pure atlas tests pass on an independently invented seeded 200,000-node / 400,000-relation graph.

`AtlasSource` now reads canonical Device vertices from the selected AGE or Dgraph backend and unions relation endpoints, and `RuntimeSupervisor` uses `rest_for_one` to restart the producer after store loss. The focused pure suite passed 13 tests covering both response adapters, isolated vertices, hosted fanout, large-graph pages, and malformed-source rejection; the full Elixir run also passed the supervision fault-injection checks. These results do not validate live AGE/Dgraph queries. Actual backend query integration, bounded inventory enrichment, schema-3 encoding, encoded-byte enforcement, and HTTP/channel integration remain open. Cardinality limits are provisional and separate from byte limits; no browser latency or wire-size acceptance is claimed. Schema-3 client integration depends on #4749 landing. Existing `topology_overview_projection.js`, `layout_elk_radial_overview.js`, and their tests already implement substantial parts of 3.4 and 3.5; reuse and reverify them against bounded levels before marking those tasks complete. The current snapshot bootstrap and channel still use the schema-2 path.

The earlier server foundation passed two focused RBE targets. The serialized-publication regression passed in a `srql-fixtures` scratch database after its negative control reproduced the race, and teardown confirmed the database was absent. The link-key regression also failed against the prior implementation and passes with the fix. The full `make test` run completed with 350 targets passed, one failed remotely, and two skipped; all Elixir suites passed. The remaining failure is the existing `build/contracts:web_ng_db_runner_contract_test` mismatch between 43 runner files and 42 expected files, which omit `dashboard_export_round_trip_db_test.exs`. Task 5.8 remains open because the repository-wide gate is not green and no PR has been delivered through the review proxy.

Tasks 2.2 and 4.x remain outside #4774. Do not mark them complete as a side effect of level delivery.

## 1. Topology Contract
- [ ] 1.1 Implement and round-trip the carrier-scale extension of schema 3 for backbone projection, attachment census summaries, endpoint drill-down neighborhoods, level metadata, and topology quality counters.
- [ ] 1.2 Adopt the single-scene geometry contract delivered by `refactor-god-view-elk-scene`; keep this change's backend work limited to bounded topology semantics and expansion metadata.
- [x] 1.3 Define content revisioning, stable aggregate/level identity, structural signatures, targeted invalidation, and cache behavior so non-structural updates do not trigger geometry churn.
- [x] 1.4 Specify one-level HTTP fetches, revision mismatch behavior, schema-3 metadata, and bounded channel invalidations in the existing carrier-scale deltas.
- [x] 1.5 Build immutable atlas indexes during canonical runtime refresh and return bounded semantic memberships through `AtlasStore`, ready for later enrichment and encoder integration.
- [x] 1.6 Read complete canonical relations and publish SQL cache rows with matching completeness markers in an atomic transaction that serializes writers before deletion.
- [x] 1.7 Expose bounded revision watches through `AtlasStore`, with a separate canonical revision and per-level content/structure revisions.
- [ ] 1.8 Validate canonical isolated vertices through actual AGE/Dgraph queries and integrate bounded inventory enrichment before delivering the selected level through the schema-3 encoder.
- [x] 1.9 Validate `AtlasSource` response adapters with synthetic AGE/Dgraph responses and `RuntimeSupervisor` recovery through fault injection; preserve the last published index when a source read fails. Live backend query integration remains in 1.8.

## 2. Discovery and Projection Semantics
- [ ] 2.1 Refactor canonical topology export so the default backbone includes only promotable infrastructure-to-infrastructure transport relations.
- [ ] 2.2 Quarantine unresolved sightings, null-neighbor rows, and duplicate identity fragments from the default backbone while preserving them for diagnostics.
- [ ] 2.3 Export endpoint attachments as bounded summaries and explicit drill-down neighborhoods rather than unbounded default graph leaves.

## 3. UI Reliability and Readability
- [ ] 3.1 Bootstrap the global level over HTTP; serve child/page levels over HTTP and restrict channel traffic to bounded invalidations or small deltas, with reconnect fallback to the last good scene.
- [ ] 3.2 Add zoom-tier label budgets, edge-label suppression rules, and visible-node budgets for expanded endpoint neighborhoods.
- [ ] 3.3 Apply visible-member and paging budgets to the compound groups delivered by `refactor-god-view-elk-scene`, so overflow degrades to summary/paging instead of overlap chaos without adding another geometry pass.
- [ ] 3.4 Add a pure deterministic transport-forest projection with stable roots, stable tree-edge selection, and explicit non-tree cross-link metadata.
- [ ] 3.5 Add an ELK Radial overview adapter that consumes only the projected forest, preserves semantic relation bindings, rejects overlapping/invalid geometry, and remains deterministic under reversed input arrays.
- [ ] 3.6 Select one layout pipeline per atlas level, include the level and algorithm in layout/cache identity, and preserve the last compatible good scene on failure.
- [ ] 3.7 Make endpoint expansion enter a bounded focus level with stable visible-member paging/sampling instead of growing the global overview.
- [ ] 3.8 Replace anonymous-glyph label ceilings with per-level self-identification contracts, and make Fit contain the complete bounded level without a route-derived zoom floor.
- [ ] 3.9 Retain cross-link counts in overview metadata and reveal relevant cross-links only for a selected bounded neighborhood.
- [ ] 3.10 Log client layout/render failure reason and algorithm/level metadata at the LiveView boundary.
- [ ] 3.11 After #4749 lands, cache levels by revision, level id, and expansion state; prefetch hovered children, deduplicate requests, and restore parents without a fetch.
- [ ] 3.12 Reuse geometry on telemetry-only revisions, invalidate only affected levels after structural changes, and reject stale in-flight responses.
- [ ] 3.13 Enforce node, relation, label, member, and encoded-byte budgets on every level, including paged global aggregates and oversized single components.

## 4. Status and Diagnostics
- [ ] 4.1 Replace heuristic three-hop `Affected` propagation with evidence-backed impact semantics.
- [ ] 4.2 Expose topology quality counters for unresolved identities, duplicate identity collisions, attachment drops, and bootstrap failures.
- [ ] 4.3 Add operator-visible diagnostics for quarantined identities without promoting them into the default backbone graph.

## 5. Verification
- [ ] 5.1 Add regression fixtures covering unresolved `sr:*` identities, duplicate-IP identity fragments, null-neighbor attachments, and dense endpoint fanout.
- [ ] 5.2 Generate an independently invented seeded graph of at least 200,000 nodes and 400,000 relations; assert returned wire bytes, rows, layout inputs, paging reachability, and visible labels stay within level budgets. Reuse existing fixtures only after confirming they are invented from scratch.
- [x] 5.3 Run `openspec validate refactor-topology-read-model-for-carrier-scale --strict`.
- [ ] 5.4 Add independently invented regressions for radial forest determinism, complete Fit, self-identifying visible glyphs, cross-link disclosure, and safe repeated expansion; verify stable aggregate ids under reversed canonical inputs.
- [ ] 5.5 Verify in a real WebGPU browser with packet flow enabled; record device limits and largest-level timings for first paint <=3 seconds, hover/select <100 milliseconds, and filter <300 milliseconds. SwiftShader alone does not satisfy this gate.
- [ ] 5.6 Verify one child fetch per drill-down, no fetch on cached-parent return, prefetch reuse, telemetry-only geometry reuse, and targeted structural invalidation.
- [ ] 5.7 Round-trip level metadata, local edge endpoints, and details through the schema-3 NIF encoder and client decoder.
- [ ] 5.8 Run `make test` with `--config=remote` before the PR. Run any database tests only against a `srql-fixtures` scratch database and deliver every PR through the no-mistakes git review proxy with that restriction in the run intent.
- [x] 5.9 Pass pure atlas tests using an independently invented seeded 200,000-node / 400,000-relation graph to verify bounded in-memory pages and navigation invariants. Wire counts, encoded-byte limits, layout size, and real-WebGPU performance remain covered by the open acceptance tasks above.
