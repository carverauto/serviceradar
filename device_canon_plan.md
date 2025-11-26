# Device Canonicalization Fix Plan

## Problem Statement

Expected device count: **50,000 + 2** (50k from faker, poller, agent)
Actual device count: **~61,100**
Excess devices: **~11,000 duplicates**

Despite implementing the ServiceRadar UUID identity system (`sr:<uuid>`), device count continues to grow beyond the expected 50k. This document analyzes the root causes and proposes a comprehensive fix.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                         Current Data Flow                                        │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│  ┌─────────────┐         ┌─────────────┐         ┌─────────────┐               │
│  │   Faker     │         │   Sync      │         │   Poller    │               │
│  │  (50k dev)  │         │  Service    │         │  (Sweep)    │               │
│  └──────┬──────┘         └──────┬──────┘         └──────┬──────┘               │
│         │                       │                       │                        │
│         │ HTTP /api/v1/search   │                       │ gRPC ReportSweep      │
│         ▼                       │                       ▼                        │
│  ┌─────────────┐                │              ┌─────────────────────┐          │
│  │ Armis Sync  │                │              │ result_processor.go │          │
│  │ devices.go  │                │              │ processHostResults()│          │
│  └──────┬──────┘                │              └──────────┬──────────┘          │
│         │                       │                         │                      │
│         │ DeviceUpdate {        │                         │ DeviceUpdate {       │
│         │   DeviceID: ""        │                         │   DeviceID:          │
│         │   armis_id: "12345"   │                         │   "default:10.1.2.3" │
│         │   MAC: "AA:BB:CC..."  │                         │   (no strong IDs)    │
│         │ }                     │                         │ }                    │
│         │                       │                         │                      │
│         └───────────────────────┼─────────────────────────┘                      │
│                                 ▼                                                │
│                    ┌─────────────────────────────┐                               │
│                    │ DeviceRegistry              │                               │
│                    │ ProcessBatchDeviceUpdates() │                               │
│                    └──────────────┬──────────────┘                               │
│                                   │                                              │
│                                   ▼                                              │
│                    ┌─────────────────────────────┐                               │
│                    │ DeviceIdentityResolver      │                               │
│                    │ ResolveDeviceIDs()          │                               │
│                    │ - Check cache               │                               │
│                    │ - Query CNPG                │                               │
│                    │ - Generate UUID             │                               │
│                    └──────────────┬──────────────┘                               │
│                                   │                                              │
│                                   ▼                                              │
│                    ┌─────────────────────────────┐                               │
│                    │ CNPG (unified_devices)      │                               │
│                    └─────────────────────────────┘                               │
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

---

## Root Cause Analysis

### Primary Issue: UUID Generation Inconsistency

The `generateServiceRadarDeviceID()` function in `device_identity.go:851-905` creates **different UUIDs** for the same physical device depending on what identifiers are available:

```go
func generateServiceRadarDeviceID(update *models.DeviceUpdate) string {
    h := sha256.New()
    h.Write([]byte("serviceradar-device-v1:"))

    hasStrong := false

    // Strong identifiers
    if update.MAC != nil && *update.MAC != "" {
        h.Write([]byte("mac:" + normalizeMAC(*update.MAC) + ":"))
        hasStrong = true
    }
    if armisID := update.Metadata["armis_device_id"]; armisID != "" {
        h.Write([]byte("armis:" + armisID + ":"))
        hasStrong = true
    }

    // Weak identifiers ONLY if no strong
    if !hasStrong {
        if update.IP != "" {
            h.Write([]byte("ip:" + update.IP + ":"))
        }
        if update.Partition != "" {
            h.Write([]byte("partition:" + update.Partition + ":"))
        }
    }
    // ... UUID generation from hash
}
```

**The Problem:**

| Discovery Source | Available Identifiers | Hash Input | Resulting UUID |
|-----------------|----------------------|------------|----------------|
| Sweep (first) | IP only | `ip:10.1.2.3:partition:default` | `sr:aaa...` |
| Armis sync (later) | MAC, armis_id, IP | `mac:AA:BB:CC:armis:12345` | `sr:bbb...` |

**Same device → Two different UUIDs → Device count growth**

### Secondary Issues

#### 1. Legacy DeviceID Format in result_processor.go

**Location:** `pkg/core/result_processor.go:71`

```go
result := &models.DeviceUpdate{
    DeviceID:    fmt.Sprintf("%s:%s", partition, host.Host),  // "default:10.1.2.3"
    // ...
}
```

Sweep results arrive with legacy `partition:IP` format. The `DeviceIdentityResolver` filters these as legacy IDs but then falls through to UUID generation with IP-only identifiers.

#### 2. Race Condition: Sweep vs Armis Sync Timing

```
Timeline:
────────────────────────────────────────────────────────────────►
     T0              T1              T2              T3
     │               │               │               │
     ▼               ▼               ▼               ▼
  Sweep #1       Armis Sync      Sweep #2        Problem

  T0: Sweep discovers IP 10.1.2.3
      → No existing device, no strong IDs
      → Generate sr:hash(ip:10.1.2.3)
      → Store as sr:aaa...

  T1: Armis sync for same device
      → Has MAC + armis_id
      → Query CNPG by IP → finds sr:aaa...
      → sr:aaa... has NO strong IDs (sweep device)
      → Generate NEW sr:hash(mac:XX:armis:123)
      → Store as sr:bbb...

  T2: Sweep #2 for IP 10.1.2.3
      → Query CNPG by IP → finds TWO devices!
      → May pick sr:aaa... or sr:bbb... depending on ORDER BY

  T3: 50k devices → 61k devices (11k duplicates)
```

#### 3. Cache Invalidation Gap

- Cache TTL: 5 minutes
- Sync interval: 5 minutes
- Cache may expire between cycles, causing CNPG queries
- Query results depend on timing, may find different "canonical" device

#### 4. IP Fallback Logic Allows Duplicates

In `batchFindExistingDevices()` at `device_identity.go:527`:

```go
if (!hasAnyStrongIdentifier(ids) || allowIPFallbackForStrong) && len(ids.IPs) > 0 {
    for _, ip := range ids.IPs {
        if device := deviceByIP[ip]; device != nil {
            // Allow attaching to devices with strong identifiers when IP fallback is enabled
            if allowIPFallbackForStrong || !deviceHasStrongIdentifiers(device) {
                result[update] = device.DeviceID
            }
        }
    }
}
```

With `allowIPFallbackForStrong=true`, a sweep update can attach to a device that already has strong identifiers. But if that device was created by Armis sync, the sweep update's UUID generation would have been different → inconsistency.

---

## Proposed Solution

### Phase 1: Deterministic UUID Generation (Critical)

**Goal:** Same physical device always gets the same UUID, regardless of discovery order.

#### 1.1 Modify UUID Generation Strategy

Change `generateServiceRadarDeviceID()` to use a **consistent identifier hierarchy**:

```go
func generateServiceRadarDeviceID(update *models.DeviceUpdate) string {
    h := sha256.New()
    h.Write([]byte("serviceradar-device-v2:"))  // Bump version

    // ALWAYS include IP in hash (primary anchor)
    if update.IP != "" {
        h.Write([]byte("ip:" + update.IP + ":"))
    }

    // Include partition for namespace isolation
    if update.Partition != "" {
        h.Write([]byte("partition:" + update.Partition + ":"))
    }

    // Strong identifiers are ADDITIVE, not ALTERNATIVE
    // They're used for MERGING, not UUID generation
    // The UUID is always based on the primary IP

    // ... rest of UUID generation
}
```

**Key Insight:** The UUID should be stable based on the **primary network identity (IP + partition)**. Strong identifiers like MAC and Armis ID are used for **merging** devices, not for generating UUIDs.

#### 1.2 New UUID Generation Logic

```go
func generateServiceRadarDeviceID(update *models.DeviceUpdate) string {
    // Primary UUID anchor: IP + Partition
    // This ensures the same IP always gets the same base UUID
    h := sha256.New()
    h.Write([]byte("serviceradar-device-v2:"))

    // Primary identity anchor
    ip := strings.TrimSpace(update.IP)
    partition := strings.TrimSpace(update.Partition)
    if partition == "" {
        partition = "default"
    }

    // UUID is ALWAYS based on IP + partition
    // This ensures determinism regardless of discovery order
    h.Write([]byte(fmt.Sprintf("partition:%s:ip:%s", partition, ip)))

    // Generate UUID from hash
    // ...
}
```

### Phase 2: Fix Sweep Result Processor

**Goal:** Remove legacy DeviceID generation from result_processor.go

#### 2.1 Empty DeviceID for Sweep Results

**File:** `pkg/core/result_processor.go:67-79`

```go
// BEFORE
result := &models.DeviceUpdate{
    DeviceID:    fmt.Sprintf("%s:%s", partition, host.Host),
    // ...
}

// AFTER
result := &models.DeviceUpdate{
    DeviceID:    "",  // Let DeviceIdentityResolver generate sr: UUID
    Partition:   partition,
    IP:          host.Host,
    // ...
}
```

### Phase 3: Merge-Only Strong Identifiers

**Goal:** Strong identifiers (MAC, Armis ID) should MERGE devices, not create new UUIDs.

#### 3.1 Modify Resolution Logic

In `ResolveDeviceIDs()`, when we find an existing device by IP:

```go
// Current behavior (problematic):
// 1. Find existing device by IP
// 2. If update has strong IDs but existing doesn't → generate NEW UUID
// 3. This creates duplicates

// New behavior:
// 1. Find existing device by IP
// 2. If update has strong IDs → REUSE existing UUID
// 3. Strong IDs get added as metadata to the existing device
// 4. No new UUID generation
```

#### 3.2 Implementation

```go
func (r *DeviceIdentityResolver) ResolveDeviceIDs(ctx context.Context, updates []*models.DeviceUpdate) error {
    // Step 1: Group updates by IP
    updatesByIP := make(map[string][]*models.DeviceUpdate)
    for _, update := range updates {
        if update.IP != "" {
            updatesByIP[update.IP] = append(updatesByIP[update.IP], update)
        }
    }

    // Step 2: Query CNPG for all IPs
    existingDevices, _ := r.db.GetUnifiedDevicesByIPsOrIDs(ctx, maps.Keys(updatesByIP), nil)

    // Step 3: Build IP → canonical device_id map
    canonicalByIP := make(map[string]string)
    for _, device := range existingDevices {
        if isServiceRadarUUID(device.DeviceID) {
            canonicalByIP[device.IP] = device.DeviceID
        }
    }

    // Step 4: Assign device IDs
    for _, update := range updates {
        if existing, ok := canonicalByIP[update.IP]; ok {
            // ALWAYS reuse existing UUID for this IP
            update.DeviceID = existing
        } else {
            // Generate new UUID based on IP + partition
            update.DeviceID = generateServiceRadarDeviceID(update)
            canonicalByIP[update.IP] = update.DeviceID  // Cache for batch
        }
    }
}
```

### Phase 4: Database Cleanup

**Goal:** Merge duplicate devices in CNPG.

#### 4.1 Identify Duplicates

```sql
-- Find IPs with multiple device_ids
SELECT ip, COUNT(DISTINCT device_id) as uuid_count,
       array_agg(DISTINCT device_id) as device_ids
FROM unified_devices
WHERE device_id LIKE 'sr:%'
GROUP BY ip
HAVING COUNT(DISTINCT device_id) > 1
ORDER BY uuid_count DESC;
```

#### 4.2 Merge Strategy

```sql
-- For each IP with duplicates:
-- 1. Pick the device_id with the most metadata (strongest identity)
-- 2. Update all other records to point to the canonical device_id
-- 3. Mark duplicates with _merged_into metadata

WITH duplicates AS (
    SELECT ip, device_id,
           ROW_NUMBER() OVER (
               PARTITION BY ip
               ORDER BY
                   CASE WHEN metadata->>'armis_device_id' IS NOT NULL THEN 1 ELSE 0 END DESC,
                   CASE WHEN mac IS NOT NULL THEN 1 ELSE 0 END DESC,
                   last_seen DESC
           ) as rank
    FROM unified_devices
    WHERE device_id LIKE 'sr:%'
),
canonical AS (
    SELECT ip, device_id as canonical_id
    FROM duplicates
    WHERE rank = 1
)
UPDATE unified_devices u
SET metadata = metadata || jsonb_build_object('_merged_into', c.canonical_id)
FROM duplicates d
JOIN canonical c ON d.ip = c.ip
WHERE u.device_id = d.device_id
  AND d.rank > 1
  AND u.ip = d.ip;
```

### Phase 5: Prevent Future Duplicates

#### 5.1 Add Database Constraint (Long-term)

```sql
-- After migration, add unique constraint
-- This prevents duplicate sr: UUIDs for the same IP
CREATE UNIQUE INDEX idx_unified_devices_ip_sr_uuid
ON unified_devices (ip)
WHERE device_id LIKE 'sr:%'
  AND (metadata->>'_merged_into' IS NULL OR metadata->>'_merged_into' = '');
```

#### 5.2 Add Batch Deduplication

In `ProcessBatchDeviceUpdates()`, before publishing:

```go
func (r *DeviceRegistry) deduplicateBatch(updates []*models.DeviceUpdate) []*models.DeviceUpdate {
    // Track IPs seen in this batch
    seenIPs := make(map[string]*models.DeviceUpdate)

    for _, update := range updates {
        if existing, ok := seenIPs[update.IP]; ok {
            // Same IP twice in batch - merge into first occurrence
            mergeUpdateMetadata(existing, update)
        } else {
            seenIPs[update.IP] = update
        }
    }

    // Return deduplicated list
    result := make([]*models.DeviceUpdate, 0, len(seenIPs))
    for _, update := range seenIPs {
        result = append(result, update)
    }
    return result
}
```

---

## Implementation Checklist

### Critical Path (Must Fix)

- [ ] **P0:** Modify `generateServiceRadarDeviceID()` to be IP-based only
- [ ] **P0:** Fix `result_processor.go` to not set legacy DeviceID
- [ ] **P0:** Modify `ResolveDeviceIDs()` to always reuse existing UUID for same IP
- [ ] **P0:** Add batch deduplication before publishing

### Database Cleanup

- [ ] **P1:** Write and test SQL migration script for merging duplicates
- [ ] **P1:** Run migration in staging
- [ ] **P1:** Run migration in production
- [ ] **P1:** Add unique index after migration

### Validation

- [ ] **P2:** Truncate unified_devices
- [ ] **P2:** Let sync + sweep run for 2-3 cycles
- [ ] **P2:** Verify device count is exactly 50,002 (50k + poller + agent)
- [ ] **P2:** Verify no duplicate IPs with different UUIDs

---

## Risk Assessment

| Risk | Impact | Mitigation |
|------|--------|------------|
| UUID change breaks existing references | High | Version bump in UUID prefix (`sr2:`) |
| Migration script corrupts data | High | Test in staging, backup before prod |
| Race condition during migration | Medium | Temporarily pause sync during migration |
| Cache poisoning with old UUIDs | Medium | Clear identity cache after migration |

---

## Success Metrics

| Metric | Current | Target |
|--------|---------|--------|
| Device count | 61,100 | 50,002 |
| Duplicate IPs | ~11,000 | 0 |
| UUID format | Mixed sr: | All sr: with IP-based hash |
| Strong ID utilization | Creates duplicates | Merges into existing |

---

## Files to Modify

1. `pkg/registry/device_identity.go`
   - `generateServiceRadarDeviceID()` - IP-based UUID generation
   - `ResolveDeviceIDs()` - Always reuse existing UUID for same IP
   - `batchFindExistingDevices()` - Simplify to IP-first resolution

2. `pkg/core/result_processor.go`
   - `processHostResults()` - Remove legacy DeviceID generation

3. `pkg/registry/registry.go`
   - `ProcessBatchDeviceUpdates()` - Add batch deduplication

4. New migration script for database cleanup

---

## Timeline

1. **Phase 1-3:** Code changes (1-2 days implementation, 1 day testing)
2. **Phase 4:** Database migration (1 day staging, 1 day production)
3. **Phase 5:** Validation and monitoring (1-2 days)

**Total estimated effort:** 4-6 days

---

## Appendix: Current Code Locations

| Component | File | Line | Function |
|-----------|------|------|----------|
| UUID Generation | `pkg/registry/device_identity.go` | 851 | `generateServiceRadarDeviceID()` |
| Batch Resolution | `pkg/registry/device_identity.go` | 184 | `ResolveDeviceIDs()` |
| Sweep Processing | `pkg/core/result_processor.go` | 41 | `processHostResults()` |
| Registry Entry | `pkg/registry/registry.go` | 118 | `ProcessBatchDeviceUpdates()` |
| Armis Sync | `pkg/sync/integrations/armis/devices.go` | 1101 | `createDeviceUpdateEventWithAllIPs()` |
| CNPG Resolver | `pkg/registry/identity_resolver_cnpg.go` | - | `hydrateCanonical()` |
