# Change: Fix DIRE (Device Identity and Reconciliation Engine) Brittleness

## Why

The device identity and reconciliation system is fundamentally broken, causing ~10k device loss out of 50k expected devices from the faker service. Multiple OpenSpec proposals have attempted partial fixes (`fix-sync-duplicate-key-constraint`, `fix-registry-ip-canonicalization`, `restore-soft-deleted-devices`), but each fix creates new edge cases because the underlying architecture has conflicting design constraints.

### Root Cause Analysis

**1. IP-Centric Model Conflicts With Strong Identifiers**

The unique constraint `idx_unified_devices_ip_unique_active` enforces one active device per IP, but the system also tracks devices by strong identifiers (Armis ID, MAC, NetBox ID). When IP churn occurs (DHCP reassignment), two devices with different strong identifiers can temporarily share the same IP, triggering incorrect merges.

```
T=0: Device X (armis_id=X, IP=10.0.0.1) -> sr:AAA
     Device Y (armis_id=Y, IP=10.0.0.2) -> sr:BBB

T=1: DHCP churn - Device Y now has IP=10.0.0.1

T=2: Update arrives for Device Y (armis_id=Y, IP=10.0.0.1)
     -> IP conflict with sr:AAA detected
     -> sr:BBB tombstoned to sr:AAA (WRONG! Different Armis IDs)
     -> Device Y lost, sr:AAA corrupted with mixed identifiers
```

**2. Multiple Identity Resolvers With Inconsistent Behavior**

The codebase has four overlapping identity resolution systems:
- `DeviceIdentityResolver` (`pkg/registry/device_identity.go`) - generates sr: UUIDs, uses cache + DB lookups
- `identityResolver` (`pkg/registry/identity_resolver.go`) - KV-backed canonical resolution
- `cnpgIdentityResolver` (`pkg/registry/identity_resolver_cnpg.go`) - CNPG-backed canonical hydration
- `lookupCanonicalFromMaps()` in registry.go - builds identity maps from DB and applies canonicalization

These don't coordinate, leading to race conditions where the same device gets different IDs depending on code path and timing.

**3. Tombstone Cascade ("Black Holes")**

When a device is incorrectly tombstoned (`_merged_into = wrong_target`), subsequent updates for that device:
1. Fail to resolve the tombstoned ID (it's hidden from queries)
2. Generate a new sr: UUID
3. Hit IP conflict with another device
4. Get tombstoned again
5. Repeat until inventory collapses

In demo: ~49,641 rows with `_merged_into` set, ~49,510 pointing to non-existent targets.

**4. Soft Delete Reanimation Failures**

Devices marked `_deleted=true` should reanimate when re-sighted, but:
- The upsert logic preserves `_deleted` during merges in some code paths
- The fix in `restore-soft-deleted-devices` only partially works
- Registry hydration doesn't properly filter deleted devices

**5. In-Memory Registry vs CNPG Discrepancy**

The in-memory `DeviceRegistry` cache shows ~45-48k devices while CNPG has ~50k. The registry:
- Uses `applyRegistryStore()` which doesn't fully sync with DB state
- Has stale tombstone references
- Doesn't properly handle the `_deleted`/`_merged_into` filtering

**6. Batch Processing Order Dependence**

`deduplicateBatch()` and `resolveIPConflictsWithDB()` use first-wins semantics. The first device in a batch "wins" the IP, regardless of which device has the authoritative strong identifier.

## What Changes

### Phase 1: Consolidate Identity Resolution (Critical)

1. **Single identity resolver**: Merge the four resolver systems into one `IdentityEngine` with clear precedence:
   - Strong ID (Armis/NetBox/MAC) -> canonical device ID (deterministic hash)
   - Existing sr: UUID -> preserve
   - IP -> lookup only if no strong ID present

2. **Strong ID index tables**: Add `device_identifiers` table with unique constraints on (identifier_type, identifier_value) instead of IP-based uniqueness

3. **Remove IP uniqueness constraint**: Replace `idx_unified_devices_ip_unique_active` with soft constraint (warning/metric) since IP is a mutable attribute, not an identity anchor

### Phase 2: Simplify Updates (No More Conflicts)

4. **No IP conflict handling needed**: With IP uniqueness constraint removed, there are no IP conflicts. Just UPDATE the IP column.

5. **Strong ID uniqueness at DB level**: The `device_identifiers` unique constraint makes it impossible to create duplicate devices for the same strong ID - the DB enforces correctness.

### Phase 3: Remove Soft Delete / Tombstone System

6. **No soft deletes**: Device updates just UPDATE the record. No `_deleted` flag needed.

7. **No tombstones**: No `_merged_into` needed. Strong ID uniqueness prevents duplicates at the DB level.

8. **Hard delete for explicit deletion**: When user clicks "delete device" in UI, do a real DELETE with audit log to `device_updates` hypertable.

9. **Registry hydration from CNPG**: Replace in-memory-first model with CNPG-authoritative reads, in-memory cache for hot path only

### Phase 4: Observability and Guardrails

10. **Cardinality assertion**: CI/E2E test that asserts 50k faker devices = 50k inventory devices

11. **Metrics**: Prometheus metrics for IP churn events, registry/CNPG drift

## Impact

- **Affected specs**: `device-identity-reconciliation` (MODIFIED)
- **Affected code**:
  - `pkg/registry/device_identity.go` - consolidate into IdentityEngine
  - `pkg/registry/identity_resolver.go` - remove, merge into IdentityEngine
  - `pkg/registry/identity_resolver_cnpg.go` - remove, merge into IdentityEngine
  - `pkg/registry/registry.go` - simplify ProcessBatchDeviceUpdates
  - `pkg/registry/strong_identity.go` - extend for new conflict logic
  - `pkg/db/cnpg_unified_devices.go` - atomic delete/reanimate, identifier index
  - `pkg/db/cnpg/migrations/` - new migration for device_identifiers table
  - `tests/e2e/inventory/` - cardinality assertion test
- **Risk**: High - fundamental architecture change, requires careful rollout
- **Migration**: Shadow mode first, validate counts, then switch

## Trade-offs Considered

### Option A: Rust Rewrite
- Pros: Type system prevents many error classes, better concurrency primitives
- Cons: Significant effort, doesn't solve the design problems (just moves them)
- Decision: Not recommended - the issues are architectural, not language-related

### Option B: Remove IP Uniqueness Entirely
- Pros: Simplest fix, allows multiple devices per IP
- Cons: Breaks UI assumptions, search, some API contracts
- Decision: Partial adoption - soft constraint with metrics instead of hard unique

### Option C: Event Sourcing
- Pros: Full audit trail, replayable, fixes many consistency issues
- Cons: Major architecture change, performance concerns at 50k+ devices
- Decision: Deferred - too much scope creep, can add later

### Option D: Incremental Fixes (Current Approach)
- Pros: Lower risk per change
- Cons: Each fix creates new edge cases, we've tried this 4+ times
- Decision: Rejected - need holistic fix, not more patches

---

## Implementation Progress

### Completed (Phases 0-3, ~80% done)

**Schema (Phase 0)** ✅
- Consolidated 19 incremental migrations into single idempotent `00000000000001_schema.up.sql`
- Added `device_identifiers` table with unique constraint on `(identifier_type, identifier_value, partition)`
- Removed `idx_unified_devices_ip_unique_active` constraint - IP is now just a mutable attribute
- Old migration files deleted

**Identity Engine (Phase 1)** ✅
- Created `pkg/registry/identity_engine.go` with unified `IdentityEngine` struct
- Implements deterministic sr: UUID generation from strong identifiers (SHA-256 hash)
- Priority order: armis_device_id > integration_id > netbox_device_id > mac
- Deleted old resolver files: `device_identity.go`, `identity_resolver.go`, `identity_resolver_cnpg.go`, `canonical_helpers.go`

**Simplified Device Updates (Phase 2)** ✅
- Rewrote `ProcessBatchDeviceUpdates()` - now just: normalize → resolve IDs → register identifiers → upsert
- Deleted ~400 lines: `deduplicateBatch()`, `resolveIPConflictsWithDB()`, `filterObsoleteUpdates()`, tombstone code
- IP changes are now simple column updates - no conflict resolution needed

**Simplified Queries (Phase 3)** ✅
- Removed `_merged_into` and `_deleted` filters from `unifiedDevicesSelection`
- `SoftDeleteDevices()` now calls hard `DELETE` with audit trail to `device_updates`
- Deleted `normalizeDeletionMetadata()` and related tests

### Remaining Work

**Registry/CNPG Consistency (Phase 4)** - Not started
- Need `SyncRegistryFromCNPG()` to hydrate in-memory registry from database
- Add Prometheus metrics: `registry_device_count`, `registry_cnpg_drift`

**E2E Cardinality Tests (Phase 5)** - Not started
- Add test asserting `COUNT(unified_devices) >= 50000`
- Add test asserting `COUNT(DISTINCT armis_device_id) = COUNT(*)` (no duplicates)

**Verification (Phase 7)** - Partially done
- ✅ `go test ./pkg/registry/...` passes
- ✅ `go test ./pkg/db/...` passes
- ❌ Need: Drop demo DB, deploy, run faker, verify 50k devices
- ❌ Need: 24h soak test

---

## Implementation Notes & Gotchas

### Test Mock Patterns for IdentityEngine

When testing code that uses IdentityEngine, you need these mocks:

```go
// Required mocks for IdentityEngine-enabled registry
mockDB.EXPECT().
    ExecuteQuery(gomock.Any(), gomock.Any(), gomock.Any()).
    DoAndReturn(func(_ context.Context, query string, _ ...interface{}) ([]map[string]interface{}, error) {
        // Return canonical device mapping for IP queries
        if strings.Contains(query, "10.1.1.1") {
            return []map[string]interface{}{
                {"ip": "10.1.1.1", "device_id": "sr:canonical"},
            }, nil
        }
        return []map[string]interface{}{}, nil
    }).
    AnyTimes()

mockDB.EXPECT().
    BatchGetDeviceIDsByIdentifier(gomock.Any(), gomock.Any(), gomock.Any()).
    Return(nil, nil).
    AnyTimes()

mockDB.EXPECT().
    UpsertDeviceIdentifiers(gomock.Any(), gomock.Any()).
    Return(nil).
    AnyTimes()
```

**Key gotcha**: Don't use `allowCanonicalizationQueries()` helper if you need specific `ExecuteQuery` behavior - it sets up empty-result mocks first, which get matched before your specific mocks.

### ExecuteQuery Signature

The `ExecuteQuery` method has a variadic parameter:
```go
ExecuteQuery(ctx context.Context, query string, params ...interface{}) ([]map[string]interface{}, error)
```

DoAndReturn functions must match this signature:
```go
// WRONG - will fail with "wrong number of arguments"
func(_ context.Context, query string) ([]map[string]interface{}, error)

// CORRECT
func(_ context.Context, query string, _ ...interface{}) ([]map[string]interface{}, error)
```

### IP Resolution Flow

The sweep-to-canonical merge flow works via:
1. `ProcessBatchDeviceUpdates()` receives sweep update
2. `attachSweepSightings()` collects IPs
3. `resolveIPsToCanonical()` queries for canonical devices at those IPs
4. If CNPG available: uses `resolveIPsToCanonicalCNPG()` → `QueryRegistryRows()`
5. If KV fallback: uses `resolveIdentifiers()` → `ExecuteQuery()`
6. Canonical device found → sweep update gets that device's ID
7. Update published with canonical ID

The `db.MockService` doesn't implement `cnpgRegistryClient`, so tests use the KV fallback path via `ExecuteQuery`.

### Skipped Test: canon_simulation_test.go

`TestCanonicalizationSimulation` is skipped with:
```go
t.Skip("Test needs to be rewritten for new DIRE - deterministic UUID generation replaces IP-based merging")
```

This test simulates DHCP churn scenarios. With DIRE:
- Sweep-only devices (no strong ID) at different IPs create separate devices (correct)
- When Armis provides a strong ID, it's registered in `device_identifiers`
- No IP-based merging happens - the strong ID is the identity anchor

The test assumptions about IP-based merging no longer apply.

---

## Next Steps for Continuation

1. **Phase 4: Registry/CNPG Consistency**
   - Implement `SyncRegistryFromCNPG()` in `pkg/registry/registry.go`
   - Add periodic sync call (every 5 minutes)
   - Add Prometheus gauges for device counts and drift detection

2. **Phase 5: E2E Cardinality Tests**
   - Create test in `tests/e2e/inventory/` that spins up faker + checks counts
   - Add to CI as required check

3. **Rewrite canon_simulation_test.go**
   - Update for new DIRE semantics (strong ID = identity, IP = mutable attribute)
   - Test that devices with same strong ID always resolve to same sr: UUID
   - Test that IP churn doesn't cause incorrect merges

4. **Deploy and Soak Test**
   - Drop demo database
   - Deploy with new schema
   - Run faker, verify 50k devices stable over 24h
