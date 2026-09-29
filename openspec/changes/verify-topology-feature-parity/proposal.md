# Change: God View: verify legacy feature parity and bounded ELK detail layouts

Tracking issue: [#4908](https://github.com/carverauto/serviceradar/issues/4908).

## Why

Completion gate for #4774 and #4901. Keep the current workstream focused on the mapping/topology engine. Audit the previous working topology experience and prove the replacement preserves its operator behavior.

## What Changes

- Build a concrete old-versus-new parity matrix from the existing renderer, tests and documented behavior: infrastructure/attachment visibility, labels, picking and details, search and filtering, expansion/paging, status colors, traffic controls, Fit/Home, pan/zoom and detail entry/return. Link overlapping search/filter work in #4449 rather than implementing a competing path.
- Fix regressions in the tile engine and bounded detail renderer. Audit existing ELK radial/forest adapters before rebuilding them.
- Preserve #4749's typed schema-3/WebGPU layers and per-edge procedural packet animation.
- The world overview uses persisted server coordinates. ELK remains the layout authority inside explicitly entered, bounded detail scenes. Do not run ELK on the entire million-device world or claim a coordinate grid alone proves ELK parity.
- Preserve map camera/cache when entering and leaving details, correctly scoped Fit behavior, stable selection and compact location links.

Related workstreams have separate proposals and acceptance checklists.

## Impact

Existing topology browser, bounded ELK scene adapters and acceptance evidence. Depends on the carrier-scale engine implementation; this is a completion gate for #4774.

Proposal and tracking only; no deployment, data ingestion or recording is enabled
by this documentation change.
