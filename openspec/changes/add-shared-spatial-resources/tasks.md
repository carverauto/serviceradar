## 1. Implementation

- [ ] 1.1 Extend existing createPlanView/usePlanView, map layer factories and host api.navigate/query-state interfaces. Coordinate with #4847; reuse its plan-view work. #4748's screen-space LOD is separate, already-tracked behavior.
- [ ] 1.2 Define authorized host-owned spatial resource descriptors: stable resource/view identity, coordinate space/version, bounds, units/axes, default camera, zoom semantics, payload format and budgets.
- [ ] 1.3 Extract bounded tile transport/cache/invalidation behind a source adapter. Keep schema-3 topology decoding, SNMP overlays and ELK in the topology adapter. Existing bounded frame-based maps remain supported.
- [ ] 1.4 Share a fixed camera with optional selection, or resolve an object link to its current provider-owned location. Identify the dashboard instance and stable map view, including dashboards with multiple maps.
- [ ] 1.5 Restore after resource readiness, ahead of default fit; debounce address-bar updates with host-owned replaceState and preserve unrelated query/history state. Include coordinates and zoom; geographic maps expose latitude/longitude and supported bearing/pitch.
- [ ] 1.6 Reuse the #4774 location contract and compact route conventions. Links convey no access grants, backend URLs or credentials.

## 2. Acceptance

- [ ] A synthetic non-network Cartesian resource and a geographic moving-object resource work through the same provider boundary.
- [ ] Copy/paste, reload and Back/Forward restore the intended map/view/camera; refreshes do not reset it.
- [ ] Fixed-view links remain at the shared area after an object moves; object links resolve current position without silently enabling tracking.
- [ ] Wrong resource/version, missing selection and denied access produce explicit states.
- [ ] Tile budgets/cache identities remain isolated across resources; unmount/resource changes release requests, subscriptions and cache.
- [ ] Topology ELK, packet flow and existing dashboard maps retain parity.

## 3. Delivery

- [ ] 3.1 Validate this proposal with openspec validate --strict and run applicable remote checks.
- [ ] 3.2 Run make test and deliver code changes through no-mistakes with the srql-fixtures-only database restriction in the intent.
- [ ] 3.3 Record evidence and close only this issue after its own acceptance passes.
