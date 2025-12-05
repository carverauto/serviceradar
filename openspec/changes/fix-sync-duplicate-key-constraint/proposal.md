# Change: Fix duplicate key constraint violation during sync batch processing

## Why

Core in the demo namespace is emitting duplicate key constraint violations during device sync processing (issue #2067):

```
ERROR: duplicate key value violates unique constraint "idx_unified_devices_ip_unique_active" (SQLSTATE 23505)
```

Investigation reveals the root cause:

1. **`deduplicateBatch()` only handles weak-identity devices**: The current deduplication logic (registry.go:375-410) skips devices with strong identities (Armis ID, Netbox ID, MAC, integration_id). It assumes strong-identity devices represent distinct entities and should not be deduplicated by IP.

2. **Multiple strong-identity devices can share the same IP**: During sync, different discovery sources (or identity reconciliation flows) can produce multiple `DeviceUpdate` records with the same IP but different device IDs. When both have strong identities, neither is deduplicated.

3. **Batch upsert only handles device_id conflicts**: The `cnpgInsertDeviceUpdates()` function (cnpg_unified_devices.go:121-164) uses `ON CONFLICT (device_id)` but the unique constraint is on IP for active `sr:` devices. When two records in the same batch have the same IP, the second insert violates `idx_unified_devices_ip_unique_active`.

4. **Tombstones don't help within a batch**: When device A is canonicalized to device B, a tombstone is emitted for A (with `_merged_into`). However, both the tombstone and the canonical update are in the same batch. The constraint check happens at INSERT time before the tombstone marks device A as merged.

### The constraint definition (migration 008)

```sql
CREATE UNIQUE INDEX IF NOT EXISTS idx_unified_devices_ip_unique_active
ON unified_devices (ip)
WHERE device_id LIKE 'sr:%'
  AND (metadata->>'_merged_into' IS NULL OR metadata->>'_merged_into' = '' OR metadata->>'_merged_into' = device_id)
  AND COALESCE(lower(metadata->>'_deleted'),'false') <> 'true'
  AND COALESCE(lower(metadata->>'deleted'),'false') <> 'true';
```

This ensures only one active ServiceRadar device per IP, which is correct semantics. The problem is the batch processing doesn't guarantee this invariant before attempting the insert.

## What Changes

### 1. Extend batch deduplication to enforce IP uniqueness

Modify `deduplicateBatch()` to deduplicate ALL devices by IP within a batch, not just weak-identity devices. When multiple devices share the same IP:

- The **first device** (by order in batch) becomes the canonical device for that IP
- **Subsequent devices** with the same IP are converted to tombstones pointing to the first device
- Metadata from subsequent devices is merged into the first device to preserve information

This ensures the batch respects the unique constraint before it reaches the database.

### 2. Add IP collision logging and metrics

Add observability for IP collisions within batches:
- Log when IP collisions are detected and resolved
- Add metric `device_batch_ip_collisions_total` to track frequency

### 3. Preserve strong identity during merge

When merging strong-identity devices by IP:
- Copy identity markers (armis_device_id, netbox_device_id, etc.) from the tombstoned device to the surviving device
- This preserves the ability to look up the device by either identity

## Impact

- **Affected specs**: device-identity-reconciliation
- **Affected code**:
  - `pkg/registry/registry.go` (`deduplicateBatch()`, new logging/metrics)
  - `pkg/registry/metrics.go` (new counter metric)
- **Risk**: Low - changes are additive and defensive
- **Performance**: Negligible - adds one map lookup per device in batch

## Trade-offs

- **First-wins semantics**: When two strong-identity devices have the same IP, the first one in the batch survives. This is arbitrary but deterministic. The merged metadata preserves information from both sources.

- **Potential data loss**: If two genuinely distinct devices share an IP (e.g., behind NAT), this approach will merge them. However, the unique constraint already enforces this invariant, so this matches the intended data model.

- **Alternative considered - two-phase batch processing**: Process tombstones in a separate batch before inserts. Rejected because it requires transaction coordination and doesn't solve the case where two new devices have the same IP (neither has a tombstone yet).

- **Alternative considered - database-level MERGE**: Use a CTE to update existing records before inserting. Rejected because it adds significant query complexity and the Go-level deduplication is cleaner.
