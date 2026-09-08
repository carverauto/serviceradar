## ADDED Requirements

### Requirement: Automatic legacy recovery uses narrow system authority
The system SHALL perform automatic legacy assignment recovery only through a
named internal actor and a non-parameterizable background worker. That actor
SHALL be limited by current first-party package trust, current authenticated edge
identity, current schema validation, and current conflict checks. Its system
identity SHALL NOT by itself authorize an uploaded package, caller-supplied
partition, caller-edited configuration, or historical policy state.

#### Scenario: Trusted first-party assignment is eligible
- **GIVEN** a disabled unbound manual assignment references an approved, verified, signed, content-addressed first-party package
- **AND** the exact agent has current authenticated mTLS control-session evidence
- **WHEN** the named recovery worker evaluates the assignment
- **THEN** the worker may create only the corresponding fresh partition-bound assignment after current schema and conflict checks pass
- **AND** the historical row remains disabled and unbound

#### Scenario: System actor cannot expand package trust
- **GIVEN** a disabled unbound assignment references an uploaded, unsigned, unverified, non-first-party, or unavailable package
- **WHEN** automatic recovery evaluates it under the internal actor
- **THEN** no assignment is created or enabled
- **AND** system-actor authority does not bypass package provenance or verification

#### Scenario: Browser cannot parameterize automatic recovery
- **GIVEN** an operator knows a historical assignment identifier
- **WHEN** the operator opens the plugin UI or submits a forged recovery event
- **THEN** the browser cannot select a partition, alter worker inputs, or grant automatic recovery authority
- **AND** fresh user intent must use the normally authorized assignment action

### Requirement: Policy reconciliation uses current owner authority
The system SHALL authorize policy- and credential-rule-owned replacement
assignments only through the existing narrow reconciler for a current enabled
authoritative owner. A historical assignment and a generic system actor SHALL NOT
authorize policy materialization or credential access.

#### Scenario: Current owner materializes desired state
- **GIVEN** a current enabled policy or credential rule targets an agent and package
- **WHEN** its ordinary reconciler evaluates desired state
- **THEN** it may create only the targets, configuration, and credential references produced by that current owner
- **AND** it rechecks package, schema, credential, and mTLS requirements

#### Scenario: Historical owner reference is insufficient
- **GIVEN** a historical policy row refers to a missing, disabled, unsupported, or no-longer-matching owner
- **WHEN** reconciliation runs
- **THEN** no assignment or credential grant is created from the historical row
- **AND** the row remains disabled audit history

### Requirement: Raw recovery history remains internally fenced
The system SHALL restrict raw recovery audit and quarantined-assignment
enumeration to named internal contexts. Normal plugin assignment reads SHALL
exclude disabled partition-unbound history.

#### Scenario: Plugin manager reads normal assignments
- **GIVEN** a plugin manager can view or manage assignments
- **WHEN** the normal assignment collection is read
- **THEN** current bound assignments are returned
- **AND** disabled partition-unbound migration rows and raw recovery audits are not enumerated

#### Scenario: Internal diagnosis reads audit history
- **GIVEN** a named internal audit context investigates a recovery outcome
- **WHEN** it reads the legacy assignment and immutable recovery audit
- **THEN** the records remain available for diagnosis
- **AND** secret values are not present in the recovery audit payload
