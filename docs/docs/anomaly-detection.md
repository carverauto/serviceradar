---
title: Anomaly Detection (Tuning & Operations)
---

# Anomaly Detection (Tuning & Operations)

:::note Looking for how the engine works?
This page is the **operator-facing tuning and operations guide**. For the
architecture, the actual statistics, the data contract, honest naming (what is and
is **not** causal), the disposition loop, and the proof harness, see the
[Anomaly Engine](./anomaly-engine.md) reference — the single source of truth.
:::

ServiceRadar can evaluate live metrics for short-term anomalies and long-term
capacity risk. The detector watches metric streams, emits findings into the
event stream, and lets the normal alert/rule workflow handle notification and
triage.

Use this guide when tuning the deployment-level settings in
**Settings > Anomaly Detection**, editing anomaly add-on assignment/profile params,
or reviewing anomaly and capacity findings in **Events**.

## Tuning Ownership

Short-term edge spike tuning is owned by the native `anomaly` add-on profile or
assignment params. Deployment-level settings in **Settings > Anomaly Detection**
own central seasonal disposition, capacity forecasts, and planning metadata;
they do not rewrite existing edge add-on assignments.

The seeded "Default Edge Anomaly Detection" profile pins only
`metric_feed.sources` to `["sysmon", "snmp"]`. It intentionally omits scalar
edge detector knobs such as `window_size`, `min_samples`, `n_sigma`,
`confirm_slots`, `max_series`, and checkpoint limits, so omitted values use the
defaults shipped in the approved add-on package. To tune spike detection, edit
the add-on profile or a narrower assignment, canary it on a small cohort, and
then broaden the assignment after status and event volume are healthy.

## Access

Anomaly detection settings require the `observability.alerts.manage`
permission. Users without that permission can still view events and alerts if
their role grants the normal observability read permissions, but they cannot
change detector or forecast tuning.

## Edge Spike Detector Tuning

Short-term spike detection runs in the native `anomaly-addon` next to the
ServiceRadar agent. The add-on consumes the local `metric-feed:v1` stream before
the agent publishes those samples upstream, compares each series against its
rolling baseline, and emits OCSF Detection Finding events for confirmed
anomalies.

By default the add-on subscribes only to local `sysmon` and `snmp` metric
sources. ICMP and generic timeseries feeds are opt-in in the add-on assignment
params. This keeps the default profile focused on agents that actually collect
host or network-device metrics, rather than every add-on-capable agent in the
fleet.

A single outlier is not enough to create a finding; the detector waits until
enough consecutive evaluation slots are anomalous.

Important detector fields across these ownership surfaces:

- **N-sigma threshold**: how far a value must move from the baseline before a
  slot is anomalous. Higher values reduce noise and may miss smaller changes.
  Lower values catch smaller changes and can increase false positives.
- **Window size**: maximum number of samples retained for the rolling baseline.
  Increase it for stable metrics with long periodic behavior; decrease it for
  metrics that legitimately shift quickly. Edge spike scoring is count-based:
  the native add-on receives `window_size`, not a wall-clock duration.
- **Core target duration**: target wall-clock span for operator cadence and
  baseline-planning metadata in the central settings model. It is not sent to
  the edge add-on; keep it aligned with the intended sampling cadence so future
  central workflows and documentation reflect the same baseline horizon.
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
that behave differently without changing the whole deployment. These central
settings feed the seasonal and capacity runtime; edge spike overrides belong in
the native add-on profile or assignment params.

Supported detector classes include:

- `interface`: SNMP interface and flow-derived utilization series
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
- For edge spike findings, check
  `metadata.service_radar.verdict_source`. The native add-on sets it to
  `edge-spike`.
- If a class emits too many short-lived findings, raise `confirm_slots` or
  `min_samples` before raising the global threshold.

Do not tune a whole deployment around one bad series. Prefer a class override
or, when available, a targeted series override.

## Rollout Guidance

Metrics must enter ServiceRadar through NATS JetStream before they are written
to CNPG. This keeps anomaly detection and the causal engine subscribed to the
same stream as the persistence consumer.

For spike detection, assign the native `anomaly` add-on to the agents that own
sysmon or SNMP collection. The default profile uses the broad SRQL target
`in:devices`, with add-on params restricting the consumed feed sources to
`["sysmon", "snmp"]`, and relies on the approved package defaults for scalar
detector knobs until an operator explicitly overrides them. Narrow the SRQL
target when a deployment has agents that should never run host add-ons. Do not
assign the native anomaly add-on to the in-cluster `k8s-agent` unless that pod
is deliberately acting as the owner of a host metric feed; in normal
deployments, Kubernetes SNMP or sysmon collection belongs on host agents.

During rollout:

1. Import and approve the signed `anomaly` add-on package.
2. Assign it to one canary agent or a small cohort that collects sysmon or SNMP.
3. Enable the SNMP and sysmon metric publishers
   (`AGENT_GATEWAY_SNMP_METRICS_ENABLED` / `AGENT_GATEWAY_SYSMON_METRICS_ENABLED`,
   or the `gateway.snmpMetricsEnabled` / `gateway.sysmonMetricsEnabled` Helm
   values) only after the metrics stream and database sync path are healthy.
4. Check add-on status and drift for the canary, then search Events for
   `verdict_source:edge-spike` and for operational
   `status_code:anomaly_capacity_shed` records.
5. Broaden the add-on assignment by cohort after canary status, CPU, memory, and
   shed records are clean.
6. Keep remediation workflows manual until a separate guarded-remediation
   proposal is approved and implemented.

Runback is also assignment based. Disable the add-on assignment or retarget the
previous approved package version, wait for the agent to receive the next
compiled config, and verify `in:addon_statuses`. Raw metrics continue flowing to
JetStream and CNPG for graphs, rollups, and capacity forecasts. The retired
central raw-stream anomaly analyzer is not a fallback path on this branch; if a
deployment needs short-term spike verdicts, keep the edge add-on assigned or
roll back to a release that still carries the old central analyzer.

## Guarded Remediation Is Future Work

This release is detect-and-alert only. It does not automatically throttle
traffic, restart services, change polling profiles, resize resources, or mutate
network policy.

Any future automatic action must ship as a separate feature-flagged change with
bounded-intervention gates defined before enablement:

1. Trigger and score the finding.
2. Require a persistence or duration gate.
3. Check an already-acting interlock so repeated findings do not stack actions.
4. Clamp the action to an approved safe envelope.
5. Audit-log the decision, action, and operator override path.

Do not wire anomaly or capacity findings directly to remediation scripts. Route
them through events, alerts, and manual operator review until that guarded
phase exists.

## Troubleshooting

- **No findings**: confirm the `anomaly` add-on package is approved and assigned,
  the target agent is active, the assignment params include the relevant
  `metric_feed.sources` entry, and the series has at least `min_samples`.
- **Too many findings**: increase `confirm_slots` for bursty classes, then
  consider increasing `n_sigma`.
- **Capacity shed records**: reduce the assignment scope, narrow
  `metric_feed.sources`, or raise `max_series` only after confirming the host has
  enough add-on CPU and memory headroom.
- **Forecasts missing**: verify rollups are current and the series has at least
  `minimum_history_points`.
- **Forecasts look too aggressive**: increase `minimum_history_points`, shorten
  the forecast horizon, or switch back to `linear` until seasonal history is
  trustworthy.
