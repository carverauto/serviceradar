# Change: Restore Soft-Deleted Devices on Fresh Sightings

## Why
After the latest deploy, the demo inventory dropped from ~50k faker devices to ~42k, and CNPG shows ~50k devices marked `_deleted=true`. Once a device is tombstoned, new sightings no longer clear `_deleted`, so devices never reanimate during DHCP churn.

## What Changes
- Allow non-deletion device updates to clear `_deleted`/`deleted` flags so re-sighted devices return to the active inventory while still honoring explicit deletion updates.
- Add regression coverage to prevent future drops in faker/demo when devices churn IPs.
- Verify demo counts recover to 50k and remain stable across churn cycles.

## Impact
- Affected specs: `service-device-capabilities`
- Affected code: `pkg/db/cnpg_unified_devices.go` (metadata merge), CNPG upsert regression tests, faker/demo verification scripts or docs.
- Open issue: Registry inventory is under-counting (~45–48k vs 50k in CNPG/SRQL); registry rehydration/consistency needs follow-up.
