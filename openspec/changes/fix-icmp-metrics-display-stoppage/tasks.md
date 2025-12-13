## 1. Investigation (Completed)

- [x] 1.1 Verify ICMP data collection - Confirmed ~120 metrics/hour in `timeseries_metrics` table for `serviceradar:agent:k8s-agent`
- [x] 1.2 Verify service status updates - Confirmed fresh entries in `service_status` every 30s
- [x] 1.3 Test API endpoint directly - Confirmed `/api/devices/{id}/metrics?type=icmp` returns HTTP 401 "unauthorized"
- [x] 1.4 Identify root cause - `handleAPIKeyAuth` authenticates but doesn't set user context for RBAC/RouteProtection middleware

## 2. Implementation (Completed)

- [x] 2.1 Fix `handleAPIKeyAuth` in `pkg/core/api/server.go` to inject a system/service user into request context after successful API key validation
- [x] 2.2 Ensure the injected user has appropriate roles (`admin`, `operator`, `viewer`) to pass RBAC checks for all device metrics endpoints
- [x] 2.3 Build and run tests to verify no regressions

## 3. Verification

- [ ] 3.1 Deploy fix to demo namespace
- [ ] 3.2 Verify UI displays fresh "Latest ICMP RTT" (not 19h stale)
- [ ] 3.3 Verify Device Metrics Timeline shows recent data
- [ ] 3.4 Monitor for 1 hour to ensure metrics continue displaying

## 4. Secondary Issue (KV Watcher Telemetry)

- [ ] 4.1 Investigate why only core service appears in watcher telemetry
- [ ] 4.2 Determine if watcher state needs to be aggregated across services via NATS/KV
- [ ] 4.3 Create separate proposal if architectural changes needed
