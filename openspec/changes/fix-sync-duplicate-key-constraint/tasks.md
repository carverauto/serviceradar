## 1. Extend batch deduplication to enforce IP uniqueness (intra-batch)

- [x] 1.1 Modify `deduplicateBatch()` to track all devices by IP, not just weak-identity devices.
- [x] 1.2 When an IP collision is detected (second device with same IP), convert the second device to a tombstone pointing to the first.
- [x] 1.3 Merge metadata from the tombstoned device into the surviving device using `mergeUpdateMetadata()`.
- [x] 1.4 Preserve identity markers (armis_device_id, netbox_device_id, mac, integration_id) during merge.
- [x] 1.5 Skip service device IDs (`serviceradar:*`) as they use device_id identity.
- [x] 1.6 Skip existing tombstones (devices with `_merged_into` already set).

## 2. Add database conflict resolution (cross-batch)

- [x] 2.1 Create `resolveIPConflictsWithDB()` function to check batch against existing database records.
- [x] 2.2 Query database for existing active devices with IPs in the batch using `resolveIPsToCanonical()`.
- [x] 2.3 For conflicting devices, convert new device to tombstone pointing to existing device.
- [x] 2.4 Create merge update for existing device to incorporate new metadata.
- [x] 2.5 Call `resolveIPConflictsWithDB()` from `ProcessBatchDeviceUpdates()` after intra-batch deduplication.

## 3. Add observability for IP collisions

- [x] 3.1 Add `device_batch_ip_collisions_total` counter metric to identity metrics.
- [x] 3.2 Log IP collision events at Debug level with device IDs involved.
- [x] 3.3 Log summary at Info level with collision counts (`ip_collisions`, `db_ip_conflicts`).
- [x] 3.4 Record metrics in both `deduplicateBatch()` and `resolveIPConflictsWithDB()`.

## 4. Handle tombstone ordering within batch

- [x] 4.1 Append tombstones after canonical devices in the batch result.
- [x] 4.2 This ensures canonical devices are processed before tombstone references.

## 5. Testing

- [x] 5.1 Update existing `TestDeduplicateBatchMergesStrongIdentityByIP` to verify tombstone creation.
- [x] 5.2 Update existing `TestDeduplicateBatchMergesWeakSightings` to verify new behavior.
- [x] 5.3 Add `TestDeduplicateBatchSkipsServiceDeviceIDs` - service devices not deduplicated by IP.
- [x] 5.4 Add `TestDeduplicateBatchSkipsExistingTombstones` - existing tombstones pass through.
- [x] 5.5 Add `TestDeduplicateBatchSkipsEmptyIP` - devices without IPs not deduplicated.
- [x] 5.6 Add `TestDeduplicateBatchMultipleCollisions` - multiple IP collisions in single batch.
- [x] 5.7 Verify all registry tests pass (`go test ./pkg/registry/...`).
- [x] 5.8 Verify linter passes (`golangci-lint run ./pkg/registry/...`).

## 6. Deployment and validation

- [x] 6.1 Build updated code (`make build`).
- [x] 6.2 Push container images (`make push_all`).
- [x] 6.3 Deploy to demo namespace via helm upgrade.
- [x] 6.4 Verify duplicate key errors are eliminated in logs.
- [x] 6.5 Verify `db_ip_conflicts` logging shows conflicts being resolved.

**Validation Results (2025-12-05):**
- Deployed to demo namespace (helm revision 251)
- Observed: `"db_ip_conflicts":1286` - Fix resolved 1286 IP conflicts with existing database records
- Verified: Zero duplicate key errors in logs after fix deployment
- Sync processing completes successfully with large batches (16K+ devices)
