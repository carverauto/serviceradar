# Change: Fix duplicate key constraint violation during sync batch processing

## Why

Core in the demo namespace is emitting duplicate key constraint violations during device sync processing (issue #2067):

```
ERROR: duplicate key value violates unique constraint "idx_unified_devices_ip_unique_active" (SQLSTATE 23505)
```

Investigation reveals two root causes:

### Root Cause 1: Intra-batch IP duplicates

1. **`deduplicateBatch()` only handled weak-identity devices**: The original deduplication logic skipped devices with strong identities (Armis ID, Netbox ID, MAC, integration_id), assuming they represent distinct entities.

2. **Multiple strong-identity devices can share the same IP**: During sync, different discovery sources can produce multiple `DeviceUpdate` records with the same IP but different device IDs and different strong identities (e.g., different Armis IDs).

3. **Batch upsert only handles device_id conflicts**: The `cnpgInsertDeviceUpdates()` function uses `ON CONFLICT (device_id)` but the unique constraint is on IP. When two records in the same batch have the same IP but different device_ids, the constraint fires.

### Root Cause 2: Conflicts with existing database records

4. **Identity resolution prioritizes strong identities over IP**: The `lookupCanonicalFromMaps()` function resolves device identity in order: Device ID → Armis ID → Netbox ID → MAC → IP. When a device has a strong identity (e.g., Armis ID), it matches based on that identity, NOT based on IP.

5. **New devices can conflict with existing database records**: A new device with a different Armis ID but the same IP as an existing device will NOT be merged during identity resolution. When it tries to insert, the IP uniqueness constraint fires against the existing record.

### The constraint definition (migration 008)

```sql
CREATE UNIQUE INDEX IF NOT EXISTS idx_unified_devices_ip_unique_active
ON unified_devices (ip)
WHERE device_id LIKE 'sr:%'
  AND (metadata->>'_merged_into' IS NULL OR metadata->>'_merged_into' = '' OR metadata->>'_merged_into' = device_id)
  AND COALESCE(lower(metadata->>'_deleted'),'false') <> 'true'
  AND COALESCE(lower(metadata->>'deleted'),'false') <> 'true';
```

This ensures only one active ServiceRadar device per IP, which is correct semantics. The problem was that batch processing didn't guarantee this invariant against both intra-batch duplicates AND existing database records.

## What Changes

### 1. Extend batch deduplication to enforce IP uniqueness (intra-batch)

Modified `deduplicateBatch()` to deduplicate ALL devices by IP within a batch, not just weak-identity devices. When multiple devices share the same IP:

- The **first device** (by order in batch) becomes the canonical device for that IP
- **Subsequent devices** with the same IP are converted to tombstones pointing to the first device
- Metadata from subsequent devices is merged into the first device to preserve information
- Service device IDs (`serviceradar:*`) are excluded as they use device_id identity
- Existing tombstones pass through unchanged

### 2. Add database conflict resolution (cross-batch)

Added new `resolveIPConflictsWithDB()` function that runs after intra-batch deduplication:

- Queries the database for existing active devices with IPs in the batch using `resolveIPsToCanonical()`
- For any device whose IP already belongs to a different active device in the database:
  - Converts the new device to a tombstone pointing to the existing device
  - Creates a merge update to add new metadata to the existing device
- This prevents constraint violations when new devices conflict with existing records

### 3. Add IP collision logging and metrics

Added observability for IP collisions:
- Debug-level logging when IP collisions are detected (both intra-batch and database)
- Info-level summary logging with collision counts
- Metric `device_batch_ip_collisions_total` to track cumulative collision frequency

### 4. Preserve identity markers during merge

When merging devices by IP:
- Metadata from the tombstoned device is copied to preserve identity markers (armis_device_id, netbox_device_id, etc.)
- MAC addresses are merged if present
- This preserves the ability to look up the device by any of its identities

## Impact

- **Affected specs**: device-identity-reconciliation
- **Affected code**:
  - `pkg/registry/registry.go`:
    - `deduplicateBatch()` - extended to handle all devices by IP
    - `resolveIPConflictsWithDB()` - new function for database conflict resolution
    - `ProcessBatchDeviceUpdates()` - added call to new function
  - `pkg/registry/identity_metrics.go` - new `device_batch_ip_collisions_total` metric
  - `pkg/registry/registry_dedupe_test.go` - updated and added tests
- **Risk**: Low - changes are defensive and gracefully handle edge cases
- **Performance**: One additional database query per batch (to resolve IPs to canonical device IDs)

## Trade-offs

- **First-wins semantics**: When two devices have the same IP, the first one (either in batch or in database) survives. This is deterministic and consistent with the constraint semantics.

- **Database query per batch**: The `resolveIPConflictsWithDB()` function adds one database query per batch. This is acceptable given batch sizes (~16K devices) and the query uses existing `resolveIPsToCanonical()` infrastructure which is optimized for bulk IP lookups.

- **Potential data loss**: If two genuinely distinct devices share an IP (e.g., behind NAT), this approach will merge them. However, the unique constraint already enforces this invariant, so this matches the intended data model.

## Validation Results (2025-12-05)

Deployed to demo namespace and observed:
- `"db_ip_conflicts":1286` - Fix resolved 1286 IP conflicts with existing database records
- Zero duplicate key errors after fix deployment
- Sync processing completes successfully with large batches (16K+ devices)
