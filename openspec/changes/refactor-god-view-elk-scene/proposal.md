# Change: Refactor God-View into one ELK-authored scene

## Why
The current God-View client imports ELK but normally bypasses it. A custom radial pass lays out the backbone, then separate satellite and endpoint-cluster projection passes move subsets of nodes afterward. Edges are rendered as direct source-to-target segments, fixed-pixel labels are not part of collision decisions, and camera fitting only considers node centers. The result can be connected and still be unreadable: the observed farm01 fixed-build snapshot reports one connected component and no unplaced nodes, but its nodes collapse into a narrow vertical spine, labels overlap, groups collide with the backbone, routes cross unrelated nodes, and fitted content clips against the viewport.

PR #3928 and PR #3937 repaired important topology semantics, including lost attachment connectivity, redundant inferred-edge suppression, and transitive satellite placement. They did not establish a coherent geometry contract. Continuing to tune the custom radial, spiral, and crossing heuristics would preserve the same split authority that produced the regressions.

## What Changes
- Make one compound ELK layout the production geometry authority for every node, group, and rendered relation in the bounded visible graph.
- Canonicalize and collapse semantic relations into stable rendered-route entities before layout so ELK optimizes exactly the strokes deck.gl will draw.
- Represent expanded endpoint clusters as real compound layout groups so ELK allocates space for their members instead of placing them in a post-layout projection pass.
- Preserve ELK route sections as scene geometry and render those polylines instead of drawing direct source-to-target arcs through unrelated nodes and groups.
- Keep the existing collapsed-cluster edge contract: expansion may reveal members without multiplying visible transport trunks.
- Add deterministic screen-space label decluttering because fixed-pixel text and glyph halos are renderer concerns that ELK cannot model reliably in world coordinates.
- Fit the complete visual scene and focus complete selected neighborhoods using routed geometry, glyph extents, labels, and measured UI safe areas.
- Add paired collapsed/expanded farm01-style fixtures and geometry assertions that fail on overlap, clipping, unstable placement, or route/node intersection.
- Remove the custom radial/spiral geometry path entirely. If ELK fails, preserve the last exactly compatible good scene or show an explicit recoverable layout error; do not silently switch algorithms.

## Impact
- Affected spec:
  - `topology-god-view`
- Affected code:
  - `elixir/web-ng/assets/js/lib/god_view/layout_topology_state_methods.js`
  - `elixir/web-ng/assets/js/lib/god_view/layout_elk_scene.js` (new pure scene adapter)
  - `elixir/web-ng/assets/js/lib/god_view/rendering_graph_data_methods.js`
  - `elixir/web-ng/assets/js/lib/god_view/rendering_graph_layer_transport_methods.js`
  - `elixir/web-ng/assets/js/lib/god_view/rendering_graph_layer_node_methods.js`
  - `elixir/web-ng/assets/js/lib/god_view/rendering_graph_view_methods.js`
  - God-View JavaScript fixtures, Bazel test targets, and browser acceptance coverage

## Dependencies and Coordination
- Builds from PR #3937's topology semantics and regression fixes. This change does not reintroduce redundant inferred attachment rows or change the server-side expansion limit.
- Implements the frontend geometry, route rendering, collision-based label admission, camera bounds, and dense geometry fixtures needed by `refactor-topology-read-model-for-carrier-scale`. That carrier-scale change retains ownership of bounded snapshot/read-model semantics, visible-member and paging budgets, zoom-tier label-count budgets, HTTP bootstrap, and causal-overlay semantics.
- At post-deployment archive time, `fix-topology-islands-and-cluster-expansion` SHALL be archived before this change. Its placement requirements are layout-engine-neutral, so this change can supersede the interim radial/spiral implementation while preserving its connectivity and channel-state outcomes.
- This client consumes only the already bounded visible graph. It does not redefine canonical read-model completeness or require every canonical attachment to be a simultaneous default-render node.

## Non-Goals
- Changing discovery, identity resolution, AGE projection, raw-link filtering, or bounded snapshot membership.
- Rendering an unbounded endpoint census; upstream visible-member limits still apply.
- Guaranteeing a crossing-free drawing for every mathematically possible graph. The hard contract is no duplicate or coincident rendered relation, no node/group overlap, no route through a nonincident node or group, and no nonincident route crossing/overlap in the supported dense acceptance fixtures; ELK minimizes crossings for other bounded graphs and the adapter validates the enforceable runtime invariants.
- Preserving the existing source-to-target edge color gradient; standard `PathLayer` uses one deterministic route color in this change.
- Replacing deck.gl or adding a second layout dependency.
