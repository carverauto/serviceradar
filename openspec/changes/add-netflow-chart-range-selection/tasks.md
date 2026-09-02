## 1. Shared Range-Selection Controller

- [x] 1.1 Confirm the shared first-drag lifecycle correction has landed and archive the completed `add-chart-region-selection` prerequisite before implementation begins.
- [x] 1.2 Add regression coverage for a coalesced fast drag whose qualifying movement first appears on pointer-up and an unrelated LiveView update during pointer capture, then extract a composable controller while keeping the standalone `ChartRangeSelection` hook data attributes, pointer/touch/keyboard behavior, and Events consumer intact.
- [x] 1.3 Add controller coverage for renderer-supplied SVG/overlay/geometry updates, invalidated metadata reset, teardown, and repeated redraws without duplicate listeners.

## 2. NetFlow Interval and URL Contract

- [x] 2.1 Add failing Elixir tests for canonical NetFlow `{x, start, end}` metadata, including deterministic Lines and Grid coordinates, a centered single point, missing buckets, and an inclusive end exactly one microsecond before the next bucket boundary.
- [x] 2.2 Add a focused NetFlow range helper that derives selectable intervals from the current Traffic Over Time points and validates an ordered client payload against a contiguous span of those intervals.
- [x] 2.3 Add failing LiveView tests proving valid committed ranges replace only the SRQL `time:` clause, set `view=explorer`, and preserve all remaining query tokens, compact/talker, compare, geography, Sankey-prefix, stack, graph, and effective-limit options. Cover both an SRQL `limit:` token and a legacy URL `limit=` value so the effective limit and its precedence survive.
- [x] 2.4 Add rejection tests for missing, malformed, equal, reversed, stale, out-of-window, and well-formed but non-rendered bounds; hidden or empty Lines/Grid, Stacked/100%, Protocol, and Application surfaces across each view/mode; and any payload containing fields beyond `start` and `end`, including query fragments or destinations.
- [x] 2.5 Implement `netflow_range_selected` through the existing same-route Flow Explorer patch flow, while routing the existing one-bucket action through the same validation/helper with its corrected inclusive end and current-view behavior.

## 3. Traffic Over Time Integration

- [x] 3.1 Add failing component tests for range metadata, accessible instructions/status, selection overlay, and empty state in Lines and Grid modes while retaining the current bucket click values and tooltip data.
- [x] 3.2 Compose the shared controller into `NetflowTrafficTooltip` and opt the server-rendered Traffic Over Time chart into range selection without adding a second LiveView hook.
- [x] 3.3 Add JavaScript regression tests proving tooltip movement, sub-threshold one-bucket clicks, a completed drag, keyboard selection, LiveView update survival, and cleanup coexist.
- [x] 3.4 Add failing D3 tests for Stacked and 100% Traffic Over Time using the actual D3 x scale and exact server intervals across mount, unchanged LiveView update, resize, data update, and teardown.
- [x] 3.5 Compose the shared controller into `NetflowStackedAreaChart`, skip destructive redraws when its render fingerprint is unchanged, and retain legend behavior plus the existing `data-zoomable` device-detail brush path without allowing both interaction modes at once.

## 4. Protocol and Application Activity Integration

- [x] 4.1 Add component tests proving Activity by Protocol and Activity by Application provide the same canonical range metadata and accessible selection surface as Traffic Over Time.
- [x] 4.2 Add D3 hook tests proving a range drag emits only `netflow_range_selected`, a plain protocol/application series click still emits `netflow_stack_series`, and a committed drag suppresses only its synthetic follow-up click.
- [x] 4.3 Enable shared range selection on both activity charts and preserve their colors, legends, tooltips, empty states, and `protocol_group`/`app` filtering.
- [x] 4.4 Add LiveView coverage proving a committed selection from either activity card opens Flow Explorer for the selected interval while preserving active graph/stack and the remaining non-time options.

## 5. Verification and Rollout

- [x] 5.1 Run the shared range helper/controller and NetFlow hook Vitest files, followed by the complete `elixir/web-ng/assets` suite.
- [x] 5.2 Run `mix format --check-formatted`, focused database-free NetFlow ExUnit tests, targeted lint, and the Bazel production web asset build.
- [ ] 5.3 Verify first-attempt pointer drag through a qualifying renderer redraw, reverse drag, touch-sized input, keyboard selection, ordinary clicks, and Flow Explorer navigation on all three requested cards in a browser.
  - Browser verification passed for first-attempt redraw, reverse drag, keyboard selection, ordinary clicks, and all three cards on farm01 and CarverAuto demo. The in-app browser rejects genuine touch dispatch, so a hardware touch pass remains; controller regression coverage for `pointerType: "touch"` passes.
- [x] 5.4 Run the repository-required `make lint` and `make test` Bazel gates and resolve any failures attributable to this change.
- [x] 5.5 Build and push the required immutable SHA image set with Bazel only, roll it to farm01, and verify exact image digests plus all three cards navigate to Flow Explorer for committed ranges while ordinary clicks retain their current-view actions.
- [x] 5.6 Sign the required CarverAuto digest(s), advance the guarded Argo demo source, and verify `Synced|Healthy|Succeeded`, exact running digests, and all three cards navigate to Flow Explorer for committed ranges without fresh web errors.
- [x] 5.7 Add regression coverage for a visible first-drag selection whose pointer release lands just outside the plot, commit the last successfully rendered endpoint, and rerun the focused chart suite, complete asset suite, targeted lint, and repository Bazel test gate.
- [x] 5.8 Roll the follow-up immutable digest to farm01 and CarverAuto demo, verify both clusters are healthy on that exact digest with clean steady-state logs, and confirm a first-attempt drag released below the plot opens Flow Explorer on all three NetFlow cards.
- [ ] 5.9 Reproduce the remaining coalesced first-drag failure where no in-plot move is sampled, keep range starts strict while projecting active-gesture endpoints onto the plot, run focused/full JavaScript and Bazel gates, and roll plus verify the corrected immutable digest on farm01 and CarverAuto demo.
