# Design: Device chart anomaly and capacity overlays

## Context

The merged CPU chart work made device sysmon charts readable and restored hover behavior. Device detail also already loads:

- Anomaly rows through `DeviceLive.AnomalyCapacityData` using indexed `in:events class_uid:2004 source_type:anomaly_detection ...`.
- Capacity rows through `in:capacity_forecasts status:(projected,at_risk,exhaustion_projected) has_exhaustion:true ...`.
- Basic chart annotations through `DeviceLive.SysmonMetrics.annotate_metric_sections/3`, `Timeseries.SeriesData.annotation_markers/4`, and `ChartCard.annotation_markers_svg/1`.

That gives a good base, but it only draws point-in-time vertical markers. The next useful UX is to make findings explain themselves directly on the graph.

## Goals

- Let an operator see "this graph is where the anomaly happened" without hunting between the finding list and the chart.
- Preserve the existing overall CPU and per-core drilldown layout.
- Reuse existing finding/capacity queries and chart components.
- Make overlays honest: if an event lacks window, peak, or series metadata, show only the parts we can prove.

## Non-Goals

- No new anomaly detector or forecast model.
- No write-time mutation of findings.
- No metric writes outside JetStream/event_writer.
- No suppression/disposition computation in the chart. The chart only displays effective fields produced or projected by the existing anomaly/disposition path.

## Proposed Overlay Model

### Anomaly findings

Project each device anomaly row into a normalized chart overlay shape:

- `kind: :anomaly`
- `time` or `timestamp`
- optional `window_started_at` / `window_ended_at`
- optional `peak_value` / `metric_value`
- optional `threshold_value`
- `metric_class`, `metric_name`, `series_key`
- `severity` and, when available, `disposition` / effective severity
- `finding_uid`, `title`, and reason text for tooltip/detail

Rendering:

- Draw a vertical marker at the finding time when no window is available.
- Draw a translucent time-window band when both start/end are available.
- Draw a small peak marker at the closest chart point when peak/value is present and the series matches.
- Keep color tied to effective severity/disposition, not raw detector severity.

### Capacity forecasts

Project each capacity row into a normalized chart overlay shape:

- `kind: :capacity`
- `metric_name`, `metric_class`, `resource_key`, `resource_label`
- `current_value`, `projected_value`, `exhaustion_threshold`
- `projected_exhaustion_at`
- optional `lower_bound`, `upper_bound`, `confidence`
- `status`

Rendering:

- Keep the threshold as a horizontal reference line.
- Draw a forecast/runway segment from the current sample toward the projected value when both current and projected values are in the visible unit/domain.
- Draw the projected exhaustion marker if it falls in or near the chart window; otherwise expose it in chart tooltip/summary only.
- Draw confidence bands only when lower/upper bounds are numeric and unit-compatible.

## Matching Rules

- CPU overlays match CPU charts by `metric_class=cpu` or `metric_name` containing CPU.
- Per-core CPU overlays match a top-core panel only when `series_key` can be normalized to one of the rendered core series; otherwise the overlay appears on the overall CPU chart.
- Memory and disk overlays match by metric class/name.
- Capacity rows match disk/capacity charts by `resource_key`, `resource_label`, or metric name where possible.
- Unmatched overlays are not discarded from the anomaly/capacity panel; they are simply not drawn on a chart.

## Risks

- Too many markers can make charts noisy. Limit rendered overlays per chart and prefer selected finding focus for dense histories.
- Forecast projections may extend beyond the current 24h chart window. Do not squeeze the time axis just to show a far-future exhaustion date; show out-of-window runway context in text instead.
- Disposition metadata is still being completed by `add-anomaly-finding-disposition`. The overlay must accept raw current rows and richer future rows without requiring a migration.
