# Change: Refactor topology layout stability and performance

## Why
`prop2.md` identifies deferred layout concerns that can cause hairball rendering and unstable node placement under high fanout. We need a dedicated change to stabilize layout computation and control expensive per-snapshot work.

## What Changes
- Define deterministic topology layout behavior under unchanged topology revisions.
- Add role/priority-informed layout controls for infrastructure anchoring.
- Reduce expensive per-snapshot layout computations that do not materially improve operator outcomes.

## Impact
- Affected specs:
  - `build-web-ui`
- Expected code areas:
  - `web-ng/lib/serviceradar_web_ng/topology/*`
  - Rust NIF layout paths used by web-ng topology snapshots
