## Context
Camera analysis workers are now part of the platform runtime, but there is no first-class operator surface for creating, disabling, or inspecting them. That leaves important runtime state visible only through low-level resource access and telemetry consumers.

## Goals
- Provide a supported authenticated API for camera analysis worker management.
- Allow operators to inspect worker health, capabilities, and recent failover-relevant state.
- Reuse the existing Ash resource and runtime model rather than creating a second config store.

## Non-Goals
- Changing the dispatch contract.
- Adding a full external scheduler UI.
- Replacing Ash Admin where it is already sufficient for internal development.

## Decisions
### Start with API-first management
The first slice should expose a clean authenticated JSON API. A richer `web-ng` page can build on that, and Ash Admin remains a secondary/internal surface.

### Keep health inspection read-only from the management surface
Operators should be able to inspect health and enable/disable workers. Forced health overrides can come later if needed, but the initial management surface should not fight the runtime health model.

### Reuse current auth patterns
The management API should live under the existing authenticated `web-ng` API surface and follow the same scope/permission model as other operational endpoints.

## Risks
### Surface drift from runtime truth
If the management surface re-derives worker state instead of reading the registry directly, operators will see stale or partial information. The API should read the authoritative Ash model.

### Overexposing operational internals
Health and failure details are useful, but the surface should remain operator-focused instead of dumping raw internal state blobs without structure.
