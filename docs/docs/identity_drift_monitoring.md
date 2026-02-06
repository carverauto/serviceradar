# Identity Drift Monitoring & Alerts

Use the identity reconciliation gauges to detect device cardinality drift and pause or investigate promotions before inventory balloons.

## Metrics
- `identity_cardinality_current` – current unified device count from the drift check.
- `identity_cardinality_baseline` – baseline used for drift computation.
- `identity_cardinality_drift_percent` – percentage drift vs baseline (positive is over).
- `identity_cardinality_blocked` – 1 when promotion is paused due to drift.

## Example Prometheus Rules
```yaml
groups:
  - name: identity-drift
    rules:
      - record: serviceradar:identity_cardinality_drift_over_baseline
        expr: max by (job) (identity_cardinality_drift_percent) > 0
      - alert: IdentityDriftExceeded
        expr: serviceradar:identity_cardinality_drift_over_baseline > 0
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "Identity drift exceeded baseline on {{ $labels.job }}"
          description: |
            Device count is {{ printf "%.0f" $value }}%% over baseline for >10m.
            Check identity reconciliation settings and promotion backlog.
      - alert: IdentityPromotionPaused
        expr: max by (job) (identity_cardinality_blocked) == 1
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "Identity promotion paused on {{ $labels.job }}"
          description: |
            Promotion blocked due to drift (baseline {{ printf "%.0f" identity_cardinality_baseline }}).
            Investigate cardinality growth, tuner settings, and upstream inventory sources.
```

## Operational Guidance
- Set `core.identity.drift.baselineDevices` to your expected strong-ID cardinality, and set `tolerancePercent` to allow minor fluctuations.
- Keep `pauseOnDrift` enabled in labs; in production, pair alerts with an incident playbook before disabling pause.
- Correlate with `identity_cardinality_blocked` and promotion run metrics (`identity_promotions_*`) to see if drift coincides with blocked promotions.
- If drift is intentional (e.g., temporary load), raise baseline and restart core with updated config; otherwise, investigate embedded sync sources, discovery, and onboarding for duplicate strong IDs or promotion misconfiguration.
- If scraping via the Prometheus bridge, confirm `/metrics` is enabled on core and scraped successfully before trusting drift alerts.
