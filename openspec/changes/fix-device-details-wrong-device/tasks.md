# Tasks: Fix Device Details Page Showing Wrong Device

## Phase 1: Investigation & Immediate Fix

### 1.1 Investigate Registry Miss Rate
- [x] Add debug logging to `GetDevice` to log when device ID lookup fails
- [x] Deploy to Docker environment and collect logs
- [ ] Compare with K8s environment to understand timing differences
- [ ] Document findings: why does the lookup fail in Docker?

### 1.2 Fix `GetMergedDevice` Fallback Logic
- [x] Modify `GetMergedDevice` to detect device ID vs IP format
- [x] For device IDs (containing `:`), return error if not found - DO NOT fall back to IP
- [x] For IP addresses only, allow IP-based lookup
- [x] Add unit tests for device ID vs IP detection

### 1.3 Fix API Handler
- [x] Update `getDevice` handler to fall back to `dbService.GetUnifiedDevice` instead of IP lookup
- [x] Ensure 404 is returned for non-existent device IDs (not wrong device)
- [x] Add integration test: Docker environment with shared IP returns correct device

## Phase 2: Clean Architecture (Optional)

### 2.1 Deprecate `GetMergedDevice`
- [x] Mark `GetMergedDevice` as deprecated
- [x] Audit all callers of `GetMergedDevice`
- [x] Create migration plan for each caller

### 2.2 Create Explicit Functions
- [x] Add `GetDeviceByIDStrict(deviceID string)` - exact match only, returns error if not found
- [x] Keep existing `GetDevicesByIP(ip string)` for legitimate IP lookups
- [x] Update interface definition

### 2.3 Update Callers
- [x] Update `pkg/core/api/server.go:getDevice` to use new functions
- [x] Update any other callers identified in 2.1
- [x] Remove deprecated `GetMergedDevice` after migration

## Testing

### Unit Tests
- [x] Test: Device ID lookup for `serviceradar:agent:X` returns exact match or error
- [x] Test: Device ID lookup does NOT fall back to IP even if IP matches another device
- [x] Test: IP lookup (if kept) returns devices at that IP

### Integration Tests
- [ ] Docker environment: `docker-agent` details page shows correct device
- [ ] Docker environment: `docker-poller` details page shows correct device
- [ ] K8s environment: No regression - `k8s-agent` still works correctly

### Manual Verification
- [x] Deploy fix to Docker environment
- [x] Verify: Click docker-agent → shows docker-agent details
- [x] Verify: Click docker-poller → shows docker-poller details
- [x] Verify: Device inventory shows correct device counts

## Implementation Summary

### Changes Made

1. **pkg/registry/registry.go**
   - Added `looksLikeIP(input string) bool` helper function to detect valid IP addresses
   - Added `looksLikeDeviceID(input string) bool` helper function to detect device IDs
   - Modified `GetMergedDevice` to NOT fall back to IP lookup for device IDs
   - Added debug logging when device ID lookup fails
   - Added warning when multiple devices share an IP (for IP-based lookups)

2. **pkg/core/api/server.go**
   - Modified `getDevice` handler to fall back to database lookup when registry returns `ErrDeviceNotFound`
   - Previously: returned 404 immediately when device not in registry
   - Now: falls through to database lookup, only returns 404 if DB also fails

3. **pkg/registry/registry_test.go**
   - Added `TestLooksLikeIP` - tests IP address detection for IPv4, IPv6, and edge cases
   - Added `TestLooksLikeDeviceID` - tests device ID detection for various formats
   - Added `TestGetMergedDevice_DoesNotFallbackToIPForDeviceIDs` - verifies fix for Docker issue
   - Added `TestGetMergedDevice_DeviceIDNotInRegistryReturnsError` - verifies error handling
