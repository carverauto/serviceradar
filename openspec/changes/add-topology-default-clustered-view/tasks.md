## 1. Backend Clustered Topology Projection
- [x] 1.1 Define backend snapshot semantics for clustered endpoint-summary nodes, including stable IDs, counts, state rollups, and explicit cluster edges.
- [x] 1.2 Update the God-View projection pipeline so dense endpoint attachments are summarized into cluster nodes in the default view while preserving backbone topology.
- [x] 1.3 Keep backend-authored coordinates authoritative for both clustered and expanded views.

## 2. Expansion and Layer Behavior
- [x] 2.1 Add an explicit operator-driven expansion path for clustered endpoints that requests a new backend snapshot and renders expanded members in a backend-authored spiral fan-out rather than computing layout in the browser.
- [x] 2.2 Ensure endpoint-layer toggles hide/show clustered endpoint summaries and expanded endpoint leaves without affecting backbone infrastructure visibility.
- [x] 2.3 Define cluster detail metadata sufficient for node detail cards and operator drill-down.

## 3. Verification
- [x] 3.1 Add backend and frontend regression coverage using dense endpoint-heavy topology fixtures so the default view fails if it renders every endpoint leaf instead of clustering.
- [ ] 3.2 Validate representative demo-style fixtures where multiple endpoints attach to the same access device and confirm the default graph is materially simpler than the fully expanded endpoint view.
- [x] 3.3 Run `openspec validate add-topology-default-clustered-view --strict`.
