# Change: Prevent duplicate devices for identical IP and partition

## Why
Issue 2642 reports the same device (farm01) appearing twice in inventory with the same IP address and partition. This indicates DIRE is creating multiple device IDs for the same IP-only identity, which fragments inventory and downstream reconciliation.

## What Changes
- Resolve IP-only updates to an existing canonical device when the primary IP matches within the same partition.
- Merge existing duplicates that share the same partition + primary IP during reconciliation.
- Add tests and telemetry around IP-only resolution and merge decisions.

## Impact
- Affected specs: device-identity-reconciliation
- Affected systems: DIRE identity resolution, reconciliation job, device inventory ingest
