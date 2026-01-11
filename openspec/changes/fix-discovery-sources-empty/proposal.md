# Change: Fix empty discovery_sources in ocsf_devices table

## Why

Device discovery sources (armis, netbox, snmp, etc.) are set correctly in the Go sync/integrations layer but never propagate to the `ocsf_devices` table in the database. The Elixir `SyncIngestor` module does not extract the `source` field from incoming device updates, resulting in all devices having empty `discovery_sources` arrays.

## What Changes

- Modify `SyncIngestor.normalize_update/1` to extract the `source` field from incoming device update payloads
- Modify `SyncIngestor.build_device_upsert_records/2` to include `discovery_sources` in device records
- Update the bulk upsert query to merge discovery sources on conflict (preserving existing sources while adding new ones)

## Impact

- Affected specs: device-inventory
- Affected code:
  - `elixir/serviceradar_core/lib/serviceradar/inventory/sync_ingestor.ex` (lines 261-281, 371-382)
  - Bulk upsert query in `bulk_upsert_devices/2` (lines 283-312)
