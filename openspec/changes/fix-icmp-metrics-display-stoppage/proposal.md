# Change: Fix ICMP Metrics Display Stoppage

## Why
ICMP metrics for `k8s-agent` in the demo namespace stopped appearing in the UI ~19 hours ago, even though:
1. **Data IS being collected** - Database shows ~120 ICMP metrics/hour continuously for `serviceradar:agent:k8s-agent`
2. **Service status IS being updated** - `service_status` table shows fresh ICMP data every 30s

The UI displays stale data ("Latest ICMP RTT: 8.5ms - 19h ago") because the API endpoint `/api/devices/{id}/metrics?type=icmp` returns HTTP 401 "unauthorized" even when the correct API key is provided.

**Root Cause**: The RBAC middleware at `pkg/core/auth/middleware.go:70` checks `GetUserFromContext(r.Context())` and rejects requests when no user is found. The `handleAPIKeyAuth` function in `pkg/core/api/server.go:538-547` authenticates API keys but does not inject a user into the request context, causing subsequent RBAC checks to fail.

## What Changes
- **Fix API key auth to set user context**: Modify `handleAPIKeyAuth` in `pkg/core/api/server.go` to inject a service/system user into the request context after successful API key validation, allowing RBAC middleware to pass.
- **Add regression test**: Verify API key authenticated requests can access device metrics endpoints.
- **Secondary issue - KV watcher telemetry**: Only core service appears in watcher telemetry because watcher state is process-local. This is a separate concern to track but may contribute to configuration propagation issues.

## Impact
- Affected specs: None (bug fix restoring intended behavior)
- Affected code:
  - `pkg/core/api/server.go` (handleAPIKeyAuth)
  - `pkg/core/auth/middleware.go` (context propagation)
- No breaking changes
