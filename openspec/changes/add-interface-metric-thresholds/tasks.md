# Tasks: Add Per-Metric Interface Thresholds

## 1. Data Model
- [ ] 1.1 Add per-metric threshold storage on interface settings (JSONB map keyed by metric name)
- [ ] 1.2 Generate Ash migration via `mix ash.codegen` and apply with `mix ash.migrate`

## 2. Threshold Evaluation
- [ ] 2.1 Update InterfaceThresholdWorker to evaluate thresholds per selected metric
- [ ] 2.2 Emit events/alerts with metric name/value/threshold metadata
- [ ] 2.3 Ensure thresholds are ignored for metrics not enabled/selected

## 3. UI
- [ ] 3.1 Update interface metric cards to include explicit enable/disable control
- [ ] 3.2 Add per-metric threshold controls (comparison, value, duration, severity)
- [ ] 3.3 Persist per-metric threshold settings via InterfaceSettings upsert
- [ ] 3.4 Prevent card click/controls from accidentally toggling selection

## 4. Tests
- [ ] 4.1 Unit tests for per-metric threshold evaluation
- [ ] 4.2 UI tests for per-metric threshold save + enable flows
