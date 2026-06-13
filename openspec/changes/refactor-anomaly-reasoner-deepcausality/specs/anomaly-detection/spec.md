# Spec Delta: anomaly-detection (DeepCausality reasoner unification)

## ADDED Requirements

### Requirement: Single DeepCausality Reasoner
The anomaly engine SHALL evaluate every metric series through exactly one statistical reasoner, implemented on the DeepCausality library (`deep_causality_core` flow + `deep_causality_data_structures` sliding window) in the `causal_reasoner_nif`. The engine SHALL NOT maintain a second, parallel detector implementation of the rolling statistics in another language or module.

#### Scenario: Per-series evaluation goes through the DeepCausality reasoner
- **GIVEN** a metric sample for a series whose baseline is ready
- **WHEN** the anomaly engine evaluates the sample
- **THEN** the verdict SHALL be produced by the DeepCausality reasoner NIF
- **AND** no divergent in-process reimplementation of the rolling z-score SHALL be consulted

#### Scenario: The hand-rolled compact evaluator is removed
- **GIVEN** the migration is complete and the NIF reasoner is at verdict parity
- **WHEN** the codebase is inspected
- **THEN** the standalone hand-rolled rolling-statistics evaluator SHALL NOT exist as a second reasoner path
- **AND** the bench harness SHALL exercise the reasoner NIF rather than a parallel evaluator

### Requirement: Incremental O(1) Rolling Statistics
The reasoner SHALL maintain rolling baseline statistics incrementally at O(1) per sample using a numerically stable Welford mean/variance accumulator, rather than recomputing mean and variance over the full window on each evaluation.

#### Scenario: Evaluation is constant-time with respect to window size
- **GIVEN** a configured rolling window of size W
- **WHEN** a sample is evaluated against a filled window
- **THEN** the per-sample statistics update SHALL be O(1) in W
- **AND** the oldest value SHALL be removed from the accumulator using the sliding window's evict-candidate before the new value is admitted

#### Scenario: Numerical stability at large magnitudes
- **GIVEN** a baseline of large-magnitude values (for example near 1e9) with small variance
- **WHEN** the reasoner computes the standard deviation
- **THEN** the computed standard deviation SHALL match a numerically stable reference within floating-point tolerance
- **AND** the computation SHALL NOT collapse the standard deviation to zero through catastrophic cancellation

### Requirement: Stateless Caller-Owned Reasoner State
The reasoner SHALL be stateless across calls: the caller SHALL pass the per-series rolling accumulator in, and the reasoner SHALL return the updated accumulator in the verdict so the caller persists compact scalar state rather than a growing baseline list.

#### Scenario: Accumulator is threaded in and out
- **GIVEN** a per-series rolling accumulator of count, mean, and variance state
- **WHEN** the reasoner evaluates a sample
- **THEN** the reasoner SHALL read the rolling statistics from the passed-in accumulator
- **AND** the verdict SHALL include the next accumulator for the caller to persist
- **AND** the persisted per-series state SHALL NOT require storing the full baseline value list

### Requirement: Batched Reasoner Evaluation
The reasoner SHALL expose a batched evaluation entry that processes many (series-state, sample) pairs in a single foreign-function call so per-sample FFI overhead is amortized at high throughput; a single-sample entry SHALL remain available for out-of-order rebuild.

#### Scenario: A batch returns one verdict per sample
- **GIVEN** a batch of N (series-state, sample) pairs
- **WHEN** the batched reasoner entry is invoked once
- **THEN** it SHALL return N verdicts in input order
- **AND** each verdict SHALL be identical to evaluating that pair through the single-sample entry

#### Scenario: Out-of-order rebuild replays through the reasoner
- **GIVEN** a series requiring rebuild from an ordered sample log
- **WHEN** the engine rebuilds the series state
- **THEN** it SHALL replay the ordered samples through the reasoner
- **AND** the resulting accumulator SHALL match in-order incremental evaluation

### Requirement: Reasoner Verdict Parity
Any change to the reasoner statistics or state representation SHALL preserve the verdict contract verified by the reasoner test oracle.

#### Scenario: Verdict contract is preserved
- **GIVEN** an identical context and sample
- **WHEN** the incremental reasoner and the two-pass reference are both evaluated
- **THEN** sample variance SHALL use the (n-1) divisor, the z-score SHALL be the absolute standardized deviation with the documented zero-variance guard, breach SHALL be score at or above n-sigma, breached samples SHALL be withheld from the baseline, consecutive-anomalous hysteresis SHALL increment and reset identically, the insufficient-baseline gate SHALL trigger below the minimum sample count, and non-finite samples SHALL be dropped
- **AND** the incremental and two-pass results SHALL agree within floating-point tolerance over random in-order streams
