## Context
The platform already has:
- a worker registry
- worker management API and UI
- active probe runtime for enabled registered workers

What is missing is a supported operator-facing way to configure probe behavior per worker.

## Goals
- Add explicit per-worker probe configuration to the registry.
- Expose probe settings through the existing management surface.
- Keep the active probe manager driven by registry state instead of duplicated runtime config.

## Non-Goals
- Adding a separate probe policy service
- Tenant-specific probe state or routing
- Building advanced probe schedules beyond bounded interval and timeout controls

## Probe Settings
The registry should support:
- `health_endpoint_url` override
- `health_path` fallback
- `health_timeout_ms`
- `probe_interval_ms`

These values live in worker metadata or first-class attributes, but the management surface must present them explicitly and predictably.

## Runtime Behavior
- The probe manager reads per-worker probe settings from the worker record.
- Missing values fall back to bounded platform defaults.
- Invalid values are rejected by the management surface rather than silently ignored when possible.
