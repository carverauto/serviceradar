# Change: Add central seasonal anomaly detection over CAGGs

## Why
The edge anomaly add-on (`move-anomaly-detection-to-edge`) does fast, local,
per-series **spike** detection — a rolling z-score over the last few minutes. It
is excellent at "this jumped versus recent behavior and held," and it needs no
history. But it **cannot** answer "is this an anomaly, or a normal busy Tuesday
morning?" By construction, at 9am its rolling window is full of overnight-quiet
samples, so the morning ramp reads as a clean breach. That is a false positive
baked into the method, not a tuning problem.

Answering the seasonal question requires comparing *now* against the same
**time-of-day / day-of-week** historically, which needs weeks of history. That
history already lives in CNPG — in the hourly continuous aggregates
(`cpu_metrics_hourly`, `memory_metrics_hourly`, `disk_metrics_hourly`,
`timeseries_metrics_hourly`, …). Data gravity says: do the seasonal analysis
where the data already is, not by shipping weeks of state to the edge.

This is a different shape from the central raw-stream detection that
`move-anomaly-detection-to-edge` retires (the `causal_reasoner_nif` + the
`ANALYSIS_METRICS_*` durables consuming `metrics.>`). Seasonal detection is a
**scheduled job over CAGGs** — bucketed aggregates, not raw points — so it does
not reintroduce the raw firehose and does not resurrect the retired pipeline. It
is the same pattern the capacity planner already uses (`CapacityForecasting.Worker`:
Oban cron → SRQL over CAGGs → per-series fit), and largely reuses it.

The two tiers compose into **recall + precision**: the edge proposes fast
candidates (high recall, some seasonal noise); central seasonal context disposes
(suppresses seasonal-expected spikes, escalates spikes that are *also* off-baseline
for the time, and surfaces slow seasonal deviations the edge never sees — a
Tuesday that is quietly 2x normal all morning with no sharp spike).

## What Changes
- Add a central **seasonal-anomaly Oban worker** (mirroring
  `CapacityForecasting.Worker`) that, per series, builds a **seasonal profile** —
  hour-of-week mean/stddev — from the hourly CAGGs over a trailing window
  (default 8 weeks) via SRQL, compares the latest complete bucket, and emits an
  "off-baseline-for-time" verdict when the deseasonalized deviation breaches.
- Compute the profile as a `GROUP BY` over `extract(dow)`/`extract(hour)` of the
  CAGG bucket (168 hour-of-week buckets); detect on the **deseasonalized residual**
  (value minus the bucket mean, over the bucket stddev), so expected seasonality
  is removed before scoring.
- Require a **minimum per-bucket sample count** before a bucket is trusted; below
  it, report `insufficient_seasonal_baseline` and defer to the edge spike signal
  (graceful cold-start over the first few weeks).
- Add an **edge↔central verdict join** in the signal/alert layer: correlate edge
  spike verdicts with central seasonal context by `(series_key, time window)` —
  suppress seasonal-expected spikes, escalate spikes that are also off-baseline,
  and surface seasonal-only deviations. Verdicts carry a `source`
  (`edge-spike` | `central-seasonal`) and the series/time keys to join on.
- Keep it **per-tenant**: under instance-per-tenant SaaS, each tenant's worker
  reads its own CNPG CAGGs.

## Impact
- Affected specs: observability-signals
- Affected code: new `ServiceRadar.Observability.SeasonalAnomaly.{Worker,Source,Profile,VerdictEmitter}`, the signal/alert correlation that joins edge + seasonal verdicts, Oban cron registration; reads existing hourly CAGGs via `SRQLRunner`
- Reuses: the `CapacityForecasting.Worker` pattern (Oban cron → SRQL over CAGGs → per-series result + Ash upsert) and the existing hourly CAGG tier
- Related changes: `move-anomaly-detection-to-edge` (this is the central counterpart to its edge spike detector; it revises that change's "anomaly is 100% edge" framing to "edge spike + central seasonal-over-CAGGs"); `add-delta-metrics-lakehouse` (CAGGs/rollups remain the seasonal substrate)
