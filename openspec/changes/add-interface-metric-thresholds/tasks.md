# Tasks: Add Per-Metric Interface Thresholds

## 1. Data Model
- [ ] 1.1 Add per-metric threshold storage on interface settings (JSONB map keyed by metric name, includes event + alert config)
- [ ] 1.2 Add unified `EventRule` resource with `source_type` (log/metric) and mapping to event metadata
- [ ] 1.3 Generate Ash migration via `mix ash.codegen` and apply with `mix ash.migrate`
- [ ] 1.4 Migrate existing log promotion rules into `event_rules` and keep legacy tables intact

## 2. Threshold Evaluation
- [ ] 2.1 Update log promotion pipeline to read log `EventRule` records
- [ ] 2.2 Update InterfaceThresholdWorker to evaluate thresholds per selected metric
- [ ] 2.3 Emit OCSF events from metric `EventRule` configs with metric metadata
- [ ] 2.4 Auto-create/update stateful alert rules for per-metric alert settings
- [ ] 2.5 Ensure thresholds are ignored for metrics not enabled/selected

## 3. UI
- [ ] 3.1 Update interface metric cards to show concise status summary (icons/labels for event + alert)
- [ ] 3.2 Open a modal on card click to edit per-metric event/alert settings
- [ ] 3.3 Reuse shared event/alert builder controls inside the modal where possible
- [ ] 3.4 Persist per-metric threshold settings via InterfaceSettings upsert
- [ ] 3.5 Surface metric `EventRule` records in the Events settings tab
- [ ] 3.6 Surface auto-created metric alert rules in the Alerts settings tab
- [ ] 3.7 Ensure card clicks open the modal without accidental enable/disable toggles

## 4. Tests
- [ ] 4.1 Unit tests for per-metric threshold evaluation + event generation
- [ ] 4.2 Unit tests for event rule migration and lookup
- [ ] 4.3 UI tests for per-metric threshold save + enable flows
