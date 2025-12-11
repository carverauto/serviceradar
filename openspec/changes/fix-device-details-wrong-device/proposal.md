# Change: Fix Device Details Page Showing Wrong Device in Docker Environment

## Why

When viewing device details for `docker-agent` in the Docker environment, the page incorrectly displays details for `docker-poller` instead. This is caused by flawed fallback logic in `GetMergedDevice` that treats device IDs as potential IP addresses.

**Root Cause Analysis:**

The `GetMergedDevice` function (registry.go:2034-2049) has fundamentally broken semantics:

```go
func (r *DeviceRegistry) GetMergedDevice(ctx context.Context, deviceIDOrIP string) (*models.UnifiedDevice, error) {
    // Step 1: Try exact device ID lookup in in-memory registry
    if device, err := r.GetDevice(ctx, deviceIDOrIP); err == nil {
        return device, nil
    }

    // Step 2: PROBLEMATIC - Falls back to IP lookup
    devices, err := r.GetDevicesByIP(ctx, deviceIDOrIP)
    // ...
    return devices[0], nil  // Returns FIRST device at that IP
}
```

**Why the fallback is wrong:**
1. ServiceRadar device IDs like `serviceradar:agent:docker-agent` are strong identifiers - they should NEVER be treated as IPs
2. If the in-memory registry lookup fails (race condition, timing, etc.), the code treats the device ID as an IP address
3. In Docker environments where multiple containers share the same host IP, `GetDevicesByIP` returns multiple devices, and `devices[0]` may be the wrong one

**Why this is a code smell (not just a bandaid fix needed):**
- The function signature `deviceIDOrIP string` conflates two different query types
- The fallback masks underlying issues (why is the device not in the registry?)
- IP should never be treated as equivalent to device ID for resolution

**Why K8s works but Docker doesn't:**
- In K8s: Each pod has its own IP, so IP-based fallback accidentally works
- In Docker: Multiple containers share host IP, so IP-based fallback returns wrong device

Related issue: #2100

## What Changes

1. **Split `GetMergedDevice` into two distinct functions:**
   - `GetDeviceByID(deviceID)` - Exact device ID lookup, no fallback
   - `GetDeviceByIP(ip)` - IP-based lookup for legitimate IP queries

2. **Update API endpoint to use correct lookup:**
   - `/api/devices/{id}` should use `GetDeviceByID` (or fall back to database directly)
   - Remove ambiguous IP fallback for device ID queries

3. **Add explicit IP detection at the API layer:**
   - If the input looks like an IP, use IP lookup
   - If the input looks like a device ID, use exact ID lookup

## Impact

- Affected code: `pkg/registry/registry.go:GetMergedDevice`
- Affected code: `pkg/core/api/server.go:getDevice`
- API behavior change: Device ID lookups that previously "succeeded" via IP fallback will now properly return 404 if the device isn't in the registry

## Deeper Questions to Investigate

1. **Why is the device not in the in-memory registry?**
   - Is there a hydration timing issue in Docker?
   - Is the device being registered after hydration completes?
   - Is there a difference in how Docker vs K8s initialize the registry?

2. **Should the API bypass the in-memory registry entirely for exact ID queries?**
   - The database query `cnpgGetUnifiedDevice` is correct (filters by `device_id = $1`)
   - Maybe exact ID lookups should go straight to DB, not through the registry cache
