## 1. Implementation

### 1.1 IP Conflict Resolution with Strong Identity Check
- [x] Modify `resolveIPConflictsWithDB()` in `pkg/registry/registry.go:465-585` to check strong identity (Armis ID, Netbox ID, MAC) before tombstoning:
  - Fetch existing device's full record when IP conflict detected
  - If both devices have different strong identities: clear IP from existing device instead of tombstoning new device
  - If same identity or no strong identity: use existing merge logic
- [x] Add helper function `getStrongIdentity(update *models.DeviceUpdate)` and `getStrongIdentityFromDevice(device *models.UnifiedDevice)` to fetch authoritative IDs

### 1.2 Batch Deduplication with Strong Identity Check
- [x] Modify `deduplicateBatch()` in `pkg/registry/registry.go:389-463` to respect strong identity:
  - When IP collision detected within batch, compare strong identities
  - If different identities: newer update claims IP, emit IP-clear update for older device (not tombstone)
  - If same identity: existing first-wins logic is correct (same device, duplicate update)

### 1.3 IP Clear Update Mechanism
- [x] Implement IP clearing by issuing a DeviceUpdate with `IP: "0.0.0.0"` and `_ip_cleared_due_to_churn` metadata.
  - Allows the device to remain canonical but release the IP for reassignment
  - Does NOT set `_merged_into` (device is not being merged, just losing its stale IP)

### 1.4 Diagnostic Logging
- [x] Add info-level logging when IP reassignment is detected between different devices:
  ```
  level=info msg="IP reassignment detected in batch (strong identity mismatch)" ip=10.0.0.1 old_device=sr:AAA old_identity=X new_device=sr:BBB new_identity=Y
  ```

## 2. Testing

- [x] Add unit test: Two devices with different Armis IDs, same IP → no tombstone, IP cleared from old device
- [x] Add unit test: `TestDeduplicateBatchMergesStrongIdentityByIP` updated to verify IP clearing on mismatch

## 3. Data Repair / Verification

- [ ] Write SQL query to identify devices with multiple/conflicting `armis_device_id` values in metadata
- [ ] Write SQL query to find tombstones where source and target have different Armis IDs (incorrect merges)
- [ ] Document cleanup procedure:
  1. Clear `_merged_into` on incorrectly tombstoned devices
  2. Deduplicate devices that were created after their original was tombstoned
  3. Re-poll from Armis to restore correct state
- [ ] Validate on demo: device inventory returns to ~50k devices after fix + cleanup
- [ ] Alternative: document reseed procedure for faker data on demo namespace
