# Change: Refactor God-View into one ELK-authored scene

## Why
The current God-View client imports ELK but normally bypasses it. A custom radial pass lays out the backbone, then separate satellite and endpoint-cluster projection passes move subsets of nodes afterward. Edges are rendered as direct source-to-target segments, fixed-pixel labels are not part of collision decisions, and camera fitting only considers node centers. The result can be connected and still be unreadable: the observed farm01 fixed-build snapshot reports one connected component and no unplaced nodes, but its nodes collapse into a narrow vertical spine, labels overlap, groups collide with the backbone, routes cross unrelated nodes, and fitted content clips against the viewport.

PR #3928 and PR #3937 repaired important topology semantics, including lost attachment connectivity, redundant inferred-edge suppression, and transitive satellite placement. They did not establish a coherent geometry contract. Continuing to tune the custom radial, spiral, and crossing heuristics would preserve the same split authority that produced the regressions.

## What Changes
- Make one compound ELK layout the production geometry authority for every node, group, and rendered relation in the bounded visible graph.
- Canonicalize and collapse semantic relations into stable `scene.routes` entities before layout so their branch identity and count remain stable when ELK adds any required manifold geometry.
- Bind a degree-one node endpoint role directly to one deterministic flow-side port; for a same-role degree `d > 1`, give ELK one sibling zero-thickness fanout rail of `(d + 1) * 208` world units on the cross axis, one routed glyph-to-rail trunk, and one sorted branch port per semantic route without inflating the real glyph envelope. The `208` slot is twice the named `104` ELK edge-node corridor; cross-axis nodes and expanded-compound member layers use the named `112` spacing.
- Preserve only a deterministic spanning forest of load-bearing inferred-segment rows, normalize those retained bridges as transport while retaining raw provenance, keep them out of endpoint-attachment collapse, and reserve their bounded read quota independently from ordinary attachment rows.
- Keep pipeline diagnostics honest across suppression: `raw_links` records the pre-filter input count while unique-pair and final-edge counts record each later stage.
- Represent expanded endpoint clusters as real compound layout groups so ELK allocates space for their members instead of placing them in a post-layout projection pass.
- Own every rendered and layout-only relation at the lowest common compound containing both endpoints; only genuinely cross-compound relations remain root-owned.
- Preserve ELK semantic-branch and manifold-trunk sections plus the ELK-positioned rail span as scene geometry, and render that complete physical path set instead of drawing direct source-to-target arcs through unrelated nodes and groups.
- Keep the existing collapsed-cluster edge contract: expansion may reveal members without multiplying visible transport trunks.
- Add deterministic screen-space label decluttering because fixed-pixel text and glyph halos are renderer concerns that ELK cannot model reliably in world coordinates.
- Fit the complete visual scene and focus complete selected neighborhoods using every semantic branch and manifold rail/trunk, glyph extents, labels, and measured UI safe areas.
- Select a truthful managed presentation-density contract when fixed-pixel glyphs or physical-path strokes cannot fit at detail size, without changing ELK-authored nodes, groups, semantic branches, rails, or trunks.
- Keep every fixed-width semantic and manifold stroke clear of nonincident glyphs and noncontact physical paths at every managed camera scale, exempt only declared manifold junctions from contact diagnostics, and remeasure LiveView chrome when warning/details surfaces appear without resizing the canvas.
- Accept prepared snapshot/profile scenes only after rendering succeeds so a camera or layer exception cannot replace coherent last-good state.
- Add paired collapsed/expanded farm01-style fixtures and geometry assertions that fail on overlap, clipping, unstable placement, or any semantic/manifold path intersection with nonincident geometry.
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
- Supersedes PR #3937's topology semantics and regression fixes. This change does not reintroduce redundant inferred attachment rows; it makes the already bounded projection explicit as independent quotas of 5,000 backbone rows, 2,000 inferred-segment candidates, and 2,000 ordinary attachment rows so one class cannot starve another. It also closes the remaining case where a sole inferred-segment bridge was selected and then removed by attachment collapse or projection.
- Implements the frontend geometry, route rendering, collision-based label admission, camera bounds, and dense geometry fixtures needed by `refactor-topology-read-model-for-carrier-scale`. That carrier-scale change retains ownership of bounded snapshot/read-model semantics, visible-member and paging budgets, zoom-tier label-count budgets, HTTP bootstrap, and causal-overlay semantics.
- At post-deployment archive time, `fix-topology-islands-and-cluster-expansion` SHALL be archived before this change. Its placement requirements are layout-engine-neutral, so this change can supersede the interim radial/spiral implementation while preserving its connectivity and channel-state outcomes.
- This client consumes only the already bounded visible graph. It does not redefine canonical read-model completeness or require every canonical attachment to be a simultaneous default-render node.

## Non-Goals
- Changing discovery, identity resolution, AGE projection, general raw-link filtering, or bounded snapshot membership beyond deterministic preservation and independently bounded admission of load-bearing inferred-segment connectivity.
- Rendering an unbounded endpoint census; upstream visible-member limits still apply.
- Guaranteeing a crossing-free drawing for every mathematically possible graph. The hard runtime contract is no duplicate semantic relation, no node/group overlap, no physical path through a nonincident node or group, and no positive-length coincident path interiors. Unrelated zero-length crossings and T-contacts remain accepted diagnostics; only contact at an explicitly shared manifold junction is exempt from that diagnostic. The supported dense acceptance fixtures require zero unrelated contacts or crossings, and an invalid scene is never repaired after layout.
- Preserving the existing source-to-target edge color gradient; standard `PathLayer` uses one deterministic route color in this change.
- Replacing deck.gl or adding a second layout dependency.
- Adding an independent portrait packer or post-layout coordinate transform; evaluated native ELK packing variants either lost cross-hierarchy route sections or remained below the required portrait fit scale.
