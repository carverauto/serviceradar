## ADDED Requirements

### Requirement: Source Identifier Change Is Modeled
The DIRE resolution model SHALL represent a device's source-authoritative identifier as state that a re-key action can change, together with exact source collections, the absence of an identifier from them, its retirement, and the reconciler's succession merge, and every resolution `goal` configuration whose environment enables re-keys SHALL check that, once neither retirement nor succession can change anything, at most one live record holding a source identifier describes each physical device.
The goal configurations SHALL also check that a device's current source identifier, once
owned, is owned by its canonical record; that no merge joins two records holding distinct
current source identifiers; that every succession merge had a shared universally administered
MAC, an agreeing first-seen time or hostname, and a one-to-one pairing; and that no live record
holds neither an identifier nor an address. Re-keys SHALL be gated by a constant, so that an
environment that does not enable them keeps its existing state space. A goal configuration
that proves succession is reachable SHALL accompany them.

#### Scenario: A re-keyed device converges in the goal configuration
- **WHEN** a goal configuration whose environment re-keys one device observed by Armis and the sweep is model checked
- **THEN** every goal property holds, including one source record per device at rest

#### Scenario: A retired identifier that still vetoes is rejected
- **WHEN** the goal configuration for the re-key environment is model checked with a retired identifier still vetoing succession
- **THEN** TLC reports a violation of the one-source-record-per-device property

#### Scenario: Succession is reachable
- **WHEN** the vacuity configuration for succession is model checked
- **THEN** TLC reports a violation of the property that no succession merge ever happens

### Requirement: Rejected Identity Alternatives Have Negative Configurations
The DIRE resolution model SHALL represent each design alternative rejected for identity safety as a member of a constant set of unsafe alternatives, separate from the defect switches, and SHALL have one negative configuration per alternative that enables only it and expects TLC to report a violation of the property that no two physical devices share a live record.
The alternatives SHALL include succession on a shared MAC without corroboration, and
resolution that ignores retired identifiers when a source re-issues an old identifier. No goal
configuration and no trace configuration SHALL enable an unsafe alternative.

#### Scenario: MAC-only succession is unsafe
- **WHEN** the negative configuration enabling MAC-only succession, in an environment where two devices share a MAC, is model checked
- **THEN** TLC reports a violation of the no-false-merge property and the test passes

#### Scenario: Forgetting retired identifiers is unsafe
- **WHEN** the negative configuration that ignores retired identifiers, in an environment where a source re-issues identifiers, is model checked
- **THEN** TLC reports a violation of the no-false-merge property and the test passes

#### Scenario: A rejected alternative stops being unsafe
- **WHEN** a negative configuration is model checked and TLC finds no violation, or reports a different property
- **THEN** the test fails

### Requirement: The Lifecycle Model Does Not Assume Expiry Runs
The DIRE lifecycle model SHALL gate ephemeral expiry by a constant, SHALL have a configuration with expiry disabled that checks every must-pass property, and SHALL model the marking of a record whose source identifiers are all retired, its deletion after a grace period, and the rule that no sweep, address-only or MAC-only sighting restores a `source_retired` tombstone.
A configuration that proves the grace deletion is reachable SHALL accompany them.

#### Scenario: The lifecycle goal holds without expiry
- **WHEN** the lifecycle configuration with expiry disabled is model checked
- **THEN** every must-pass property holds

#### Scenario: Evidence never restores a source-retired tombstone
- **WHEN** the lifecycle `current` configuration is model checked
- **THEN** no reachable step restores a `source_retired` tombstone through an evidence sighting

#### Scenario: Grace deletion is reachable
- **WHEN** the vacuity configuration for grace deletion is model checked
- **THEN** TLC reports a violation of the property that no grace deletion ever happens

### Requirement: The Lifecycle Model Restores By Discovery Source
The DIRE lifecycle model SHALL record whether each record was discovered only by sweeps and the reason each tombstone was deleted, SHALL model a sweep's restore with the same rule the sweep ingestor applies, and SHALL check that a sweep write changes only a record that is live after the step and that a sweep matching an expired tombstone restores it.

#### Scenario: The fixed sweep path holds
- **WHEN** the lifecycle `goal` configuration is model checked
- **THEN** the property that a sweep matching an expired tombstone restores it holds
- **AND** no sweep write changes a record that is not live after the step

### Requirement: Regression Traces Cover Source Identifier Change
The committed DIRE traces SHALL include a source-identifier re-key followed by sustained absence and reconciliation, a shared-MAC pair whose first device leaves its source, an identified device taking the only address of a sweep seed, and an expired sweep-only device that answers a sweep again. Each SHALL be model-checked with exactly the defect switches that the code it was recorded from still has, as listed in `formal/dire/CurrentBugs.tla`.
A trace that demonstrates a defect switch which only withholds a step, so that no knockout
configuration can reject it, SHALL instead have a configuration that checks it with those
switches against the property the defect violates and expects that violation. The fix deletes
that configuration with the switch, as it deletes a knockout configuration.

#### Scenario: A trace proves a defect that only withholds a step
- **WHEN** the re-key trace recorded from today's code is model checked with today's defect switches against the one-source-record-per-device property
- **THEN** TLC reports a violation of that property, so the real code exhibits the defect

#### Scenario: A re-keyed device is recorded converging
- **WHEN** the re-key trace runs against the real code after the fix
- **THEN** the recorded trace ends with one live record holding the current source identifier, and TLC accepts it

#### Scenario: Cloned machines stay separate after one leaves its source
- **WHEN** the shared-MAC trace runs and its first device's identifier retires
- **THEN** the recorded trace keeps the two records separate and marks the first `source_retired`, because their first-seen times and hostnames differ

#### Scenario: A released seed is recorded as retired
- **WHEN** the sweep-seed trace runs against the real code after the fix
- **THEN** the recorded trace ends with the seed soft-deleted with reason `seed_released`

#### Scenario: An expired sweep-only device is recorded returning
- **WHEN** the expired-device trace runs against the real code after the fix
- **THEN** the recorded trace ends with the device restored, its revision bumped and a revival audit row written
