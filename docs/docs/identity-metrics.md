# Identity Reconciliation Metrics and Alerts

Use these OpenTelemetry gauges to monitor promotion health. All metrics emit on the `serviceradar.identity` meter and reflect the most recent reconciliation run:

- `identity_promotions_attempted_last_batch` – total sightings evaluated
- `identity_promotions_last_batch` – sightings promoted in the run
- `identity_promotions_eligible_auto_last_batch` – policy-passing and auto-enabled
- `identity_promotions_shadow_ready_last_batch` – policy-passing while in shadow mode
- `identity_promotions_blocked_policy_last_batch` – failed policy gates (missing hostname/fingerprint/persistence/etc.)
- `identity_promotion_shadow_only_last_batch` – evaluated in shadow-only mode
- `identity_promotion_run_timestamp_ms` – epoch ms of the last run
- `identity_promotion_run_age_ms` – age of the last run in ms

### Alert recommendations

- **Policy blocks**: `identity_promotions_blocked_policy_last_batch > 0` for 3 consecutive runs (PagerDuty) and WARN at 1 run. Indicates promotions are stuck on missing identifiers or thresholds.
- **Shadow backlog**: `identity_promotions_shadow_ready_last_batch > 0` while promotion shadow mode is enabled. Page if sustained for >30m; action is to enable auto-promotion or adjust policy.
- **Run staleness**: `identity_promotion_run_age_ms > 900000` (15 minutes) signals reconciliation is not running; WARN at 10 minutes.
- **Throughput dip**: `identity_promotions_last_batch == 0 AND identity_promotions_blocked_policy_last_batch > 0` for 2 runs suggests policy misconfiguration.
- **Volume surge**: sudden jump in `identity_promotions_attempted_last_batch` (>2x baseline) may indicate flood of sightings or replay; add a high-watermark alert tailored to environment.

### Dashboard panels

- Single-stat for the latest values of each gauge (attempted, promoted, eligible, shadow-ready, blocked).
- Time-series of `attempted`, `eligible`, `blocked` to spot trends after policy changes.
- Run age + last run timestamp side-by-side with a threshold line at 15 minutes.
- Breakdown table for blocked reasons (if/when exposed in metrics); until then, correlate with sighting UI “blockers” column.
