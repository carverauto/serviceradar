# Device Canon Architecture Findings

## Context
We investigated an issue where the device count is inflated due to duplicate devices being created. This is caused by inconsistent UUID generation between devices discovered via network sweeps (IP-only) and devices synced from Armis (Strong IDs).

## Documents Reviewed
- `kv_fix.md`: Describes the history of the problem and the discovery of the UUID generation issue.
- `device_canon_plan.md`: Proposes a solution to make UUID generation deterministic based on IP+Partition.

## Codebase Exploration Findings

### `pkg/registry/device_identity.go`
- **UUID Generation**: `generateServiceRadarDeviceID` currently includes strong identifiers (MAC, Armis ID) in the hash if available. This means a device discovered via sweep (IP only) gets a different UUID than the same device synced from Armis (IP + MAC/Armis ID).
- **Resolution Logic**: `ResolveDeviceIDs` attempts to find existing devices but falls back to generating a new UUID if the identifiers don't match exactly or if the existing device doesn't have a strong identifier.

### `pkg/core/result_processor.go`
- **Legacy IDs**: `processHostResults` explicitly sets `DeviceID` to `fmt.Sprintf("%s:%s", partition, host.Host)`. This legacy format (`partition:IP`) forces the registry to treat it as a "legacy" device and potentially generate a new UUID if not handled correctly, but more importantly, it doesn't match the `sr:` UUID format we want.

### `pkg/sync/integrations/armis/devices.go`
- **Armis Updates**: Armis sync creates `DeviceUpdate` events. We need to ensure these updates allow the registry to resolve the identity rather than forcing a specific ID that might conflict or duplicate.

## Evaluation of Proposed Fixes
The proposed plan in `device_canon_plan.md` addresses the root cause:
1.  **Deterministic UUIDs**: Changing `generateServiceRadarDeviceID` to use `partition:IP` as the *only* seed for the UUID ensures that the same physical device (assuming static IP or handled IP churn) gets the same UUID regardless of whether it was found by sweep or Armis.
2.  **Strong IDs as Merge Signals**: Strong identifiers will be used to *merge* records (e.g., adding MAC/Armis ID to an existing IP-based record) rather than changing the UUID.
3.  **Legacy ID Cleanup**: Stopping `result_processor.go` from generating `partition:IP` IDs will prevent "legacy" devices from entering the system and force them through the new resolution logic.

## Recommendations
We should proceed with the plan outlined in `device_canon_plan.md`.
1.  Modify `pkg/registry/device_identity.go` to make UUID generation IP-based.
2.  Modify `pkg/core/result_processor.go` to stop sending legacy IDs.
3.  Implement batch deduplication in `pkg/registry/registry.go`.
4.  Run a database migration to merge existing duplicates.
