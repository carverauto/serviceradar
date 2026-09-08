# Change: Add Per-Metric Interface Thresholds

## Why
Interface threshold alerting is currently a single configuration per interface. Once multiple interface metrics can be selected, operators need per-metric thresholds (e.g., alert on ifInOctets utilization but not ifOutErrors) without losing the multi-metric selection model.

## What Changes
- Store per-metric threshold configuration for interfaces (keyed by metric name).
- Introduce a unified event-creation rule resource with source types (log + metric) and migrate log promotion rules to it.
- Update threshold evaluation to create OCSF events from metric rules and promote those events into alerts.
- Auto-create stateful alert rules for per-metric alert settings and surface them in the alerts admin UI.
- Update the interface metrics UI so each metric card opens a modal to configure event + alert settings without accidental toggling.

## Impact
- Affected specs: `device-inventory`, `observability-signals`, `build-web-ui`.
- Affected code: core-elx inventory settings + threshold worker, observability event/alert rules, metrics ingestion/alert pipeline, and web-ng interface details + rules UI.
