## 1. Notification Policy Integration
- [x] 1.1 Route camera analysis worker routed alerts into the standard notification-policy evaluation path.
- [x] 1.2 Preserve duplicate suppression for unchanged worker alert state while relying on standard re-notify behavior for long-lived incidents.
- [x] 1.3 Keep notification integration sourced from the existing routed alert lifecycle rather than a parallel worker notification path.

## 2. Operator Surface
- [x] 2.1 Expose normalized notification-policy eligibility or routing context for worker alerts through the worker management API.
- [x] 2.2 Show notification-policy context in the `web-ng` camera analysis worker ops surface.

## 3. Verification
- [x] 3.1 Add focused tests for routed worker alert notification-policy integration and operator-surface exposure.
- [x] 3.2 Validate the change with `openspec validate add-camera-analysis-worker-notification-policy-integration --strict`.
