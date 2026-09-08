# Tasks — anomaly finding disposition

## 0. Decision gate (RESOLVED)
- [x] 0.1 Resolution model **ratified: Option B** — matched-resolution peak disposition (edge forwards peak+window; core builds a peak profile from the existing `max_value` and judges the spike against it). The intended rollout model is per metric class behind a peak-profile stability gate; cold-start/uncovered classes fall through to edge-governed pass-through. Recorded in `design.md`.

## 1. Soundness + liveness (precede trusting disposition)
- [x] 1.1 Switch the default seasonal sources from `:mean_stddev` to `:median_mad` (`seasonal_disposition/source.ex`); add a test that a single past-incident hour in a 5-sample cell does not poison the baseline.
- [x] 1.2 Add a `dispose_batch` NIF liveness assertion at worker start/health (`worker.ex`): a missing/retired NIF surfaces a degraded-mode signal, not a silent `{:error}→dropped`. Test the degraded path emits the signal.
- [x] 1.3 Emit a disposition coverage metric: count of series seasonally covered vs `:insufficient_seasonal_baseline`, so "seasonal is working" is measured.

## 2. Make a verdict exist to join
- [x] 2.1 `surfaces?/3` (`worker.ex:534`) / verdict emission: persist a non-surfacing `:normal` disposition record for every evaluated series+window (keyed by canonical `series_key`), not only `{:seasonal_breach}`/`:suppress`. Keep it cheap (no alert, no class_uid=2004 surface).
- [x] 2.2 Prove the join key: add a test asserting edge `series_key` == central `series_key` **after** canonical re-key (`causal_signals.ex:1410`). This is the precondition for any disposition firing.

## 3. Disposition correlation (alert/query layer)
- [ ] 3.1 Implement the disposition function (depends on §6 peak profile): given an edge-spike finding carrying its forwarded peak, judge the peak against the peak profile for the matching `(dow, hod)` cell and return `suppress | downgrade | escalate | pass_through` per the Option B quadrant table (peak above profile → escalate; peak within → suppress/downgrade; insufficient peak history → pass-through). Sustained drift (no spike, hourly mean off-baseline) uses the mean profile.
- [ ] 3.2 Teach `stateful_alert_engine.ex` `verdict_source` + apply the disposition before opening an alert (suppress/downgrade/escalate/pass-through). Dedup/coalesce per canonical series with the existing cooldown — one ongoing condition = one alert.
- [ ] 3.3 Surface the disposition in the web-ng device-detail anomaly panel (suppressed/downgraded/escalated/pass-through) instead of raw severity.
- [ ] 3.4 Tests: each quadrant; cold-start/insufficient-peak-history pass-through; recurring spike (peak within profile) → suppressed; novel spike (peak above profile) → escalated; sustained drift surfaced via the mean profile.

## 4. Metric-class scoping
- [x] 4.1 Restrict the seasonal sources to sustained host metrics (`cpu`, `mem` usage).
- [x] 4.2 Route `disk usage_percent` disposition to the capacity forecaster (Tier B), not the seasonal tier.
- [x] 4.3 SNMP interface / sysmon counter series: edge-only, no seasonal coverage claimed; disposition = pass-through with calibrated severity.

## 5. Non-edge flood drivers — DEFERRED to fix-anomaly (no work here)
- [x] 5.1 capacity_forecasting `event_id` idempotency → owned by `fix-anomaly-engine-semantics-and-delivery` **F12 (tasks 10.1, 12.4, done)**; relief ships with that deploy, not here.
- [x] 5.2 severity calibration (raw detector→finding/alert severity) → owned by fix-anomaly **task 23.4**; this proposal only sets *disposition-driven effective* severity (suppress/downgrade/escalate), per the spec.
- [x] 5.3 per-series debounce / one-ongoing-condition-one-alert → owned by fix-anomaly **task 23.2**. Removed from this proposal to avoid double-fixing the same flood.

## 6. Peak profile — matched-resolution robust disposition gate (Option B core; prerequisite for §3)
- [x] 6.1 Edge: forward **peak magnitude + spike window** in the finding payload (the detector already computes both).
- [x] 6.2a SRQL: implement the peak variant of `profile_hour_of_week` (`profile_hour_of_week_peak`) over `timeseries_metrics_hourly.max_value`, emitting per-`(series, hod)` cell `n, median, (p95−p05)·0.30398, q95` **and** the per-series prior. Covered by `sfw cargo test -p srql profile_hour_of_week -- --nocapture`.
- [ ] 6.2b Validate on demo that the generated `profile_hour_of_week_peak` SQL runs read-only and has sufficient warm-cell coverage before activation.
- [ ] 6.3 Core: implement the robust peak-profile disposition module on `deep_causality_core::CausalFlow` (**NOT** `Uncertain<T>`, and not branded as UASB).
- [ ] 6.4 Gate per the **salvaged invariants**: two-sided; inner scale `min(s_cell, CAP·s_prior)` (poison-bounded); per-series prior; sigma-relative `1+A/√n`; cold / over-dispersed / ceiling-proximity → pass-through; suppress does **not** reset the confirm-slot counter (leaky-bucket decay). Include the report-only kill switch.
- [ ] 6.5 **Invariant test suite** — kernel+flow tests for I1, I2, I4–I8; I3 enforced + validated in SQL; I7 = the oscillating-anomaly leaky-bucket proof.
- [ ] 6.6a Ship suppression **disabled (report-only)** by default in the kernel; the kernel records the trajectory for calibration but surfaces nothing until activation.
- [ ] 6.6b Calibrate initial constants from demo per-cell distributions before activation; full `A/Z_sup/Z_esc/CAP/N_min/D` tuning continues against production data, kept safe by the report-only gate until signed off. The invariants are safe a priori; the constants are not.

> Remaining for activation: demo validation/calibration, the core Oban peak worker (querying `profile_hour_of_week_peak`, calling the disposition kernel, round-tripping the confirm counter), and the alert/query-layer disposition join. Do not add a `:peak` NIF ABI until the kernel boundary is settled against the causal-context design.

## 7. Verification (prove it on the live system)
- [ ] 7.1 Live re-trace on demo after deploy: assert one OPEN + one CLEAR per episode (no per-sample), capacity_forecasting dedup holds, Critical share normalized, and disposition coverage > 0 for covered series.
- [ ] 7.2 Confirm the deployed seasonal NIF is the live `dispose_batch`, not the retired `causal_reasoner_nif` (runtime, not branch).
