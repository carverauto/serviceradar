# Change: Add Camera Analysis Worker Probe Management

## Why
Active worker probing is running, but operators cannot yet manage probe-specific settings through the worker registry surface. That leaves important runtime behavior, such as health endpoint overrides and probe timing, effectively hard-coded.

## What Changes
- Extend the camera analysis worker registry model with probe-specific configuration.
- Expose probe settings through the existing worker management API and UI.
- Use registry-managed probe settings in the active probe manager.

## Impact
- Affected specs: `edge-architecture`, `build-web-ui`
- Affected code: `elixir/serviceradar_core`, `elixir/serviceradar_core_elx`, `elixir/web-ng`
