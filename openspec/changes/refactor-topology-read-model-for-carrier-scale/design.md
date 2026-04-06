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
- Non-Goals:
  - Recreate every raw mapper relation in the default graph.
  - Guarantee that all endpoints are simultaneously visible on a single canvas.
  - Introduce multitenant topology partitions or customer-specific graph modes.
  - Replace the entire rendering stack in this change; the contract must support future renderer swaps, but renderer replacement is not required here.

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
The backend will author topology semantics only: the bounded backbone, attachment summaries, expansion membership, and the metadata needed for deterministic client layout. The frontend will remain the only geometry authority and will run exactly one layout path for the visible graph. The system must remove backend-authored geometry ownership, legacy backend layout fallback, and any second client-side projection pass layered on top of the primary client layout.

Consequences:
- We keep the proven direction of using ELK or a successor client layout engine rather than revisiting failed backend-authored geometry.
- Topology stability becomes testable at the frontend layout-contract boundary.
- The client no longer creates second-order overlap bugs by mixing ELK backbone placement with a second projection/layout pass for endpoint groups.

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

## Migration Plan
1. Define the new snapshot schema and bounded-read-model semantics.
2. Move default graph export to transport-backbone-only projection with endpoint census summaries.
3. Add unresolved-identity quarantine and topology quality counters.
4. Refactor frontend layout so ELK or its successor is the only geometry path for visible topology, and remove secondary client projection passes plus legacy backend-layout fallback.
5. Add HTTP bootstrap before streaming updates.
6. Narrow status overlays and regression-test evidence-backed `Affected` behavior.
7. Validate with dense demo fixtures and high-cardinality synthetic fixtures before implementation rollout.

## Open Questions
- Should attachment drill-down use pagination, density-based sampling, or both when a single anchor has extremely high fanout?
- Which evidence sources are sufficient to elevate a relation into the transport backbone when LLDP/CDP and inferred evidence disagree?
- Do we want a separate diagnostics mode that intentionally surfaces quarantined identities without polluting the default operational view?
