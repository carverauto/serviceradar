# Change: Expose discovered endpoints in the topology view

## Why
GitHub issue #3051 reports that the God-View topology canvas currently shows backbone infrastructure but does not surface discovered client/end-user devices even when the `endpoints` layer is enabled. In the reported environment, toggling `endpoints` hides the MikroTik router and still does not render client devices, which means the current endpoint-attachment contract is not reliable enough for operators to trust topology.

The codebase already contains partial support for endpoint-aware topology (`ATTACHED_TO` / `endpoint-attachment` relations, endpoint layer controls, endpoint visual styles), but there is no explicit end-to-end requirement that discovered endpoints survive canonical AGE projection, snapshot generation, and frontend filtering/rendering. We need a narrow proposal that closes that contract gap without reopening the broader topology refactors already in flight.

## What Changes
- Add an `age-graph` requirement that canonical topology projection preserves discovered endpoint attachments as first-class graph relations instead of dropping them from the God-View read model.
- Add a `build-web-ui` requirement that enabling the `endpoints` layer renders endpoint nodes and attachment links on the topology canvas.
- Require endpoint-layer toggles to affect only endpoint attachments, not backbone infrastructure nodes or links.
- Add regression coverage for a mixed topology fixture containing backbone devices plus downstream endpoints so the `AGE -> snapshot -> canvas` path fails loudly if endpoints disappear.
- Keep this change intentionally narrow and complementary to `improve-mapper-topology-fidelity` and `refactor-lldp-first-topology-and-route-analysis` rather than duplicating their broader discovery and route-analysis scope.

## Impact
- Affected specs:
  - `age-graph`
  - `build-web-ui`
- Affected code:
  - `elixir/serviceradar_core/lib/serviceradar/network_discovery/topology_graph.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng/topology/runtime_graph.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng/topology/god_view_stream.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/topology_live/god_view.ex`
  - `elixir/web-ng/assets/js/lib/god_view/*`
  - topology snapshot/runtime graph/frontend regression tests
