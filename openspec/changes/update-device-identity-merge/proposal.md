# Change: Multi-Identifier Device Merge for DIRE

## Why
GitHub issue #2377 reports duplicate device records for `tonka01` in the demo-staging environment. DIRE should have reconciled multiple identifiers for the same router into a single canonical device.

Current observations in `demo-staging` (2026-01-19):
- `platform.ocsf_devices` contains two `tonka01` records with the same name/hostname and primary IP `216.17.46.98`, but different UIDs and MACs:
  - `sr:1bb1b077-df44-4ef9-b4ab-127eed6af3bf` (mac `0c:ea:14:32:d2:77`)
  - `sr:7588d12c-e8da-4b9e-a21d-8cc5c7faef38` (mac `0e:ea:14:32:d2:77`)
- `platform.device_identifiers` only registers the per-device MAC, so DIRE does not reconcile a multi-interface device when different sources choose different MACs.
- `platform.discovered_interfaces` already contains both MACs (`0c:ea:14:32:d2:77` and `0e:ea:14:32:d2:77`) on each device ID, indicating that the interface set overlaps and could be used to link identities.
- `platform.ocsf_devices.network_interfaces` is empty across all devices in demo-staging (50,003/50,003), so the UI Interfaces tab never renders data even when discovered interfaces exist.

These inconsistencies break inventory correctness, produce duplicate devices, and hide interface data in the UI. The current interface stream (`platform.discovered_interfaces`) is populated by mapper, but the UI expects `ocsf_devices.network_interfaces`, so interfaces never surface.

## What Changes
- **DIRE multi-identifier convergence**: when a device update includes multiple strong identifiers (e.g., MACs), DIRE must reconcile them into a single canonical device ID and merge duplicates.
- **Identifier enrichment**: register interface MACs as strong identifiers to prevent new duplicates when multiple sources see different interfaces.
- **Interface storage consolidation**: stop writing to `platform.discovered_interfaces` and instead write interface data directly to `ocsf_devices.network_interfaces` so the UI Interfaces tab reflects actual interface data.
- **Backfill/reconciliation**: provide a one-off reconciliation job to merge existing duplicates (starting with demo-staging).

## Impact
- **Affected specs**: `device-identity-reconciliation`, `device-inventory`
- **Affected systems**: IdentityReconciler (Elixir), SyncIngestor, mapper interface publishing, device identifier upserts, device merge auditing
- **Data operations**: reassign identifiers and associated records to canonical device IDs; backfill interface arrays
