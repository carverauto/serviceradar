## 1. Scene contract and regression fixtures
- [x] 1.1 Add sanitized collapsed and expanded farm01-style decoded fixtures pinning `30/34/24/32 -> 54/58/48/32` node/semantic-edge/attachment-edge/semantic-`scene.routes` counts, the exact 24-member identity delta, rendered-glyph counts, local shape, layer settings, visibility mask, and aggregation policy.
- [x] 1.2 Add failing contract tests for one connected component, no unplaced/isolated nodes, deterministic output, compound containment, node/group separation, one valid ELK section per semantic branch and manifold trunk, connected manifold rails, and the zero semantic-route delta.
- [x] 1.3 Define and test the named viewport, real-glyph minima, `208` manifold slot, `112` cross-axis/expanded-member spacing, `104` ELK edge-node corridor, distinct `96` runtime clearance, `192` edge-edge spacing, padding, label, seed, and numeric-tolerance constants from the design.
- [x] 1.4 Add failing camera and label tests for safe-viewport containment, collision rejection, two-pass Fit idempotence, selected-label fallback, and latest-group focus without collapsing concurrent expansions.

## 2. Compound ELK geometry authority
- [x] 2.1 Canonicalize semantic relations before layout into stable semantic `scene.routes` entities with canonical direction and sorted contributing `relationIds`.
- [x] 2.2 Add a pure `layout_elk_scene` adapter that deterministically builds the compound graph and decodes absolute nodes, groups, semantic routes, manifolds, physical routes, and bounds using `edge.container` coordinate frames.
- [x] 2.3 Keep real glyph envelopes at the `448/112/96/112` minima; bind each degree-one node endpoint role directly to one deterministic flow-side port, and give only a same-role degree greater than one a sibling zero-thickness rail sized `(degree + 1) * 208` on the cross axis, one ELK-routed glyph trunk, and sorted branch ports while leaving layout-only member constraints on implicit ports.
- [x] 2.4 Make the normal God-View path invoke layered ELK with `INCLUDE_CHILDREN` exactly once for the complete bounded visible graph, its manifolds, and its compound packing constraints using sorted inputs, a fixed seed, `112` cross-axis node spacing, `112` expanded-compound member between-layer spacing, and the `104` ELK edge-node corridor.
- [x] 2.5 Remove post-layout attachment-satellite, expanded-cluster, and alternate fallback geometry; preserve a last-good scene only for an exact structural graph, expansion set, and viewport-profile key, or show a recoverable error.
- [x] 2.6 Cache layouts by structural graph identity, expansion state, and quantized usable-viewport profile.
- [x] 2.7 Own every rendered and layout-only relation at the lowest common compound containing both endpoints; keep only genuinely cross-compound relations on the root.
- [x] 2.8 Preserve a deterministic forest of load-bearing inferred-segment bridges through attachment collapse and endpoint projection using normalized transport semantics plus raw provenance.
- [x] 2.9 Reserve independent bounded runtime quotas for backbone, inferred-segment, and ordinary attachment rows, and keep pre-filter raw-link counts visible through pipeline diagnostics.
- [x] 2.10 Accept snapshot and viewport-profile candidates transactionally so render/camera failure restores the coherent last-good presentation and remains recoverable.

## 3. Routed rendering
- [x] 3.1 Decode exactly one continuous ELK route section for each pre-aggregated semantic branch and manifold trunk, decode each rail from its zero-thickness ELK sibling and sorted ports, and reject missing, multi-section, branching, discontinuous, degenerate, or disconnected physical geometry.
- [x] 3.2 Keep `scene.routes` as the canonical semantic-branch set and count, expose manifold rail/trunk metadata plus the complete `physicalRoutes` set, and replace direct transport line/arc geometry with deck.gl path rendering for mantle, crust, hover, and selection using one deterministic route color.
- [x] 3.3 Disable traffic particles on bent routes until they can sample cumulative path distance.
- [x] 3.4 Validate every semantic branch, manifold rail, and manifold trunk against nonincident padded node and compound-group interiors using incident-ancestor semantics and the distinct `96` world-unit runtime clearance, while retaining `192` world-unit ELK edge-edge spacing.
- [x] 3.5 Reject positive-length coincident physical-path interiors at runtime using scale-independent linear tolerances; allow and count unrelated zero-length crossings or T-contacts while exempting only a contact where both paths declare the same manifold junction at that point.
- [x] 3.6 Reject physical paths that contact and then re-enter an incident glyph's open interior while allowing a direct branch or manifold trunk to egress or ingress at its declared glyph boundary.
- [x] 3.7 Filter managed routes with hidden rendered endpoints while retaining only the intentional visible-anchor/non-rendered-expanded-gateway trunk contract.

## 4. Labels and camera
- [x] 4.1 Add deterministic screen-space label candidates, priority ordering, non-owner protected glyph boxes, complete semantic/manifold stroke corridors, and measured UI safe-area exclusion after existing zoom-tier budgets.
- [x] 4.2 Recompute labels on view-state changes without rerunning ELK; evict lower-priority conflicts for selected/focused labels and use the details surface when no safe canvas candidate exists.
- [x] 4.3 Implement full-scene initial/Fit bounds and selected-neighborhood focus over nodes, groups, semantic branches, and manifold rails/trunks with one safe-rectangle convention, managed-view glyph separation, and the bounded two-pass Fit algorithm.
- [x] 4.4 Preserve user-locked camera state, focus the latest expanded group otherwise, and handle resize through two quantized profiles without clipping or same-bucket layout churn.
- [x] 4.5 Keep portrait managed views camera-feasible with presentation-only density: overview outer-radius caps of `10` CSS pixels for ordinary/member glyphs, `20` for summaries, and `12` for anchors, plus managed physical-path width caps of `10` CSS pixels in overview and `12` in detail. Density SHALL NOT change ELK-authored glyph, semantic-branch, rail, or trunk geometry.
- [x] 4.6 Derive per-density camera floors and intrinsic safe-rectangle spans that keep fixed-pixel glyphs and every finite-width physical path feasible across Fit, focus, manual, and user-locked cameras; leave accepted unrelated zero-length contacts to the diagnostic validator while exempting only declared manifold junctions from diagnostics; dynamically observe warning/details/control/status safe-area chrome inserted or removed without a canvas resize.

## 5. Browser acceptance and rollout
- [x] 5.1 Add a Bazel-owned Vitest unit target with fixture files declared as data and include it in the normal repository unit sweep.
- [x] 5.2 Add a Bazel-owned Playwright `acceptance_test` target and test-only geometry snapshot hook covering collapsed, expanded, two concurrent expansions, collapse/re-expand, Fit idempotence, focus, and resize.
- [x] 5.3 Pin Chromium, CSS viewport, DPR, font readiness, reduced motion, and animation state; upload screenshot and trace artifacts from an explicit CI acceptance invocation.
- [x] 5.4 Run the final hermetic browser acceptance once with cached results disabled and retries disabled; verify the canonical landscape/portrait, collapse/re-expand, density, geometry, and exact nine-output contracts.
- [ ] 5.5 Run focused JavaScript tests, `make test-toolchains`, lint, type checks, web-ng unit shards, and the repository-required `make test` gate.
  - Verified on 2026-08-24: 613 focused JavaScript tests, God View ESLint and TypeScript checks, all 11 focused Bazel targets, the complete non-Swift `make HOST_OS=Linux lint` contract, and all 193 repository unit tests passed.
  - Host/toolchain blockers: `make test-toolchains` stops in the upstream `github.com/cilium/ebpf@v0.22.0` module at an invalid embedded BOM, and native `make lint` stops when SwiftLint cannot load the local SourceKit framework. Neither failure reaches or implicates this change.
- [x] 5.6 Run `openspec validate refactor-god-view-elk-scene --strict`.
- [ ] 5.7 Roll the fixed build to demo and verify collapsed plus expanded farm01 endpoint-cluster views before merge.
