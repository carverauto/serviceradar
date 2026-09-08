# Change: Add Boombox-backed camera analysis sidecar worker

## Why
The platform now has:
- relay-scoped analysis branches
- a bounded HTTP worker adapter
- a reference HTTP worker proving the normalized contract
- an optional Boombox-backed analysis adapter that preserves relay, branch, and worker provenance

What is still missing is a real executable worker path that consumes relay-derived media through a Boombox-backed sidecar flow instead of only proving the contract through direct result injection. Without that, the Boombox path is structurally present but not operationally proven end to end.

## What Changes
- Add a small executable Boombox-backed analysis sidecar/worker that consumes bounded relay-derived media and processes it through Boombox.
- Define one bounded ingest mode for the sidecar, suitable for deterministic end-to-end validation and future production-facing worker evolution.
- Return derived findings through the existing normalized `camera_analysis_result.v1` contract and existing observability ingestion path.
- Preserve relay session, branch, and worker provenance from Boombox branch creation through sidecar result ingestion.
- Keep this sidecar path optional and adapter-specific; it does not replace the existing HTTP worker adapter.

## Impact
- Affected specs:
  - `edge-architecture`
  - `observability-signals`
- Affected code:
  - `elixir/serviceradar_core_elx/**`
  - `elixir/serviceradar_core/**`
  - supporting worker runtime or fixture path to be determined
- Dependencies:
  - Builds on `add-boombox-camera-analysis-adapter`
  - Compatible with the existing normalized analysis result contract
