## 1. Analysis and Proposal
- [x] 1.1 Confirm current NetFlow map interaction model and renderer type.
- [x] 1.2 Confirm current God View deck.gl camera/control implementation.
- [x] 1.3 Identify LiveView responsibilities that need module boundaries.
- [x] 1.4 Draft and validate OpenSpec proposal.

## 2. Snapshot Reliability
- [x] 2.1 Update `GodViewStream.latest_snapshot/1` so valid over-budget snapshots are served and cached.
- [x] 2.2 Emit over-budget/drop telemetry without returning `snapshot_unavailable` for valid payloads.
- [x] 2.3 Add runtime and Helm configuration for snapshot budget and coalescing.
- [x] 2.4 Update channel/controller/stream tests for valid over-budget snapshots.

## 3. LiveView Refactor
- [x] 3.1 Extract God View template and presentation helpers into component/template modules.
- [x] 3.2 Extract stream state and client perf telemetry into a dedicated module.
- [x] 3.3 Extract MTR overlay query/cache/normalization into a dedicated module.
- [x] 3.4 Extract camera relay single-session workflow into a dedicated module.
- [x] 3.5 Extract camera relay tile workflow into a dedicated module.
- [x] 3.6 Extract filter/layer/zoom assign transformations into a dedicated control-state module.
- [x] 3.7 Keep `TopologyLive.GodView` under a few hundred lines with event delegation and no embedded workflow bulk.

## 4. Shared Map Controls
- [x] 4.1 Add pure God View deck camera math for focal zoom, pan, clamp, and reset/fit state.
- [x] 4.2 Add topology map control binding for zoom in, zoom out, reset, and fit actions.
- [x] 4.3 Wire God View wheel/pan/control actions through the deck camera helper while preserving zoom-tier updates.
- [x] 4.4 Add or update CSS so topology controls render correctly without overlapping the existing LiveView controls.

## 5. Verification
- [x] 5.1 Run focused JS unit tests for God View camera math and controls.
- [ ] 5.2 Run focused Elixir tests for topology stream/channel/controller behavior.
- [x] 5.3 Run `mix compile --warnings-as-errors` in `elixir/web-ng`.
- [ ] 5.4 Run applicable web-ng quality checks or document any environment blockers.
- [ ] 5.5 Browser-check `/dashboard` NetFlow map and `/topology` after login with desktop/mobile screenshots.
