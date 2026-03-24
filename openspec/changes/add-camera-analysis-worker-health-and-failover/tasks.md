## 1. Worker Health
- [x] 1.1 Add platform-owned health state for registered camera analysis workers.
- [x] 1.2 Support marking workers healthy or unhealthy with bounded reason metadata.
- [x] 1.3 Make worker resolution skip unhealthy workers by default and fail explicitly for unhealthy explicit-id targets.

## 2. Failover
- [x] 2.1 Add bounded failover for capability-targeted analysis branches when dispatch detects worker unavailability.
- [x] 2.2 Preserve worker identity, failover count, and terminal failure reason in relay analysis telemetry.
- [x] 2.3 Keep explicit worker-id targeting non-failover by design.

## 3. Verification
- [x] 3.1 Add focused tests for health-aware selection, bounded failover, and terminal failure behavior.
- [x] 3.2 Validate the change with `openspec validate add-camera-analysis-worker-health-and-failover --strict`.
