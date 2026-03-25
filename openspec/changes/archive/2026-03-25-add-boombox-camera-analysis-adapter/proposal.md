# Change: Add Boombox-backed adapter for camera stream analysis

## Why
The platform now has:
- relay-scoped analysis branches
- a normalized analysis worker contract
- a bounded HTTP worker adapter
- an executable reference worker proving the contract end to end

What is still missing is a production-oriented media bridge that can hand relay-derived media to external processing systems without forcing every worker to accept raw HTTP JSON payloads directly. Boombox is a reasonable next adapter candidate because it can help bridge media into external analysis systems while keeping the platform-owned relay/session model intact.

## What Changes
- Add a Boombox-backed analysis adapter on top of the existing relay-scoped analysis branch model.
- Define how relay-derived media samples or streams are exposed to Boombox-managed analysis consumers.
- Preserve the existing normalized result ingestion path so Boombox-backed workers return through the same observability contract.
- Keep Boombox as an optional adapter path, not the only supported analysis transport.

## Impact
- Affected specs:
  - `edge-architecture`
  - `observability-signals`
- Affected code:
  - `elixir/serviceradar_core_elx/**`
  - `elixir/serviceradar_core/**`
- Dependencies:
  - Builds on `add-camera-stream-analysis-egress`
  - Builds on `add-camera-analysis-http-worker-adapter`
  - Builds on `add-camera-analysis-reference-worker`
