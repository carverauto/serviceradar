# Change: Add Per-Metric Interface Thresholds

## Why
Interface threshold alerting is currently a single configuration per interface. Once multiple interface metrics can be selected, operators need per-metric thresholds (e.g., alert on ifInOctets utilization but not ifOutErrors) without losing the multi-metric selection model.

## What Changes
- Store per-metric threshold configuration for interfaces (keyed by metric name).
- Update threshold evaluation to check each enabled metric threshold and emit events/alerts accordingly.
- Update the interface metrics UI so each metric card supports enable/disable and per-metric threshold controls without accidental toggling.

## Impact
- Affected specs: `device-inventory`, `observability-signals`, `build-web-ui`.
- Affected code: core-elx inventory settings + threshold worker, metrics ingestion/alert pipeline, and web-ng interface details UI.
