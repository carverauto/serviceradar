## ADDED Requirements

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
A change that fixes a modeled DIRE defect MUST remove the defect's switch from the model and add the invariant its witness named to the must-pass set of the `current` configuration.

#### Scenario: A defect is fixed in code
- **WHEN** the Elixir code path behind a switch is corrected
- **THEN** the switch is removed, its witness configuration is deleted, and the named invariant is checked as must-pass in `current`

### Requirement: The Model Is Validated Against Real Traces
Integration tests SHALL drive DIRE lifecycle operations against the shared srql-fixtures CNPG database, record a projection of the identity state after each step, and fail when TLC reports that the recorded sequence is not a behavior of the model.

#### Scenario: The code and the model disagree
- **WHEN** the real code produces a state transition the model does not permit
- **THEN** the trace validation test fails

#### Scenario: The trace checker can fail
- **WHEN** a deliberately corrupted trace is checked
- **THEN** TLC rejects it and the recorder self-test passes only because of that rejection

### Requirement: Formal Model Fixtures Are Synthetic
Every trace, fixture and example used by the DIRE formal model and its tests MUST be constructed synthetically, using invented device uids, documentation-range IP addresses and `00:00:5e:00:53:xx` MAC addresses.

#### Scenario: A trace is recorded
- **WHEN** a trace validation test records identity state
- **THEN** every identifier in it was created by the test itself and none was captured from a running deployment
