# srql delta

## ADDED Requirements

### Requirement: Overlap declared side reads the persisted declared relation

The `device_sweep_overlap` entity's declared side SHALL be sourced from the
per-group persisted declared-target relation with agent eligibility derived
from the sweep group's agent assignment, and SHALL report the
`declared_not_observed`, `declared_and_observed` and `observed_not_declared`
relationship classes in production without any persisted compiled sweep
config document.

#### Scenario: Declared but never observed is reported

- **GIVEN** an enabled sweep group declaring a target for which no coverage
  row exists
- **WHEN** an operator queries the overlap entity
- **THEN** a `declared_not_observed` row SHALL be reported for that target
- **AND** the row SHALL name the sweep group and, for a fixed-subset group,
  the selected agent that owes the sweep

#### Scenario: Declared and observed is reported

- **GIVEN** an enabled sweep group declaring a target for which a coverage
  row exists
- **WHEN** an operator queries the overlap entity
- **THEN** a `declared_and_observed` row SHALL be reported for that target
- **AND** it SHALL carry both the declaration and the observation

#### Scenario: Observed without any declaration is still reported

- **GIVEN** a coverage row whose device and IP no enabled sweep group
  declares
- **WHEN** an operator queries the overlap entity
- **THEN** an `observed_not_declared` row SHALL be reported
- **AND** the declared side's rewrite SHALL NOT change the observed side

#### Scenario: Partition-wide groups declare once for any agent

- **GIVEN** an enabled partition-wide sweep group (no selected agents)
- **WHEN** its declared targets are reported
- **THEN** the declaration SHALL be compatible with coverage reported by any
  agent in the group's partition
- **AND** a disabled group SHALL declare nothing, matching what the compiler
  delivers

#### Scenario: Declaration timestamp reflects the snapshot

- **GIVEN** a declared row reported by the overlap entity
- **WHEN** its declaration timestamp is read
- **THEN** it SHALL state when the group's declared relation was last
  refreshed, exposed as `declared_at`
- **AND** it SHALL NOT claim to be a config delivery time
