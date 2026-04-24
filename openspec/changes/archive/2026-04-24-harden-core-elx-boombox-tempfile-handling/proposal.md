# Change: Harden core-elx boombox tempfile handling

## Why
Core-ELX still stages relay-derived H264 capture samples in the global temp directory using predictable filenames built from `System.unique_integer/1`. That is a local-host hardening gap around transient media samples and temp-file ownership.

Both the external boombox worker and the relay-attached boombox sidecar follow this pattern today, so the fix should be shared instead of patched in two separate places.

## What Changes
- Add a shared secure tempfile helper for core-elx camera relay capture files.
- Move external boombox worker capture staging to secure random temp allocation with cleanup.
- Move boombox sidecar default output-path allocation to the same secure helper.
- Add focused tests for secure path generation and cleanup behavior.

## Impact
- Affected specs: `camera-streaming`
- Affected code:
  - `elixir/serviceradar_core_elx/lib/serviceradar_core_elx/camera_relay/external_boombox_analysis_worker.ex`
  - `elixir/serviceradar_core_elx/lib/serviceradar_core_elx/camera_relay/boombox_sidecar_worker.ex`
  - shared helper under `elixir/serviceradar_core_elx/lib/serviceradar_core_elx/camera_relay/`
