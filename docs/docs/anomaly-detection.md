---
title: Anomaly Detection and Capacity Forecasts
---

# Anomaly Detection and Capacity Forecasts

ServiceRadar can evaluate live metrics for short-term anomalies and long-term
capacity risk. The detector watches metric streams, emits findings into the
event stream, and lets the normal alert/rule workflow handle notification and
triage.

Use this guide when tuning the deployment-level settings in
**Settings > Anomaly Detection** or when reviewing anomaly and capacity findings
in **Events**.

## Access

Anomaly detection settings require the `observability.alerts.manage`
permission. Users without that permission can still view events and alerts if
their role grants the normal observability read permissions, but they cannot
change detector or forecast tuning.

## Streaming Detector Tuning

The streaming detector compares a series against its rolling baseline. A single
outlier is not enough to create a finding; the detector waits until enough
consecutive evaluation slots are anomalous.

Key settings:

- **N-sigma threshold**: how far a value must move from the baseline before a
  slot is anomalous. Higher values reduce noise and may miss smaller changes.
  Lower values catch smaller changes and can increase false positives.
- **Window size**: maximum number of samples retained for the rolling baseline.
  Increase it for stable metrics with long periodic behavior; decrease it for
  metrics that legitimately shift quickly.
- **Window duration**: target wall-clock span represented by the rolling window.
  Keep this aligned with the sampling cadence for the metric class.
- **Confirm slots**: consecutive anomalous slots required before a finding is
  emitted. Increase this for bursty signals; decrease it for signals where
  delayed detection is worse than occasional noise.
- **Minimum samples**: clean baseline samples required before findings may
  emit. Raise this when onboarding a new metric class with sparse or irregular
  data.

Start conservatively. For noisy or bursty metrics, prefer increasing
`confirm_slots` before raising `n_sigma`; that keeps true sustained deviations
visible while filtering one-off spikes.

## Metric Class Overrides

The global values apply first. Metric class overrides let operators tune classes
that behave differently without changing the whole deployment.

Supported detector classes include:

- `interface`: SNMP interface and flow-derived utilization series
- `red`: request/error/duration style OpenTelemetry metrics
- `cpu`: sysmon CPU series
- `memory`: sysmon memory series
- `disk`: sysmon disk series

The overrides field must be a JSON object. Any omitted keys inherit the global
or built-in defaults.

```json
{
  "interface": {
    "n_sigma": 3.5,
    "confirm_slots": 4,
    "window_size": 360,
    "min_samples": 30
  },
  "red": {
    "n_sigma": 3.0,
    "confirm_slots": 3,
    "window_size": 120
  },
  "disk": {
    "confirm_slots": 6,
    "min_samples": 48
  }
}
```

For seasonal signals, per-class overrides may also include
`seasonal_enabled`, `seasonal_sensitivity`, `seasonal_min_samples`,
`trend_enabled`, `trend_n_sigma`, and `trend_min_samples`. Enable these only
after the class has enough history to distinguish a daily or weekly pattern
from a real incident.

## Capacity Forecast Tuning

Capacity forecasts read long-horizon rollups and project whether a series is
likely to cross a configured utilization threshold.

Key settings:

- **Forecast horizon**: how far into the future the model projects.
- **Warning horizon**: how soon projected exhaustion must occur before a
  warning finding is emitted.
- **Warning threshold**: utilization percentage treated as exhaustion. For
  example, `80.0` means the forecast warns when the projection reaches 80
  percent utilization inside the warning horizon.
- **Model**: `linear`, `seasonal_linear`, or `holt_winters`. Use `linear` for
  steady trends. Use a seasonal model only when the metric has a repeatable
  pattern and enough history.
- **Minimum history points**: aggregate samples required before forecasts emit.
  Increase this for sparse series or seasonal models.

Capacity overrides use the same JSON object shape and class names, but only
forecast settings are meaningful:

```json
{
  "interface": {
    "minimum_history_points": 168,
    "warning_threshold_percent": 85.0
  },
  "disk": {
    "minimum_history_points": 336,
    "model": "linear"
  }
}
```

## Interpreting Findings

Anomaly findings indicate a metric series moved outside its learned baseline
for the required number of confirm slots. Capacity findings indicate a trend is
projected to cross the configured threshold inside the warning horizon.

When reviewing a finding:

- Confirm the event timestamp and affected series match a real device,
  interface, service, or host metric.
- Compare the finding against nearby deploys, maintenance windows, and known
  traffic changes.
- For interface capacity findings, check whether the underlying counter has
  enough history and whether the interface is normally bursty.
- For CPU, memory, and disk findings, compare against sysmon profile changes
  and agent sampling cadence.
- If a class emits too many short-lived findings, raise `confirm_slots` or
  `min_samples` before raising the global threshold.

Do not tune a whole deployment around one bad series. Prefer a class override
or, when available, a targeted series override.

## Rollout Guidance

Metrics must enter ServiceRadar through NATS JetStream before they are written
to CNPG. This keeps anomaly detection and the causal engine subscribed to the
same stream as the persistence consumer.

During rollout:

1. Start with the always-live OpenTelemetry metric subjects.
2. Enable SNMP and sysmon shadow subjects only after the metrics stream and
   database sync path are healthy.
3. Check Events for anomaly and capacity findings before wiring new rules to
   paging destinations.
4. Keep remediation workflows manual until a separate guarded-remediation
   proposal is approved and implemented.

## Troubleshooting

- **No findings**: confirm the relevant metric subject is enabled for analysis,
  the stream has recent messages, and the series has at least `min_samples`.
- **Too many findings**: increase `confirm_slots` for bursty classes, then
  consider increasing `n_sigma`.
- **Forecasts missing**: verify rollups are current and the series has at least
  `minimum_history_points`.
- **Forecasts look too aggressive**: increase `minimum_history_points`, shorten
  the forecast horizon, or switch back to `linear` until seasonal history is
  trustworthy.
