# Change: Add camera analysis worker registry

## Why
The platform now supports:
- relay-scoped analysis branches
- normalized analysis result ingestion
- an HTTP worker adapter
- a reference worker
- an external Boombox-backed worker

What is still missing is a platform-owned worker registry and selection model. Without that, analysis workers are still effectively configured as one-off endpoints, which prevents clean multi-worker rollout, capability targeting, and operational failover.

## What Changes
- Add a registry of camera analysis workers that `core-elx` can target by identity and capability instead of only by ad hoc endpoint configuration.
- Define worker selection rules for relay-scoped analysis branches.
- Preserve the existing normalized `camera_analysis_result.v1` contract and provenance model.
- Add observability for worker registration, selection, and unavailable-worker conditions.
- Keep registry ownership in the platform rather than in external workers.

## Impact
- Affected specs:
  - `edge-architecture`
  - `observability-signals`
- Affected code:
  - `elixir/serviceradar_core/**`
  - `elixir/serviceradar_core_elx/**`
- Dependencies:
  - builds on `add-camera-analysis-http-worker-adapter`
  - builds on `add-external-boombox-camera-analysis-worker`
