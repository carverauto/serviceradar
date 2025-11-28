# Identity Reconciliation Alert Rules (Prometheus examples)

Use the gauges from `identity-metrics.md` to wire alerts. Replace label selectors to match your OTEL→Prometheus pipeline (or the Prometheus `/metrics` bridge when enabled via the monitoring bridge change).

```yaml
groups:
  - name: identity-reconciliation
    rules:
      # Promotion blocked by policy (missing hostname/fingerprint/persistence)
      - alert: IdentityPromotionPolicyBlocked
        expr: identity_promotions_blocked_policy_last_batch > 0
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "Identity promotions blocked by policy"
          description: "Latest reconciliation batch had {{ $value }} policy-blocked sightings. Investigate promotion thresholds or missing identifiers."

      # Shadow backlog — promotions ready but shadow mode prevents attach
      - alert: IdentityPromotionShadowBacklog
        expr: identity_promotions_shadow_ready_last_batch > 0
        for: 30m
        labels:
          severity: warning
        annotations:
          summary: "Shadow backlog accumulating"
          description: "Shadow mode sees {{ $value }} policy-ready sightings. Enable auto-promotion or relax policy if appropriate."

      # Reconciliation stalled
      - alert: IdentityPromotionStalled
        expr: identity_promotion_run_age_ms > 900000
        for: 15m
        labels:
          severity: critical
        annotations:
          summary: "Identity reconciliation not running"
          description: "Last promotion run older than {{ $value }} ms. Check core scheduler/reaper health."

      # Zero promotions with blocks
      - alert: IdentityPromotionThroughputDrop
        expr: (identity_promotions_last_batch == 0) and (identity_promotions_blocked_policy_last_batch > 0)
        for: 20m
        labels:
          severity: warning
        annotations:
          summary: "Promotions halted due to policy"
          description: "No promotions are occurring while policy blocks persist. Likely misconfiguration or missing identifiers."

      # Surge detection
      - alert: IdentityPromotionVolumeSurge
        expr: identity_promotions_attempted_last_batch > (2 * clamp_min(identity_promotions_attempted_last_batch offset 1h, 1))
        for: 10m
        labels:
          severity: info
        annotations:
          summary: "Sighting volume surge"
          description: "Attempted promotions jumped above 2x the 1h baseline. Check for replay or discovery floods."

      # Drift over baseline (50k demo default; adjust per env)
      - alert: IdentityDriftExceeded
        expr: identity_cardinality_drift_percent > 3
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "Identity drift above tolerance"
          description: "Device inventory is {{ printf \"%.0f\" $value }}%% over baseline. Check faker inputs, promotion policy, and blocked merges."

      # Promotion paused because drift guard is on
      - alert: IdentityPromotionPausedOnDrift
        expr: identity_cardinality_blocked == 1
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "Identity promotion paused due to drift"
          description: "Promotion is paused because drift exceeded tolerance. Review baseline, unblock intentional growth, or investigate duplicate strong IDs."

      # Missing scrapes (bridge or OTEL pipeline broken/disabled)
      - alert: IdentityMetricsMissing
        expr: absent(identity_promotions_attempted_last_batch)
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Identity metrics not present"
          description: "Prometheus cannot find identity promotion metrics. Confirm identity reconciliation is enabled and `/metrics` is being scraped via OTEL bridge."
```

### Dashboard suggestions
- Single-stat panels for attempted, promoted, eligible-auto, shadow-ready, blocked-policy.
- Time-series for attempted/promoted/blocked to visualize trends after policy changes.
- Run age/timestamp side by side with a 15m threshold line.
- Drift panels: `identity_cardinality_drift_percent` with tolerance lines and a single-stat for `identity_cardinality_blocked`.
