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

## Implemented server foundation and remaining integration
The independent server foundation now reads complete canonical relations instead of applying the legacy display caps at the source. `RuntimeTopologyProjection` publishes the SQL cache and matching completeness markers in one transaction, serializing publication before deletion so overlapping refreshes cannot combine generations. Complete reads observe rows and markers in one SQL snapshot; older incomplete projections fall back to the canonical source. `RuntimeGraph` builds the atlas from that complete relation set while retaining the bounded schema-2 compatibility reader.

`Atlas` builds an immutable index at runtime refresh and selects bounded global, component, neighborhood, and endpoint-member pages. Its indexed fetch path selects memberships before the planned bounded inventory enrichment and schema-3 encoder integration. `AtlasStore` publishes replacement indexes atomically and returns bounded revision information for at most 64 watched levels, separating the canonical source revision from per-level content and structure revisions.

`AtlasSource` now reads canonical Device vertices, including isolated vertices, from the AGE or Dgraph backend selected for that refresh and unions them with relation endpoints. `RuntimeSupervisor` places `AtlasStore` before `RuntimeGraph` under `rest_for_one`, so losing the store restarts its producer and requests an immediate rebuild when automatic refresh is enabled. Source response-adapter and supervision recovery checks pass, including fault injection. This verifies synthetic provider responses and process recovery, not live AGE/Dgraph query integration. Actual backend query integration and enrichment of only selected inventory members remain work for the final delivery. The HTTP controller, topology channel, and encoder still use the existing schema-2 path; schema-3 level transport, byte enforcement, client navigation, and client cache behavior remain pending #4749 and subsequent integration.

The focused pure suite passed 13 tests covering AGE/Dgraph response adapters, isolated canonical vertices, hosted fanout, malformed-source rejection, and bounded in-memory pages on an independently invented seeded graph of 200,000 nodes and 400,000 relations. These checks do not measure wire rows or bytes, browser layout size, or interaction latency. The link-key regression failed against the prior implementation and passes with the fix. Browser and wire acceptance remain open. The initial node, relation, label, and member limits are provisional cardinality bounds; encoded-byte limits are a separate boundary and still require enforcement and measurement after encoding.

Two focused RBE targets passed for the earlier server foundation. The projection-publication concurrency regression was reproduced with a negative control and passed after serialization against a `srql-fixtures` scratch database; teardown verified that the scratch database was absent. The full `make test` run then completed with 350 targets passed, one failed remotely, and two skipped. Every Elixir suite passed, including the source and supervision checks in `unit_tests_app_domain` and the core network-discovery suite. The remaining failure is the existing `build/contracts:web_ng_db_runner_contract_test` manifest mismatch: the runner lists 43 files while the contract expects 42 and omits `dashboard_export_round_trip_db_test.exs`. The full repository gate is therefore not green, and real-WebGPU acceptance is still pending.

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

The server builds an atlas index once per canonical runtime refresh. A level request selects bounded semantic node and relation identifiers before inventory enrichment or Arrow encoding. Selecting a level must not enrich, encode, or ask the browser to lay out the complete canonical graph. Endpoint membership and transport components are indexed for direct bounded access.

| Level | Content | Overflow behavior |
| --- | --- | --- |
| Global | Stable site or transport-component aggregates, member counts, cross-link counts | Page aggregates; every omitted aggregate remains reachable |
| Site or component | One aggregate's infrastructure backbone and attachment summaries | Page or subdivide the backbone; retain bounded context |
| Infrastructure neighborhood | One device's transport neighborhood and relevant cross-links | Page or summarize relations and neighbors |
| Endpoint membership | One attachment group's members and required anchor context | Stable member pages |

Transport components provide the initial grouping when authoritative site metadata is unavailable. Aggregate and level identifiers derive from stable semantic identity, never input row order, telemetry, or a display label. Pages use stable ordering within a revision. Every level, including global and a single large transport component, has an overflow path; a fixed cap must not make excess inventory unreachable.

These are semantic levels, not geometric tiles. ELK remains the only geometry authority, with one selected layout algorithm per level. Server coordinates and quadtree tiles are future work.

### Decision: Extend schema 3 with level metadata
Each HTTP level response contains one bounded schema-3 Arrow batch from #4749. It retains typed node columns, UInt32 edge endpoints, columnar details, and lazily decoded irregular details. Level metadata is encoded in the Arrow schema metadata, not in a parallel JSON graph format: `level_id`, `parent_level_id` (empty only for the global root), `revision`, level kind, structural signature, budgets, actual node/relation counts, and bounded continuation information. The HTTP envelope must agree with the batch metadata.

All edge indices and causal bitmap positions are local to the returned batch. The batch must not reference a node omitted by paging. Summary counts describe omitted members or relations without serializing their full identity lists. A level is rejected before publishing if it cannot satisfy its node, relation, label, member, or encoded-byte budget.

### Decision: Cache content revisions separately from geometry identity
The client caches a level by `(revision, level_id, expansion state)` and includes the selected layout algorithm and structural signature in its scene identity. Here `revision` identifies that level's exact content, not the canonical source revision and not its parent's revision. The separate `canonical_revision` identifies an atlas refresh and prompts reconciliation of watched levels. A telemetry-only content revision retains level ids, aggregate ids, and the structural signature, so existing geometry is reused. Structural signatures cover membership and layout-relevant semantic relations, including stable relation identity and bindings, not status or traffic counters.

Structural invalidations name only affected levels, including ancestors whose summaries changed. A canonical refresh does not automatically invalidate every cache entry: unaffected level revisions and scenes remain reusable, and changed content with a compatible structural signature reuses geometry. In-flight results from an older canonical generation must not replace a newer accepted level. Hover prefetch requests a bounded child level and deduplicates against cached or pending requests. Selecting that aggregate reuses the prefetch; navigating back restores the cached parent and camera without a fetch.

### Decision: Bootstrap via HTTP snapshot first, then stream updates
The existing authenticated `GET /topology/snapshot/latest` endpoint accepts `level_id` and an optional `revision`. Omitting `level_id` requests the global level; omitting `revision` requests the requested level's current content revision. A first visit or prefetch to a child uses its `child_level_id` and omits `revision`; it must not send its parent's revision. Later requests may pin a known revision for that child. A successful response contains exactly one level. The first usable scene comes from this HTTP bootstrap, regardless of channel timing.

A requested level revision that is no longer available returns HTTP 409 with that level's current revision; the server must not silently return different content under the requested cache identity. Unknown levels or out-of-range pages return 404, malformed parameters return 400, and an atlas that is not ready returns 503. Errors preserve the client's last compatible good scene. Child and continuation references are interpreted within their issuing canonical generation; structural invalidation requires reconciliation before accepting an in-flight result.

The `topology:god_view` channel publishes `topology_invalidated` with `previous_canonical_revision`, `canonical_revision`, and bounded `affected_level_ids`; per-level revision hints identify changed watched content, and an explicit reset marker replaces a list that exceeds its budget. It may also carry bounded telemetry deltas for loaded levels. It never sends a complete graph or level payload. Reconnect reconciles watched level revisions through HTTP, preserving the last good scene until a compatible response is ready.

Consequences:
- First render no longer depends on winning a channel timing race.
- The HTTP endpoint becomes a real contract rather than dead configuration.

### Decision: Reserve `Affected` for evidence-backed impact overlays
The UI will distinguish local health state from inferred impact state. A node may render as unhealthy or unknown from availability data alone, but `Affected` requires a qualifying causal signal path from supported evidence sources. When qualifying evidence is absent, the UI must not paint a blast radius simply because a node is within a hop budget of an unhealthy node.

Consequences:
- Operators stop seeing speculative impact coloring presented as causal truth.
- Availability overlays stay useful without pretending to be root-cause analysis.

### Decision: Enforce scale budgets at the contract boundary
The final server boundary must enforce hard per-level cardinality budgets before enrichment and encoding, then separately check actual encoded bytes before publishing. The foundation implements initial conservative limits of at most 128 visible nodes, 256 relations, and 128 identity labels per level, with at most 64 endpoint members plus bounded anchor context within the same node budget. These numbers are provisional safety bounds, not measured performance claims. Bounded row counts do not prove bounded bytes: details, labels, and metadata can vary in size. Schema-3 integration must add an explicit byte limit and measure it from the returned Arrow bytes.

When a budget is exceeded, the system summarizes, subdivides, or pages. Summaries, context nodes, labels, continuation metadata, and cross-links all count toward their corresponding budgets. Labels constrain the visible set before rendering; the client may reduce density further but must not increase the server-admitted membership. Quality counters for unresolved identities, duplicate identity collisions, and dropped attachments remain part of the wider change.

The acceptance workload is an independently invented, seeded graph of at least 200,000 nodes and 400,000 relations. Wire row and byte counts must stay bounded as canonical size increases. On a real WebGPU device with packet flow enabled, initial global paint must take no more than 3 seconds; at the largest allowed level hover and select must each take less than 100 milliseconds, and filter must take less than 300 milliseconds. Record device limits and timings before accepting the initial budgets.

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
7. Add HTTP level bootstrap and revision-only channel invalidation, then integrate client navigation and cache after #4749 lands.
8. Narrow status overlays and regression-test evidence-backed `Affected` behavior.
9. Validate with independently invented high-cardinality fixtures and real WebGPU browser checks with packet flow enabled. Any database tests use only a `srql-fixtures` scratch database. Live inspection requires the user's authorization and never supplies committed fixtures or examples.

## Open Questions
- Which lower per-level node, relation, label, and byte budgets are required by measured synthetic WebGPU interaction timings?
- Which evidence sources are sufficient to elevate a relation into the transport backbone when LLDP/CDP and inferred evidence disagree?
- Do we want a separate diagnostics mode that intentionally surfaces quarantined identities without polluting the default operational view?
