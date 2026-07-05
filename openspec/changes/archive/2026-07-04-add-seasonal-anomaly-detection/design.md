## Context
Anomaly detection splits cleanly by **timescale and data gravity**:

- **Edge (spike).** The edge add-on runs a rolling z-score over the last few
  minutes per series. Immediate, local, no history, minimal state. Catches
  "jumped vs. recent and held." Cannot account for time-of-day/day-of-week.
- **Central (seasonal/contextual).** "Is this normal for *this time*?" needs
  weeks of history, which is already materialized in the hourly CAGGs
  (`cpu_metrics_hourly`, `memory_metrics_hourly`, `disk_metrics_hourly`,
  `process_metrics_hourly`, `timeseries_metrics_hourly`). It is naturally a
  scheduled batch over aggregates — exactly the capacity planner's shape.

This change adds the central seasonal tier. It is NOT the retired raw-stream
pipeline: it reads CAGGs (bucketed averages), never `metrics.>`, and never the
`causal_reasoner_nif`. It refines the "anomaly is 100% edge" framing of
`move-anomaly-detection-to-edge` to: **edge does spike, central does seasonal
over rollups, the alert layer joins them.**

## Goals
- Answer "anomaly vs. normal for this time-of-day/day-of-week" using existing
  CNPG history, without shipping history to the edge.
- Suppress the edge spike detector's seasonal false positives (the morning ramp)
  and escalate spikes that are genuinely off-baseline for the time.
- Surface slow seasonal deviations the edge cannot see (no sharp spike, but the
  whole window is wrong for the day).
- Reuse the capacity-forecasting machinery; add no raw-stream load.

## Non-Goals
- Real-time seasonal detection. Seasonal anomalies are slow; bucket+cadence
  latency (minutes to ~1h) is acceptable. The edge owns real-time.
- Replacing the edge spike detector. The two compose.
- Per-raw-sample central processing. This runs over CAGG buckets only.
- Forecasting. That is the capacity planner; this shares its CAGG/Holt-Winters
  pattern but emits anomaly verdicts, not forecasts.
- A holiday/event calendar (a known limitation; see Risks).

## The seasonal model
- **Seasonal key = hour-of-week** (168 buckets: `extract(dow)` x `extract(hour)`
  of the CAGG `bucket`). This captures both daily shape and weekday/weekend
  difference in one compact profile. Granularity is configurable (e.g.
  hour-of-day = 24 to ignore weekday/weekend, or finer for spiky business hours).
- **Profile = per-bucket distribution** built by aggregating the hourly CAGG
  averages at the same hour-of-week over a **trailing window** (default 8 weeks):

  ```sql
  SELECT extract(dow  from bucket) AS dow,
         extract(hour from bucket) AS hod,
         avg(avg_usage_percent)    AS seasonal_mean,
         stddev(avg_usage_percent) AS seasonal_stddev,
         count(*)                  AS bucket_samples
  FROM   platform.cpu_metrics_hourly
  WHERE  device_id = $1 AND bucket >= now() - interval '8 weeks'
  GROUP  BY 1, 2;
  ```

  The CAGGs store hourly `avg_*`, not stddev — so the seasonal stddev is the
  spread of the hourly averages across same-hour-of-week buckets, which is
  exactly the seasonal variance we want.
- **Detect on the deseasonalized residual.** For the latest complete bucket
  value `v` in bucket `(dow,hod)`: `z = |v - seasonal_mean| / seasonal_stddev`;
  breach when `z >= n_sigma`. Expected seasonality is subtracted before scoring,
  so the busy-Tuesday ramp does not fire.
- **Insufficient seasonal baseline.** A bucket with `bucket_samples < min_bucket_samples`
  (default ~3-4 same-hour-of-week observations) is not trusted: emit
  `insufficient_seasonal_baseline`, do not flag, defer to the edge spike signal.
  This gives graceful cold-start over the first few weeks per series/bucket.

## The worker
- `ServiceRadar.Observability.SeasonalAnomaly.Worker` — an Oban cron worker
  mirroring `CapacityForecasting.Worker` (same `use Oban.Worker` + unique guard,
  same `SRQLRunner` access, same per-`Source` iteration).
- Cadence: configurable; default every 15-30 min (seasonal buckets are hourly, so
  finer cadence only re-checks the same bucket). Each run, per series: one SRQL
  query for the profile + latest bucket, compute the residual z, emit a verdict
  via a `VerdictEmitter` onto the same signal path other anomaly verdicts use.
- Bounded work per run (prioritized/active series, page through the fleet) so a
  large tenant does not blow the run budget — same discipline as the planner.
- The stats are pure SQL + Elixir (mean/stddev are SQL aggregates; the residual
  compare is trivial). **No NIF, no Rust** — consistent with retiring the NIF.

## The edge<->central verdict join
Verdicts carry `source` (`edge-spike` | `central-seasonal`), `series_key`, and a
time window. The signal/alert layer (e.g. `stateful_alert_engine`) correlates by
`(series_key, overlapping window)`:

- **edge spike + seasonal "expected for this time"** -> suppress/downgrade (the
  morning ramp). This is the precision win.
- **edge spike + seasonal "also off-baseline"** -> confirm/escalate (high
  confidence: unusual vs. recent AND vs. this time).
- **no edge spike + seasonal "off-baseline"** -> surface a slow seasonal anomaly
  (the quiet-2x-Tuesday the edge cannot see).
- **edge spike + seasonal `insufficient_seasonal_baseline`** -> pass the spike
  through unmodified (cold-start: edge is the only signal).

So edge = recall, central = precision; neither is redundant.

## Cold-start and degraded modes
- First few weeks per series: most buckets are `insufficient_seasonal_baseline`,
  so seasonal is quiet and the edge spike signal carries detection. The profile
  fills in as history accrues (or is warm immediately if CAGG history predates
  the rollout).
- Islanded edge (intermittently-connected site): no central seasonal context is
  available, so the user gets spike-only — the same mode an edge-only design
  would always have. Graceful, not a regression.

## Per-tenant (SaaS)
Under instance-per-tenant, the worker runs against each tenant's own CNPG and
reads that tenant's CAGGs. No cross-tenant seasonal sharing.

## Risks / Trade-offs
- **Latency.** Seasonal verdicts land at bucket (1h) + cadence granularity. Fine
  for seasonal anomalies; never use this for real-time (edge handles that).
- **Holidays / irregular events.** A holiday Monday looks like a normal Monday in
  the hour-of-week model, causing a false flag (or a miss for the inverse). Known
  limitation; a holiday/event calendar is a later refinement, not in scope.
- **Concept drift / regime change.** The trailing window adapts but slowly; a
  legitimate sudden regime change (capacity added, workload moved) causes
  transient flags until the window catches up. The trailing window length trades
  stability vs. adaptation.
- **mean/stddev fragility for bursty metrics.** For heavy-tailed series (p99
  latency, request rates) the outliers inflate stddev and hide themselves; a
  robust statistic (median + MAD, or a p05-p95 band) is better per metric class.
  Start with mean/stddev (matches the edge), allow a per-metric-class override.
- **Join complexity.** Correlating two verdict sources by series+window adds
  alert-layer logic and a dedup discipline so the user sees one enriched alert,
  not two. The `source` label + series/time keys are the join contract.

## Reconciliation with the NIF retirement
`move-anomaly-detection-to-edge` retires the central **raw-stream per-sample**
detector (NIF + `ANALYSIS_METRICS_*` durables). This change adds a central
**aggregate-based seasonal** detector (Oban cron over CAGGs). They are not in
tension: the retired thing consumed `metrics.>` per sample; this consumes hourly
CAGGs on a schedule. The end-state is "edge spike + central seasonal-over-rollups,"
with no raw-stream central anomaly pipeline.
