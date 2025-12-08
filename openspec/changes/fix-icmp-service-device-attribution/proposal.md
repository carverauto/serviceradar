# Change: Fix ICMP Collector Attribution for Service Devices

## Why
ICMP sparklines disappeared for `k8s-agent` in the demo Kubernetes inventory (issue #2069). Investigation revealed two root causes:

1. **Search planner routing bug**: The device search planner's `supportsRegistry()` function returned `true` for `device_id:` queries, but `executeRegistry()` never implemented device_id filtering. This caused device details pages to return the wrong device (e.g., showing `k8s-poller` when viewing `k8s-agent`).

2. **SRQL auth misconfiguration**: The Core init script set `.api_key` at root level but not `.srql.api_key`, causing Core's SRQL queries to fail with 401 authentication errors.

The original hypothesis about agent ICMP attribution was incorrect - the ICMP metrics were already correctly attributed to `serviceradar:agent:k8s-agent` in the database. The issue was that queries couldn't retrieve them.

## What Changes
- **Search planner fix**: Reject `device_id:` queries from the registry engine, forcing them through SRQL which correctly implements device_id filtering (`pkg/search/planner.go`).
- **Auth config fix**: Add `.srql.api_key = $api_key` to the Core init script so SRQL queries authenticate correctly (`helm/serviceradar/files/serviceradar-config.yaml`).
- Verify ICMP data appears in both device inventory (sparklines) and device details (timeline) views.

## Impact
- Affected specs: `service-device-capabilities`
- Affected code: `pkg/search/planner.go` (supportsRegistry), `helm/serviceradar/files/serviceradar-config.yaml` (init script)
