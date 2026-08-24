# network-discovery Specification

## ADDED Requirements

### Requirement: Interface Observations Are Stored as Current State

Discovered interface state SHALL be stored as one current row per
`(device_id, if_index)`, updated in place. A discovery poll SHALL NOT create a new
stored row for an interface whose semantic state is unchanged.

Semantic state SHALL comprise the interface's identity and operational attributes —
name, description, alias, physical address, admin and operational status, speed, MTU,
duplex, type, kind, and its set of IP addresses. It SHALL NOT include per-poll
provenance such as discovery id, mapper job id, or discovery time.

Per-poll provenance SHALL be recorded as last-observation fields on the current row.
Provenance changing alone SHALL NOT constitute a change.

#### Scenario: Repeated polls of an unchanged interface store one row

- **GIVEN** an interface whose attributes and addresses do not change
- **WHEN** it is polled repeatedly over many discovery runs
- **THEN** exactly one current row SHALL exist for that `(device_id, if_index)`
- **AND** its last-observation fields SHALL reflect the most recent poll

#### Scenario: A new discovery id alone is not a change

- **GIVEN** an interface already stored
- **WHEN** a later poll reports identical attributes under a new discovery id, mapper
  job id and discovery time
- **THEN** no additional stored observation SHALL be created

#### Scenario: A real attribute change is recorded

- **GIVEN** an interface stored with operational status `up`
- **WHEN** a poll reports it as `down`
- **THEN** the current row SHALL reflect `down`

### Requirement: Interface Addresses Have a Canonical Order

An interface's IP address set SHALL be stored in a canonical order, so that a
reordered but otherwise identical set is not treated as a change.

#### Scenario: Reordered addresses are not a change

- **GIVEN** an interface stored with addresses `[A, B, C]`
- **WHEN** a poll reports the same addresses in the order `[C, A, B]`
- **THEN** the stored address set SHALL be unchanged
- **AND** no additional stored observation SHALL be created

### Requirement: Interface History Is Bounded and Change-Driven

Where interface history is retained, it SHALL be written only when semantic state
changes, and SHALL have an explicit retention policy. The volume of retained history
SHALL be a function of how often interfaces change, never of how often they are
polled.

#### Scenario: Polling faster does not grow history

- **GIVEN** a deployment that halves its discovery interval
- **WHEN** interface state does not change
- **THEN** the volume of retained interface history SHALL NOT increase

#### Scenario: Retention is enforced

- **GIVEN** interface history older than the configured retention window
- **WHEN** retention runs
- **THEN** that history SHALL be removed
