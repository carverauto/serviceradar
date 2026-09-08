## 1. Notification Audit Context
- [x] 1.1 Add a bounded lookup for current routed worker alert notification audit state from the standard alert lifecycle.
- [x] 1.2 Keep notification audit visibility derived from the routed alert / alert model rather than a parallel worker store.

## 2. Management Surface
- [x] 2.1 Expose notification audit fields through the worker management API.
- [x] 2.2 Show notification audit state in the `web-ng` camera analysis worker ops surface.

## 3. Verification
- [x] 3.1 Add focused tests for routed worker alert notification audit lookup and API/UI exposure.
- [x] 3.2 Validate the change with `openspec validate add-camera-analysis-worker-notification-audit-surface --strict`.
