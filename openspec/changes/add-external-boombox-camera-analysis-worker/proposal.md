# Change: Add external Boombox-backed camera analysis worker

## Why
The platform now has:
- relay-scoped analysis branches
- a normalized analysis result contract
- an HTTP worker adapter
- an in-process Boombox-backed sidecar proof inside `core-elx`

What is still missing is a production-facing executable worker path outside `core-elx`. Without that, the Boombox analysis path is proven in-process, but not as an independently deployable worker boundary with explicit lifecycle, transport, and observability expectations.

## What Changes
- Add a real external Boombox-backed analysis worker executable that consumes bounded relay-derived media.
- Define one explicit handoff mode from `core-elx` relay analysis branches to that worker.
- Keep result ingestion on the existing normalized `camera_analysis_result.v1` contract.
- Preserve relay session, branch, and worker provenance from dispatch through result ingestion.
- Keep the external worker bounded and subordinate to relay/viewer stability rather than turning it into a second media plane.

## Impact
- Affected specs:
  - `edge-architecture`
  - `observability-signals`
- Affected code:
  - `elixir/serviceradar_core_elx/**`
  - `elixir/serviceradar_core/**`
  - new worker/runtime path to be added
- Dependencies:
  - builds on `add-boombox-camera-analysis-sidecar`
  - compatible with the existing normalized analysis result contract
