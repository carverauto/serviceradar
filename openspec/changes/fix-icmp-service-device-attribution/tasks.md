## 1. Implementation

### Completed
- [x] 1.1 Fix search planner to reject `device_id:` queries from registry engine, forcing SRQL path which correctly filters by device_id (`pkg/search/planner.go:322-325`).
- [x] 1.2 Fix Core init script to set `.srql.api_key` so SRQL queries authenticate correctly (`helm/serviceradar/files/serviceradar-config.yaml`).
- [x] 1.3 Deploy fix via Helm upgrade with new image tag `sha-691d182cd47b1ec746b88c5544b64b3699d91e8f`.
- [x] 1.4 Verify SRQL backend returns correct ICMP metrics for `serviceradar:agent:k8s-agent` with fresh timestamps.
- [x] 1.5 Verify device inventory sparklines render ICMP for `k8s-agent` (confirmed `metrics_summary.icmp=true`).
- [x] 1.6 Fix device details ICMP timeline to display ICMP values instead of flattening to zero when units vary (handle ns/ms scaling in `web/src/components/Devices/DeviceDetail.tsx`).
- [x] 1.7 Add regression test to ensure `device_id:` queries bypass the registry engine (`pkg/search/planner_test.go`).

### Pending
- [ ] None (all implementation tasks for this change are currently completed)

## 2. Investigation Notes
- Original hypothesis (agent ICMP attribution) was incorrect - ICMP metrics were correctly written to `serviceradar:agent:k8s-agent`.
- Actual bugs: (1) registry engine returned wrong device for `device_id:` queries; (2) Core couldn't auth to SRQL.
- Backend is now working: SRQL returns ICMP metrics with timestamps within seconds of query time.
- Frontend issue: Device details page (`DeviceDetail.tsx`) queries `in:timeseries_metrics` with time window but displays stale data. May be CDN caching, web API routing, or frontend parsing issue.
