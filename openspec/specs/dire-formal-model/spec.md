# dire-formal-model Specification

## Purpose
Keep DIRE (the Device Identity and Reconciliation Engine) verifiably correct: TLA+ models of its resolution and lifecycle behavior are model-checked in unit tests, every known defect has a witness that reproduces it, and traces recorded from the real code are checked against the models so the models cannot drift from the code. Created by archiving change add-dire-formal-model.

## Requirements

### Requirement: DIRE Lifecycle Model Checked in Unit Tests
The repository SHALL contain a TLA+ model of the DIRE device lifecycle whose TLC model checks run as Bazel tests selected by `make test`.
Each action in the model cites the Elixir function it models. A model check that exceeds its
runtime budget is split or reduced, never excluded from `make test`.

#### Scenario: A must-pass invariant breaks
- **WHEN** a change to the model or its `current` configuration lets TLC find a violation of an invariant expected to pass
- **THEN** the corresponding `tlc_test` fails and `make test` fails

#### Scenario: The intended design is checked
- **WHEN** a `goal` configuration, with no known defect enabled, is model checked
- **THEN** every invariant and action property in the model holds

### Requirement: Known DIRE Defects Have Witness Configurations
Each known DIRE defect SHALL be represented by a switch in the model's `Bugs` constant and by a witness configuration that enables only that switch and expects TLC to report one named violated property.
A switch is added only after a TLC counterexample for it is confirmed against the Elixir code.

#### Scenario: The defect is still present in the model
- **WHEN** a witness configuration is model checked and TLC reports a violation of the property it names
- **THEN** the witness test passes

#### Scenario: The witness no longer reproduces
- **WHEN** a witness configuration is model checked and TLC finds no violation, or reports a different property
- **THEN** the witness test fails

### Requirement: Fixing a Modeled Defect Promotes Its Invariant
A change that fixes a modeled DIRE defect MUST remove the defect's switch from the model and from the trace tests' current switches, and MUST make the property its witness named must-pass: in the lifecycle `current` configuration, or in every resolution `goal` configuration.
The traces that exercise the fixed path are regenerated, and the witness configuration and any
trace knockout configuration for the switch are deleted with it.

#### Scenario: A defect is fixed in code
- **WHEN** the Elixir code path behind a switch is corrected
- **THEN** the switch is removed, its witness and knockout configurations are deleted, the affected traces are regenerated and model-checked without it, and the named property is checked as must-pass

### Requirement: The Model Is Validated Against Real Traces
Integration tests SHALL drive the real DIRE resolution and lifecycle entry points against the shared srql-fixtures CNPG database, record the full model state after each step, and fail when a recorded trace differs from its committed copy under `formal/dire/traces`; `make test` SHALL model-check every committed trace and fail when it is not a behavior of the model.
TLC runs only in `make test`; the integration lanes compare traces and never run Java. A
recorded trace is regenerated with `DIRE_TRACE_WRITE=1` and model-checked before it is committed.

#### Scenario: The code's behavior changes
- **WHEN** the real code produces a different sequence of states for a scenario
- **THEN** the integration test fails until the trace is regenerated and committed

#### Scenario: The code and the model disagree
- **WHEN** a committed trace contains a transition the model does not permit
- **THEN** that trace's model check in `make test` fails

#### Scenario: The trace checker can fail
- **WHEN** a trace's final state is altered in exactly one model variable
- **THEN** TLC rejects the altered trace

#### Scenario: A lifecycle trace proves its defect
- **WHEN** a lifecycle trace is checked with the defect switch it demonstrates turned off
- **THEN** TLC rejects the trace, so the real code exhibits that defect

### Requirement: Formal Model Fixtures Are Synthetic
Every trace, fixture and example used by the DIRE formal model and its tests MUST be constructed synthetically, using invented device uids, documentation-range IP addresses and `00:00:5e:00:53:xx` MAC addresses.

#### Scenario: A trace is recorded
- **WHEN** a trace validation test records identity state
- **THEN** every identifier in it was created by the test itself and none was captured from a running deployment
