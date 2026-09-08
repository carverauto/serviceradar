# Change: Add camera analysis worker management surface

## Why
The platform now has:
- a camera analysis worker registry
- health-aware worker selection
- bounded capability failover

What is still missing is an operator-facing way to manage and inspect that worker fleet. Without a supported API or UI, workers can only be created or modified through ad hoc Ash calls, which is not acceptable for real operations.

## What Changes
- Add an authenticated management API for camera analysis workers.
- Support registering, updating, enabling, disabling, and inspecting worker health and capability metadata.
- Surface recent worker health and failover state in an operator-facing management surface.
- Keep the runtime dispatch contract unchanged; this change only adds supported management and inspection paths.

## Impact
- Affected specs:
  - `edge-architecture`
  - `build-web-ui`
- Affected code:
  - `elixir/serviceradar_core/**`
  - `elixir/web-ng/**`
- Dependencies:
  - builds on `add-camera-analysis-worker-registry`
  - builds on `add-camera-analysis-worker-health-and-failover`
