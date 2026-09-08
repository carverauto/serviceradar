# Design — refactor-anomaly-engine-rigor

## Context

A 23-agent adversarial audit (12 confirmed / 1 partial / 1 refuted, all file:line-verified)
established what the anomaly engine **actually is**, stripped of branding:

- **Edge detector** (`rust/anomaly-core` + `rust/anomaly-addon`): a guarded rolling **symmetric**
  z-score. Welford O(1) **mean/std** (not median/MAD), withhold-breach-from-baseline, absolute +
  CV dispersion floors, a directional saturation gate for percent gauges (`min_value` 80/80/85 for
  cpu/mem/disk — intentional, to kill a disk-at-1.36% false-fire), and confirm-slot hysteresis.
  Defaults `n_sigma=3.0`, `window=300`, `min_samples=30`, `confirm_slots=5`. **Sound** as a spike
  detector. The add-on stamps OCSF `signal_type: "causal"` on this z-score
  (`rust/anomaly-addon/src/verdict.rs:54`). Disk is **not** dropped — it is collected and scored,
  but the 80% gate means below-80%-full can never breach.
- **Core seasonal** (`rust/causal-disposition/seasonal` + `causal_disposition_nif` +
  `seasonal_disposition/worker.ex`): hour-of-week 168-bucket robust residual-z (mean/std |
  median/MAD | p05/p95). **Live and data-fed** — the `profile_hour_of_week` SRQL verb is
  implemented and integration-tested (`rust/srql/src/query/timeseries_metrics.rs`; tests in
  `rust/srql/tests/api.rs`), Oban-scheduled `"47 * * * *"`, default-on. **Sound.** Caveat:
  `confirm_slots` default = 1 (no hysteresis).
- **Core capacity** (`rust/causal-disposition/capacity` + `capacity_forecasting/worker.ex:368`):
  OLS + additive Holt-Winters (alpha/beta/gamma `0.35/0.05/0.25`, fixed/unfitted), 90-day horizon,
  **live**. **Overclaim:** the `lower`/`upper` band is `projection ± 1.96·in-sample-RMSE` (constant
  width, ignores extrapolation variance — not a prediction interval); `confidence` is
  `clamp(1 - rmse/scale)` (heuristic, not a probability).
- **`peak_profile` kernel** (`rust/causal-disposition/.../peak_profile`): fully built + unit-tested
  but **dead code** — `types.rs:8` admits no NIF ABI; zero production callers.
- **"Causal" is cosmetic throughout.** `deep_causality_core::CausalFlow` is used only as a
  pipeline/state-machine combinator; **zero** causal inference (no SCM, do-calculus, counterfactual,
  intervention). `causal-engine` is 13 hand-coded if-then rules + ultragraph centrality/reachability
  — a legitimate deterministic dependency expert system, **not** causal inference; its
  `CausaloidGraph` wraps identity functions.
- **The architecture is misconceived as a pipeline.** It is **not** "edge proposes → core
  confirms." Edge and central are two independent detectors emitting parallel verdicts
  (`verdict_source` `edge-spike` vs `central-seasonal`) that never read each other. The disposition
  loop is **open**, and the two tiers measure different physical quantities (sub-minute spike peak
  vs hourly-CAGG **mean**), so a naive join is resolution-mismatched.

Reference benchmark verdict: **refine, do not rip out.** A robust z-score at the edge is the
correct mainstream edge design; RPCA (Netflix RAD/Surus) is a core/batch seasonal+multivariate
method; S-H-ESD (Twitter) is the lighter core seasonal validator; MIDAS is for streaming graphs,
not sysmon scalars.

## Goals / Non-Goals

- **Goals:** (1) remove every overclaim (causal label, capacity uncertainty, stale docs, dead
  code) without removing working behavior; (2) close the disposition loop **at matched resolution**
  so a specific finding is judged real vs seasonal; (3) add the missing statistical rigor
  (robust dispersion, drift, edge deseasonalization, S-H-ESD, optional RPCA); (4) make every
  behavioral claim **harness-proven on real code**.
- **Non-Goals:** re-architecting the metrics pipeline; removing the DeepCausality substrate;
  rewriting `fix-anomaly`'s F-items; turning the detector into actual causal inference; renaming
  the topology-overlay on-the-wire "causal envelope" fields (descriptive labeling only).

## Decisions

### D1 — Honest naming (detector/disposition layer), keep the expert system

- The edge z-score verdict SHALL not be `signal_type: "causal"`. The seasonal/capacity tiers are
  named for their method. `CausalFlow` may remain as the host substrate but is documented as a
  combinator, not causal inference.
- `causal-engine` is **kept** and documented as deterministic rule + dependency-graph reasoning.
- The on-the-wire envelope shared with the BMP/topology overlay path (baseline
  `observability-signals` `External Causal Signal Normalization`) **is renamed** as part of this
  change — see **D7**. This is a BREAKING schema rename handled via a versioned dual-publish +
  dual-consume cutover, not deferred to a separate change.
- **Alternative considered:** leave the wire envelope `causal`-named and correct only
  descriptive/operator-facing claims (the smaller, non-breaking honesty pass). **Not chosen** — the
  decision is to make the naming honest end to end including the wire; D7's migration discipline
  contains the blast radius. The topology expert system itself remains a legitimately useful
  component; only the *inference* claim and the `causal` label are wrong, not the component.
- **Coordination:** `retire-uasb-causal-disposition` strips the narrower UASB naming; this is the
  superset for the "causal" label. The two are additive (distinct requirement names).

### D2 — Capacity uncertainty: valid prediction intervals on both model paths (D-Q1 resolved)

**Decision:** surface a **valid prediction interval** on both model paths; drop the
"honest in-sample band" fallback entirely.

- **Linear-trend (OLS):** closed-form OLS prediction interval, half-width
  `t · s · sqrt(1 + 1/n + (x0 - x̄)² / Sxx)`, which widens with horizon distance from the
  fitted-window mean.
- **Additive Holt-Winters:** the interval is **not** closed-form, so compute a valid prediction
  interval via **residual-bootstrap / simulation** (resample the model's one-step residuals and
  roll the recursion forward many times; take empirical quantiles). This is **off the hot path** —
  capacity is a periodic Oban job — so the simulation cost is acceptable.
- **`confidence`** (`clamp(1 - rmse/scale)`) is a heuristic, not a probability: **removed**, or
  replaced with a calibrated quantity (e.g. the interval's coverage level). No value is presented
  as a probability unless calibrated.
- **Alternatives considered:** (b) keep `± 1.96·RMSE` and merely **re-label** it an in-sample band —
  **rejected**: cheaper but still surfaces a band that is not a prediction interval, and a
  capacity-planning band's whole job is to be predictive. A full Bayesian predictive model —
  **rejected** for V1 as over-engineering; residual-bootstrap is the standard, sufficient method
  for an additive Holt-Winters interval.

### D3 — Matched-resolution loop closure (absorbs #4280's Option B)

The hinge finding: edge fires on a **sub-minute spike peak**; seasonal scores the **hourly mean**.
A naive join is unsound. #4280 already ratified **Option B**: the edge forwards the spike
**peak + window**; the core builds a **peak profile** = a robust hour-of-week aggregate of
`timeseries_metrics_hourly.max_value` (which already materializes per `(series, hour)` — no schema
change) and judges spike-peak against spike-peak history. Sustained drift without a spike is judged
against the **mean** profile. Disposition is computed at the **alert/query layer** (raw findings
retained for recall + audit), and the seasonal worker emits a verdict for **every** series so the
join always has a partner.

- **Why absorb rather than depend:** the user wants one consolidated rigor program; #4280 is Open
  (14/26) and its decision is sound. Absorbing it lets #4280 be withdrawn and keeps the loop
  closure under the same honest-naming and proof-harness umbrella.
- **Alternative considered (#4280's Option A):** reconcile only where resolutions are comparable;
  never suppress a short spike on hourly evidence. **Rejected by #4280** (and here) because it can
  never reduce recurring-spike noise — but note **Option B's ramp behavior *is* Option A**: the
  per-class stability gate keeps every class in pass-through (Option A's exact behavior) until its
  peak profile earns suppression, so B subsumes A in one gated mechanism. The Option-A-equivalent
  safety is delivered immediately; suppression activates per class only when its own data proves
  the peak profile trustworthy.
- **Peak-profile stability gate (binding invariants; constants are calibration):** two-sided band;
  inner (suppression) band scale bounded above by `min(s_cell, CAP·s_prior)` with a **per-series**
  prior (a `min`-cap bound, not the band center — calibration showed a `(hod)`-class prior pools
  idle+saturated series ≈ 30 and never binds an idle series at scale ≈ 0.5, defeating
  poison-resistance); cell is `(series, hod)`, never pooled across `hod`; cold / over-dispersed /
  ceiling-proximity cells pass through; low-`n` margin is sigma-relative `1 + A/√n` (no additive raw
  floor); a `suppress` verdict does not reset the confirm-slot counter; suppression ships
  **report-only**; coverage is reported as suppression-eligible mass. The cardinal error is
  **false-suppress** (it hides a real anomaly), so every uncertain path resolves to pass-through or
  escalate.
- **Precondition (do not re-author):** `fix-anomaly` F14 proves edge `series_key` == central
  `series_key` after canonical re-key; a load-bearing test asserts it (without it the join silently
  no-ops).

### D4 — Edge robustness: median/MAD (Hampel) or breach-freeze; + CUSUM; + deseasonalization

- **Self-masking** is the concrete defect: a big spike inflates its own mean/std and hides the next
  spike. **Decision (D-Q2, resolved harness-driven):** implement **both** a robust
  **median/MAD (Hampel)** dispersion (robust by construction) AND the **breach-freeze** fallback
  (freeze window updates during a confirmed breach; cheaper, O(1), but only protects during an
  *already-confirmed* breach), and let the harness self-masking recall scenario pick the shipped
  default. This removes the "which is sufficient?" guess from review — the real-code recall number
  chooses.
- **Drift** is invisible to a point z-score. Add a **two-sided CUSUM** on the residual — the
  standard streaming primitive for slow level shifts/leaks; cheap, O(1), complements the z-score.
  **Alternative:** EWMA control chart. **CUSUM chosen** for crisp two-sided change-point latency on
  slow drifts; EWMA is a reasonable substitute and can be a config option.
- **Edge seasonality** the edge has none, so a normal morning ramp false-fires. Feed it a **coarse
  hour-of-week baseline** (from the core S-H-ESD profile) and score the deseasonalized residual;
  fall back to raw scoring when no baseline exists (cold-start safe). The edge stays
  cause-agnostic and node-local — the baseline is a small pushed artifact, not weeks of edge state.
- **Keep** the floors, saturation gate, and confirm-slot hysteresis — the audit confirms these are
  good and prevent known false-fires; this change replaces only the dispersion estimator.

### D5 — Core rigor: S-H-ESD primary; optional RPCA; Holt-Winters stays capacity-only

- **S-H-ESD** (STL/MSTL decomposition + median/MAD ESD on the residual) is the reference lighter
  core seasonal validator and the natural source of the hour-of-week baseline pushed to the edge.
  It supersedes `add-seasonal-anomaly-detection`'s plain mean/stddev plan for the **primary**
  validator. **Alternative:** keep the current hour-of-week residual-z. **S-H-ESD chosen** because
  STL handles trend+multiple seasonalities the bucket-mean cannot, and ESD bounds the number of
  outliers tested.
- **RPCA** (Netflix RAD/Surus): robust PCA separates a low-rank "normal" structure from a sparse
  anomaly matrix — the right tool for **correlated and multivariate** anomalies the univariate edge
  is blind to. Kept **optional, feature-flagged, off the hot path, default disabled** (it is a batch
  matrix method, not an edge primitive). **Decision (D-Q4, resolved):** **V1 ships the
  single-series hour-of-week reshape only**; the host-stacked fleet matrix (the bigger payoff but
  heavier lift) is a follow-on. **MIDAS rejected** for this layer — it is for streaming *graphs*
  (NetFlow/DDoS), not sysmon scalars.
- **Confirm-slot hysteresis (D-Q3, resolved):** once the core seasonal tier supports
  `confirm_slots > 1`, the **default is 2** (today's default of 1 has no hysteresis; 2 stops a
  single off-baseline bucket from flipping a disposition without materially hurting latency).
- **Holt-Winters stays strictly for capacity forecasting** — it is a forecaster, not an anomaly
  validator; repurposing it would re-introduce the confusion this change removes.

### D6 — Proof harness as the acceptance gate (anti-hallucination)

Every behavioral requirement maps to a harness scenario over **real code**. The harness **exists**:
`tools/anomaly-proof/{gen.py,plot.py}` drives the real `target/debug/anomaly-backtest` (built from
`rust/anomaly-core/src/bin/anomaly-backtest.rs`); the core half runs the real Elixir seasonal +
capacity workers and the `causal_disposition` NIF against the `srql-fixtures` CNPG scratch DB / a
local TimescaleDB CAGG, **never production**. Synthetic **labeled** datasets (bounded gauges +
monotonic counters; injected spike/step/drift/off-cycle + counter wrap/reset) yield precision /
recall / detection-latency scorecards + Fig-2-style overlay plots.

**Initial scorecard (pure rolling z-score, real `anomaly-backtest`)** — both validates the engine
where it should be sound and pins the Phase 2 targets:

| scenario | result | reads as |
|---|---|---|
| spike / step / burst | recall 1/1 @ ~4-sample latency, precision 1.0 | detector is sound |
| recurring nightly load | flagged 21/21 | the recurring-spike noise the matched-resolution seasonal disposition must suppress |
| raw SNMP counter | 6956 false alarms | data-contract / counter-normalization point (rate-normalized = precision 1.0) |
| drift + leak | recall 0/1 | **no edge drift detection** → D4 CUSUM target |
| single-blip | 0/1 | confirm-slot hysteresis working as intended |

The harness currently exercises only the pure z-score because `anomaly-backtest` hardcodes
`seasonal_enabled`/`trend_enabled` off and `min_std_floor`/`min_cv`/`saturation_gate` to `None`
(`rust/anomaly-core/src/bin/anomaly-backtest.rs:124-139`); Phase 0 **extends the binary** to expose
those `ReasonContext` fields so the stability-gate, MAD, CUSUM, and seasonal requirements become
harness-provable. This is the structural guard against "asserted but not real" claims — the whole
point of the proposal.

### D7 — On-the-wire de-causal rename + migration (BREAKING)

The cosmetic `causal` naming is not only in code/docs; it is **on the wire**, in an envelope that
the anomaly verdict path **shares** with the BMP/BGP routing path and the topology-overlay path:

- the verdict `signal_type` discriminator value `"causal"` (`rust/anomaly-addon/src/verdict.rs:54`);
- the NATS subject namespace `signals.causal.predictions.*` and the causal envelope subjects
  consumed by `causal_signals.ex`;
- the `SignalSchemaRef` / schema names.

Because the envelope is shared across three producers and several consumers, renaming it is a
**breaking schema change** and cannot be a flag-day. **Approach — versioned envelope, dual-publish +
dual-consume cutover:**

1. **Add** the new honest subject/field/schema names alongside the old (versioned envelope).
2. **Dual-publish:** every producer (anomaly addon `verdict.rs`, the BMP producer, the
   topology-overlay producer) emits **both** the old (`signals.causal.predictions.*`) and the new
   form during the cutover window.
3. **Dual-consume:** every consumer (`causal_signals.ex` ingest, `causal-engine` evidence, web-ng)
   accepts **both** forms, preferring the new.
4. **Migrate** producers and consumers independently (no ordering dependency, since both forms are
   live).
5. **Drop** the old subject/field/schema only after a verification step confirms **zero** traffic
   on the old form across all producers/consumers.

- **Rollback:** because both forms are live throughout the window, rollback is reverting the
  producer/consumer that regressed back to the old form; the old subject/field is not dropped until
  step 5, so a mid-cutover rollback never loses delivery.
- **Coordination:** the BMP producer and the topology-overlay producer are owned by
  `add-bmp-dual-path-observability` and the `topology-causal-overlays` spec respectively; the
  dual-publish change to them must be sequenced with this change (they are not modified in this
  change's specs but must migrate in lockstep). The MODIFIED `External Signal Normalization`
  requirement is the spec home for the renamed envelope.
- **Alternative considered:** a hard flag-day rename. **Rejected** — a shared envelope with multiple
  independently-deployed producers/consumers cannot be cut atomically without dropping signals.

## Risks / Trade-offs

- **Key misalignment** (edge vs central `series_key`) silently no-ops the join → mitigated by the
  load-bearing F14 alignment test (task 1.14); do not enable suppression until it passes.
- **Premature suppression** hides real spikes → suppression ships **report-only** behind a
  per-class stability gate; the invariants force every uncertain path to pass-through/escalate.
- **Robust estimator cost** (median/MAD is O(window) vs Welford O(1)) → bounded window (300) keeps
  it cheap at the edge; if it is too costly the breach-freeze fallback (D4) preserves O(1) and the
  harness decides.
- **S-H-ESD/RPCA compute** on core → RPCA is off-hot-path/optional/default-disabled; S-H-ESD runs
  on the same Oban cadence as today's seasonal worker.
- **Naming churn** breaking consumers of `signal_type:"causal"` → workspace-wide grep before the
  rename (API-removal-needs-workspace-wide-grep lesson); migrate queries/dashboards keyed on it.
- **BREAKING wire envelope rename dropping signals** (the shared causal envelope with BMP/topology)
  → the highest-risk item; mitigated by the D7 versioned **dual-publish + dual-consume** cutover —
  the old subject/field is dropped only after verified zero traffic, so no producer/consumer is cut
  atomically. Risk = a missed producer/consumer keeps the old form alive (caught by the zero-traffic
  verification gate before drop).
- **Holt-Winters bootstrap interval cost** → the residual-bootstrap PI runs in the periodic capacity
  Oban job (off the hot path); bound the simulation count and reuse the fitted residuals.
- **Overlap with `fix-anomaly`** → explicitly retain F16 (capacity ETA/slope/flow math) and F17
  (numeric-safety floors / confirm-slot definition); this change touches only the
  prediction-interval/confidence overclaim and the dispersion estimator.

## Migration Plan

1. Phase 0 harness first (gates everything).
2. Phase 1 honesty + loop-closure; suppression **report-only**; verify on harness; ship behind
   per-class kill switches. The **BREAKING** wire envelope rename runs as the D7 versioned
   dual-publish + dual-consume cutover (add new names → dual-publish → dual-consume → migrate →
   drop old after verified zero traffic), sequenced with the BMP and topology-overlay producers.
3. Phase 2 edge robustness + core S-H-ESD; optional RPCA default-disabled; calibrate constants
   against real per-cell distributions guarded by invariant tests.
4. Phase 3 documentation overhaul + the de-causal code/docs cleanup.
5. Rollback: each item is independently revertible (loop-closure and Phase 2 are flag-gated;
   capacity PI is compute-local; the wire rename rolls back per-producer/consumer because both
   forms stay live until the verified drop). No data migration (peak profile uses existing
   `max_value`; edge peak/window payload is forward-only/additive).

## Open Questions

All prior open questions are now **resolved as decisions**:

- **D-Q1 capacity uncertainty** → **valid prediction intervals on both paths** (closed-form OLS PI
  + residual-bootstrap Holt-Winters PI); the in-sample-band fallback is dropped and `confidence` is
  removed/calibrated (D2).
- **D-Q2 edge dispersion** → build **both** median/MAD-Hampel and breach-freeze; the harness
  self-masking recall picks the shipped default (D4).
- **D-Q3 core seasonal `confirm_slots`** → default **2** (D5).
- **D-Q4 RPCA V1** → **single-series hour-of-week reshape only**; fleet host-stacked matrix is a
  follow-on (D5).
- **#4280** → **superseded / withdrawn** (Coordination & supersession).
- **On-the-wire causal envelope rename** → **in scope, BREAKING**, via the D7 dual-publish +
  dual-consume cutover.

Remaining coordination item (not a design question): the D7 cutover requires the BMP
(`add-bmp-dual-path-observability`) and topology-overlay (`topology-causal-overlays`) producers to
add dual-publish in the same window — confirm ownership/sequencing with those change owners before
the old subject/field is dropped.
