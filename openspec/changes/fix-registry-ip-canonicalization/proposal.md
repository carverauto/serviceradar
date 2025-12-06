# Change: Fix IP conflict resolution to respect Armis device identity

## Why

Demo inventory collapsed to **362 devices out of 50,002**. Investigation revealed the root cause is **not** missing tombstone filtering (that filtering already exists), but rather that **IP conflict resolution ignores strong identity (Armis ID)**, causing distinct devices to be incorrectly merged when IPs are reassigned.

### The Real Problem: IP Churn Causes Wrong Merges

Our source system (Armis) polls devices at regular intervals. Due to DHCP and IP churn, devices occasionally change IP addresses. The `armis_device_id` is stable and should be the authoritative identifier—when we detect an IP change, we should simply update our record with the new IP.

**Current behavior (WRONG):**

When `resolveIPConflictsWithDB()` at `registry.go:522` detects an IP conflict:
```
DB state:      sr:AAA (armis_id=X, IP=10.0.0.1)
Incoming:      sr:BBB (armis_id=Y, IP=10.0.0.1)  ← different Armis device!
```

The code:
1. Sees IP conflict: "10.0.0.1 already belongs to sr:AAA"
2. **Tombstones sr:BBB → sr:AAA** (WRONG—these are different devices!)
3. Merges B's metadata (including `armis_id=Y`) into sr:AAA

**Result:**
- sr:AAA now has conflicting Armis IDs (corrupted identity)
- sr:BBB (the real device Y) is tombstoned to the wrong device
- Device Y is effectively lost from inventory

### IP Churn Scenario

```
T=0: Armis poll
     Device X (armis_id=X) has IP=10.0.0.1 → sr:AAA
     Device Y (armis_id=Y) has IP=10.0.0.2 → sr:BBB

T=1: IP churn (DHCP reassignment)
     Device X now has IP=10.0.0.2
     Device Y now has IP=10.0.0.1

T=2: Next Armis poll arrives
     Device X (armis_id=X, IP=10.0.0.2) - should update sr:AAA
     Device Y (armis_id=Y, IP=10.0.0.1) - should update sr:BBB

     But sr:AAA still has IP=10.0.0.1 in DB!

     If Y is processed before X's IP update:
     → IP conflict detected for 10.0.0.1
     → sr:BBB tombstoned to sr:AAA (WRONG!)
     → Device Y lost, sr:AAA corrupted with Y's identity
```

### Why Tombstone Cascade Happens

1. Device Y (sr:BBB) gets tombstoned to Device X (sr:AAA) — wrong merge
2. Next poll: Y's update tries to resolve `armis_id=Y`, but sr:BBB is tombstoned
3. System generates new sr:CCC for Y
4. IP conflict again with whoever currently has Y's IP
5. sr:CCC tombstoned to another wrong device
6. Repeat until inventory collapses

This explains:
- **49,641 rows with `_merged_into` set** — cascading wrong merges
- **49,510 tombstones pointing to non-existent targets** — targets themselves got tombstoned
- **`_merged_into` cycles** — devices merged in both directions due to IP swaps

### Previous Analysis Was Incorrect

The original proposal claimed "Registry IP resolution code does not filter out tombstoned rows." This is **no longer accurate**:

- `unifiedDevicesSelection` at `pkg/db/cnpg_unified_devices.go:54-56` already filters tombstones
- All identity resolution queries (`queryDeviceIDsByMAC`, `queryDeviceIDsByArmisID`, etc.) include tombstone filtering
- `resolveCanonicalIPs()` explicitly checks `isCanonicalUnifiedDevice()`

The tombstone filtering is working correctly. The problem is **upstream**: wrong merges are being created in the first place.

## What Changes

### 1. IP conflict resolution must respect strong identity

Modify `resolveIPConflictsWithDB()` at `registry.go:465-585` to check Armis ID before merging:

```go
// Current (WRONG):
if existingDeviceID, exists := existingByIP[update.IP]; exists && existingDeviceID != update.DeviceID {
    // Tombstone new device to existing ← WRONG if different Armis IDs!
}

// Fixed:
if existingDeviceID, exists := existingByIP[update.IP]; exists && existingDeviceID != update.DeviceID {
    existingArmisID := getArmisID(existingDevice)
    updateArmisID := getArmisID(update)

    if existingArmisID != "" && updateArmisID != "" && existingArmisID != updateArmisID {
        // DIFFERENT Armis devices sharing IP due to churn
        // The existing device's IP is stale—clear it, let new device have the IP
        emitIPClearUpdate(existingDeviceID)
        // Process update normally (no tombstone)
    } else {
        // Same device or no strong identity—existing merge logic OK
    }
}
```

### 2. Batch deduplication must respect strong identity

Apply same logic to `deduplicateBatch()` at `registry.go:389-463`:
- When two updates in the same batch have the same IP but different Armis IDs, they are **different devices**
- Only the most recent update (by timestamp or batch order) should claim the IP
- The other device should have its IP cleared, not be tombstoned

### 3. Identity-first resolution order

Ensure `DeviceIdentityResolver.ResolveDeviceIDs()` resolves by Armis ID **before** any IP-based conflict resolution runs, so devices are correctly identified before IP deduplication.

### 4. Add diagnostic logging

Log when IP conflict resolution encounters different Armis IDs to help diagnose IP churn patterns:
```
level=info msg="IP reassignment detected" ip=10.0.0.1 old_device=sr:AAA old_armis=X new_device=sr:BBB new_armis=Y
```

## Impact

- **Affected specs**: device-identity-reconciliation
- **Affected code**:
  - `pkg/registry/registry.go`: `resolveIPConflictsWithDB()`, `deduplicateBatch()`
  - `pkg/registry/device_identity.go`: Ensure Armis ID resolution happens first
- **Risk**: Medium — changes IP conflict handling logic, but targeted to check strong identity before merging

## Data Model Clarification

For our use case:
- **Armis ID** is the stable, authoritative device identifier from the source system
- **ServiceRadar ID** (`sr:...`) is our internal stable identifier, mapped 1:1 from Armis ID
- **IP address** is a mutable attribute that can change due to DHCP/churn
- **Tombstones** should only be created when migrating legacy IDs to `sr:` format, NOT for IP conflicts between distinct devices

## Data Repair

After deploying the fix:
1. Identify devices with multiple/conflicting Armis IDs in metadata (corruption from wrong merges)
2. Clear `_merged_into` on devices that were incorrectly tombstoned
3. Re-poll from Armis to restore correct device inventory
4. Alternatively: reseed faker data for clean slate on demo
