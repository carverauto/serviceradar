## Context
Issue `#2894` reports that God-View edge particle animations are absent in the deck.gl topology view. The current rendering pipeline already builds a particle layer (`PacketFlowLayer`) from edge telemetry, but there is no explicit visibility contract in code for contrast floors, minimum opacity/size under low-telemetry edges, or reduced-motion fallback behavior.

Primary render path:
- `elixir/web-ng/assets/js/lib/god_view/rendering_graph_layer_transport_methods.js`
- `elixir/web-ng/assets/js/lib/god_view/rendering_style_edge_particle_methods.js`
- `elixir/web-ng/assets/js/lib/deckgl/PacketFlowLayer.js`
- `elixir/web-ng/assets/js/lib/god_view/lifecycle_dom_interaction_methods.js`
- `elixir/web-ng/assets/js/lib/god_view/lifecycle_bootstrap_state_defaults_methods.js`

## Goals
- Make edge particles reliably visible over base edge layers in God-View default rendering.
- Preserve good readability for dense graphs (avoid particles blending into line strokes).
- Support reduced-motion behavior that disables animation but preserves topology readability.
- Add targeted tests around particle generation and layer composition.

## Non-Goals
- Reworking topology layout or snapshot schema.
- Introducing new server-side topology payload fields.
- Large visual redesign of God-View node/edge palettes.

## Proposed Implementation Plan
### 1. Add visibility guardrails for particle styling
File:
- `elixir/web-ng/assets/js/lib/god_view/rendering_style_edge_particle_methods.js`

Changes:
- Enforce stronger minimum particle alpha and size floors for low-intensity edges.
- Tune color interpolation to keep particles distinguishable from mantle/crust line colors.
- Ensure particle count heuristics remain bounded for performance while still producing visible markers on medium/low traffic links.

Why:
- The particle style builder is the single source for particle color/size/alpha; enforcing visibility floors here keeps behavior deterministic.

### 2. Make particle layer compositing explicit
File:
- `elixir/web-ng/assets/js/lib/god_view/rendering_graph_layer_transport_methods.js`

Changes:
- Keep `PacketFlowLayer` composition explicit as an atmosphere/top-most effect layer for transport visuals.
- Add clear comments and explicit layer ordering expectations in `buildTransportAndEffectLayers`.
- Adjust blend/depth parameters only if needed to preserve visibility over line layers.

Why:
- This is where `LineLayer`, `ArcLayer`, and `PacketFlowLayer` are composed. If ordering/blending causes visual washout, this file is the correct control point.

### 3. Add reduced-motion handling for render loop
Files:
- `elixir/web-ng/assets/js/lib/god_view/lifecycle_bootstrap_state_defaults_methods.js`
- `elixir/web-ng/assets/js/lib/god_view/lifecycle_dom_interaction_methods.js`

Changes:
- Track reduced-motion preference in lifecycle state (via `matchMedia("(prefers-reduced-motion: reduce)")`).
- In reduced-motion mode, skip the animation RAF loop updates while keeping static edge layers rendered.
- Ensure toggling reduced-motion does not break initial snapshot rendering.

Why:
- Animation time (`animationPhase`) is currently advanced every RAF tick with no motion preference guard.

### 4. Add targeted tests for particle visibility behavior
Files (new/updated):
- `elixir/web-ng/assets/js/lib/god_view/rendering_style_edge_particle_methods.test.js` (new)
- `elixir/web-ng/assets/js/lib/god_view/rendering_graph_layer_transport_methods.test.js` (new)
- `elixir/web-ng/assets/js/lib/god_view/lifecycle_dom_interaction_methods.test.js` (new or update existing lifecycle tests)

Test coverage:
- Particle builder returns visible defaults (non-zero alpha/size/count) for representative edge telemetry inputs.
- Layer builder includes atmosphere particle layer when enabled and composes with expected order.
- Reduced-motion mode avoids animation-loop updates but still permits static render calls.

## Verification Plan
Local checks:
- `cd elixir/web-ng/assets && bun run lint:god_view`
- `cd elixir/web-ng/assets && bun run test:god_view:contracts`
- `cd elixir/web-ng/assets && bunx vitest run js/lib/god_view/rendering_style_edge_particle_methods.test.js js/lib/god_view/rendering_graph_layer_transport_methods.test.js js/lib/god_view/lifecycle_dom_interaction_methods.test.js`
- `cd elixir/web-ng/assets && bun run typecheck:god_view`

Manual checks in browser (God-View `/topology`):
- Confirm particles are visible on active edges at default zoom.
- Confirm particles remain visible during pan/zoom.
- Confirm layer toggles (`mantle`, `crust`, `atmosphere`, `security`) do not regress particle visibility.
- Enable reduced-motion and confirm static topology remains readable with motion disabled.

## Risks and Mitigations
- Risk: Over-bright particles may overwhelm labels in dense scenes.
  - Mitigation: Cap alpha/size and validate with dense snapshots.
- Risk: Additional particles may reduce frame rate.
  - Mitigation: Keep global particle cap and maintain current bounded per-edge heuristics.
- Risk: Browser differences in additive blending.
  - Mitigation: Validate in Chrome and Safari/WebKit with the same snapshot.
