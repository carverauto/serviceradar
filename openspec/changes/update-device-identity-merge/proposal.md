# Change: Multi-Identifier Device Merge for DIRE

## Why
GitHub issue #2377 reports duplicate device records for `tonka01` in the demo-staging environment. DIRE should have reconciled multiple identifiers for the same router into a single canonical device.

Current observations in `demo-staging` (2026-01-19):
- `platform.ocsf_devices` contains two `tonka01` records with the same name/hostname and primary IP `216.17.46.98`, but different UIDs and MACs:
  - `sr:1bb1b077-df44-4ef9-b4ab-127eed6af3bf` (mac `0c:ea:14:32:d2:77`)
  - `sr:7588d12c-e8da-4b9e-a21d-8cc5c7faef38` (mac `0e:ea:14:32:d2:77`)
- `platform.device_identifiers` only registers the per-device MAC, so DIRE does not reconcile a multi-interface device when different sources choose different MACs.
- `platform.discovered_interfaces` already contains both MACs (`0c:ea:14:32:d2:77` and `0e:ea:14:32:d2:77`) on each device ID, indicating that the interface set overlaps and could be used to link identities.

These inconsistencies break inventory correctness and produce duplicate devices. Interface presentation has moved to SRQL `in:interfaces` against `platform.discovered_interfaces` (see `add-interface-timeseries`), so this change focuses on identity reconciliation and merge correctness.

## What Changes
- **DIRE multi-identifier convergence**: when a device update includes multiple strong identifiers (e.g., MACs), DIRE must reconcile them into a single canonical device ID and merge duplicates.
- **Identifier enrichment**: register interface MACs as strong identifiers to prevent new duplicates when multiple sources see different interfaces.
- **Merge reassignment**: reassign interface observations and inventory-linked records to the canonical device during merges (no data loss).
- **Scheduled reconciliation**: keep the AshOban reconciliation job running on a fixed cadence with run logging to clean up legacy duplicates.

## Impact
- **Affected specs**: `device-identity-reconciliation`
- **Affected systems**: IdentityReconciler (Elixir), mapper interface publishing, device identifier upserts, device merge auditing, job scheduling
- **Data operations**: reassign identifiers and associated records (including `discovered_interfaces`) to canonical device IDs
