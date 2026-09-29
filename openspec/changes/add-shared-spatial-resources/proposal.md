# Change: Dashboard SDK: reusable spatial providers, tile sources and shareable map locations

Tracking issue: [#4910](https://github.com/carverauto/serviceradar/issues/4910).

## Why

Follow-up to #4774, not a blocker for its topology/ELK/scale acceptance. Expose the mapping engine to arbitrary dashboard use cases without copying the God View hook or requiring network topology storage.

## What Changes

- Extend existing createPlanView/usePlanView, map layer factories and host api.navigate/query-state interfaces. Coordinate with #4847; reuse its plan-view work. #4748's screen-space LOD is separate, already-tracked behavior.
- Define authorized host-owned spatial resource descriptors: stable resource/view identity, coordinate space/version, bounds, units/axes, default camera, zoom semantics, payload format and budgets.
- Extract bounded tile transport/cache/invalidation behind a source adapter. Keep schema-3 topology decoding, SNMP overlays and ELK in the topology adapter. Existing bounded frame-based maps remain supported.
- Share a fixed camera with optional selection, or resolve an object link to its current provider-owned location. Identify the dashboard instance and stable map view, including dashboards with multiple maps.
- Restore after resource readiness, ahead of default fit; debounce address-bar updates with host-owned replaceState and preserve unrelated query/history state. Include coordinates and zoom; geographic maps expose latitude/longitude and supported bearing/pitch.
- Reuse the #4774 location contract and compact route conventions. Links convey no access grants, backend URLs or credentials.

Related workstreams have separate proposals and acceptance checklists.

## Impact

Dashboard host plus carverauto/serviceradar-sdk-dashboard. Reuses #4847 plan-view work and #4774 camera/tiles; this follow-up does not block #4774.

Proposal and tracking only; no deployment, data ingestion or recording is enabled
by this documentation change.
