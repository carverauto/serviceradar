## 1. Specification
- [ ] 1.1 Confirm the God-View layout-engine pivot proposal with product and engineering stakeholders.
- [ ] 1.2 Resolve overlap with `refactor-endpoint-cluster-feature-layout` and document whether it is superseded or partially retained.

## 2. Frontend Layout Engine
- [x] 2.1 Add an ELK-based layout adapter in the God-View frontend pipeline.
- [x] 2.2 Build visible-graph translation from decoded topology state, including collapsed and expanded endpoint clusters.
- [x] 2.3 Add deterministic layout caching keyed by topology revision and expanded cluster state.
- [x] 2.4 Feed client-computed coordinates into existing deck.gl layers without regressing selection, hover, or bitmap-driven overlays.
- [x] 2.5 Add frontend regression coverage for collapsed clusters, expanded clusters, reset or collapse, and duplicate-cluster prevention.

## 3. Backend Simplification
- [x] 3.1 Reduce `god_view_stream.ex` to semantic grouping, stable identity, and transport concerns instead of final coordinate authority.
- [x] 3.2 Preserve Arrow and roaring bitmap payload compatibility during the migration.
- [x] 3.3 Add revision semantics that cleanly distinguish collapsed versus expanded topology state for client cache invalidation.

## 4. Rollout
- [ ] 4.1 Validate ELK-based layout behavior against endpoint-heavy demo topologies.
- [x] 4.2 Re-enable any required demo debugging tooling, including `serviceradar-tools`, if needed for rollout diagnostics.
- [ ] 4.3 Remove or retire obsolete backend layout branches after the client layout path is verified.
