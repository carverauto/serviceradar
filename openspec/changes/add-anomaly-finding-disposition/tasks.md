# Tasks — anomaly finding disposition

## 0. Decision gate (RESOLVED)
- [x] 0.1 Resolution model **ratified: Option B** — matched-resolution peak disposition (edge forwards peak+window; core builds a peak profile from the existing `max_value` and judges the spike against it). Rolled out per metric class behind a peak-profile stability gate; cold-start/uncovered classes fall through to edge-governed pass-through. Recorded in `design.md`.

## 1. Soundness + liveness (precede trusting disposition)
- [ ] 1.1 Switch the three default seasonal sources from `:mean_stddev` to `:median_mad` (`seasonal_disposition/source.ex:82,103,116`); add a test that a single past-incident hour in a 5-sample cell does not poison the baseline.
- [ ] 1.2 Add a `dispose_batch` NIF liveness assertion at worker start/health (`worker.ex:341-356`): a missing/retired NIF surfaces a degraded-mode signal, not a silent `{:error}→dropped`. Test the degraded path emits the signal.
- [ ] 1.3 Emit a disposition coverage metric: count of series seasonally covered vs `:insufficient_seasonal_baseline`, so "seasonal is working" is measured.

## 2. Make a verdict exist to join
- [ ] 2.1 `surfaces?/3` (`worker.ex:534`) / verdict emission: persist a non-surfacing `:normal` disposition record for every evaluated series+window (keyed by canonical `series_key`), not only `{:seasonal_breach}`/`:suppress`. Keep it cheap (no alert, no class_uid=2004 surface).
- [ ] 2.2 Prove the join key: add a test asserting edge `series_key` == central `series_key` **after** canonical re-key (`causal_signals.ex:1410`). This is the precondition for any disposition firing.

## 3. Disposition correlation (alert/query layer)
- [ ] 3.1 Implement the disposition function (depends on §6 peak profile): given an edge-spike finding carrying its forwarded peak, judge the peak against the peak profile for the matching `(dow, hod)` cell and return `suppress | downgrade | escalate | pass_through` per the Option B quadrant table (peak above profile → escalate; peak within → suppress/downgrade; insufficient peak history → pass-through). Sustained drift (no spike, hourly mean off-baseline) uses the mean profile.
- [ ] 3.2 Teach `stateful_alert_engine.ex` `verdict_source` + apply the disposition before opening an alert (suppress/downgrade/escalate/pass-through). Dedup/coalesce per canonical series with the existing cooldown — one ongoing condition = one alert.
- [ ] 3.3 Surface the disposition in the web-ng device-detail anomaly panel (suppressed/downgraded/escalated/pass-through) instead of raw severity.
- [ ] 3.4 Tests: each quadrant; cold-start/insufficient-peak-history pass-through; recurring spike (peak within profile) → suppressed; novel spike (peak above profile) → escalated; sustained drift surfaced via the mean profile.

## 4. Metric-class scoping
- [ ] 4.1 Restrict the seasonal sources to sustained host metrics (`cpu`, `mem` usage).
- [ ] 4.2 Route `disk usage_percent` disposition to the capacity forecaster (Tier B), not the seasonal tier.
- [ ] 4.3 SNMP interface / sysmon counter series: edge-only, no seasonal coverage claimed; disposition = pass-through with calibrated severity.

## 5. Non-edge flood drivers — DEFERRED to fix-anomaly (no work here)
- [x] 5.1 capacity_forecasting `event_id` idempotency → owned by `fix-anomaly-engine-semantics-and-delivery` **F12 (tasks 10.1, 12.4, done)**; relief ships with that deploy, not here.
- [x] 5.2 severity calibration (raw detector→finding/alert severity) → owned by fix-anomaly **task 23.4**; this proposal only sets *disposition-driven effective* severity (suppress/downgrade/escalate), per the spec.
- [x] 5.3 per-series debounce / one-ongoing-condition-one-alert → owned by fix-anomaly **task 23.2**. Removed from this proposal to avoid double-fixing the same flood.

## 6. Peak profile — matched-resolution disposition + UASB gate (Option B core; prerequisite for §3)
- [ ] 6.1 Edge: forward **peak magnitude + spike window** in the finding payload (the detector already computes both).
- [ ] 6.2 SRQL: add a peak variant of `profile_hour_of_week` over the existing `timeseries_metrics_hourly.max_value` emitting per-`(series, hod)` cell `n, median, (p95−p05), q05, q95` **and** the `(series, hod)`-localized prior (collapse only DOW; ±1-hour-neighbor then metric-class fallback). No new CAGG/schema — `max_value` exists; materialize the prior as a daily-refreshed table.
- [ ] 6.3 Core: implement UASB as a **disposition causaloid in `rust/causal-disposition`** (already on `deep_causality_core`). O(1) scalar decision over the SQL-precomputed robust stats — **NOT** `deep_causality_uncertain`/`Uncertain<T>` Monte-Carlo (wrong compute model + reintroduces non-robust variance; see design.md "Implementation substrate").
- [ ] 6.4 UASB gate per the **invariants** (design.md): two-sided bands; inner scale `min(s_cell, CAP·s_prior)` (poison-bounded); `(series,hod)`-localized prior; sigma-relative `1+A/√n` inflation (no additive floor); cold / over-dispersed / ceiling-proximity → pass-through; suppress does **not** reset the confirm-slot counter. Per-class kill switch + coverage metric (suppression-eligible mass).
- [ ] 6.5 **Invariant test suite** (each test = the adversarial scenario that established it): (I1) downward anomaly escalates; (I2) poisoned thin cell can't widen the suppress band → real spike escalates; (I3) quiet hour not whitewashed by a spiky neighbor (prior localized); (I4) tight near-100% cell passes through, never a >100% band; (I5) over-dispersed cell passes through; (I6) cold cell passes through; (I7) suppress doesn't reset confirm-slot; (I8) every uncertain path → pass-through/escalate, never suppress.
- [ ] 6.6 Calibrate `A, Z_sup, Z_esc, CAP, N_min, D`, saturation thresholds against real per-cell distributions before enabling suppression in production. Ship suppression **disabled (report-only)** until calibrated + the invariant suite is green; the invariants are safe a priori, the constants are not.

## 7. Verification (prove it on the live system)
- [ ] 7.1 Live re-trace on demo after deploy: assert one OPEN + one CLEAR per episode (no per-sample), capacity_forecasting dedup holds, Critical share normalized, and disposition coverage > 0 for covered series.
- [ ] 7.2 Confirm the deployed seasonal NIF is the live `dispose_batch`, not the retired `causal_reasoner_nif` (runtime, not branch).
