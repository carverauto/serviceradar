## 1. Scene contract and regression fixtures
- [x] 1.1 Add sanitized collapsed and expanded farm01-style decoded fixtures pinning `30/34/24/32 -> 54/58/48/32` node/semantic-edge/attachment-edge/rendered-route counts, the exact 24-member identity delta, rendered-glyph counts, local shape, layer settings, visibility mask, and aggregation policy.
- [x] 1.2 Add failing contract tests for one connected component, no unplaced/isolated nodes, deterministic output, compound containment, node/group separation, one valid section per rendered route, and the zero rendered-route delta.
- [x] 1.3 Define and test the named viewport, node/group box, padding, clearance, label, seed, and numeric-tolerance constants from the design.
- [x] 1.4 Add failing camera and label tests for safe-viewport containment, collision rejection, two-pass Fit idempotence, selected-label fallback, and latest-group focus without collapsing concurrent expansions.

## 2. Compound ELK geometry authority
- [x] 2.1 Canonicalize semantic relations before layout into stable rendered-route entities with canonical direction and sorted contributing `relationIds`.
- [x] 2.2 Add a pure `layout_elk_scene` adapter that deterministically builds the compound graph and decodes absolute nodes, groups, routes, and bounds using `edge.container` coordinate frames.
- [x] 2.3 Model endpoint summaries as non-rendered gateways and expanded members as compound children with one visible anchor trunk and layout-only member constraints.
- [x] 2.4 Make the normal God-View path invoke ELK exactly once for the complete bounded visible graph with sorted inputs and a fixed seed.
- [x] 2.5 Remove post-layout attachment-satellite, expanded-cluster, and alternate fallback geometry; preserve a last-good scene only for an exact structural graph, expansion set, and viewport-profile key, or show a recoverable error.
- [x] 2.6 Cache layouts by structural graph identity, expansion state, and quantized usable-viewport profile.

## 3. Routed rendering
- [x] 3.1 Decode exactly one continuous route section for each pre-aggregated rendered relation; reject zero, multi-section, branching, discontinuous, or degenerate visible-edge geometry.
- [x] 3.2 Replace direct transport line/arc geometry with deck.gl path rendering for mantle, crust, hover, and selection using one deterministic route color.
- [x] 3.3 Disable traffic particles on bent routes until they can sample cumulative path distance.
- [x] 3.4 Validate every rendered route against nonincident padded node and compound-group interiors using incident-ancestor semantics and the named clearance constants.

## 4. Labels and camera
- [x] 4.1 Add deterministic screen-space label candidates, priority ordering, non-owner protected glyph boxes, routed-stroke corridors, and measured UI safe-area exclusion after existing zoom-tier budgets.
- [x] 4.2 Recompute labels on view-state changes without rerunning ELK; evict lower-priority conflicts for selected/focused labels and use the details surface when no safe canvas candidate exists.
- [x] 4.3 Implement full-scene initial/Fit bounds and selected-neighborhood focus with one safe-rectangle convention, managed-view glyph separation, and the bounded two-pass Fit algorithm.
- [x] 4.4 Preserve user-locked camera state, focus the latest expanded group otherwise, and handle resize through two quantized profiles without clipping or same-bucket layout churn.

## 5. Browser acceptance and rollout
- [x] 5.1 Add a Bazel-owned Vitest unit target with fixture files declared as data and include it in the normal repository unit sweep.
- [x] 5.2 Add a Bazel-owned Playwright `acceptance_test` target and test-only geometry snapshot hook covering collapsed, expanded, two concurrent expansions, collapse/re-expand, Fit idempotence, focus, and resize.
- [x] 5.3 Pin Chromium, CSS viewport, DPR, font readiness, reduced motion, and animation state; upload screenshot and trace artifacts from an explicit CI acceptance invocation.
- [ ] 5.4 Run focused JavaScript tests, `make test-toolchains`, lint, type checks, web-ng unit shards, and the repository-required `make test` gate. (Everything except `make test-toolchains` passed; its Go `-coverpkg` pass rejects the upstream leading BOM in `github.com/cilium/ebpf@v0.22.0/asm/func_lin.go`. The CI-equivalent `make test` passed 193/193.)
- [x] 5.5 Run `openspec validate refactor-god-view-elk-scene --strict`.
- [ ] 5.6 Roll the fixed build to demo and verify collapsed plus expanded farm01 endpoint-cluster views before merge.
