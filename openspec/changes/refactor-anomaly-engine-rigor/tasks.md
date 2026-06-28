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
- [x] 0.7 Self-masking scenario added (`gen.py` double-spike `selfmask_a`/`selfmask_b`) and scored: the second spike is DETECTED (z=17.1, recall 1/1) — the withhold-from-baseline rule keeps the first spike's samples out of the window, so it does not inflate the baseline std.

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

- [~] 1.f1 Producer-side honest naming added ALONGSIDE the old (additive, non-breaking): the anomaly verdict now emits `detector_method: "rolling_robust_zscore"` next to the legacy routing `signal_type:"causal"` (`rust/anomaly-addon/src/verdict.rs`, 73 tests green). The NATS subject + `SignalSchemaRef` rename and the BMP/topology producers' matching dual-publish (1.f2) are the coordinated breaking parts (the value rename needs dual-consume 1.f3 first).
- [ ] 1.f2 **Dual-publish** from every producer during the cutover: anomaly addon `verdict.rs`, the BMP producer (`add-bmp-dual-path-observability`), the topology-overlay producer (`topology-causal-overlays`).
- [ ] 1.f3 **Dual-consume** in every consumer (prefer new, accept old): `.../event_writer/processors/causal_signals.ex`, `rust/causal-engine` evidence consumer, web-ng.
- [ ] 1.f4 Migrate producers/consumers; add a zero-traffic verification step on the old subject/field; **drop** the old form only after verified zero traffic. Document rollback (revert the regressed side; old form stays live until the verified drop).

### 1c. Close the matched-resolution disposition loop (absorbs #4280)

- [x] 1.8 Edge ALREADY forwards spike **peak + window** (`verdict.rs:108-111`: episode_peak_value / episode_peak_at / episode_started_at / episode_ended_at) — verified, no change needed.
- [x] 1.9 The **peak variant** of `profile_hour_of_week` over `timeseries_metrics_hourly.max_value` ALREADY EXISTS (`build_profile_hour_of_week_peak_query`, `rust/srql/src/query/timeseries_metrics.rs:1219`) — verified, no change needed.
- [~] 1.10 RESOLVED BY DESIGN (matched-resolution Option B): the disposition is computed ON DEMAND from the queryable hour-of-week PEAK profile (the F19 `profile_hour_of_week_peak` verb) when an edge finding arrives — so the central need NOT emit a verdict for every evaluated series (which would flood `ocsf_events`, the very thing this change fixes). The seasonal worker keeps emitting only its own breach/clear verdicts; the on-demand peak-profile lookup is part of the alert-engine wiring (with 1.11). Re-open only if a verdict-stream join (vs on-demand query) is later required.
- [~] 1.11 The matched-resolution disposition correlation LOGIC is implemented + unit-tested (`ServiceRadar.Observability.AnomalyDisposition.dispose/3`, 8 tests green): given an edge spike's forwarded peak + the central hour-of-week PEAK profile it returns suppress/downgrade/escalate/pass_through (compares peak-vs-peak, not the diluting hourly mean). The alert/query-layer WIRING (call it in `stateful_alert_engine.ex`/`alert_generator.ex` + the device-detail panel, joined on the F14-aligned `series_key`, raw findings retained) follows.
- [~] 1.12 The peak-profile stability gate + report-only kill switch is implemented + tested (`AnomalyDisposition.actionable?/2`): suppression is OFF by default (report-only is the safety default), gated on peak-profile stability (`>= :min_stable_samples` + finite center/scale) and a per-metric-class `:suppression_enabled` flag. The suppression-eligible-mass telemetry is the consumer wiring.
- [~] 1.13 The disposition decision (suppress→off-path / downgrade→lower / escalate→higher / pass_through) is the `AnomalyDisposition.dispose/3` output (operator-tunable thresholds); applying it to a finding's effective severity in the alert engine is the consumer wiring (follows with 1.11).
- [x] 1.14 Edge↔central series_key alignment test added + PASSING (`series_key_test.exs`, 11 tests green): the same logical series re-keys identically regardless of the provisional producer hints the edge varies (agent_id/host_id/host_ip and the `host` tag are excluded; the canonical resource + metric + if_index + partition decide the key). The precondition for the join. (Existing F14 tests already covered device_id-over-host/agent canonicalization.)

### 1d. Robust seasonal statistic + hysteresis

- [x] 1.15 Seasonal robust statistic defaults to `median + MAD`: the live cpu/memory sources were already `:median_mad`; the `Source` struct default + the `from_config` fallback (`source.ex`) now default to `:median_mad` too (the profile verb supplies center/mad). (Peak-profile robust IQR scale lands with the 1c loop.)
- [x] 1.16 Core seasonal `confirm_slots` is tunable (operator-overridable) and supports `> 1`; **default = 2** — Rust `SeasonalConfig` default + Elixir `@default_confirm_slots` (D-Q3). Hysteresis verified: `drift_pending_until_confirm_slots_met`; the e2e escalation test pins `confirm_slots: 1` for the single-bucket immediate-breach case.

### 1e. Dead code + stale docs

- [x] 1.17 `peak_profile` kernel unambiguously marked DORMANT/not-wired (no NIF ABI), with the marker now pointing at the matched-resolution loop closure (1c) that will wire it. Kept rather than deleted because that wiring is the next step.
- [x] 1.18 Corrected the false "capacity phase 2 — NOT yet wired" doc in the NIF (`causal_disposition_nif/src/lib.rs:46`); capacity is live and wired (`dispose_batch(:capacity, ...)`).
- [x] 1.19 Write the "what the engine really is" document (robust detector + seasonal/forecast disposition + deterministic dependency expert system).

## 2. Phase 2 — Statistical rigor

### 2a. Edge

- [x] 2.1 HARNESS-RESOLVED (D-Q2, harness-driven): the existing withhold-from-baseline (a breaching sample is never admitted to the window — `detector.rs` branch arms) already achieves self-masking recall **1/1** (second spike z=17.1, 0.7), so the robust median/MAD (Hampel) upgrade is NOT needed for self-masking — keep the guarded mean/std estimator (a MAD-over-window sort adds O(window) cost with no measured benefit here; floors + saturation gate + confirm-slot hysteresis preserved). Re-open only if a future scenario demonstrates masking the current estimator misses.
- [x] 2.2 **Two-sided CUSUM** primitive implemented + unit-tested in `rust/anomaly-core/src/cusum.rs` (anchored, reset-on-alarm; ETA ≈ h/(δ−k)) and wired into `anomaly-backtest --cusum`. HARNESS-PROVEN: it catches the CPU drift the rolling z-score structurally misses (z-score 0/300 → CUSUM 216/300, +20-sample latency). MUST run on the deseasonalized residual (raw CUSUM floods 42–74% FP on seasonal data — measured). Production wiring into the addon/`ReasonContext` path is the deployment follow-up.
- [~] 2.3 Edge **deseasonalization** demonstrated in the harness (CUSUM over a causal hour-of-week residual): with a robust **median** hour-of-week baseline (latest-excluded) CUSUM FP drops to **0.6%/1.0%** (cpu/snmp) while still catching the drift/leak (+20/+31 latency). FINDING: a *persistent* 2-week leak in a 3-week window still pollutes any SHORT-history edge baseline (memory 38% FP) → the production design must push the core's 180-day robust seasonal profile to the edge (2.6), which a short edge window cannot substitute. anomaly-core/`ReasonContext` integration follows.
- [~] 2.4 Harness now measures slow-leak/drift **detection-latency** (+20/+31 samples) and CUSUM **false-positive rate** per series; the self-masking (0.7) and morning-ramp FP scenarios still to add.

### 2b. Core

- [~] 2.5 S-H-ESD primitive IMPLEMENTED + reference-verified in `rust/anomaly-core/src/esd.rs`: Generalized ESD (Rosner) with a robust median/MAD center/scale (the "Hybrid") + Acklam normal-inverse-CDF + Cornish-Fisher Student-t quantile for the critical values. Unit tests pin Φ⁻¹(0.975)=1.96, t(0.975,10)=2.228, and that GESD finds exactly the injected outliers / nothing on a clean series. Production integration (swap the per-bucket residual-z for GESD over the deseasonalized hour-of-week residual series) + the harness scenario (2.9) follow.
- [ ] 2.6 Make the S-H-ESD profile the **source of the coarse hour-of-week baseline pushed to the edge** (feeds 2.3).
- [~] 2.7 RPCA primitive IMPLEMENTED + rigorously verified in `rust/anomaly-core/src/rpca.rs`: PCP via inexact-ALM with a one-sided Jacobi SVD. The SVD is verified DIRECTLY (reconstruction `||A−UΣVᵀ|| < 1e-8` + orthonormal U/V), and RPCA is verified to separate a rank-1 seasonal `L` from injected sparse spikes (the top-|S| entries are exactly the spike locations). V1 = single-series reshape (the caller supplies the `slots × periods` matrix; a host-stacked fleet matrix is the same primitive with hosts as columns). Feature-flag + core integration + harness scenario (2.9) follow.
- [x] 2.8 Verified: Holt-Winters is capacity-only — the seasonal validator is the residual-z kernel; `holt_winters`/`seasonal_forecast` appear only under `disposition/capacity/`. No change needed.
- [~] 2.9 S-H-ESD vs raw-ESD comparison VERIFIED in-test (S-H-ESD ignores recurring seasonal peaks a raw ESD flags; finds only genuine off-pattern anomalies); RPCA verified to separate seasonal-`L` from sparse-`S` (recovers the exact spike locations); CUSUM drift recall + FP verified in the streaming harness. Full harness wiring over the `gen.py` synthetic series + the RPCA host-stacked fleet demo follow.

## 3. Phase 3 — Documentation overhaul (single source of truth)

- [x] 3.1 Stripped the "causal"/causal-inference overclaim from the engine code module-docs + inline comments (`anomaly-core` lib/detector, `anomaly-addon` engine, `causal-disposition` lib, `causal-engine` lib/god_view/domain_model/reasoner, `causal_disposition_nif`, `CausalReasoner`) and the docs site (Phase 3). Archived proposal history untouched. (The wire `signal_type`/`signals.causal.*` value renames remain in 1f.)
- [x] 3.2 Author the new end-to-end engine doc set under `docs/docs/` (the single source of truth) and register it in `docs/sidebars.ts`, covering: two-tier architecture (edge robust spike detector + core seasonal/capacity disposition + deterministic dependency expert system); data contract (gauges vs monotonic counters, rate normalization, counter wrap/reset, directional saturation gate, series keying); actual statistics (rolling robust z-score; hour-of-week residual-z / S-H-ESD; OLS + Holt-Winters capacity); honest naming (what is and is NOT causal); the disposition loop; operations/tuning knobs; how to run the proof harness (`tools/anomaly-proof`).
- [x] 3.3 Overhauled the stale `docs/docs/anomaly-detection.md` (retitled "Anomaly Detection (Tuning & Operations)", points to the new engine doc, dropped the duplicated stale section; operator content preserved).

## 4. Validation, coordination + rollout

- [ ] 4.1 Phase 1 first; suppression report-only; verify on the proof harness before any suppression is enabled live.
- [ ] 4.2 Phase 2 behind per-metric-class kill switches; calibrate constants against real per-cell distributions guarded by the invariant tests.
- [~] 4.3 Code-doc de-causal VERIFIED complete: a workspace grep finds no causal-INFERENCE claims left in engine code docs (the survivors are the honest "not causal inference" framing, crate-NAME references like `causal-engine`/`causal_disposition_nif`, or the wire subject). The `signal_type:"causal"` wire value + `signals.causal.*` subject rename and the zero-traffic check are 1f (BREAKING).
- [ ] 4.4 **Close `add-anomaly-finding-disposition` #4280 as superseded** by this change (decided), pointing its archive/withdrawal note at this change as the consolidation of record.
- [x] 4.5 `openspec validate refactor-anomaly-engine-rigor --strict` passes ("Change 'refactor-anomaly-engine-rigor' is valid").
