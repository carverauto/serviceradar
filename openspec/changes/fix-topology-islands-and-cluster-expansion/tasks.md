## 1. Read-model projection completeness (islands)
- [x] 1.1 Add Device-to-Device `ATTACHED_TO`/`inferred-segment` branch to `graph_projection_query/0` in `runtime_topology_projection.ex`, projected with `topology_plane: 'attachment'`
- [x] 1.2 Map attachment rows for the new branch in `projection_attrs/2` (relation/evidence/plane metadata)
- [x] 1.3 Unit tests: projection includes inferred-segment device-device rows; counts match canonical AGE adjacency
- [ ] 1.4 Refresh demo projection and confirm island count drops to ~0 (diagnostics query; requires deploying the new core image)

## 2. Attachment-anchor metadata
- [x] 2.1 Resolve attachment anchors client-side from edge adjacency (`attachmentSatellitePlacements` in `layout_topology_state_methods.js`) instead of backend metadata - no identity fusion involved, backend change unnecessary
- [x] 2.2 Map `inferred-segment` evidence to the `endpoints` topology class in `god_view_stream.ex` so class counts match layout treatment

## 3. Concurrent cluster expansion
- [x] 3.1 Make the expansion limit configurable (`:serviceradar_web_ng, :god_view_expanded_cluster_limit`, default 4) in `topology_channel.ex`; expanding a new cluster no longer clears existing expansions; oldest collapses past the limit
- [x] 3.2 Channel tests: expand A then B - both present; exceed limit - oldest removed; collapse_all still clears all

## 4. Client layout: satellite + spiral geometry
- [x] 4.1 Place attachment-only devices on a ring/spiral around their anchor instead of unplaced lanes (`attachmentSatellitePlacements`)
- [x] 4.2 Replace expanded-cluster grid with golden-angle spiral placement (`expandedClusterSpiralMetrics`/`expandedClusterSpiralPosition`); degenerate small clusters collapse to the spiral center
- [x] 4.3 Score candidate placements by node overlap AND edge-segment crossings against non-cluster edges (`chooseExpandedClusterPlacement` + `clusterLayoutEdgeSegments` + `segmentsIntersect`)
- [x] 4.4 Barycenter ordering of backbone siblings before angular span division (`applyBarycenterChildOrder`, two-pass assignment in `computeBackboneLayeredPositions`)
- [x] 4.5 Unit tests for spiral math, crossing scorer, barycenter ordering, and satellite placement (30/30 in `layout_topology_state_methods.test.js`; 198/198 god_view suite; eslint + tsc clean)

## 5. Verification
- [ ] 5.1 Demo environment: two simultaneous cluster expansions render without node overlap or member-edge crossings (screenshots; requires image rollout)
- [ ] 5.2 Status-bar class counts show attachment devices connected (att count up, islands 0)
- [x] 5.3 Full gates: `make test` (Bazel unit shards) before PR; `openspec validate --strict` passing
