# KV Store Identity Map Fix Plan

## Problem Statement

The device identity map is storing 5-6 keys per device in the NATS KV store:
- `device_canonical_map/device-id/<device_id>`
- `device_canonical_map/ip/<ip>`
- `device_canonical_map/partition-ip/<partition:ip>`
- `device_canonical_map/mac/<mac>`
- `device_canonical_map/armis-id/<armis_id>`

With 5k devices from the faker (plus real devices), we're seeing:
- 250k+ keys in the KV store
- 600k+ values stored (due to updates/history)
- ~300 writes/second during sync cycles
- datasvc CPU spiking to 300-500m
- NATS memory growing to 700MB+

Each device update triggers:
1. Get existing record
2. Build 5-6 identity keys
3. For each key: Get → PutIfAbsent or Update
4. Delete stale keys if IP changed

This is fundamentally using the KV store as a database index, which it was not designed for.

## Root Cause Analysis

1. **Wrong storage layer**: The identity map should be in CNPG (PostgreSQL), not NATS KV
2. **Excessive write amplification**: 1 device update = 10-12 KV operations
3. **DHCP churn compounds the problem**: IP changes create stale keys that need cleanup
4. **Cache TTL mismatch**: 5-min cache TTL vs 5-min sync interval provides minimal benefit
5. **No batching**: Each key is written individually with full backoff/retry logic

---

## Implementation Progress

### Phase 1: CNPG Identity Resolver (2025-11-24) ✅

Implemented the "Hybrid: unified_devices + cache" approach - query CNPG `unified_devices` table directly with an in-memory cache layer.

**Changes Made:**

1. **Created `pkg/registry/identity_resolver_cnpg.go`** (NEW)
   - `cnpgIdentityResolver` struct that queries CNPG directly
   - In-memory cache with 5-minute TTL and 50k max entries
   - `hydrateCanonical()` - enriches device updates with canonical metadata
   - `resolveCanonicalIPs()` - resolves IPs to canonical device IDs
   - LRU-style eviction when cache is full (evicts oldest 10%)

2. **Modified `pkg/core/server.go`**
   - Removed `WithIdentityPublisher` from registry initialization
   - Added `WithCNPGIdentityResolver(database)` option

3. **Modified `pkg/registry/registry.go`**
   - Added `cnpgIdentityResolver *cnpgIdentityResolver` field to `DeviceRegistry`
   - Updated `ProcessDeviceUpdates()` to prefer CNPG resolver over legacy KV resolver

---

### Phase 2: ServiceRadar UUID Device Identity System (2025-11-25) ✅

**Problem Discovered:** After removing the KV identity publisher, device count grew uncontrollably (50k → 80k → 115k+). The Armis sync was generating DeviceID based on IP address (`partition:IP`), and DHCP churn created new device IDs.

**User Requirement:** "We can't turn Armis IDs into our primary identifier. We need to create a ServiceRadar UUID and use that. IP address is a weak identifier, but a strong identifier like MAC or Armis ID can override it."

**Solution Implemented:** A new `DeviceIdentityResolver` that:
- Generates ServiceRadar UUIDs (`sr:<uuid>`) for devices
- Uses **strong identifiers** (MAC, Armis ID, NetBox ID) for device merging
- Uses **weak identifiers** (IP) only when no strong identifiers conflict
- Filters out legacy `partition:IP` format IDs from all resolution paths

#### Files Created/Modified

**NEW: `pkg/registry/device_identity.go`**
```go
// Key structures and constants
const (
    identityResolverCacheTTL = 5 * time.Minute
    identityResolverCacheMaxSize = 100000
    StrongIdentifierMAC    = "mac"
    StrongIdentifierArmis  = "armis_device_id"
    StrongIdentifierNetbox = "netbox_device_id"
    WeakIdentifierIP = "ip"
)

type DeviceIdentityResolver struct {
    db     db.Service
    logger logger.Logger
    cache  *deviceIdentityCache
}

// Helper functions
func isServiceRadarUUID(deviceID string) bool {
    return strings.HasPrefix(deviceID, "sr:")
}

func isServiceDeviceID(deviceID string) bool {
    return strings.HasPrefix(deviceID, "serviceradar:")
}

func isLegacyIPBasedID(deviceID string) bool {
    // Detects "partition:IP" format like "default:10.1.2.3"
    // These need migration to sr: format
}

func generateServiceRadarDeviceID(update *models.DeviceUpdate) string {
    // Creates deterministic UUID from device identifiers
    // Format: sr:xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
}
```

**Key Functions:**
- `ResolveDeviceID()` - Single device resolution
- `ResolveDeviceIDs()` - Batch resolution (more efficient)
- `findExistingDevice()` - Queries CNPG for matching devices (skips legacy IDs)
- `batchFindExistingDevices()` - Batch CNPG query (skips legacy IDs)
- `extractIdentifiers()` - Extracts MAC, Armis ID, NetBox ID, IP from update
- `checkCacheForStrongIdentifiers()` - Cache lookup for strong identifiers

**MODIFIED: `pkg/registry/registry.go`**
```go
// Added to DeviceRegistry struct
deviceIdentityResolver   *DeviceIdentityResolver

// Added in ProcessBatchDeviceUpdates() at line 155-159
if r.deviceIdentityResolver != nil {
    if err := r.deviceIdentityResolver.ResolveDeviceIDs(ctx, valid); err != nil {
        r.logger.Warn().Err(err).Msg("Device identity resolution failed")
    }
}

// Modified canonicalIDCandidate() to skip legacy IDs
func canonicalIDCandidate(update *models.DeviceUpdate) string {
    // Now returns "" for legacy partition:IP IDs
    // Forces generation of new ServiceRadar UUIDs
}

// Modified scanIdentifierRows() to filter legacy IDs
// Modified resolveIPsToCanonical() to skip legacy IDs
```

**MODIFIED: `pkg/core/server.go`**
```go
deviceRegistry := registry.NewDeviceRegistry(database, log,
    registry.WithDeviceIdentityResolver(database),  // NEW
    registry.WithCNPGIdentityResolver(database),
)
```

**MODIFIED: `pkg/sync/integrations/armis/devices.go`**
```go
// BEFORE: deviceID based on IP
deviceID := fmt.Sprintf("%s:%s", a.Config.Partition, primaryIP)

// AFTER: Empty deviceID - let registry generate ServiceRadar UUID
event := &models.DeviceUpdate{
    DeviceID:  "", // Let registry generate ServiceRadar UUID
    Metadata: map[string]string{
        "armis_device_id": fmt.Sprintf("%d", d.ID), // Strong identifier
        // ...
    },
}
```

**MODIFIED: `pkg/sync/integrations/armis/armis_test.go`**
```go
// Updated test expectations
assert.Equal(t, "", events[0].DeviceID) // Empty - registry generates UUID
```

---

### Phase 3: Legacy ID Migration (2025-11-25) ✅

**Problem:** Sweep-discovered devices still used `default:IP` format because:
1. `processHostResults()` in `pkg/core/result_processor.go` sets `DeviceID: fmt.Sprintf("%s:%s", partition, host.Host)`
2. The CNPG resolver and identity maps were returning legacy IDs from existing database records
3. `canonicalIDCandidate()` was falling back to `partition:IP` format

**Solution:** Added `isLegacyIPBasedID()` filtering throughout the resolution pipeline:

1. **`findExistingDevice()`** - Skip devices with legacy IDs when looking for matches
2. **`batchFindExistingDevices()`** - Skip legacy IDs from batch query results
3. **`scanIdentifierRows()`** - Skip legacy IDs when building identity maps
4. **`resolveIPsToCanonical()`** - Skip legacy IDs from resolved mappings
5. **`canonicalIDCandidate()`** - Return "" for legacy IDs (forces new UUID generation)

---

## Deployment History

| Date | Image | Tag | Description |
|------|-------|-----|-------------|
| 2025-11-24 | core | `sha-f8ffa80d281f` | KV identity publisher removed |
| 2025-11-24 | sync | `sha-17bdc4b3640b` | Armis stable device ID (armis:partition:id) |
| 2025-11-25 | core | `sha-def6a9bfb415` | ServiceRadar UUID identity system |
| 2025-11-25 | sync | `sha-0ebaddb1871c` | Empty DeviceID for registry generation |
| 2025-11-25 | core | `sha-f5cefe72881a` | Legacy ID detection helpers |
| 2025-11-25 | core | `sha-bae5122ead29` | Debug logging for identity resolution |
| 2025-11-25 | core | `sha-492cb7f79988` | Legacy ID filtering in all resolution paths |

---

## Test Results (2025-11-25)

### After `sha-492cb7f79988` deployment:

**Device count after fresh truncate + sweep:**
```
 id_format        | count
------------------+-------
 sr:uuid          | 49908
 serviceradar:component |     2
```

**Identity resolution logs:**
```json
{
  "uncached_updates": 49908,
  "generated_new_ids": 31206,
  "existing_matches": 0,
  "already_uuid": 18702,
  "message": "Device identity resolution completed"
}
```

**Result:** All sweep devices now use `sr:uuid` format. No `partition:ip` legacy IDs.

### Current Issue: Device Count Still Growing

Despite the fixes, device count is still reaching ~93k (should be ~50k).

**Possible causes being investigated:**

1. **Multiple sweep cycles before cache populates** - First sweep generates UUIDs, but before cache is fully populated, a second sweep may generate different UUIDs for the same IPs

2. **Cache not being populated correctly** - The `cacheIdentifierMappings()` function caches by IP, but sweep devices may not have strong identifiers, leading to cache misses

3. **Armis sync still running** - May be creating additional devices

4. **UUID generation not fully deterministic** - The `generateServiceRadarDeviceID()` uses SHA256 hash, but if the same device comes in with slightly different metadata, it may generate a different UUID

---

### Latest Ops (2025-11-25)

- Built and pushed all images with Bazel at commit `sha-63aa3dddfaac07d65dc32b7e0a9e9f3fb215ea89`, then helm-upgraded the `demo` release with those tags for core/web/datasvc/agent/poller/sync/db-event-writer/mapper/snmp-checker/trapd/tools/otel.
- Truncated CNPG device data via `serviceradar-tools` (rw svc `10.43.112.54`, user `serviceradar`): `TRUNCATE TABLE device_updates CASCADE; TRUNCATE TABLE unified_devices CASCADE;`.
- Core initially hit OOMKilled hydrating ~245k rows, then stabilized; unified_devices is now ~60.9k devices and core shows 2 restarts on this rollout.
- Outstanding: device count remains above target and registry/CNPG mismatch persists; need to continue dedup (strong ID merges, cache seeding) and consider memory bump or staged hydration to avoid OOM on cold start.

### Mitigations Applied (2025-11-25 PM)

- **Identity resolver**: allow IP-based fallback even when existing devices already have strong identifiers. Purpose: merge sweep-only devices into the later Armis/MAC records instead of minting new UUIDs.
- **Faker churn halted**: patched `serviceradar-config` `faker.json` to disable `simulation.ip_shuffle` (with `warmup_cycles=30` for safety) and restarted faker. This stops the 5%/minute DHCP churn that was creating duplicate sweep devices before Armis identifiers arrived.
- **Repeated truncates**: cleared CNPG multiple times during testing via tools pod:  
  `PGPASSWORD=<secret> psql -h cnpg-rw -U serviceradar -d serviceradar -c "TRUNCATE TABLE device_updates CASCADE; TRUNCATE TABLE unified_devices CASCADE;"`
- **Current counts after churn-off + truncation**: ~58.6k rows, ~51.6k distinct IPs; remaining ~7k duplicates to be addressed by resolver merging as new data flows.
- **Rollouts**: rebuilt/pushed core image (digest `sha256:a89d84e2dd699e14ba2c220c4d28b5105b86434917648aeae940a1b63dfb29fd`, tag `sha-63aa3dddfaac07d65dc32b7e0a9e9f3fb215ea89`), helm-upgraded demo, restarted core and faker deployments.

Next tactical levers if growth persists:
- Temporarily scale `serviceradar-poller` to 0 to pause sweeps while Armis sync seeds strong IDs; truncate once; let Armis repopulate; then scale poller back to 1.
- Keep faker churn off until counts stabilize; re-enable only after identity convergence is confirmed.

#### Architectural impact (2025-11-25)

```mermaid
flowchart TD
    SWEEP[Poller sweep results<br/>DeviceID=partition:IP, no strong IDs] --> IDR[DeviceIdentityResolver<br/>now allows IP fallback into devices that already have MAC/armis_id]
    ARMIS[Armis sync events<br/>DeviceID=\"\", strong IDs (MAC/armis_id)] --> IDR
    IDR --> CNPG[(CNPG unified_devices)]
    subgraph Churn
      FAKER[Armis faker<br/>DHCP churn] -. disabled ip_shuffle .-> FAKER
    end
    FAKER -. emits Armis events .-> ARMIS
```

- Identity resolver now intentionally matches sweep-only updates to existing UUIDs even when those UUIDs already have strong identifiers (previously avoided), reducing duplicate UUID creation when Armis data arrives later.
- Faker churn is disabled in config to prevent IP-only duplicates during the warmup period; churn can be re-enabled after counts stabilize.

#### Commands executed (build/deploy/reset)

- Build/push core: `bazel run --config=remote //docker/images:core_image_amd64_push`
- Build/push faker (local docker): `docker build -f cmd/faker/Dockerfile -t ghcr.io/carverauto/serviceradar-faker:sha-31ba3f234ded -t ghcr.io/carverauto/serviceradar-faker:latest .` then `docker push ...`
- Helm upgrade demo: `helm upgrade serviceradar helm/serviceradar -n demo --reuse-values --set-string image.tags.core=sha-63aa3dddfaac07d65dc32b7e0a9e9f3fb215ea89 --set-string image.tags.faker=sha-31ba3f234ded`
- Restarts: `kubectl -n demo rollout restart deploy/serviceradar-core`; `kubectl -n demo rollout restart deploy/serviceradar-faker`
- Faker config patch: `kubectl -n demo patch configmap serviceradar-config --type json -p '[{"op":"replace","path":"/data/faker.json","value":"<json with ip_shuffle.enabled=false,warmup_cycles=30>"}]'`
- CNPG reset: `PGPASSWORD=<secret> psql -h cnpg-rw -U serviceradar -d serviceradar -c "TRUNCATE TABLE device_updates CASCADE; TRUNCATE TABLE unified_devices CASCADE;"`

## Next Steps

### Immediate Investigation

1. **Check if Armis sync is contributing devices:**
   ```bash
   kubectl exec -n demo cnpg-4 -- psql -U postgres -d serviceradar -c \
     "SELECT COUNT(*), metadata->>'armis_device_id' IS NOT NULL as has_armis
      FROM unified_devices GROUP BY 2;"
   ```

2. **Check for duplicate IPs with different UUIDs:**
   ```bash
   kubectl exec -n demo cnpg-4 -- psql -U postgres -d serviceradar -c \
     "SELECT ip, COUNT(DISTINCT device_id) as uuid_count
      FROM unified_devices
      WHERE device_id LIKE 'sr:%'
      GROUP BY ip HAVING COUNT(DISTINCT device_id) > 1
      LIMIT 20;"
   ```

3. **Verify UUID determinism:**
   - Add logging to `generateServiceRadarDeviceID()` to show input values
   - Compare UUIDs generated for same IP across sweep cycles

### Potential Fixes

1. **Make UUID generation IP-based for sweep devices:**
   ```go
   // For sweep devices with no strong identifiers, use IP as the sole UUID seed
   if update.Source == models.DiscoverySourceSweep && !hasAnyStrongIdentifier(ids) {
       h.Write([]byte("sweep-ip:" + update.IP))
       // Don't include partition - it may vary
   }
   ```

2. **Increase cache priority for IP mappings:**
   - Cache sweep device IP → UUID mappings with longer TTL
   - Pre-populate cache from CNPG on startup

3. **Add deduplication in batch processing:**
   - Track IPs seen in current batch
   - Reuse UUID for duplicate IPs in same batch

4. **Query CNPG for existing IP before generating new UUID:**
   ```go
   // In ResolveDeviceIDs, for uncached updates:
   existingByIP, _ := r.db.GetUnifiedDevicesByIP(ctx, update.IP)
   for _, existing := range existingByIP {
       if isServiceRadarUUID(existing.DeviceID) {
           update.DeviceID = existing.DeviceID
           break
       }
   }
   ```

### Code Locations for Reference

| File | Line | Function | Description |
|------|------|----------|-------------|
| `pkg/registry/device_identity.go` | 105 | `ResolveDeviceID()` | Single device resolution |
| `pkg/registry/device_identity.go` | 169 | `ResolveDeviceIDs()` | Batch resolution |
| `pkg/registry/device_identity.go` | 534 | `generateServiceRadarDeviceID()` | UUID generation |
| `pkg/registry/device_identity.go` | 594 | `isLegacyIPBasedID()` | Legacy ID detection |
| `pkg/registry/registry.go` | 155 | ProcessBatchDeviceUpdates | Calls identity resolver |
| `pkg/registry/registry.go` | 464 | `canonicalIDCandidate()` | Canonical ID selection |
| `pkg/core/result_processor.go` | 71 | `processHostResults()` | Sweep device ID generation |

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│                          Device Update Flow                              │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│   Sweep Data                    Armis Sync                               │
│   (from agent)                  (from API)                               │
│        │                             │                                   │
│        ▼                             ▼                                   │
│   ┌─────────────┐             ┌─────────────┐                           │
│   │DeviceUpdate │             │DeviceUpdate │                           │
│   │DeviceID:    │             │DeviceID: "" │ ◄── Empty, let registry   │
│   │"default:IP" │             │Metadata:    │     generate UUID         │
│   │             │             │ armis_id:X  │                           │
│   └─────────────┘             └─────────────┘                           │
│        │                             │                                   │
│        └──────────────┬──────────────┘                                   │
│                       ▼                                                  │
│         ┌─────────────────────────────┐                                 │
│         │ ProcessBatchDeviceUpdates() │                                 │
│         │    (registry.go:125)        │                                 │
│         └─────────────────────────────┘                                 │
│                       │                                                  │
│                       ▼                                                  │
│         ┌─────────────────────────────┐                                 │
│         │  DeviceIdentityResolver     │                                 │
│         │  ResolveDeviceIDs()         │                                 │
│         │  (device_identity.go:169)   │                                 │
│         └─────────────────────────────┘                                 │
│                       │                                                  │
│      ┌────────────────┼────────────────┐                                │
│      ▼                ▼                ▼                                │
│ ┌──────────┐   ┌──────────────┐   ┌───────────────┐                    │
│ │Cache Hit │   │CNPG Query    │   │Generate UUID  │                    │
│ │(sr:uuid) │   │(skip legacy) │   │sr:xxxx-xxxx   │                    │
│ └──────────┘   └──────────────┘   └───────────────┘                    │
│      │                │                  │                              │
│      └────────────────┼──────────────────┘                              │
│                       ▼                                                  │
│         ┌─────────────────────────────┐                                 │
│         │ update.DeviceID = sr:uuid   │                                 │
│         └─────────────────────────────┘                                 │
│                       │                                                  │
│                       ▼                                                  │
│         ┌─────────────────────────────┐                                 │
│         │ hydrateCanonical() (CNPG)   │                                 │
│         │ lookupCanonicalFromMaps()   │                                 │
│         │ (may override if strong ID) │                                 │
│         └─────────────────────────────┘                                 │
│                       │                                                  │
│                       ▼                                                  │
│         ┌─────────────────────────────┐                                 │
│         │ PublishBatchDeviceUpdates() │                                 │
│         │ (to NATS stream → CNPG)     │                                 │
│         └─────────────────────────────┘                                 │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Success Metrics

| Metric | Before | Target | Current |
|--------|--------|--------|---------|
| Device count | 115k+ (growing) | ~50k (stable) | ~93k (improving) |
| Legacy IDs | 100% | 0% | 0% ✅ |
| KV store keys | 250k+ | <100 | TBD |
| datasvc CPU | 300-500m | <50m | TBD |
| NATS memory | 700MB+ | <100MB | TBD |

---

## Related Issues

- Device count growth: Tracked in this document
- GLIBC version mismatch: Affects OTEL, needs base image update
- Faker DHCP churn rate: Currently 5% every 5 minutes, may be too aggressive
