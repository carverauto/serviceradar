## Context
ServiceRadar now has two related but distinct lifecycle concepts on `ocsf_devices`:
- `is_managed`: whether ServiceRadar treats the device as part of the managed inventory estate.
- `is_active`: whether that managed device is currently in service and should produce operational signal.

Conflating these fields would make inactive devices disappear from managed inventory context and would conflict with existing agent-backed device rules that require managed state.

## Goals / Non-Goals
- Goals:
  - Make newly imported devices managed by default.
  - Preserve explicit operator managed/unmanaged choices during later imports.
  - Keep inactive devices visible but excluded from active usage accounting.
  - Exclude inactive devices from operational work by default.
  - Avoid reactivating or remanaging devices just because an integration sees them again.
- Non-Goals:
  - Add commercial billing policy or hard feature gates.
  - Delete inactive devices or raw telemetry.
  - Use `is_managed` as a replacement for active/inactive lifecycle state.

## Decisions
- Decision: Treat `is_managed` as estate membership and `is_active` as service lifecycle.
- Decision: Import/create paths set managed and active defaults only for newly created devices.
- Decision: Update/upsert paths must not overwrite existing `is_managed` or `is_active` with defaults unless the source explicitly owns that lifecycle field and the action permits it.
- Decision: Operator active/inactive actions update only `is_active`.
- Decision: Default SRQL `in:devices` queries include active devices only. Explicit `is_active:false` remains the inactive archival lookup path, and inventory views that need all lifecycle states use `include_inactive:true`.
- Decision: Polling, sweeping, baseline diagnostics, and camera relay source selection must treat inactive devices as ineligible targets.

## Risks / Trade-offs
- Existing bulk upsert code that always writes `is_managed = true` can remanage devices unexpectedly.
  - Mitigation: split create defaults from update preservation or use conflict updates that omit managed/active fields for existing records.
- Some existing integrations may believe they own management status.
  - Mitigation: require explicit tests for each changed import path and preserve source-owned fields only where already modeled.

## Migration Plan
No data migration is required beyond the existing `is_active` migration. Existing `is_managed` values remain authoritative operator/source state.
