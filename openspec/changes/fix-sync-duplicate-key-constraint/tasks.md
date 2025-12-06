## 1. Extend batch deduplication to enforce IP uniqueness

- [x] 1.1 Modify `deduplicateBatch()` to track all devices by IP, not just weak-identity devices.
- [x] 1.2 When an IP collision is detected (second device with same IP), convert the second device to a tombstone pointing to the first.
- [x] 1.3 Merge metadata from the tombstoned device into the surviving device using `mergeUpdateMetadata()`.
- [x] 1.4 Preserve identity markers (armis_device_id, netbox_device_id, mac, integration_id) during merge.
- [x] 1.5 Add unit tests for IP collision scenarios in batch deduplication.

## 2. Add observability for IP collisions

- [x] 2.1 Add `device_batch_ip_collisions_total` counter metric to registry metrics.
- [x] 2.2 Log IP collision events at Debug level with device IDs involved.
- [x] 2.3 Record collision count per batch in existing batch processing log message.

## 3. Handle tombstone ordering within batch

- [x] 3.1 Sort the final batch so tombstones (devices with `_merged_into`) are processed after their targets.
- [x] 3.2 This ensures the canonical device exists before references to it are created.

## 4. Testing and validation

- [x] 4.1 Add integration test that verifies two strong-identity devices with same IP are deduplicated.
- [x] 4.2 Verify existing tests still pass (no regression).
- [x] 4.3 Deploy to demo namespace and verify duplicate key errors are eliminated.
- [x] 4.4 Monitor `device_batch_ip_collisions_total` metric to understand collision frequency.

**Validation Results (2025-12-05):**
- Deployed to demo namespace (helm revision 251)
- Observed: `"db_ip_conflicts":1286` - Fix resolved 1286 IP conflicts with existing database records
- Verified: Zero duplicate key errors in logs after fix deployment
