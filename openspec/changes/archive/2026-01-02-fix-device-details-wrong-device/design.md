# Design: Fix Device Details Page Showing Wrong Device

## Context

The device details page in Docker environments shows the wrong device data. The root cause is `GetMergedDevice` conflating device ID and IP lookups, combined with a flawed fallback that returns the wrong device when multiple containers share an IP.

**Stakeholders**: Backend team, Frontend team, Operations (Docker deployment users)

## Goals / Non-Goals

### Goals
- Device ID lookups always return the exact device requested or 404
- Clear separation between "lookup by device ID" and "lookup by IP" semantics
- Fix the underlying architecture issue, not just add a bandaid

### Non-Goals
- Changing the SRQL query path (it already works correctly)
- Redesigning the entire device registry
- Adding IP uniqueness constraints (IPs are mutable attributes, not identities)

## Decisions

### Decision 1: Deprecate `GetMergedDevice` in favor of explicit functions

**What**: Replace `GetMergedDevice(deviceIDOrIP string)` with:
- `GetDeviceByID(deviceID string)` - Exact device ID lookup only
- `GetDeviceByIP(ip string)` - IP-based lookup (already exists as `GetDevicesByIP`)

**Why**: The `deviceIDOrIP` parameter is fundamentally wrong - it conflates two different query types. A device ID like `serviceradar:agent:docker-agent` should never be interpreted as an IP address.

**Alternatives considered**:
1. **Add IP detection to `GetMergedDevice`** - Still a code smell, just hides the problem
2. **Keep fallback but filter results** - Doesn't fix the architectural issue
3. **Remove `GetMergedDevice` entirely** - **Chosen** - Forces callers to be explicit

### Decision 2: API should fall back to database, not IP lookup

**What**: When the in-memory registry lookup fails for a device ID, fall back to the database query directly, not to IP-based lookup.

```go
// Current (broken):
func getDevice(w, r) {
    device, err := registry.GetMergedDevice(ctx, deviceID)  // Falls back to IP
    // ...
}

// Proposed:
func getDevice(w, r) {
    device, err := registry.GetDevice(ctx, deviceID)  // In-memory only
    if err != nil {
        device, err = dbService.GetUnifiedDevice(ctx, deviceID)  // Exact DB lookup
    }
    // ...
}
```

**Why**:
- The database query `cnpgGetUnifiedDevice` correctly filters by `device_id = $1`
- This gives the correct result even if the registry isn't hydrated yet
- No risk of returning wrong device due to IP collision

### Decision 3: Investigate why registry misses in Docker

**What**: Before implementing the fix, investigate WHY the in-memory registry lookup fails in Docker but not K8s.

**Why**: The fallback is masking a deeper issue. Possible causes:
- Hydration timing (registry hydrates before devices register)
- Different startup order in Docker vs K8s
- Docker-specific configuration issue

**Approach**:
- Add logging to `GetDevice` to track misses
- Compare registry hydration timing between Docker and K8s
- Check if devices exist in DB but not in registry

## Risks / Trade-offs

### Risk: Breaking callers that rely on IP fallback
- **Assessment**: Check all `GetMergedDevice` callers to ensure they don't depend on IP fallback behavior
- **Mitigation**: The API handler already has database fallback, so this should be safe

### Risk: Performance regression if we always hit DB
- **Assessment**: Unlikely - the in-memory registry should work for most cases
- **Mitigation**: The registry is hydrated on startup; DB fallback is rare

### Trade-off: Breaking API compatibility
- If any external clients rely on `/api/devices/{ip}` returning a device by IP, this will break
- **Decision**: Check API docs - if IP lookup is documented, keep it but make it explicit (separate endpoint or query param)

## Implementation Approach

### Phase 1: Investigate and Fix Immediate Issue
1. Add logging to understand registry miss rate in Docker
2. Fix `GetMergedDevice` to not fall back to IP for device IDs containing `:`
3. Update API handler to fall back to DB instead of IP lookup

### Phase 2: Clean Architecture (if needed)
1. Deprecate `GetMergedDevice`
2. Split into explicit `GetDeviceByID` and `GetDevicesByIP`
3. Update all callers

## Open Questions

1. **Do we need IP lookup at the API level at all?**
   - Is `/api/devices/{ip}` a valid use case?
   - Should it be a separate endpoint like `/api/devices/by-ip/{ip}`?

2. **Should device ID lookups bypass the registry cache entirely?**
   - Pro: Simpler, always correct
   - Con: Loses caching benefit, higher DB load
