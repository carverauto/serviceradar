## ADDED Requirements

### Requirement: Central disposition compute runs in a DeepCausality NIF, not the BEAM
The system SHALL compute central seasonal and capacity disposition statistics in a
Rust Rustler NIF built on the shared `serviceradar-anomaly-core` DeepCausality
streaming substrate, and SHALL NOT compute those statistics in Elixir/BEAM. The
NIF SHALL reuse the existing per-series `CausalFlow` detector core rather than
introducing a second copy of DeepCausality infrastructure. The BEAM SHALL retain
only orchestration (job scheduling, aggregate reads, persistence, verdict emission).

#### Scenario: Seasonal residual scoring is computed in the NIF
- **WHEN** the central seasonal disposition tier scores the latest hour-of-week bucket for a series
- **THEN** the deseasonalized residual, z-score, breach decision, and baseline-sufficiency gate SHALL be computed inside the disposition NIF on the `anomaly-core` substrate
- **AND** no equivalent residual/breach statistic SHALL be computed in Elixir

#### Scenario: Capacity forecast math is computed in the NIF
- **WHEN** the capacity worker forecasts a series from its ordered aggregate samples
- **THEN** the fit (linear / Holt-Winters / seasonal), RMSE/confidence/bounds, exhaustion-ETA, and the insufficient-history gate SHALL be computed inside the disposition NIF
- **AND** the former Elixir capacity model SHALL be removed once the NIF path reaches numeric parity

### Requirement: Typed per-row-isolated batch NIF boundary
The disposition NIF SHALL expose a single batch entrypoint `dispose_batch(kind, rows)`
scheduled on a dirty-CPU scheduler, accepting and returning typed maps/structs (not a
JSON string), and SHALL isolate each row so that a malformed or unscorable row yields an
error result for that row only and never crashes a scheduler thread. Missing or invalid
configuration SHALL be returned as an error result, never as a panic across the FFI
boundary.

#### Scenario: One bad row does not fail the batch
- **GIVEN** a `dispose_batch` call with a batch of rows where one row is malformed
- **WHEN** the NIF processes the batch
- **THEN** it SHALL return a disposition result for every row
- **AND** the malformed row's result SHALL be an error result while the other rows are scored normally

#### Scenario: Missing config returns an error, not a panic
- **GIVEN** a `dispose_batch` row whose required disposition configuration is absent
- **WHEN** the NIF processes that row
- **THEN** it SHALL return an error/skip disposition result for that row
- **AND** it SHALL NOT unwind or panic across the BEAM boundary

### Requirement: Disposition kernels are panic-free at the FFI boundary
The disposition substrate crate SHALL forbid `unwrap`, `expect`, and `panic` in its
disposition code (enforced by a crate-level deny lint), and every detection gate
(insufficient history, insufficient seasonal baseline, zero-variance bucket, non-finite
sample) SHALL return a disposition variant through the verdict/error channel rather than
panicking.

#### Scenario: A gate short-circuits to a verdict variant
- **GIVEN** an input that hits a detection gate (for example a zero-variance bucket or a non-finite sample)
- **WHEN** the disposition kernel evaluates it
- **THEN** it SHALL emit a skip / insufficient-baseline disposition variant
- **AND** it SHALL NOT panic

### Requirement: Profile aggregation stays in SQL; only scoring moves to the NIF
The 168-bucket hour-of-week seasonal profile aggregation SHALL be computed in SQL/SRQL
over the hourly continuous aggregates (a `GROUP BY` over day-of-week and hour-of-day),
and only the deseasonalized residual scoring, breach decision, baseline-sufficiency gate,
and robust-statistic selection SHALL move into the NIF. Where a metric class requires a
robust statistic, SQL SHALL pass the per-bucket order statistics (such as percentile or
median-absolute-deviation values) rather than raw points, keeping the NIF boundary small.

#### Scenario: Profile is aggregated in SQL
- **WHEN** the seasonal worker builds a per-series hour-of-week profile
- **THEN** the per-bucket mean/stddev/count (and any robust order statistics) SHALL be produced by a SQL/SRQL aggregate over the hourly aggregates
- **AND** the NIF SHALL receive the aggregated per-bucket statistics, not the raw bucket points

### Requirement: Latest bucket is excluded from its own seasonal baseline
The seasonal disposition kernel SHALL exclude the latest complete bucket under test from
the mean/stddev distribution it is scored against, because the seasonal baseline is the
historical hour-of-week profile rather than a self-masking sliding window. A bucket SHALL
NOT inflate the baseline it is compared to.

#### Scenario: A drifting bucket cannot hide in its own baseline
- **GIVEN** a series whose latest hour-of-week bucket has drifted far from its historical norm
- **WHEN** the seasonal kernel scores that bucket
- **THEN** the bucket value SHALL be excluded from the mean/stddev it is scored against
- **AND** the drift SHALL register as a breach rather than being absorbed into its own baseline

### Requirement: Insufficient seasonal baseline defers to the edge signal
The seasonal disposition kernel SHALL emit an insufficient-seasonal-baseline disposition
(and SHALL NOT emit a breach) for an hour-of-week bucket with fewer than the configured
minimum historical samples, so that detection during cold-start relies on the edge spike
signal.

#### Scenario: Cold-start bucket defers to edge
- **GIVEN** an hour-of-week bucket with fewer than the configured minimum historical samples
- **WHEN** the seasonal kernel evaluates that bucket
- **THEN** it SHALL emit an insufficient-seasonal-baseline disposition
- **AND** it SHALL NOT emit a breach verdict for that bucket

### Requirement: Capacity disposition preserves the existing forecast semantics
The capacity disposition kernel SHALL reproduce the existing capacity model's numeric
behavior (least-squares / Holt-Winters / seasonal fit, RMSE-based confidence and bounds,
exhaustion-ETA with the implausible-projection horizon guard, and the insufficient-history
skip) within a tight tolerance, validated by a golden-fixture parity check before the
former Elixir model is removed.

#### Scenario: Capacity runway ETA within the horizon is projected
- **GIVEN** a series trending toward its capacity threshold with sufficient history
- **WHEN** the capacity kernel forecasts it
- **THEN** it SHALL emit a projected disposition with an exhaustion ETA, confidence, and bounds
- **AND** that ETA SHALL drive the at-risk classification in the worker

#### Scenario: Insufficient history is skipped, not panicked
- **GIVEN** a series with fewer than the minimum required history points
- **WHEN** the capacity kernel forecasts it
- **THEN** it SHALL emit a skip disposition with an insufficient-history reason
- **AND** it SHALL NOT panic

#### Scenario: NIF output matches the former Elixir model within tolerance
- **GIVEN** a seeded aggregate slice scored by both the former Elixir capacity model and the NIF
- **WHEN** the two forecasts are compared field by field
- **THEN** every numeric field SHALL agree within the configured parity tolerance
- **AND** the former Elixir model SHALL only be removed after this parity check passes
