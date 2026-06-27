## 1. Proposal
- [x] 1.1 Validate with `openspec validate add-seasonal-anomaly-detection --strict`.

## 2. Seasonal profile + scoring
- [ ] 2.1 Add `SeasonalAnomaly.Profile`: build the hour-of-week (dow x hour) profile per series from the hourly CAGGs via SRQL over a trailing window (default 8 weeks) — `avg`/`stddev`/`count` per bucket.
- [ ] 2.2 Deseasonalized residual scoring: `z = |v - seasonal_mean| / seasonal_stddev` for the latest complete bucket; breach at `n_sigma`; `insufficient_seasonal_baseline` when `bucket_samples < min_bucket_samples`.
- [ ] 2.3 Config: seasonal key/granularity (default hour-of-week), trailing window, `n_sigma`, `min_bucket_samples`, per-metric-class statistic override (mean/stddev default; median/MAD or p05-p95 for bursty classes).

## 3. Worker
- [ ] 3.1 Add `SeasonalAnomaly.Worker` (Oban cron, unique guard) mirroring `CapacityForecasting.Worker`; iterate per-`Source`, query the profile + latest bucket via `SRQLRunner`.
- [ ] 3.2 Bound work per run (prioritized/active series, paged) so a large fleet stays within the run budget.
- [ ] 3.3 `SeasonalAnomaly.VerdictEmitter`: emit `central-seasonal` verdicts onto the existing anomaly signal path, with `source`, `series_key`, and time window.
- [ ] 3.4 Register the cron schedule (default every 15-30 min); make cadence configurable.
- [ ] 3.5 Telemetry: per-source evaluated/breached/insufficient counts, query timing, run coverage (how many series scored vs. skipped).

## 4. Edge<->central verdict join
- [ ] 4.1 Tag edge add-on verdicts with `source: edge-spike` and central seasonal verdicts with `source: central-seasonal`; carry `series_key` + time window on both.
- [ ] 4.2 In the signal/alert layer (`stateful_alert_engine`), correlate by `(series_key, overlapping window)`: suppress seasonal-expected spikes, escalate spike + off-baseline, surface seasonal-only deviations, pass spikes through when seasonal is `insufficient_seasonal_baseline`.
- [ ] 4.3 Dedup so a single real event yields one enriched alert, not two.

## 5. Tests
- [ ] 5.1 Profile/scoring unit tests: busy-Tuesday ramp does NOT breach (deseasonalized residual ~0); a Sunday-3am value at Tuesday-9am levels DOES breach.
- [ ] 5.2 Cold-start: thin buckets report `insufficient_seasonal_baseline` and do not flag.
- [ ] 5.3 Join tests: each of the four edge x seasonal cases produces the intended alert outcome.
- [ ] 5.4 Worker integration test over seeded CAGG fixtures.
- [ ] 5.5 `./scripts/elixir_quality.sh --project elixir/serviceradar_core`.

## 6. Delivery
- [ ] 6.1 Document the two-tier model (edge spike + central seasonal) and the join semantics in the PR.
- [ ] 6.2 Open a Forgejo PR against `staging`.
