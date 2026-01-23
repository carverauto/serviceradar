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
- Introduce a unified `EventRule` resource with `source_type` (log/metric) to replace `LogPromotionRule`.
- Migrate existing log promotion rules into the new `EventRule` table and update the promotion pipeline to read `source_type = :log`.
- Threshold evaluation reads selected metrics and per-metric settings, creates OCSF events via metric `EventRule` configs, and evaluates alert promotion.
- UI displays a concise per-metric summary on the card (icons/labels for event + alert status).
- Clicking a metric card opens a modal to configure event creation and alert promotion settings for that metric.
- Modal forms should reuse existing event/alert rule builder controls where possible to stay consistent.

## Risks / Trade-offs
- UI complexity: more modal state + reuse of rule builder controls; mitigate with shared components and concise summaries.
- Migration risk: existing single threshold fields need a forward path (keep existing until removed or migrate to per-metric entry).

## Migration Plan
- Add JSONB per-metric threshold column alongside existing threshold fields.
- Create `event_rules` table and migrate existing `log_promotion_rules` into `event_rules` with `source_type = :log`.
- Update the log promotion pipeline to read from `event_rules` and leave legacy tables intact for rollback.
- Populate per-metric thresholds and metric `event_rules` lazily as users configure them.
- Auto-create a stateful alert rule when per-metric alert settings are enabled; update/delete it on changes.

## Open Questions
- Which metric should receive migrated legacy thresholds (if any)?
- Should per-metric thresholds automatically enable the metric?
