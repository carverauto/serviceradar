# Tasks — refactor-anomaly-engine-rigor

> Approval gate: do not start implementation until this proposal is approved.
> Coordination: land **after** `fix-anomaly-engine-semantics-and-delivery`'s F14 key
> alignment and F15 `profile_hour_of_week` feed deploy; **withdraw**
> `add-anomaly-finding-disposition` #4280 as superseded; build on
> `retire-uasb-causal-disposition`'s UASB naming pass; sequence the BREAKING wire-envelope
> rename (1f) with the BMP (`add-bmp-dual-path-observability`) and topology-overlay
> (`topology-causal-overlays`) producers.

## 0. Proof harness (cross-cutting; gates every later phase)

- [x] 0.1 Harness exists at `tools/anomaly-proof/{gen.py,plot.py}` driving the **real** `target/debug/anomaly-backtest` (built from `rust/anomaly-core/src/bin/anomaly-backtest.rs`); initial scorecard captured (spike/step/burst recall 1/1 @ ~4-sample latency, precision 1.0; recurring nightly 21/21; raw SNMP counter 6956 false alarms vs rate-normalized precision 1.0; drift+leak 0/1; single-blip 0/1).
- [x] 0.2 Generate synthetic **labeled** datasets: bounded percent gauges (cpu/mem/disk) + monotonic SNMP counters, with injected spike / step / drift / off-cycle anomalies and a counter wrap/reset (`gen.py`).
- [ ] 0.3 **Extend `anomaly-backtest`** to expose the `ReasonContext` fields currently hardcoded off (`seasonal_enabled`/`trend_enabled` = false; `min_std_floor`/`min_cv`/`saturation_gate` = None at `rust/anomaly-core/src/bin/anomaly-backtest.rs:124-139`) so the stability-gate, MAD, CUSUM, and seasonal requirements become harness-provable on real code.
- [ ] 0.4 **Add the core half**: run the **real** Elixir seasonal + capacity workers and the `causal_disposition` NIF against a local TimescaleDB CAGG / the `srql-fixtures` CNPG scratch DB (no production DB).
- [x] 0.5 Emit precision / recall / detection-latency scorecards + Twitter-AnomalyDetection Fig-2-style labeled-overlay plots (`plot.py` edge; `plot_seasonal.py` core; capacity scorecard via `disposition-backtest --kind capacity`).
- [ ] 0.6 Wire a scenario for **every** behavioral requirement in this change (honest-naming assertions excepted) so acceptance is harness-proven, not assertion-only.
- [ ] 0.7 Add a self-masking regression scenario (large spike then second spike) that scores recall under the chosen edge dispersion estimator.

## 1. Phase 1 — Honesty + correctness

### 1a. Strip cosmetic "causal" branding (detector/disposition layer)

- [ ] 1.1 Change the edge add-on `signal_type` stamp at `rust/anomaly-addon/src/verdict.rs:54` from `"causal"` to an honest statistical classification; update any consumers/queries that key on it (workspace-wide grep for `signal_type` and `"causal"`).
- [x] 1.2 The `causal-disposition` modules are already honestly named (`seasonal`/`capacity`); the `CausalFlow` hosting is now documented as a pipeline/state-machine combinator (NOT causal inference) across `anomaly-core` (lib/detector), `anomaly-addon` (engine), `causal-disposition` (lib), the NIF, and `CausalReasoner`. (The `causal-disposition` crate / `CausalReasoner` module identifier renames and the wire `signal_type` value are the BREAKING 1f task.)
- [x] 1.3 `rust/causal-engine` crate moduledoc rewritten as a deterministic dependency/expert-reasoning engine (hand-coded C1–C13 rules + ultragraph centrality/reachability; "causaloids" are largely identity nodes), explicitly NOT causal inference. (The wire `signals.causal.*` subject rename stays in 1f.)
- [x] 1.4 Causal-inference overclaim stripped from the engine code module-docs and the docs site (Phase 3); memory reflects the honest framing. (causal-engine's own docs are 1.3.)

### 1b. Honest capacity uncertainty (valid prediction intervals on both paths)

- [x] 1.5 **OLS prediction interval** (`half-width = Z·s·sqrt(1 + 1/n + (x0 - x̄)² / Sxx)`, widens with horizon, residual standard error `s` over `n-2` df). DONE in the Rust kernel `rust/causal-disposition/src/disposition/capacity/linear.rs` (`ols_prediction_bounds`); the worker calls it through the NIF (`worker.ex:368` is the call site, not the math).
- [x] 1.6 **Residual-bootstrap prediction interval** for the additive Holt-Winters path (off the hot path; bounded deterministic-seeded simulation re-injecting resampled in-sample residuals, 2.5/97.5 quantiles). DONE in `holt_winters.rs` (`bootstrap_prediction_bounds`).
- [x] 1.7 **Removed** the `clamp(1 - rmse/scale)` heuristic; `confidence` now carries the interval's nominal coverage level (`0.95`), web-ng relabeled "PI coverage". Parity gate updated (fit fields keep parity; band/confidence assert the new behaviour), plus a unit test (`ols_prediction_interval_widens_with_horizon`) and the harness (`disposition-backtest --kind capacity`) prove the OLS band widens with horizon (5.89→6.15 across 7d/30d/90d).

### 1f. BREAKING — on-the-wire de-causal envelope rename (D7; dual-publish + dual-consume)

- [ ] 1.f1 Add the honest new names alongside the old (versioned envelope): the verdict `signal_type` value (`rust/anomaly-addon/src/verdict.rs:54`), the NATS subject namespace (`signals.causal.predictions.*` → renamed), and the `SignalSchemaRef`/schema names.
- [ ] 1.f2 **Dual-publish** from every producer during the cutover: anomaly addon `verdict.rs`, the BMP producer (`add-bmp-dual-path-observability`), the topology-overlay producer (`topology-causal-overlays`).
- [ ] 1.f3 **Dual-consume** in every consumer (prefer new, accept old): `.../event_writer/processors/causal_signals.ex`, `rust/causal-engine` evidence consumer, web-ng.
- [ ] 1.f4 Migrate producers/consumers; add a zero-traffic verification step on the old subject/field; **drop** the old form only after verified zero traffic. Document rollback (revert the regressed side; old form stays live until the verified drop).

### 1c. Close the matched-resolution disposition loop (absorbs #4280)

- [x] 1.8 Edge ALREADY forwards spike **peak + window** (`verdict.rs:108-111`: episode_peak_value / episode_peak_at / episode_started_at / episode_ended_at) — verified, no change needed.
- [x] 1.9 The **peak variant** of `profile_hour_of_week` over `timeseries_metrics_hourly.max_value` ALREADY EXISTS (`build_profile_hour_of_week_peak_query`, `rust/srql/src/query/timeseries_metrics.rs:1219`) — verified, no change needed.
- [ ] 1.10 Seasonal worker records a verdict for **every** evaluated series/window (non-surfacing `normal`).
- [ ] 1.11 Build the disposition correlation at the alert/query layer (`stateful_alert_engine.ex`, `alert_generator.ex`, web-ng device-detail panel) on the F14-aligned `series_key`; retain raw findings.
- [ ] 1.12 Implement the robust peak-profile stability gate (invariants in spec), suppression **report-only** behind a per-metric-class kill switch; report suppression-eligible-mass coverage.
- [ ] 1.13 Disposition-driven effective severity (suppress→off-path, downgrade→lower, escalate→higher).
- [ ] 1.14 Add the load-bearing test asserting edge `series_key` == central `series_key` after F14 re-key (precondition for the join).

### 1d. Robust seasonal statistic + hysteresis

- [x] 1.15 Seasonal robust statistic defaults to `median + MAD`: the live cpu/memory sources were already `:median_mad`; the `Source` struct default + the `from_config` fallback (`source.ex`) now default to `:median_mad` too (the profile verb supplies center/mad). (Peak-profile robust IQR scale lands with the 1c loop.)
- [x] 1.16 Core seasonal `confirm_slots` is tunable (operator-overridable) and supports `> 1`; **default = 2** — Rust `SeasonalConfig` default + Elixir `@default_confirm_slots` (D-Q3). Hysteresis verified: `drift_pending_until_confirm_slots_met`; the e2e escalation test pins `confirm_slots: 1` for the single-bucket immediate-breach case.

### 1e. Dead code + stale docs

- [x] 1.17 `peak_profile` kernel unambiguously marked DORMANT/not-wired (no NIF ABI), with the marker now pointing at the matched-resolution loop closure (1c) that will wire it. Kept rather than deleted because that wiring is the next step.
- [x] 1.18 Corrected the false "capacity phase 2 — NOT yet wired" doc in the NIF (`causal_disposition_nif/src/lib.rs:46`); capacity is live and wired (`dispose_batch(:capacity, ...)`).
- [x] 1.19 Write the "what the engine really is" document (robust detector + seasonal/forecast disposition + deterministic dependency expert system).

## 2. Phase 2 — Statistical rigor

### 2a. Edge

- [ ] 2.1 Implement **both** robust **median/MAD (Hampel)** dispersion AND the breach-freeze fallback in `rust/anomaly-core` (`stats.rs`/`detector.rs`); let the harness self-masking recall pick the default (design D-Q2, harness-driven). Preserve floors + saturation gate + confirm-slot hysteresis (do not re-author F17).
- [x] 2.2 **Two-sided CUSUM** primitive implemented + unit-tested in `rust/anomaly-core/src/cusum.rs` (anchored, reset-on-alarm; ETA ≈ h/(δ−k)) and wired into `anomaly-backtest --cusum`. HARNESS-PROVEN: it catches the CPU drift the rolling z-score structurally misses (z-score 0/300 → CUSUM 216/300, +20-sample latency). MUST run on the deseasonalized residual (raw CUSUM floods 42–74% FP on seasonal data — measured). Production wiring into the addon/`ReasonContext` path is the deployment follow-up.
- [~] 2.3 Edge **deseasonalization** demonstrated in the harness (CUSUM over a causal hour-of-week residual): drops CUSUM FP to **1.4–2.4%** (cpu/snmp). FINDING: a *persistent* leak pollutes a NAÏVE causal-mean edge baseline (memory 54% FP) → the production design must use the robust core-pushed seasonal profile (2.6: latest-excluded, trailing window), not a naïve edge mean. anomaly-core/`ReasonContext` integration follows.
- [~] 2.4 Harness now measures slow-leak/drift **detection-latency** (+20/+31 samples) and CUSUM **false-positive rate** per series; the self-masking (0.7) and morning-ramp FP scenarios still to add.

### 2b. Core

- [ ] 2.5 Adopt **S-H-ESD** (STL/MSTL + median/MAD ESD on residual) as the primary seasonal validator.
- [ ] 2.6 Make the S-H-ESD profile the **source of the coarse hour-of-week baseline pushed to the edge** (feeds 2.3).
- [ ] 2.7 Add the optional, feature-flagged, off-hot-path **RPCA** layer — **V1 = single-series hour-of-week reshape only** (host-stacked fleet matrix is a follow-on; design D-Q4); default disabled.
- [ ] 2.8 Keep Holt-Winters strictly for capacity forecasting (no repurposing as the seasonal validator).
- [ ] 2.9 Harness: S-H-ESD precision/recall vs the current residual-z; RPCA fleet-correlated detection.

## 3. Phase 3 — Documentation overhaul (single source of truth)

- [ ] 3.1 Clean up stale/overclaiming anomaly docs across the repo: strip the "causal" framing and any causal-inference assertion from engine code module-docs/comments (`rust/anomaly-core`, `rust/anomaly-addon`, `rust/causal-disposition`, `rust/causal-engine`, `causal_disposition_nif`, Elixir `observability` modules) and the docs site. Do **not** rewrite other proposals' archived history.
- [x] 3.2 Author the new end-to-end engine doc set under `docs/docs/` (the single source of truth) and register it in `docs/sidebars.ts`, covering: two-tier architecture (edge robust spike detector + core seasonal/capacity disposition + deterministic dependency expert system); data contract (gauges vs monotonic counters, rate normalization, counter wrap/reset, directional saturation gate, series keying); actual statistics (rolling robust z-score; hour-of-week residual-z / S-H-ESD; OLS + Holt-Winters capacity); honest naming (what is and is NOT causal); the disposition loop; operations/tuning knobs; how to run the proof harness (`tools/anomaly-proof`).
- [x] 3.3 Overhauled the stale `docs/docs/anomaly-detection.md` (retitled "Anomaly Detection (Tuning & Operations)", points to the new engine doc, dropped the duplicated stale section; operator content preserved).

## 4. Validation, coordination + rollout

- [ ] 4.1 Phase 1 first; suppression report-only; verify on the proof harness before any suppression is enabled live.
- [ ] 4.2 Phase 2 behind per-metric-class kill switches; calibrate constants against real per-cell distributions guarded by the invariant tests.
- [ ] 4.3 Confirm no `signal_type:"causal"` remains on a statistical verdict (workspace-wide grep) and no causal-inference claim remains in code docs or the docs site; confirm zero traffic on the old envelope subject/field before dropping it (1f4).
- [ ] 4.4 **Close `add-anomaly-finding-disposition` #4280 as superseded** by this change (decided), pointing its archive/withdrawal note at this change as the consolidation of record.
- [ ] 4.5 `openspec validate refactor-anomaly-engine-rigor --strict` passes.
