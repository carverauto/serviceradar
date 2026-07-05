# observability-signals — anomaly engine honesty + rigor

## ADDED Requirements

### Requirement: Honest Statistical Signal Classification

The edge spike detector and the seasonal/capacity disposition tiers SHALL classify their
emitted signals by what they statistically are, and SHALL NOT label a robust z-score, a
seasonal residual-z, or a trend/forecast as causal inference. The OCSF `signal_type` field
emitted by the edge add-on SHALL NOT be `"causal"` for a statistical detector verdict
(today `rust/anomaly-addon/src/verdict.rs:54` stamps `"signal_type": "causal"` on a rolling
z-score); it SHALL be a value that names the actual method (for example a statistical
spike/anomaly classification). Hosting a kernel in `deep_causality_core::CausalFlow` (used as a
pipeline/state-machine combinator) SHALL NOT, by itself, justify a causal label.

#### Scenario: Edge z-score verdict is not labeled causal

- **GIVEN** the edge add-on confirms a rolling-z-score spike on a series
- **WHEN** it emits the OCSF verdict
- **THEN** the verdict `signal_type` SHALL NOT be `"causal"`
- **AND** the verdict SHALL be classified as a statistical spike/anomaly detection

#### Scenario: Seasonal and capacity tiers are named for their method

- **GIVEN** the seasonal residual-z disposition or the trend/forecast capacity model emits a signal
- **WHEN** the signal is surfaced in code, schema, or docs
- **THEN** it SHALL be described as a statistical seasonal disposition or a trend/forecast model
- **AND** it SHALL NOT be presented as causal inference (no SCM, do-calculus, counterfactual, or intervention claim)

### Requirement: Dependency Reasoning Is Not Labeled Causal Inference

The deterministic dependency/expert-reasoning engine (`rust/causal-engine`) SHALL be kept, but
its documentation and operator-facing descriptions SHALL NOT claim causal inference. The engine
is a finite set of hand-coded if-then rules plus ultragraph centrality/reachability whose
`CausaloidGraph` wraps identity functions; it SHALL be described as deterministic rule +
dependency-graph reasoning. The on-the-wire envelope rename shared with the topology overlay and
BMP paths is handled by the MODIFIED `External Signal Normalization` requirement (and design
decision D7); this requirement additionally governs the engine's descriptive/labeling claims.

#### Scenario: Expert system documented honestly

- **GIVEN** the dependency/expert-reasoning engine is documented
- **WHEN** its capability is described
- **THEN** it SHALL be described as deterministic rule and dependency-graph reasoning
- **AND** it SHALL NOT be described as performing causal inference, counterfactual analysis, or interventional reasoning

### Requirement: Honest Capacity Forecast Uncertainty

The capacity forecaster SHALL surface a **valid prediction interval** for its projected
`lower`/`upper`, not a constant-width in-sample band. Today
(`capacity_forecasting/worker.ex:368`) the band is `projection ± 1.96·in-sample-RMSE` (constant
width across the whole horizon, ignoring extrapolation variance) and `confidence` is
`clamp(1 - rmse/scale)` (a heuristic, not a probability). The system SHALL replace this on **both**
model paths:

- For the **linear-trend (OLS)** model, the system SHALL compute a closed-form OLS prediction
  interval whose half-width inflates with horizon distance by `sqrt(1 + 1/n + (x0 - x̄)² / Sxx)`, so
  the band widens with horizon.
- For the **additive Holt-Winters** path (whose interval is not closed-form), the system SHALL
  compute a valid prediction interval via residual-bootstrap / simulation. This runs off the hot
  path (capacity is a periodic Oban job), so the extra compute is acceptable.

The heuristic `confidence` SHALL be **removed**, or replaced with a calibrated quantity (for
example the chosen interval's coverage level). An in-sample error band SHALL NOT be surfaced as if
it were a prediction interval.

#### Scenario: OLS prediction interval widens with horizon

- **GIVEN** the linear-trend model is used
- **WHEN** the forecaster projects a resource forward over the horizon
- **THEN** the band half-width SHALL increase with distance from the fitted window mean (per `sqrt(1 + 1/n + (x0 - x̄)² / Sxx)`)
- **AND** the band SHALL NOT be a constant width across the full horizon

#### Scenario: Holt-Winters path yields a valid simulated interval

- **GIVEN** the additive Holt-Winters path is used
- **WHEN** the periodic capacity Oban job projects the resource forward
- **THEN** the `lower`/`upper` SHALL be a valid prediction interval computed by residual-bootstrap / simulation
- **AND** it SHALL NOT be a constant `± 1.96·in-sample-RMSE` band

#### Scenario: Heuristic confidence removed or calibrated

- **GIVEN** the surfaced forecast output
- **WHEN** uncertainty is presented in storage and UI
- **THEN** the heuristic `confidence = clamp(1 - rmse/scale)` SHALL be removed or replaced with a calibrated quantity
- **AND** no value SHALL be presented as a probability unless it is calibrated

### Requirement: Matched-Resolution Anomaly Disposition Loop

The platform SHALL close the open disposition loop between the edge spike detector and the
central seasonal tier **at matched resolution**, so a specific edge finding is judged real vs
seasonally-expected. The edge finding SHALL carry the spike's **peak magnitude and time window**.
The core SHALL build a **peak profile** — a robust hour-of-week aggregate of the series' per-hour
maxima from the existing `timeseries_metrics_hourly.max_value` (no schema change) — and judge the
spike peak against it. A sustained condition with **no** edge spike SHALL instead be judged
against the hourly **mean** profile (`profile_hour_of_week` over `avg_value`). The disposition
(`suppress` / `downgrade` / `escalate` / `pass_through`) SHALL be computed at the alert/query
layer; the raw edge finding SHALL be retained regardless of disposition (recall + audit). The
central seasonal worker SHALL record a verdict for **every** evaluated series and window
(including a non-surfacing `normal` verdict) so the correlation always has something to join.
This requirement supersedes and absorbs `add-anomaly-finding-disposition`'s loop-closure
decision; it builds on `fix-anomaly-engine-semantics-and-delivery`'s proven edge↔central
`series_key` alignment and does not re-author it.

#### Scenario: Spike judged against the peak profile, not the diluting mean

- **GIVEN** an edge spike finding for series `S` carrying its peak and window
- **AND** the peak profile for the matching hour-of-week cell is stable
- **WHEN** the alert engine evaluates the finding
- **THEN** the disposition SHALL be derived from the spike peak versus the peak profile (over `max_value`)
- **AND** it SHALL NOT be derived from the hourly mean (which dilutes a sub-minute spike)

#### Scenario: Recurring spike within the normal peak is suppressed; novel spike escalates

- **GIVEN** an edge spike whose peak is within the series' normal hour-of-week peak range
- **WHEN** it is evaluated against a stable peak profile
- **THEN** the disposition SHALL be `suppress` or `downgrade`
- **AND** an edge spike whose peak exceeds the normal hour-of-week peak range SHALL be `escalate`

#### Scenario: Raw finding retained and every series gets a verdict

- **GIVEN** the seasonal worker evaluates series `S` and finds it within baseline
- **WHEN** the run completes
- **THEN** it SHALL persist a non-surfacing `normal` verdict keyed by the canonical `series_key` and window
- **AND** any edge finding for `S` SHALL remain persisted regardless of its disposition

#### Scenario: Sustained drift without a spike is judged against the mean profile

- **GIVEN** no edge spike for series `S` in hour `H`
- **AND** the hourly **mean** profile for `S` in `H` is off-baseline
- **WHEN** the central tier runs
- **THEN** it SHALL surface a low-grade sustained-drift finding for `S`

### Requirement: Robust Peak-Profile Stability Gate

Peak-based suppression SHALL use a robust, safety-biased band over the `(series, hod)` cell
(collapsing only day-of-week) that ramps with the cell sample count `n`, and SHALL ship
**disabled (report-only)** behind a per-metric-class kill switch until its constants are
calibrated against real per-cell distributions. False-suppress (silencing a real anomaly) is the
cardinal error: every uncertain path SHALL resolve to `pass_through` or `escalate`, never to
`suppress`. The band's constants are calibration; the following invariants are binding:

- The band SHALL be **two-sided** (a downward excursion outside the escalation band SHALL escalate, never be auto-suppressed).
- The suppression (inner) band scale SHALL be **bounded above by a per-series prior** (`min(s_cell, CAP·s_prior)`), so a poisoned or thin cell cannot widen the suppression region; the prior SHALL be the series-overall robust scale (a `min`-cap bound, not the band center/width).
- The cell center/scale SHALL be `(series, hod)` and SHALL NOT be pooled across `hod`.
- A cold cell (`n < N_min`), an over-dispersed cell (`s_cell > D·s_prior`), or a ceiling-proximity cell (no upward headroom below 100) SHALL pass through.
- The low-`n` margin SHALL be **sigma-relative** (`1 + A/√n`), never an additive raw floor (an absolute floor applies only when the robust scale is ≈ 0).
- A `suppress` verdict SHALL NOT reset the confirm-slot counter.
- Suppression coverage SHALL be reported as suppression-eligible mass (fraction of cells that are not cold, not saturated, and not over-dispersed), so the ramp is observable rather than assumed.

#### Scenario: Downward anomaly escalates (two-sided)

- **GIVEN** a stable `(series, hod)` cell and a spike peak far below the escalation band
- **WHEN** the spike is evaluated
- **THEN** the disposition SHALL be `escalate` and SHALL NOT be `suppress`

#### Scenario: Poisoned thin cell cannot widen the suppression band

- **GIVEN** a `(series, hod)` cell with a minority of poisoned high samples and a real novel spike above the series' normal range
- **WHEN** the spike is evaluated
- **THEN** the suppression band SHALL be bounded by `CAP·s_prior`
- **AND** the spike SHALL `escalate`, not `suppress`

#### Scenario: Cold or ceiling-proximity cell passes through

- **GIVEN** a `(series, hod)` cell with `n < N_min`, or whose upper band would exceed 100
- **WHEN** an edge spike is evaluated
- **THEN** the disposition SHALL be `pass_through`
- **AND** the band SHALL NOT produce an upper bound above 100

### Requirement: Robust Seasonal Statistic And Confirm-Slot Hysteresis

The default central seasonal sources SHALL compute their baselines with a robust statistic
(`median + MAD`, or a robust IQR-based scale for the peak profile) rather than `mean + stddev`, so
a past incident in the history does not poison the profile. The central seasonal tier SHALL also
apply **confirm-slot hysteresis** (its `confirm_slots` SHALL be tunable and SHALL support a value
greater than 1), so a single off-baseline bucket does not flip a disposition; today the core
seasonal `confirm_slots` default is 1 (no hysteresis).

#### Scenario: Past incident does not hide itself

- **GIVEN** a seasonal cell with a small sample count, one of which is a prior incident spike
- **WHEN** the baseline is computed for that cell
- **THEN** the center and dispersion SHALL be computed with median and MAD (not mean and stddev)
- **AND** a subsequent spike of similar magnitude SHALL still be classified off-baseline

#### Scenario: Hysteresis requires sustained breach

- **GIVEN** the central seasonal tier configured with `confirm_slots > 1`
- **WHEN** a single bucket is off-baseline but the next is normal
- **THEN** the tier SHALL NOT flip its disposition on the single bucket alone

### Requirement: Core Seasonal Validator Adopts S-H-ESD

The primary central seasonal validator SHALL adopt **S-H-ESD** (seasonal-hybrid ESD: STL/MSTL
decomposition plus a median/MAD-based Extreme Studentized Deviate test on the residual) as the
seasonal validator, and SHALL be the **source of the coarse hour-of-week baseline pushed back to
the edge** for deseasonalization. Holt-Winters SHALL remain reserved for capacity forecasting and
SHALL NOT be repurposed as the seasonal anomaly validator.

#### Scenario: Seasonal validator decomposes before testing residuals

- **GIVEN** a series with a strong diurnal pattern
- **WHEN** the central seasonal validator scores the latest bucket
- **THEN** it SHALL test the STL/MSTL residual with a robust (median/MAD) ESD criterion
- **AND** the expected seasonal component SHALL be removed before the residual is scored

#### Scenario: Edge baseline is sourced from the core seasonal profile

- **GIVEN** the core seasonal validator has a stable hour-of-week profile for a series
- **WHEN** the edge requests a deseasonalization baseline for that series
- **THEN** the baseline SHALL be derived from the core seasonal profile

### Requirement: Optional Fleet And Multivariate RPCA Layer

The platform SHALL support an **optional, feature-flagged** core/batch RPCA layer that reshapes a
series into an hour-of-week matrix and/or stacks hosts to detect fleet-wide correlated and
multivariate anomalies that univariate edge scoring is blind to. This layer SHALL run off the hot
path (batch, core-side) and SHALL be disabled by default; it SHALL NOT be required for the edge or
seasonal tiers to function.

#### Scenario: RPCA detects a fleet-correlated anomaly invisible to univariate scoring

- **GIVEN** the RPCA layer is enabled and many hosts shift together in a correlated way that no single series flags as a spike
- **WHEN** the batch RPCA layer runs
- **THEN** it SHALL surface the correlated/multivariate anomaly
- **AND** with the layer disabled, the edge and seasonal tiers SHALL continue to function unchanged

### Requirement: Engine Documentation And Dead-Code Hygiene

The anomaly engine's code and documentation SHALL reflect reality. The dead `peak_profile` kernel
(`rust/causal-disposition/.../peak_profile`, which `types.rs:8` admits has no NIF ABI and which
has zero production callers) SHALL be removed or unambiguously marked as dead/non-wired.
Documentation that states the capacity forecaster's "phase 2 is not wired" SHALL be corrected,
since the capacity forecaster is live (`capacity_forecasting/worker.ex:368`). Documentation SHALL
describe the engine as a robust statistical detector, a seasonal/forecast disposition engine, and
a deterministic dependency expert system.

#### Scenario: Dead kernel removed or marked

- **GIVEN** the `peak_profile` kernel has no NIF ABI and no production callers
- **WHEN** the change is implemented
- **THEN** the kernel SHALL be removed, OR clearly marked dead/non-wired so no reader mistakes it for a live path

#### Scenario: Stale capacity documentation corrected

- **GIVEN** documentation claiming capacity "phase 2 is not wired"
- **WHEN** the documentation is reviewed
- **THEN** it SHALL be corrected to reflect that the capacity forecaster is live

### Requirement: Honest End-To-End Engine Documentation

The change SHALL author a single-source-of-truth end-to-end documentation set for the anomaly
engine under the Docusaurus content directory (`docs/docs/`, registered in `docs/sidebars.ts`),
and SHALL remove causal-inference claims from the engine's own code module-docs/comments
(`rust/anomaly-core`, `rust/anomaly-addon`, `rust/causal-disposition`, `rust/causal-engine`,
`causal_disposition_nif`, and the Elixir `observability` modules) and from the docs site (the
existing `docs/docs/anomaly-detection.md` overclaims and SHALL be overhauled or superseded). The
new documentation SHALL cover: the two-tier architecture (edge robust spike detector + core
seasonal/capacity disposition + the deterministic dependency expert system); the exact data
contract (gauges vs monotonic counters, rate normalization, counter wrap/reset, the directional
saturation gate, series keying); the actual statistics (rolling robust z-score; hour-of-week
residual-z / S-H-ESD; OLS + Holt-Winters capacity); honest naming (what is and is NOT causal); the
disposition loop; operations/tuning knobs; and how to run the proof harness (`tools/anomaly-proof`).
The change SHALL NOT rewrite other proposals' archived history.

#### Scenario: End-to-end engine doc set authored and registered

- **GIVEN** the documentation overhaul is implemented
- **WHEN** the docs site is built
- **THEN** a new end-to-end anomaly-engine document set SHALL exist under `docs/docs/` and be registered in `docs/sidebars.ts`
- **AND** it SHALL cover architecture, data contract, statistics, honest naming, the disposition loop, operations/tuning, and how to run the proof harness

#### Scenario: Causal-inference claims removed from code docs and docs site

- **GIVEN** engine code module-docs/comments and the docs site that assert causal inference
- **WHEN** the overhaul is complete
- **THEN** those causal-inference claims SHALL be removed (the detector/disposition layer described as statistics; the expert system described as deterministic rule + dependency-graph reasoning)
- **AND** the stale `docs/docs/anomaly-detection.md` SHALL be overhauled or superseded by the new set

### Requirement: Anti-Hallucination Proof-Harness Acceptance Gate

Every behavioral requirement in this change SHALL be proven by a reproducible proof-harness
scenario that exercises the **real** code — the `rust/anomaly-core` detector via the
`target/debug/anomaly-backtest` binary (built from `rust/anomaly-core/src/bin/anomaly-backtest.rs`)
driven by `tools/anomaly-proof/{gen.py,plot.py}`, and the **real** Elixir seasonal/capacity workers
plus the `causal_disposition` NIF — over **synthetic labeled datasets** (bounded percent gauges
for cpu/mem/disk and monotonic SNMP counters, with injected spike, step, drift, off-cycle, and
counter wrap/reset anomalies), with **no production database** (the core half runs against the
`srql-fixtures` CNPG scratch database or a local TimescaleDB CAGG). The harness SHALL emit
precision, recall, and detection-latency scorecards and labeled-overlay plots. The
`anomaly-backtest` binary SHALL be extended to expose the `ReasonContext` fields it currently
hardcodes off (`seasonal_enabled`/`trend_enabled`/`min_std_floor`/`min_cv`/`saturation_gate`) so
the stability-gate, MAD, CUSUM, and seasonal requirements are provable rather than asserted. A
behavioral requirement SHALL NOT be considered satisfied on assertion alone.

#### Scenario: Each requirement maps to a harness scenario over real code

- **GIVEN** a behavioral requirement in this change
- **WHEN** acceptance is evaluated
- **THEN** there SHALL be a harness scenario that exercises the real detector or worker code on a labeled dataset and reports precision/recall/detection-latency
- **AND** the harness SHALL NOT use the production database

#### Scenario: Self-masking regression is caught by the harness

- **GIVEN** a labeled dataset containing a large sustained spike followed by a second spike
- **WHEN** the harness runs the real edge detector
- **THEN** the scorecard SHALL show whether the second spike is still detected (recall) under the chosen dispersion estimator
- **AND** a regression that lets the first spike mask the second SHALL be visible in the recall metric

## RENAMED Requirements

- FROM: `### Requirement: External Causal Signal Normalization`
- TO: `### Requirement: External Signal Normalization`

## MODIFIED Requirements

### Requirement: External Signal Normalization

The system SHALL normalize external SIEM and BMP/BGP routing events into a common **signal
envelope** (the previously "causal" envelope, renamed for honesty) with source provenance and
replay-safe identity. This envelope is **shared** with the anomaly verdict path, the BMP/BGP
routing path, and the topology-overlay path, so its naming is corrected on the wire as a single
**BREAKING** schema change. The honest renaming SHALL cover the verdict `signal_type` discriminator
value `"causal"`, the NATS subject namespace (`signals.causal.predictions.*` and the causal
envelope subjects consumed by `causal_signals.ex`), and the `SignalSchemaRef` / schema names. To
avoid a flag-day, the rename SHALL be delivered as a **versioned envelope with dual-publish +
dual-consume** during a cutover window (see design D7): producers publish both old and new forms,
consumers accept both, and the old subject/field is dropped only after all producers and consumers
have migrated. The normalization behavior, provenance, replay-safe identity, and topology-overlay
eligibility SHALL be preserved across the rename.

#### Scenario: BMP event normalized into the renamed signal envelope

- **GIVEN** a BMP routing event is received from the external BMP collector path
- **WHEN** the event enters the observability pipeline
- **THEN** the system SHALL normalize it into the signal envelope with signal type, severity, source, and event identity fields
- **AND** the normalized event SHALL be eligible for topology overlay evaluation

#### Scenario: SIEM alert normalized with provenance

- **GIVEN** a SIEM alert event is received from an external source
- **WHEN** the event is normalized
- **THEN** the signal envelope SHALL include source provenance, detection timestamp, and normalized severity

#### Scenario: Dual-publish/dual-consume cutover preserves delivery

- **GIVEN** the de-causal rename is mid-cutover with both old (`signals.causal.predictions.*`) and new subjects active
- **WHEN** a producer publishes an envelope and a not-yet-migrated consumer reads it
- **THEN** the consumer SHALL still receive and normalize the event (dual-consume)
- **AND** the old subject/field SHALL be dropped only after all producers and consumers have migrated
