# Change: Fix Service Device Sightings and Identity Reporting

## Why
Pollers and agents are being demoted to sightings because identity reconciliation treats their self-reported updates as weak signals, and source_ip often arrives as `auto`/empty. Their IP/hostname and partition data never stick, so promoted devices fall back into the sightings list instead of staying in inventory.

## What Changes
- Treat ServiceRadar service updates (poller/agent/checker and host self-registration) as authoritative devices, bypassing the sighting ingest path.
- Ensure pollers/agents send normalized source_ip + hostname and core fills missing values from pod/host metadata so devices carry real identity data.
- Align partition/identity metadata so service components land in the default partition with stable IDs rather than ambiguous `Serviceradar` sightings.
- Add regression tests to cover the service-device path while identity reconciliation is enabled.

## Impact
- Affected specs: `device-identity-reconciliation`
- Affected code: registry ProcessBatchDeviceUpdates/hasStrongIdentity, poller source IP resolution and registration, service device partition handling, identity tests/UI around sightings vs devices.
