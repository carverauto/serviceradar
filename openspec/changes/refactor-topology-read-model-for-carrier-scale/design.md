## Context
The current topology surface has four coupled failure modes:

1. The default graph is semantically overloaded.
   It tries to render infrastructure transport, endpoint attachment census, unresolved identity fragments, and inferred relationships in one canvas.
2. Geometry is authored in more than one place.
   The frontend already uses ELK and additional client-side endpoint projection logic, while the backend still carries layout-oriented structure and legacy backend-layout paths.
3. Bootstrap is fragile.
   The page exposes an HTTP snapshot URL but the client relies on channel delivery, so first paint can fail if the initial stream race is lost.
4. Status overlays are not trustworthy.
   The current `Affected` state can be produced by a three-hop heuristic from unhealthy nodes even when there is no corroborating causal event evidence.

Carrier-scale support requires a topology surface that is bounded by design. Hundreds of thousands of discovered endpoints cannot be treated as individual default-render objects, and source-quality anomalies must not be allowed to silently pollute operator-facing topology.

## Goals / Non-Goals
- Goals:
  - Make the default topology graph bounded, readable, and infrastructure-first.
  - Preserve endpoint visibility through progressive disclosure rather than full expansion.
  - Prevent unresolved or low-trust identities from appearing as backbone peers.
  - Establish a single frontend geometry authority and a reliable initial load path.
  - Limit impact overlays to evidence-backed semantics.
  - Add measurable quality gates for topology ingestion and snapshot generation.
  - Make the full current level reachable through Fit and make every rendered glyph self-identifying at the level where it appears.
- Non-Goals:
  - Recreate every raw mapper relation in the default graph.
  - Guarantee that all endpoints are simultaneously visible on a single canvas.
  - Introduce multitenant topology partitions or customer-specific graph modes.
  - Replace the entire rendering stack in this change; the contract must support future renderer swaps, but renderer replacement is not required here.
  - Run browser-side ELK over every device, endpoint, or relation in a 50k-to-million-element environment.
  - Guarantee a crossing-free simultaneous drawing of arbitrary cyclic cross-links; the overview summarizes those links and discloses them only in bounded focus views.

## Decisions

### Decision: Split the topology read model into backbone, attachment census, and drill-down neighborhoods
The default God-View snapshot will include only the transport backbone needed to answer "how is infrastructure connected?" Endpoint attachments will be exported as summarized attachment census metadata anchored to backbone nodes, plus bounded drill-down neighborhood payloads requested explicitly by the operator.

Consequences:
- Endpoint summaries are not allowed to dominate backbone layout.
- Endpoint detail rendering can be paged, filtered, or capped without changing the backbone graph.
- Source systems may retain raw attachment evidence, but the default UI contract is no longer obligated to render each attachment as a graph node.

### Decision: Quarantine unresolved topology sightings and non-promotable identities
Topology sightings with unresolved `sr:*` identities, null-neighbor rows, or duplicate identity collisions are not promotable to the default backbone projection. They remain available for diagnostics and reconciliation metrics, but they render only after explicit drill-down into attachment diagnostics or after identity resolution promotes them to a stable device identity.

Consequences:
- The default graph stops showing "mystery devices" as if they were real backbone peers.
- Data-quality issues become observable counters instead of accidental graph nodes.

### Decision: Make frontend layout the single geometry authority
The backend will author topology semantics only: the bounded backbone, attachment summaries, expansion membership, and the metadata needed for deterministic client layout. The frontend will remain the only geometry authority. A visible atlas level selects exactly one layout pipeline from explicit scene semantics; the system must remove backend-authored geometry ownership, legacy backend layout fallback, and any second node-placement pass layered on top of the selected pipeline. Different bounded levels may select different ELK algorithms, but one accepted scene cannot combine competing node coordinate systems.

Implementation ownership for the renderer-neutral deck.gl scene, screen-space collision admission, and camera geometry begins with `refactor-god-view-elk-scene`. This change consumes those renderer contracts, replaces the single layered-layout assumption with explicit atlas-level selection, and owns the bounded semantic input, deterministic forest, cross-link disclosure, visible-member/paging budgets, semantic labels, bootstrap, and causal-overlay semantics.

Consequences:
- We keep the proven direction of using ELK or a successor client layout engine rather than revisiting failed backend-authored geometry.
- Topology stability becomes testable at the frontend layout-contract boundary.
- The client no longer creates second-order overlap bugs by mixing ELK backbone placement with a second projection/layout pass for endpoint groups.

### Decision: Use a deterministic transport forest for the radial overview
The global and site overview SHALL project the bounded visible topology into a deterministic rooted forest before layout. Forest construction ranks promotable infrastructure transport ahead of inferred transport, summaries, and endpoint membership; breaks ties by stable semantic relation and node identifiers; selects stable infrastructure roots; and orients every selected edge away from its component root. The overview then invokes ELK Radial only with that acyclic forest.

Semantic relations excluded from the forest remain cross-links with their original relation identifiers and telemetry metadata. Cross-links do not influence overview node placement and are not drawn as an always-on mesh. The overview exposes a stable cross-link count per component and per focused node or route; selecting or focusing a bounded neighborhood may reveal only the relevant cross-links through the detail scene.

Consequences:
- ELK Radial receives the tree input it requires instead of being asked to repair a cyclic network.
- The default overview has one non-overlapping load-bearing path between every node and its component root.
- Cycles and redundancy remain discoverable without turning the global view into an edge carpet.
- Forest membership and roots remain stable across input row order and non-structural telemetry updates.

### Decision: Treat expansion as bounded focus, not global graph growth
Expanding an endpoint summary SHALL select a bounded neighborhood level anchored to that group. The selected level retains the surrounding transport path required for context and shows a capped or paged member set. It SHALL NOT add every endpoint to the global overview or force unrelated components through a new global layout.

The first implementation may reuse radial tree layout for a focused group or preserve the validated layered detail adapter when its route contract is required. Algorithm selection is explicit scene metadata and is part of the cache key. ELK Mr. Tree is not a drop-in fallback: it may be evaluated for a future bounded detail mode only after its port and non-tree routing output satisfies the shared scene validator.

Consequences:
- Expanding one cluster cannot make unrelated topology disappear or make Fit impossible.
- Multiple expanded clusters remain represented as independent bounded focus states rather than one unbounded compound scene.
- Paging and sampling are both allowed: stable paging for explicit browsing and deterministic sampling for aggregate preview.

### Decision: Fit and labels follow semantic zoom levels
Fit SHALL always contain the complete current bounded atlas level inside the measured safe viewport. Fixed-pixel glyph and route clearances SHALL NOT raise the camera floor until part of that level becomes unreachable. When detail-sized marks cannot fit, the renderer SHALL select a smaller overview presentation and then change semantic level before clamping the requested fit.

Every glyph rendered in an overview or focus level SHALL be self-identifying without hover. Infrastructure, component, site, and endpoint-summary glyphs retain labels at overview levels. A bounded detail level retains labels for every visible infrastructure node and visible endpoint member. If those labels cannot be admitted without collision, the level SHALL aggregate, page, or reduce visible membership rather than leave anonymous glyphs on the canvas.

Consequences:
- Label budgets bound visible objects before rendering instead of silently dropping the identity of already-rendered glyphs.
- Hover and the details panel provide additional metadata, not the only available identity.
- Fit is a navigation guarantee for the current level, while drill-down changes which bounded level is current.

### Decision: Scale through server-authored levels of detail
The browser SHALL never receive an instruction to lay out the full 50k-to-million-element canonical graph. The read model authors stable aggregate identifiers and bounded level payloads for global, site or component, infrastructure neighborhood, and endpoint membership views. Viewport and selection requests fetch only the next required level, with revision and parent identifiers sufficient for stable caching and navigation.

Consequences:
- GPU primitive capacity is not confused with graph-layout, label, memory, or interaction capacity.
- Default work is bounded by visible-level budgets rather than tenant inventory size.
- Future server-side partitioning or precomputed coordinates can replace client forest construction without changing the atlas navigation contract.

### Decision: Bootstrap via HTTP snapshot first, then stream updates
The God-View surface will fetch the latest snapshot from the existing HTTP endpoint before or while joining the stream. The channel remains responsible for deltas or refreshed snapshots after initial paint, and stream failures fall back to the last good snapshot plus reconnect behavior.

Consequences:
- First render no longer depends on winning a channel timing race.
- The HTTP endpoint becomes a real contract rather than dead configuration.

### Decision: Reserve `Affected` for evidence-backed impact overlays
The UI will distinguish local health state from inferred impact state. A node may render as unhealthy or unknown from availability data alone, but `Affected` requires a qualifying causal signal path from supported evidence sources. When qualifying evidence is absent, the UI must not paint a blast radius simply because a node is within a hop budget of an unhealthy node.

Consequences:
- Operators stop seeing speculative impact coloring presented as causal truth.
- Availability overlays stay useful without pretending to be root-cause analysis.

### Decision: Enforce scale budgets at the contract boundary
The snapshot contract will define hard budgets for:
- visible backbone nodes and edges in the default view
- visible endpoint members per expanded group
- label counts by zoom tier
- quality counters for unresolved identities, duplicate identity collisions, and dropped attachment rows

When budgets are exceeded, the system summarizes or pages rather than attempting to render the entire set.

## Risks / Trade-offs
- Hiding unresolved identities by default may initially make some discovery issues less visually obvious.
  Mitigation: surface explicit quality counters and drill-down diagnostics in the UI and pipeline stats.
- Frontend geometry for expanded neighborhoods can still become expensive if we let visible sets grow without bound.
  Mitigation: enforce visible-set budgets, simple bounded neighborhood placement, and cache layout inputs by revision plus expansion state.
- Operators may want "show me everything."
  Mitigation: support explicit drill-down/export workflows, but do not treat "render everything" as the default operational mode.
- A spanning forest necessarily omits redundant links from the default drawing.
  Mitigation: retain exact cross-link counts and identities, expose them on selection, and provide a bounded detail mode for redundancy inspection.
- Radial placement can be unstable if roots or tree edges change with input order.
  Mitigation: choose roots and forest edges through a documented stable total order and regression-test reversed input arrays.

## Migration Plan
1. Define the new snapshot schema and bounded-read-model semantics.
2. Move default graph export to transport-backbone-only projection with endpoint census summaries.
3. Add unresolved-identity quarantine and topology quality counters.
4. Add deterministic forest and cross-link semantics, then select ELK Radial for the bounded overview while keeping one geometry authority per accepted level.
5. Make cluster expansion enter a bounded focus level with paging/sampling rather than growing the global scene.
6. Make semantic labels and an always-complete Fit hard acceptance contracts.
7. Add HTTP bootstrap before streaming updates.
8. Narrow status overlays and regression-test evidence-backed `Affected` behavior.
9. Validate with dense demo fixtures, live CNPG data, and high-cardinality synthetic fixtures before implementation rollout.

## Open Questions
- What are the initial per-level node, relation, and label budgets after measuring the farm01 and demo datasets?
- Which evidence sources are sufficient to elevate a relation into the transport backbone when LLDP/CDP and inferred evidence disagree?
- Do we want a separate diagnostics mode that intentionally surfaces quarantined identities without polluting the default operational view?
