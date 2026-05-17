# Change: Update managed device import semantics

## Why
`ocsf_devices.is_managed` is currently used as the canonical managed-device count input, but its semantics are fuzzy across imports and operator lifecycle actions. We need imported inventory to become managed by default while preserving explicit operator choices and keeping inactive devices out of active usage accounting.

## What Changes
- Define `is_managed` as managed-estate membership, not the out-of-service flag.
- Default new authoritative inventory creates/imports to `is_managed = true` and `is_active = true`.
- Preserve existing operator-managed `is_managed` values during re-import/update paths instead of blindly forcing imported devices back to managed.
- Keep `mark_inactive` and `mark_active` scoped to `is_active` so out-of-service state does not erase managed inventory membership.
- Keep usage/billing telemetry based on active managed devices: `is_managed = true AND is_active = true`.
- Treat inactive devices as archival-only records that are excluded from operational targeting, polling, sweeping, camera relay/start controls, and default SRQL device queries unless explicitly requested with `is_active` or `include_inactive:true`.

## Impact
- Affected specs: `device-inventory`, `tenant-capabilities`, `srql`, `sweep-jobs`, `snmp-checker`, `camera-streaming`
- Affected code: device Ash actions, inventory sync/import upserts, manual device creation behavior, tenant usage count tests, SRQL device query builder, sweep/SNMP target compilation, camera relay source selection
