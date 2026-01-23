# Change: Update SNMP Credential Resolution

## Why
Discovery jobs currently store SNMP credentials directly, while SNMP profiles are used for polling configuration. This splits credential management across two systems and makes it easy for discovery credentials to drift from polling credentials. We need a single credential model that supports profile-scoped defaults with per-device overrides, and applies consistently for discovery and polling.

## What Changes
- **SNMP profiles include credentials** (v1/v2c/v3) in addition to targets and OIDs.
- **Per-device SNMP credential overrides** are introduced for cases where a device needs different credentials than its profile.
- **Mapper discovery jobs stop storing SNMP credentials** and instead resolve credentials via profile matching + per-device overrides.
- **Credential resolution is unified** across discovery and SNMP polling with a clear precedence order and profile priority.

## Impact
- Affected specs: network-discovery, snmp-checker, device-inventory
- Affected code: SNMP profiles resources + UI, mapper discovery job resources + UI, agent config compilation, SNMP credential resolution, migrations
- Migration: existing per-job SNMP credentials need a clear path (either migrate into profile creds or device overrides)
