# Change: Preserve exact filtered connections across Atlas zoom levels

## Why

A filtered aggregate can show a positive match count while all its incident
edges disappear. `WorldTileLayer.relationShown` currently requires every device
represented by both endpoint glyphs to match. Zooming in can promote matching
devices to individual glyphs and make the same connections appear.

This is the explicitly deferred partial-aggregate limitation in
`add-topology-bitmap-query-index`, separate from the camera continuity repair.
Removing the completeness check alone would invent connections: two aggregates
can each contain matches while every connection joins excluded devices.

## What Changes

- Project exact authorized matching relation counts for each admitted Arrow
  edge, using canonical endpoint membership from the same query revision as
  the node overlay.
- Draw and allow picking a filtered edge when its exact matching count is
  positive, including edges incident to partially matched aggregates.
- Report the matching connection count in filtered picking/details. Preserve
  the geometry's full count separately for identity and validation.
- Keep whole-bundle traffic hidden unless the matching relation count equals
  the full represented count and existing telemetry completeness checks pass.
- Negotiate a version-2 membership frame while preserving version-1 behavior
  for older clients and servers. Preserve the existing pan/zoom retention,
  expiry, atomic replacement and authorization rules.
- Cover mixed-vendor aggregates, false-positive endpoint combinations, clipped
  edges, query changes and zoom refinement with invented fixtures.

## Scope and Approval

This proposal was approved in the implementation conversation. It extends
the existing bitmap query capability rather than changing layout or creating a
second filter engine. The implementation will also amend the still-pending
bitmap proposal's partial-aggregate scenario and design, so its later archival
cannot restore the old rule for version-2 clients.

Partial-population traffic calculation, relayout, new filter predicates,
deployment, and automatic merging are outside this change.

## Impact

- Native Atlas ordinal/selection projection and the existing bitmap query NIF.
- Elixir membership projection, frame encoder and channel negotiation.
- Browser frame admission, edge rendering and filtered picking.
- Existing protocol documentation and synthetic native/browser regressions.
- Implementation in this Treehouse worktree; publication through no-mistakes.

See [design](design.md), [requirements](specs/topology-god-view/spec.md) and
[tasks](tasks.md).
