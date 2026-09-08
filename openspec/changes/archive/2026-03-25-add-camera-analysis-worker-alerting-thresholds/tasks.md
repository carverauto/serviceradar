## 1. Runtime Thresholds
- [x] 1.1 Add derived worker alert state fields or evaluation outputs for bounded degradation thresholds.
- [x] 1.2 Evaluate alert thresholds when worker health, probe history, flapping, or failover state changes.
- [x] 1.3 Emit explicit alert transition signals when worker alert states activate or clear.

## 2. Management Surface
- [x] 2.1 Expose summarized worker alert state through the authenticated worker management API.
- [x] 2.2 Show worker alert state in the operator-facing worker surface.

## 3. Verification
- [x] 3.1 Add focused tests for threshold evaluation and alert transition signals.
- [x] 3.2 Validate the change with `openspec validate add-camera-analysis-worker-alerting-thresholds --strict`.
