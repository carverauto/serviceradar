# Change: Make the anomaly engine honest and statistically rigorous (phased)

## Why

A 23-agent adversarial audit (12 confirmed / 1 partial / 1 refuted, all file:line-verified)
found the anomaly engine is **real, working statistics that is mislabeled and architecturally
incomplete**. The engineering is mostly sound; the framing overclaims and the disposition loop
is open. Specifically:

- **The "causal" branding is cosmetic.** `deep_causality_core::CausalFlow` is used only as a
  pipeline/state-machine combinator; there is **zero** causal inference anywhere in the
  detector/disposition layer (no SCM, do-calculus, counterfactual, or intervention). The edge
  add-on literally stamps the OCSF field `signal_type: "causal"` onto a rolling z-score
  (`rust/anomaly-addon/src/verdict.rs:54`). The standalone `causal-engine` is 13 hand-coded
  if-then rules plus ultragraph centrality/reachability — a legitimate **deterministic
  dependency/expert system**, but not causal inference; its `CausaloidGraph` wraps identity
  functions. The team already half-acknowledged this in `retire-uasb-causal-disposition`.
- **The capacity forecaster overclaims uncertainty.** `capacity_forecasting/worker.ex:368` ships
  OLS + additive Holt-Winters (alpha/beta/gamma `0.35/0.05/0.25`, fixed/unfitted) over a 90-day
  horizon. Its `lower`/`upper` "bounds" are `projection ± 1.96·in-sample-RMSE` — a **constant
  width 90 days out** that ignores extrapolation variance, so it is **not** a valid prediction
  interval; its `confidence = clamp(1 - rmse/scale)` is a heuristic, **not** a probability.
- **The disposition loop is open.** It is *not* "edge proposes a spike → core confirms over the
  long range." Edge (`rust/anomaly-core` + `rust/anomaly-addon`) and central seasonal
  (`rust/causal-disposition/seasonal` + `seasonal_disposition/worker.ex`) are **two independent
  detectors** emitting parallel OCSF verdicts (`verdict_source` `edge-spike` vs `central-seasonal`)
  that never read each other. Worse, the two tiers measure **different physical quantities**
  (a sub-minute spike peak vs an hourly-CAGG **mean**), so a naive join is resolution-mismatched
  and statistically unsound.
- **The edge detector has known statistical blind spots.** It is a guarded rolling **symmetric**
  z-score with Welford O(1) mean/std (NOT median/MAD), withhold-breach-from-baseline, abs+CV
  dispersion floors, a directional saturation gate for percent gauges (`min_value` 80/80/85 for
  cpu/mem/disk), and confirm-slot hysteresis (defaults `n_sigma=3.0`, `window=300`,
  `min_samples=30`, `confirm_slots=5`). It is **sound as a spike detector**, but: (a) the
  non-robust mean/std **self-masks** (a large spike inflates its own baseline); (b) it has **no
  drift detection** (slow leaks are invisible to a point z-score); (c) it has **no seasonality at
  the edge** (a normal morning ramp can false-fire).
- **Dead code and stale docs.** The `rust/causal-disposition/.../peak_profile` kernel is fully
  built and unit-tested but is **dead code** — `types.rs:8` admits it has no NIF ABI and there
  are zero production callers. Docs that claim capacity "phase 2 is not wired" are **false**
  (it is live at `worker.ex:368`).

A reference-benchmark review concluded the engine should be **refined, not ripped out**: a robust
z-score at the edge is the correct mainstream edge design; RPCA (Netflix RAD/Surus) is a
core/batch matrix method for seasonal+multivariate detection; S-H-ESD (Twitter, STL + ESD on the
residual) is the lighter core seasonal validator; MIDAS targets streaming graphs (NetFlow/DDoS),
not sysmon scalars.

The **proof harness already exists** (`tools/anomaly-proof/{gen.py,plot.py}` driving the real
`target/debug/anomaly-backtest`), and an initial scorecard over the pure rolling z-score both
confirms the engine is sound where it should be and pins the exact blind spots this proposal
fixes: spike/step/burst **recall 1/1 at ~4-sample latency, precision 1.0**; a recurring nightly
load flagged **21/21** (precisely the recurring-spike noise the matched-resolution seasonal
disposition must suppress); a **raw SNMP counter produces 6956 false alarms** while the
rate-normalized series scores **precision 1.0** (the data-contract / counter-normalization point).
The measured gaps are the Phase 2 targets: **drift + leak recall 0/1** (no edge drift detection)
and **single-blip 0/1** (confirm-slot hysteresis working as intended). These numbers are the
baseline the harness scorecards will be measured against.

This proposal commits to **both** an honesty pass and a rigor pass, phased.

## What Changes

### Phase 1 — Honesty + Correctness

- **Strip the cosmetic "causal" branding from the detector/disposition layer.** The edge spike
  detector and the seasonal/capacity disposition tiers SHALL NOT label their output
  `signal_type: "causal"` (`verdict.rs:54`) nor present themselves as causal inference. They SHALL
  be named for what they are: a **robust statistical spike detector**, a **seasonal
  residual-z disposition**, and a **trend/forecast capacity model**. Cosmetic `causal`-named
  crates/modules/docs SHALL be renamed honestly. The `causal-engine` rule/graph reasoning is
  **kept** but documented honestly as **deterministic dependency/expert reasoning**, not causal
  inference. (Builds on `retire-uasb-causal-disposition`, which strips the narrower UASB naming.)
- **BREAKING — rename the cosmetic "causal" naming on the wire.** The de-causal rename extends to
  the **on-the-wire envelope** that the anomaly verdict path **shares** with the BMP/BGP routing
  path and the topology-overlay path: the verdict `signal_type` discriminator value `"causal"`, the
  NATS subject namespace (`signals.causal.predictions.*` and the causal envelope subjects consumed
  by `causal_signals.ex`), and the `SignalSchemaRef` / schema names SHALL be renamed to honest
  signal naming. Because the envelope is shared, this is a **breaking schema change**, delivered as
  a **versioned envelope with dual-publish + dual-consume** across a cutover window (producers:
  anomaly addon `verdict.rs`, the BMP producer, the topology-overlay producer; consumers:
  `causal_signals.ex` ingest, `causal-engine` evidence, web-ng), then the old subject/field is
  dropped (see design **D7** for migration + rollback).
- **Fix the overclaimed capacity uncertainty — proper prediction intervals on both model paths.**
  Replace the constant-width `± 1.96·in-sample-RMSE` band with a **valid prediction interval**:
  a closed-form **OLS prediction interval** (inflate the residual standard error by
  `sqrt(1 + 1/n + (x0 - x̄)² / Sxx)` so the band widens with horizon) for the linear-trend model,
  and a **residual-bootstrap / simulation** prediction interval for the additive Holt-Winters path
  (off the hot path — capacity is a periodic Oban job, so the extra compute is acceptable). The
  heuristic `confidence = clamp(1 - rmse/scale)` SHALL be **removed or replaced with a calibrated
  quantity**; no value SHALL be presented as a probability unless calibrated.
- **Close the disposition loop at matched resolution** (absorbs `add-anomaly-finding-disposition`
  #4280's already-ratified "Option B"): the edge forwards the spike **peak + window**; the core
  builds a **peak profile** from the existing hourly `timeseries_metrics_hourly.max_value` (no
  schema change) and disposes the edge finding (`suppress` / `downgrade` / `escalate` /
  `pass_through`); the alert engine and device-detail panel consume the disposition. The seasonal
  worker SHALL emit a verdict for **every** evaluated series so there is always something to join.
  Raw edge findings are retained for audit. Suppression ships **report-only** behind a per-class
  stability gate.
- **Remove or clearly mark dead code, and fix stale docs.** The `peak_profile` kernel SHALL be
  removed or unambiguously marked dead (no NIF ABI, `types.rs:8`); the false "capacity phase 2 not
  wired" documentation SHALL be corrected.
- **Document what the engine really is** — a robust statistical detector + a seasonal/forecast
  disposition engine + a deterministic dependency expert system — with no causal-inference claims.

### Phase 2 — Statistical Rigor

- **Edge:** replace the mean/std dispersion with a **robust median/MAD (Hampel) identifier** to
  kill self-masking — or, at minimum, **freeze window updates during a confirmed breach**. Add a
  **two-sided CUSUM** on the deseasonalized residual for slow drift/leaks. **Keep** the dispersion
  floors, the directional saturation gate, and the confirm-slot hysteresis (these are good).
  Optionally feed the edge a **coarse hour-of-week seasonal baseline** so the residual is
  deseasonalized before scoring (kills the morning-ramp false-fire).
- **Core:** adopt **S-H-ESD** (STL/MSTL decomposition + median-MAD ESD on the residual) as the
  primary seasonal validator and as the **source of the hour-of-week baseline pushed back to the
  edge**. Add an **optional RPCA** layer (reshape to an hour-of-week matrix; stack hosts for
  fleet-wide correlated/multivariate detection) as the heavyweight, off-hot-path layer for what
  univariate edge scoring is blind to. Keep **Holt-Winters strictly for capacity forecasting**.

### Phase 0 (cross-cutting) — Anti-hallucination proof harness

- The harness exists at **`tools/anomaly-proof/{gen.py,plot.py}`** and drives the **real**
  `rust/anomaly-core` detector via the **real** `target/debug/anomaly-backtest` binary (built from
  `rust/anomaly-core/src/bin/anomaly-backtest.rs`) over **synthetic labeled datasets** (bounded
  percent gauges for cpu/mem/disk + monotonic SNMP counters, with injected spike / step / drift /
  off-cycle anomalies and a counter wrap/reset), producing Twitter-AnomalyDetection Fig-2-style
  plots plus precision / recall / detection-latency scorecards. The initial scorecard above is its
  output.
- **Extend `anomaly-backtest`** to expose the `ReasonContext` fields it currently hardcodes off
  (`seasonal_enabled`/`trend_enabled` = false and `min_std_floor`/`min_cv`/`saturation_gate` =
  None at `rust/anomaly-core/src/bin/anomaly-backtest.rs:124-139`) so the stability-gate, MAD,
  CUSUM, and seasonal requirements become harness-provable on real code.
- **Add the core half** of the harness: run the **real** Elixir seasonal/capacity workers + the
  `causal_disposition` NIF against the `srql-fixtures` CNPG scratch DB / a local TimescaleDB CAGG,
  with **no production DB**.
- **Every behavioral requirement in this proposal SHALL have a harness scenario that proves it on
  real code** — the structural guard against asserted-but-unverified claims.

### Phase 3 — Documentation overhaul (single source of truth)

- **Clean up stale/overclaiming anomaly docs across the repo.** Remove the cosmetic "causal"
  framing and any causal-inference assertion from the engine's own code module-docs/comments
  (`rust/anomaly-core`, `rust/anomaly-addon`, `rust/causal-disposition`, `rust/causal-engine`,
  `causal_disposition_nif`, and the Elixir `observability` modules) and from the docs site
  (the existing `docs/docs/anomaly-detection.md` is stale and overclaims). Do **not** rewrite other
  proposals' archived history.
- **Author a new end-to-end engine documentation set** under the Docusaurus content dir
  (`docs/docs/`, registered in `docs/sidebars.ts`) that completely documents the anomaly engine end
  to end and is the **single source of truth** replacing the scattered/stale docs: the two-tier
  architecture (edge robust spike detector + core seasonal/capacity disposition + the deterministic
  dependency expert system); the exact **data contract** (gauges vs monotonic counters, rate
  normalization, counter wrap/reset, the directional saturation gate, series keying); the **actual
  statistics** (rolling robust z-score; hour-of-week residual-z / S-H-ESD; OLS + Holt-Winters
  capacity); **honest naming** (what is and is NOT causal); the disposition loop; operations/tuning
  knobs; and **how to run the proof harness** (`tools/anomaly-proof`).

## Coordination & supersession

- **`retire-uasb-causal-disposition` (Open, 2/17)** — **builds on.** That change strips the
  narrower **UASB** naming and frames detection/disposition as three honest tiers. This change
  **extends** the honesty pass to the broader **"causal"** branding (the `signal_type: "causal"`
  stamp, cosmetic `CausalFlow` hosting, and `causal-engine` labeling) and adds the capacity
  uncertainty fix. The requirements here are additive and complementary to retire-uasb's
  `No Overclaimed Methodology Naming`; they do not redefine it.
- **`add-anomaly-finding-disposition` #4280 (Open, 14/26)** — **SUPERSEDED (DECIDED).** This change
  **supersedes** #4280, and #4280 is to be **withdrawn/closed**. #4280 ratified the matched-resolution
  peak-disposition decision ("Option B") and authored the loop-closure requirements (correlation,
  edge peak forwarding, resolution model, robust peak-profile stability gate,
  seasonal-verdict-for-every-series, robust seasonal statistic, liveness gate, disposition-driven
  severity). This change **absorbs that decision and those requirements faithfully** (re-stated
  under honest, non-"causal" naming and bound to the proof harness). It does **not** contradict
  #4280's design — it consolidates it into the broader rigor program. (Note: #4280's `Seasonal Tier
  Liveness Gate` overlaps `fix-anomaly`'s NIF-liveness work; see below.)
- **`add-bmp-dual-path-observability` + the `topology-causal-overlays` spec — coordinate (shared
  envelope).** The on-the-wire de-causal rename (BREAKING, design D7) touches the **shared** signal
  envelope these paths also produce/consume. The BMP producer and the topology-overlay producer are
  in the dual-publish set; the rename MUST be sequenced with their migration so neither path breaks
  during cutover. This change MODIFIES the baseline `observability-signals` `External Causal Signal
  Normalization` requirement (renamed to `External Signal Normalization`) that governs that envelope.
- **`fix-anomaly-engine-semantics-and-delivery` (Open, 132/170)** — **complements, no overlap.**
  That change fixes how findings are **produced and delivered** (transition gating, F4/F14
  canonical re-key + `Edge And Central Verdict Correlation` key alignment, F15
  `profile_hour_of_week` data feed, F16 capacity ETA/slope/flow-label math, F17 `Edge Detector
  Numeric Safety` floors/guards + `Anomaly Confirmation Slot Definition`). This change **does not
  re-fix any F-item.** Its edge requirements explicitly **retain** F17's numeric-safety floors,
  saturation gate, and confirm-slot definition, changing only the **dispersion estimator**
  (mean/std → median/MAD) and adding **drift** + **deseasonalization**. Its capacity requirement is
  about the **prediction-interval / confidence overclaim**, distinct from F16's ETA/slope math.
  The matched-resolution loop here builds on F14's proven key alignment.
- **`add-causal-anomaly-detection` (Complete)** and **`move-anomaly-detection-to-edge` (Complete)**
  and **`refactor-anomaly-reasoner-deepcausality` (Complete)** — **refines.** These built the live
  engine and introduced the "causal" framing; this change corrects the framing **without removing**
  the working detector, seasonal disposition, or capacity model they delivered. The detector math
  and the DeepCausality substrate stay; only the overclaiming labels and the missing rigor change.
- **`add-seasonal-anomaly-detection` (Open, 1/19)** — **subsumes the rigor portion.** The live
  seasonal worker already implements hour-of-week residual-z; this change's S-H-ESD requirement
  supersedes that change's plain mean/stddev seasonal-profile plan for the **primary** validator.

## Impact

- Affected specs: `observability-signals` (honest signal classification; **BREAKING** MODIFIED
  `External Signal Normalization` envelope rename; honest capacity uncertainty; matched-resolution
  disposition loop; robust seasonal statistic + hysteresis; S-H-ESD primary validator; optional
  RPCA; documentation/dead-code hygiene; honest end-to-end engine documentation; proof-harness
  acceptance gate), `edge-architecture` (robust dispersion estimator; CUSUM drift; coarse
  deseasonalization). Coordinates with the `topology-causal-overlays` spec and
  `add-bmp-dual-path-observability` (shared envelope), which are not modified here but must migrate
  in lockstep with the de-causal cutover.
- Affected code: `rust/anomaly-addon/src/verdict.rs` (`signal_type` value + envelope publish),
  `rust/anomaly-core` (`stats.rs`/`detector.rs` dispersion estimator + CUSUM + optional
  deseasonalization; `src/bin/anomaly-backtest.rs` harness reuse), `rust/causal-disposition` (rename
  cosmetic `causal`-named modules; remove/mark the dead `peak_profile` kernel; add the `max_value`
  peak variant consumer; S-H-ESD; optional RPCA), `causal_disposition_nif`,
  `rust/srql/src/query/timeseries_metrics.rs` (peak variant of `profile_hour_of_week` over
  `max_value`), the **shared signal envelope** producers/consumers for the de-causal rename
  (NATS subjects `signals.causal.predictions.*` → renamed; the BMP producer, the topology-overlay
  producer, `.../event_writer/processors/causal_signals.ex` ingest, `rust/causal-engine` evidence
  consumer, `SignalSchemaRef`/schema names; dual-publish + dual-consume cutover),
  `elixir/serviceradar_core/.../observability/seasonal_disposition/*` (emit-every-series,
  median/MAD, confirm-slot hysteresis, disposition correlation), `.../capacity_forecasting/
  worker.ex` (OLS + Holt-Winters prediction intervals; remove heuristic confidence),
  `.../monitoring/alert_generator.ex` / `stateful_alert_engine.ex` (consume disposition),
  `rust/causal-engine` (honest documentation / module labeling), web-ng device-detail
  anomaly/capacity panel, `tools/anomaly-proof/{gen.py,plot.py}` +
  `rust/anomaly-core/src/bin/anomaly-backtest.rs` (harness extension), the docs site
  (`docs/docs/anomaly-detection.md` overhaul + new end-to-end engine doc set, `docs/sidebars.ts`),
  code module-docs across the anomaly crates/Elixir modules, and docs/memory (strip overclaim).
- Migration: the **BREAKING** envelope rename is delivered via versioned dual-publish + dual-consume
  with a cutover window and rollback (design D7); no other data migration — the edge peak/window
  payload and the peak profile use existing fields (`timeseries_metrics_hourly.max_value`) and are
  forward-only.
- Rollout: Phase 1 first (honesty + loop-closure, suppression report-only; envelope rename behind
  the dual-write cutover); Phase 2 behind per-metric-class kill switches and the proof-harness
  acceptance gate; all reversible.
