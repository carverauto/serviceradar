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

## 5. Non-edge flood completion (distinct from the edge gate)
- [ ] 5.1 Fix capacity_forecasting `event_id` idempotency — stop splicing per-run wall-clock into the id so the `(id, time)` upsert dedups re-runs. Add a test that two runs of the same forecast produce one row. Measure 2004 volume before/after.
- [ ] 5.2 Add severity calibration: map raw z/deviation score → bounded OCSF severity buckets for `class_uid=2004` findings. Test the mapping; confirm Critical share drops from ~77%.
- [ ] 5.3 Add a core-side `(device, series_key)` debounce safety net: collapse repeats of an ongoing condition into one open finding with updated state (the `(id, time)` upsert cannot catch distinct-timestamp per-slot emission).

## 6. Peak profile — matched-resolution disposition (Option B core; prerequisite for §3)
- [ ] 6.1 Edge: forward **peak magnitude + spike window** in the finding payload (the detector already computes both).
- [ ] 6.2 SRQL: add a peak variant of `profile_hour_of_week` over the existing `timeseries_metrics_hourly.max_value` (robust aggregate — median+MAD of per-hour maxima per `(series, dow, hod)`). No new CAGG/schema — `max_value` already exists.
- [ ] 6.3 Core: build the peak profile and dispose an edge spike by judging its forwarded peak against the peak profile for the matching `(dow, hod)` cell.
- [ ] 6.4 Per-**cell** stability gate (concrete criteria in design.md): dispose a spike only if its `(series, dow, hod)` cell passes depth (`min_cell_weeks`=6) + recency (`max_cell_staleness_weeks`=2) + bounded dispersion (`max_cell_dispersion`=0.5); else pass-through. Implement the conservative suppression band (`m + k_suppress·D` / `k_escalate·D`, defaults 3 / 6, `mad_floor`=0.05), all configurable. Add the per-class kill switch + a per-class coverage metric (fraction of active cells stable).
- [ ] 6.5 Tests: insufficient cell depth → pass-through; erratic cell (dispersion over bound) → not suppressed; recurring spike (peak within `k_suppress·D`) → suppressed; ambiguous (between bands) → downgraded, not silenced; novel spike (peak over `k_escalate·D`) → escalated.
- [ ] 6.6 Calibrate `max_cell_dispersion`, `k_suppress`, `k_escalate`, `mad_floor` against real per-cell peak distributions before enabling suppression in production (depth/recency are safe a priori; the dispersion bound + suppression band are data-dependent). Until calibrated, ship suppression disabled (kill switch) and report coverage only.

## 7. Verification (prove it on the live system)
- [ ] 7.1 Live re-trace on demo after deploy: assert one OPEN + one CLEAR per episode (no per-sample), capacity_forecasting dedup holds, Critical share normalized, and disposition coverage > 0 for covered series.
- [ ] 7.2 Confirm the deployed seasonal NIF is the live `dispose_batch`, not the retired `causal_reasoner_nif` (runtime, not branch).
