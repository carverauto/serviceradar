---
title: Anomaly Detection (Tuning & Operations)
---

# Anomaly Detection (Tuning & Operations)

:::note Engine reference
This page is the operator guide for tuning and rollout. For the statistics,
state machines, event contract, and proof harness, see
[Anomaly Engine](./anomaly-engine.md).
:::

ServiceRadar anomaly detection evaluates metric streams at the edge, folds
repeated detector evaluations into bounded episodes, and emits findings into the
normal event and alert workflow. The goal is to surface sustained operationally
meaningful changes, not to store one event for every noisy sample.

## Tuning Ownership

Settings flow through one authoritative chain:

1. **Settings > Anomaly Detection** writes the
   `platform.anomaly_detection_configs` singleton.
2. `AnomalyAddonConfigProjector` writes the edge-safe subset into
   anomaly add-on profile params under `managed`.
3. The add-on resolver applies `managed` defaults first and then applies
   operator-explicit top-level profile or assignment params.
4. Agents receive the merged add-on params on the normal config poll.

That ordering means the Settings UI changes fleet defaults, while explicit
profile or assignment params still win for canaries and one-off overrides.

The projector is enabled by default and scheduled in the production release,
so Settings edits reach the fleet on the next projection pass without extra
deployment config. `SERVICERADAR_ANOMALY_EDGE_CONFIG_PROJECTION=false`
disables it.

The baseline producer is a separate writer. It owns only
`seasonal_baselines`; the config projector owns only `managed`. Both writers
preserve the other key.

## Access

Managing anomaly settings requires `observability.alerts.manage`. Users without
that permission can still view anomaly findings if their role grants the normal
observability read permissions.

## Core Concepts

### Spikes

A spike is a point deviation from the rolling robust baseline. The edge add-on
maintains a per-series median/MAD window and admits a breaching sample at the
decision boundary (winsorized to the configured sigma band), so the window keeps
aging without allowing a surge to train itself in unboundedly. A stable,
non-saturated spike is adopted after `spike_adopt_after_samples` (600 by default;
300 for interface counters) and clears with `adopted` rather than flapping forever.
Findings still require `confirm_slots` consecutive breaching slots.

Spike findings use the `spike` detector and follow the same episode lifecycle as
drift: open, optional escalation update, and clear.

Interface counter rates also carry a recent-burst envelope. Once a series has at
least `burst_envelope_min_samples` (30) of lagged raw history, an upward sample
no taller than `burst_envelope_multiplier` (1.25) times the
`burst_envelope_quantile` (0.99) of that history is within what the series has
recently done and does not breach, however far over the z threshold it lands.
A recurring bulk transfer therefore opens once and then stays silent, while a
burst taller than the recent ones still opens; a sustained level change is the
drift detector's job. The suppression is written into the signal reason of the
emitted payload. Other classes have no envelope unless
`burst_envelope_enabled: true` is set for them.

### Drift

Drift is a sustained level shift detected by CUSUM. CUSUM remains the right tool,
but it is only valid against the right reference:

- Metric classes with strong daily or weekly seasonality default to
  `deseasonalized_only`.
- A series without a delivered hour-of-week baseline has no drift detection.
- Missing baseline coverage is bounded silence, never raw unseasonalized drift.

Drift episodes clear by recovery or by adoption. Adoption means the new
non-saturated level has persisted long enough to become the baseline, so the
detector re-anchors and emits one clear instead of re-alerting forever.

Common drift clear reasons:

- `recovered`: the series returned inside the clear band.
- `adopted`: the new non-saturated level was adopted as baseline.
- `stale`: the producer stopped seeing the episode and stale-close handled it.
- `flap_merged`: repeated near-threshold reopens were folded into one episode.

### Capacity

Capacity runway findings are only for monotone consumable resources by default,
such as disk usage and memory working set. Bursty mean-reverting gauges such as
CPU and interface utilization do not emit runway findings by default. Capacity
findings require trend significance and emit on state transitions, not every
hourly run.

The bursty sources are explicit opt-ins. Set
`SERVICERADAR_CAPACITY_FORECASTING_SOURCE_OPT_INS` (comma-separated:
`cpu_usage`, `interface_rate`, `flow_bytes_per_hour`) or use the source opt-in
field in **Settings > Anomaly Detection**. A non-empty Settings selection wins
over the env value; leaving the Settings field empty keeps the env opt-ins
active. Series the forecaster skips are counted with reasons and summarized on
the Observability health page. A series whose trend crosses the threshold
inside the horizon but further out than twice its observed history is recorded
as `exhaustion_beyond_history_cap` with the projected crossing time in its
diagnostics, distinct from `no_projected_exhaustion`; the runway table shows
only the newest forecast per resource from the last 24 hours.

Disk usage is forecast per mount point. The `disk_usage` source reads the
`timeseries_metric_disk_hourly` aggregate, which keeps each filesystem's
`mount_point` in the rollup identity, so a data volume filling toward 100
percent is not averaged away by a flat root filesystem on the same host. Each
mount is its own forecast row labelled `<device> / <mount>`; the resource id
stays the device, so a device page lists every mount's forecast. After the
upgrade the aggregate materializes only the raw retention window (about a
week), so early per-mount rows carry short histories until it accumulates.

## Settings Guide

### Streaming Detector

- **N-sigma threshold**: how far a value must move from baseline before a slot
  breaches. Higher values reduce sensitivity.
- **Window size**: sample count retained in the rolling baseline.
- **Confirm slots**: consecutive breaching slots required before opening.
- **Minimum samples**: clean samples required before findings can emit.
- **Core target duration**: planning metadata for central workflows. Edge
  scoring uses sample counts, not this wall-clock duration.

### Per-Class Overrides

Use per-class overrides instead of broad global changes when one metric family
is noisy. Important edge keys include:

- `enabled`: false disables detection for that class.
- `drift_mode`: `off`, `deseasonalized_only`, or `always`.
- `cusum_k`, `cusum_h`, `h_confirm_mult`: CUSUM sensitivity and confirmation.
- `drift_confirm_window`, `drift_clear_slots`,
  `drift_adopt_after_samples`, `drift_escalate_after_secs`: drift lifecycle.
- `spike_adopt_after_samples`: rolling-spike adoption horizon.
- `burst_envelope_enabled`, `burst_envelope_quantile`,
  `burst_envelope_multiplier`, `burst_envelope_lag_samples`,
  `burst_envelope_min_samples`: the recent-burst envelope (on by default for
  interface counter rates only).
- `min_std_floor`, `min_cv`: class dispersion floors. Interface counters also
  use a family-specific absolute practical-significance floor.
- `min_std_floor`, `min_cv`: dispersion floors.
- `severity_cap`: maximum severity for that class.
- `severity_bands`: class-specific severity band overrides.

Defaults are deliberately conservative: interface and other seasonal counters
should stay `deseasonalized_only`; only classes with a clear non-seasonal
meaning should use `always`.

### Denylist

The edge add-on denylist blocks metric names that should never produce detector
findings. The default includes `cpu.frequency_hz`. Use the denylist for metrics
that are metadata, constants, or operationally meaningless as anomalies.

### Emission Governance

The add-on enforces:

- Per-series cooldown for non-clear emissions.
- Per-tick add-on budget.
- Priority for clears and high-severity opens.
- Shed rollup records when budget is exhausted.

The invariant is: every detected transition is either emitted, folded into an
open episode, or accounted in a shed rollup.

## Severity Semantics

Severity is based on bounded evidence, not raw accumulator magnitude.

- Stored scores are capped.
- Drift uses a bounded shift estimator, not the raw CUSUM sum.
- Edge drift is capped at High.
- Interface statistical changes are capped at High unless explicit semantics
  such as link-down or static thresholds say otherwise.
- Critical requires High evidence, a class impact test, and minimum duration.

For CPU and memory, Critical means real saturation on the host aggregate, not a
single unusual core or a low-utilization drift. Disk Critical is owned by the
capacity and explicit-threshold paths, not unsupervised edge drift.

## Episode Lifecycle

An episode has a deterministic `finding_uid` and `episode_uid`.

Open creates the episode. A re-open inside the flap window reuses that episode
identity and emits `update` with reason `flapping`; the eventual clear is
`flap_merged`. Updates also carry severity-band escalation.
Clear closes it. Still-open heartbeats update episode state but do not create a
new finding row.

Core folds independent producers for the same finding into one canonical episode.
The episode stays open while any fresh producer reports it open; a clear is
emitted only after every producer is clean or stale. SNMP profiles that assign
the same targets to multiple pinned agents emit a config-hygiene warning.

This lifecycle bounds volume. A benign regime change should cost one open and
one clear, not a finding every poll cycle.

Episode ingest is on by default; `EVENT_WRITER_ANOMALY_EPISODES` set to
`false`, `0`, `no`, or `off` is the kill switch that falls back to per-row
anomaly ingest. Stale close waits at least twice the episode heartbeat
interval (minimum 30 minutes) before closing a silent episode, so one delayed
heartbeat cannot close a live episode. Central seasonal episodes are refreshed
by the hourly disposition worker rather than an edge heartbeat, so they use
their own window of at least 150 minutes
(`SERVICERADAR_CENTRAL_SEASONAL_STALE_AFTER_MINUTES`). Central seasonal
verdicts carry the evaluation time as their event time and need two
consecutive breaching hourly buckets by default
(`SERVICERADAR_SEASONAL_DISPOSITION_CONFIRM_SLOTS`).

## Seeded Alert Rules

The anomaly alert rules ServiceRadar seeds are managed: they carry a `managed`
marker and a template version, and upgrades reconcile them to the current
template at boot. Edit a seeded rule's owned fields and the seeder leaves it
alone (logged at boot); remove the `managed` marker to permanently detach it.
A one-time repair migration fixes pre-cutover rules that still matched the
legacy `signals.causal.predictions` subject.

## Cold Starts And Restarts

Cold starts are quiet until `min_samples` clean samples are available. Checkpoint
settings let the add-on persist rolling and episode state across restarts. If no
checkpoint path is configured, restarts cold-start baselines and may delay
detection while windows refill.

Delivered seasonal baselines are independent of rolling warmup. If a seasonal
baseline is missing or truncated by payload governance, drift stays inactive for
that series until coverage arrives.

## Expected Healthy Volume

Healthy anomaly volume is bounded by transitions, not sample count. Demo rollout
gates for this overhaul use these targets:

- After edge correctness: fewer than 1,000 anomaly rows/day fleet-wide.
- Critical share below 5%.
- No series above 20 rows/day.
- No stored score above the configured bound.
- Alert evaluation queue overflow at 0.

If volume rises, first check producer versions, profile priority ties, stale
manual assignments, and shed rollups. Do not tune the whole fleet around one bad
series.

## Silence Tripwires

Volume ceilings catch a noisy fleet; silence is now monitored in the other
direction too. Three scheduled tripwires emit operational health events when
the anomaly path goes quiet, each tunable by env:

- **Alert-path liveness**: a synthetic episode must flow through the seeded
  rule to an alert and recover on clear.
  `SERVICERADAR_ANOMALY_LIVENESS_ENABLED` (default `true`),
  `SERVICERADAR_ANOMALY_LIVENESS_CRON` (default `23 */6 * * *`).
- **Ingest silence**: zero anomaly upserts for
  `SERVICERADAR_ANOMALY_SILENCE_HOURS` (default `6`) while metric ingest is
  alive. `SERVICERADAR_ANOMALY_SILENCE_TRIPWIRE_ENABLED` (default `true`),
  `SERVICERADAR_ANOMALY_SILENCE_TRIPWIRE_CRON` (default `7 * * * *`).
- **Seasonal baseline freshness**: the edge-baseline producer records a
  heartbeat health event on every successful delivery run; the tripwire fires
  when no heartbeat landed within
  `SERVICERADAR_SEASONAL_BASELINE_FRESHNESS_HOURS` (default `26`). `SERVICERADAR_SEASONAL_BASELINE_TRIPWIRE_ENABLED` (default
  `true`), `SERVICERADAR_SEASONAL_BASELINE_TRIPWIRE_CRON` (default
  `37 * * * *`).

Each check records a `core` health event. The seeded
`core_health_state_change_events` rule promotes those transitions into
`health.core.state_change` events, and the managed `core_health_check_unhealthy`
rule opens one critical alert per check while it is unhealthy and recovers it
when the check passes again, so a dead baseline producer pages instead of
sitting unhealthy on the health timeline.

## Rollout Guidance

Metrics must flow through NATS JetStream before persistence so anomaly detection,
correlation, and storage consume the same stream.

Recommended rollout:

1. Keep only one enabled anomaly profile for the target fleet.
2. Remove stale manual assignments that pin old add-on versions.
3. Configure checkpointing before broad rollout.
4. The config projector is on by default; if profile hygiene is not clean yet,
   disable it (`SERVICERADAR_ANOMALY_EDGE_CONFIG_PROJECTION=false`) and
   re-enable once it is.
5. Seasonal baseline delivery is scheduled by default; measure params payload
   size, then enable interface drift as baselines arrive.
6. Soak each phase on demo before production defaults change.

Rollback is config-first: disable the projector, turn class `drift_mode` to
`off`, set `EVENT_WRITER_ANOMALY_EPISODES=false` to fall back to per-row
anomaly ingest, or retarget the previous approved add-on package. Raw metrics
continue flowing to JetStream and CNPG.

## Future Work

This release is detect-and-alert only. It does not restart services, throttle
traffic, resize resources, or mutate network policy.
