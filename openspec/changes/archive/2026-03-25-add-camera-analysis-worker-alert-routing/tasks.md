## 1. Runtime Routing
- [x] 1.1 Add a normalized worker alert routing payload derived from authoritative worker alert transitions.
- [x] 1.2 Route worker alert activation and clear transitions into the existing observability event/alert pipeline.
- [x] 1.3 Keep routing transition-based so repeated unchanged worker states do not create duplicate alerts.

## 2. Operator Visibility
- [x] 2.1 Expose enough metadata to correlate routed worker alerts with the worker management surface.
- [x] 2.2 Show routed alert linkage or summary in the existing worker ops surface when helpful.

## 3. Verification
- [x] 3.1 Add focused tests for worker alert routing, clear behavior, and duplicate suppression.
- [x] 3.2 Validate the change with `openspec validate add-camera-analysis-worker-alert-routing --strict`.
