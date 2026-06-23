# Tasks — anomaly finding disposition

## 0. Decision gate (blocks everything below)
- [ ] 0.1 Ratify the resolution model: **Option A** (reconcile-where-comparable, V1) vs **Option B** (edge forwards peak+window, core disposes the spike). Record the decision in `design.md`. Default recommendation: A now, B as a per-metric-class follow-on.

## 1. Soundness + liveness (precede trusting disposition)
- [ ] 1.1 Switch the three default seasonal sources from `:mean_stddev` to `:median_mad` (`seasonal_disposition/source.ex:82,103,116`); add a test that a single past-incident hour in a 5-sample cell does not poison the baseline.
- [ ] 1.2 Add a `dispose_batch` NIF liveness assertion at worker start/health (`worker.ex:341-356`): a missing/retired NIF surfaces a degraded-mode signal, not a silent `{:error}→dropped`. Test the degraded path emits the signal.
- [ ] 1.3 Emit a disposition coverage metric: count of series seasonally covered vs `:insufficient_seasonal_baseline`, so "seasonal is working" is measured.

## 2. Make a verdict exist to join
- [ ] 2.1 `surfaces?/3` (`worker.ex:534`) / verdict emission: persist a non-surfacing `:normal` disposition record for every evaluated series+window (keyed by canonical `series_key`), not only `{:seasonal_breach}`/`:suppress`. Keep it cheap (no alert, no class_uid=2004 surface).
- [ ] 2.2 Prove the join key: add a test asserting edge `series_key` == central `series_key` **after** canonical re-key (`causal_signals.ex:1410`). This is the precondition for any disposition firing.

## 3. Disposition correlation (alert/query layer)
- [ ] 3.1 Implement the disposition function: given an edge-spike finding, look up the overlapping central-seasonal disposition by `(canonical series_key, time window)` and return `suppress | downgrade | escalate | pass_through` per the **ratified** quadrant table (Option A V1: never suppress a short spike on hourly evidence).
- [ ] 3.2 Teach `stateful_alert_engine.ex` `verdict_source` + apply the disposition before opening an alert (suppress/downgrade/escalate/pass-through). Dedup/coalesce per canonical series with the existing cooldown — one ongoing condition = one alert.
- [ ] 3.3 Surface the disposition in the web-ng device-detail anomaly panel (suppressed/downgraded/escalated/pass-through) instead of raw severity.
- [ ] 3.4 Tests: each quadrant; cold-start pass-through; "real short spike + seasonally-normal hour → NOT suppressed" (the unsound quadrant is barred).

## 4. Metric-class scoping
- [ ] 4.1 Restrict the seasonal sources to sustained host metrics (`cpu`, `mem` usage).
- [ ] 4.2 Route `disk usage_percent` disposition to the capacity forecaster (Tier B), not the seasonal tier.
- [ ] 4.3 SNMP interface / sysmon counter series: edge-only, no seasonal coverage claimed; disposition = pass-through with calibrated severity.

## 5. Non-edge flood completion (distinct from the edge gate)
- [ ] 5.1 Fix capacity_forecasting `event_id` idempotency — stop splicing per-run wall-clock into the id so the `(id, time)` upsert dedups re-runs. Add a test that two runs of the same forecast produce one row. Measure 2004 volume before/after.
- [ ] 5.2 Add severity calibration: map raw z/deviation score → bounded OCSF severity buckets for `class_uid=2004` findings. Test the mapping; confirm Critical share drops from ~77%.
- [ ] 5.3 Add a core-side `(device, series_key)` debounce safety net: collapse repeats of an ongoing condition into one open finding with updated state (the `(id, time)` upsert cannot catch distinct-timestamp per-slot emission).

## 6. Option B (only if 0.1 selects it; per-metric-class, gated)
- [ ] 6.1 Edge: forward peak magnitude + spike window in the finding payload.
- [ ] 6.2 SRQL: add `profile_hour_of_week_p95`/`_max` (peak profile) + the supporting aggregate/CAGG.
- [ ] 6.3 Core: dispose the spike against the peak profile; enable per-metric-class only after the peak profile is shown stable. Tests for a recurring nightly spike → suppressed; a novel spike → escalated.

## 7. Verification (prove it on the live system)
- [ ] 7.1 Live re-trace on demo after deploy: assert one OPEN + one CLEAR per episode (no per-sample), capacity_forecasting dedup holds, Critical share normalized, and disposition coverage > 0 for covered series.
- [ ] 7.2 Confirm the deployed seasonal NIF is the live `dispose_batch`, not the retired `causal_reasoner_nif` (runtime, not branch).
