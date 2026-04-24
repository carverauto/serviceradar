## 1. Scope and Layout Contract
- [x] 1.1 Define the default God-View visible graph inputs that are allowed to affect backbone radial placement.
- [x] 1.2 Define deterministic hub/root selection rules for radial hub-and-spoke layout.
- [x] 1.3 Define how endpoint summaries, expanded endpoint members, and unplaced devices are anchored without entering the primary backbone solve.

## 2. Frontend Layout Refactor
- [x] 2.1 Replace the current default tree-plus-force-relaxation path with a true radial tier placement algorithm for infrastructure nodes.
- [x] 2.2 Remove the endpoint-heavy full-ELK fallback from the default overview path.
- [x] 2.3 Remove post-layout distortion (`normalizeHorizontalLayout`) and eliminate dead secondary projection helpers from the active default path.
- [x] 2.4 Keep auto-fit and cluster-focus behavior aligned with the new radial layout geometry.

## 3. Topology Input Cleanup
- [x] 3.1 Ensure endpoint-attachment and other non-backbone relations do not influence backbone coordinate solving.
- [x] 3.2 Ensure unresolved/unplaced nodes render in bounded diagnostic lanes or anchored groups instead of polluting hub selection.
- [ ] 3.3 Confirm the backend/frontend contract exposes the metadata needed for deterministic radial tiering without backend-authored geometry ownership.

## 4. Verification
- [x] 4.1 Add regression tests for a simple hub-and-spoke topology with one core, several access nodes, and endpoint fanout.
- [x] 4.2 Add regression tests for meshed backbone links to prove the radial layout remains readable and deterministic.
- [x] 4.3 Add regression tests proving endpoint expansion decorates an anchor instead of triggering a full backbone relayout.
- [x] 4.4 Run `openspec validate refactor-god-view-radial-hub-spoke-layout --strict`.
