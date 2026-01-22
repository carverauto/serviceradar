## Context
Interface metrics can be selected per interface, but threshold alerting is currently defined once per interface. This does not scale to multiple selected metrics and prevents independent threshold tuning per metric.

## Goals / Non-Goals
- Goals:
  - Support per-metric thresholds for interface metrics.
  - Evaluate thresholds only for enabled/selected metrics.
  - Provide clear UI controls in each metric card without accidental toggles.
- Non-Goals:
  - Changing the underlying `timeseries_metrics` ingestion pipeline.
  - Introducing new alerting engines outside the existing alert/event flow.

## Decisions
- Store per-metric thresholds as a JSONB map keyed by metric name (e.g., `"ifInOctets" => %{...}`) in interface settings.
- Threshold evaluation reads selected metrics and per-metric settings and emits events/alerts with metric metadata.
- UI uses explicit enable/disable toggles within each card; threshold controls are gated by enabled state.

## Risks / Trade-offs
- UI complexity: more controls per card; mitigate with collapsible/inline controls.
- Migration risk: existing single threshold fields need a forward path (keep existing until removed or migrate to per-metric entry).

## Migration Plan
- Add JSONB per-metric threshold column alongside existing threshold fields.
- Populate per-metric thresholds lazily as users configure them.
- Optionally migrate existing single-threshold settings to a per-metric entry when a metric is selected.

## Open Questions
- Which metric should receive migrated legacy thresholds (if any)?
- Should per-metric thresholds automatically enable the metric?
