# Change: Prevent sweep results from creating new device inventory entries

## Why
Network sweeps currently create device records for every host in a scanned CIDR, including non-responding hosts. This inflates inventory and produces misleading device counts. Sweep results should only update existing devices.

## What Changes
- Core/DIRE will gate sweep-result ingestion to existing inventory records; unmatched sweep hosts will be silently dropped and will not create new devices.
- Sweep results will continue to update availability/last_seen for matched devices and add "sweep" to `discovery_sources`.
- Update OpenSpec requirements to reflect that device creation comes from manual entry, discovery, or integrations rather than sweep results; no opt-in sweep creation path.

## Impact
- Affected specs: `sweeper`, `device-inventory`
- Affected code: core-elx sweep ingestion/DIRE identity resolution, sweep result tests, inventory update paths
