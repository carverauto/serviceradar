# sweep-jobs delta

## ADDED Requirements

### Requirement: Sweep declared-target persistence

The system SHALL persist, once per sweep group, the declared relation between
that group and every target it declares -- SRQL-resolved device targets and
static targets together -- and SHALL refresh that relation when the group's
targeting changes, without persisting any compiled sweep config document.

#### Scenario: Group targeting change persists the declared relation

- **GIVEN** a sweep group with a static target and an SRQL target query
- **WHEN** the group is created or its targeting is edited
- **THEN** one declared row SHALL exist per target for that group
- **AND** the SRQL-resolved target SHALL carry the device uid the compiler
  resolves for it
- **AND** a target that is both static and SRQL-resolved SHALL be one row

#### Scenario: Static targets are declared without a device uid

- **GIVEN** a sweep group whose only targets are static CIDRs or IPs
- **WHEN** the declared relation is persisted
- **THEN** each static target SHALL be declared with no device uid
- **AND** the migration introducing the relation SHALL backfill static
  targets for existing groups

#### Scenario: Non-targeting edits do not rewrite the relation

- **GIVEN** a sweep group whose declared relation is persisted
- **WHEN** the group records an execution or changes only its schedule,
  agent assignment, or enabled flag
- **THEN** the declared rows SHALL NOT be rewritten
- **AND** the overlap diagnostic SHALL read agent eligibility and enabled
  state from the live sweep group

#### Scenario: Group deletion removes declared targets

- **GIVEN** a sweep group with persisted declared targets
- **WHEN** the group is deleted
- **THEN** its declared target rows SHALL be removed

#### Scenario: A failed refresh leaves the previous snapshot

- **GIVEN** a sweep group whose declared relation is persisted
- **WHEN** a refresh of that group fails
- **THEN** the previously persisted rows SHALL remain visible
- **AND** the failure SHALL be logged rather than crashing the edit that
  triggered it
