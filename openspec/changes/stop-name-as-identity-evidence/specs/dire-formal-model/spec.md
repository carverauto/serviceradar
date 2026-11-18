## MODIFIED Requirements

### Requirement: Source Identifier Change Is Modeled
The DIRE resolution model SHALL represent a device's source-authoritative identifier as state that a re-key action can change, together with exact source collections, the absence of an identifier from them, its retirement, and the reconciler's succession merge, and every resolution `goal` configuration whose environment enables re-keys SHALL check that, once neither retirement nor succession can change anything, each physical device whose re-keys kept its first-seen time is described by at most one live record holding a source identifier, and each physical device re-keyed to an identifier carrying a new first-seen time is described by separate records that a recorded review names together.
The goal configurations SHALL also check that a device's current source identifier, once
owned, is owned by its canonical record; that no merge joins two records holding distinct
current source identifiers; that every succession merge had a shared universally administered
MAC, an agreeing first-seen time and a one-to-one pairing; that no succession merge, adoption or
reactivation rests on a hostname; and that no live record holds neither an identifier nor an
address. Re-keys SHALL be gated by a constant, so that an environment that does not enable them
keeps its existing state space. Devices SHALL be able to share a hostname, and a re-key SHALL be
able to give a device a new first-seen time; a goal configuration SHALL check each, one with
cloned machines sharing a MAC and a hostname and one with a re-key to an identifier carrying a
new first-seen time, which SHALL end with the two records separate and a review naming them. A
goal configuration with a re-key that keeps its first-seen time SHALL end with one live source
record for that device, and a configuration that proves succession is reachable
on an agreeing first-seen time SHALL accompany them.

#### Scenario: A re-keyed device converges in the goal configuration
- **WHEN** a goal configuration whose environment re-keys one device observed by Armis and the sweep, keeping its first-seen time, is model checked
- **THEN** every goal property holds, including one live source record per device at rest, not separate records under a review

#### Scenario: A retired identifier that still vetoes is rejected
- **WHEN** the goal configuration for the re-key environment is model checked with a retired identifier still vetoing succession
- **THEN** TLC reports a violation of the one-source-record-per-device property

#### Scenario: Succession is reachable
- **WHEN** the vacuity configuration for succession is model checked
- **THEN** TLC reports a violation of the property that no succession merge ever happens

#### Scenario: Cloned machines stay separate in the goal configuration
- **WHEN** a goal configuration whose environment has two devices sharing a MAC and a hostname, either of which may leave its source, is model checked
- **THEN** every goal property holds, including that no two physical devices share a live record

#### Scenario: A re-key with a new first-seen time is reviewed, not merged
- **WHEN** a goal configuration whose environment re-keys one device to an identifier carrying a new first-seen time is model checked
- **THEN** every goal property holds, including that the old and new records stay separate and a recorded review names them

#### Scenario: No identity step rests on a hostname
- **WHEN** any goal configuration is model checked
- **THEN** the property that no succession merge, adoption or reactivation was decided by a hostname holds

### Requirement: Rejected Identity Alternatives Have Negative Configurations
The DIRE resolution model SHALL represent each design alternative rejected for identity safety as a member of a constant set of unsafe alternatives, separate from the defect switches, and SHALL have one negative configuration per alternative that enables only it and expects TLC to report a violation of the property that no two physical devices share a live record.
The alternatives SHALL include succession on a shared MAC without corroboration, resolution
that ignores retired identifiers when a source re-issues an old identifier, a hostname that
corroborates without the time guard, a hostname that corroborates succession or reactivation
under the time guard, and hostname-agreement adoption of an address holder under the refusals it
had before this change. No goal configuration and no trace configuration SHALL enable an unsafe
alternative.

#### Scenario: MAC-only succession is unsafe
- **WHEN** the negative configuration enabling MAC-only succession, in an environment where two devices share a MAC, is model checked
- **THEN** TLC reports a violation of the no-false-merge property and the test passes

#### Scenario: Forgetting retired identifiers is unsafe
- **WHEN** the negative configuration that ignores retired identifiers, in an environment where a source re-issues identifiers, is model checked
- **THEN** TLC reports a violation of the no-false-merge property and the test passes

#### Scenario: A hostname without the time guard is unsafe
- **WHEN** the negative configuration that lets a hostname corroborate without the time guard, in an environment where two cloned machines share a MAC and a hostname, is model checked
- **THEN** TLC reports a violation of the no-false-merge property and the test passes

#### Scenario: A hostname under the time guard is unsafe
- **WHEN** the negative configuration that lets a hostname corroborate under the time guard, in an environment where a second device with the first device's MAC and hostname enters the source only after the first has left it, is model checked
- **THEN** TLC reports a violation of the no-false-merge property and the test passes

#### Scenario: Hostname-agreement adoption is unsafe
- **WHEN** the negative configuration that adopts an address holder on hostname agreement under its former refusals, in an environment where two same-named devices known to different integration providers meet at one address, is model checked
- **THEN** TLC reports a violation of the no-false-merge property and the test passes

#### Scenario: A rejected alternative stops being unsafe
- **WHEN** a negative configuration is model checked and TLC finds no violation, or reports a different property
- **THEN** the test fails
