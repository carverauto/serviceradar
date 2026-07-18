## ADDED Requirements

### Requirement: Typed Integration Identifier Registration
Integration sync ingestion SHALL register typed source identifiers through the shared identity vocabulary when the source integration exposes a stable device identifier, and SHALL keep generic integration identifiers scoped so they cannot override typed identity.

#### Scenario: Armis sync registers typed Armis identifier
- **GIVEN** an Armis device update contains `armis_device_id = A`
- **AND** the update belongs to integration source `S`
- **WHEN** core ingests the sync update
- **THEN** `platform.device_identifiers` SHALL contain a typed `armis_device_id = A` row for the resolved canonical device
- **AND** the identifier metadata SHALL include source linkage for `S`
- **AND** any generic `integration_id` for the same Armis payload SHALL not create a conflicting canonical mapping for `A`

#### Scenario: Generic integration ID is not promoted across sources
- **GIVEN** two integration sources can emit the same generic `integration_id` value
- **WHEN** core ingests updates from both sources
- **THEN** the generic identifiers SHALL remain source-scoped or otherwise disambiguated
- **AND** they SHALL NOT merge devices across sources unless a typed source identifier or another allowed strong identifier also matches

#### Scenario: Sync ingestion is source-type agnostic
- **GIVEN** a current or future integration emits identity through the shared integration identity envelope
- **WHEN** core builds lookup keys and identifier records for the sync batch
- **THEN** it SHALL iterate the shared identity vocabulary rather than branching on one concrete integration driver
- **AND** legacy integration identity bridges SHALL remain lookup-only unless they are the canonical identifier value

### Requirement: Armis Northbound Candidate Identity Validation
Armis northbound candidate loading SHALL use validated typed Armis identifiers as the outbound key and SHALL reject ambiguous or conflicting identity evidence.

#### Scenario: Candidate has stale Armis metadata
- **GIVEN** a device has typed identifier `armis_device_id = A`
- **AND** its metadata contains stale `armis_device_id = B`
- **WHEN** Armis northbound candidate loading runs
- **THEN** the stale metadata disagreement SHALL be treated as an identity conflict
- **AND** the system SHALL NOT send an outbound update for `A` or `B` from that row until the conflict is repaired

#### Scenario: Candidate has split typed and generic identifiers
- **GIVEN** Armis Device ID `A` appears as a typed identifier on device `D1`
- **AND** the same value appears as a generic Armis `integration_id` identifier on device `D2`
- **WHEN** Armis northbound candidate loading runs
- **THEN** the system SHALL prefer the typed Armis identifier path
- **AND** it SHALL skip or flag the generic split candidate rather than merging `D1` and `D2` availability silently

#### Scenario: Candidate conflict prevents wrong northbound update
- **GIVEN** a candidate row cannot be confidently matched to exactly one Armis Device ID for the configured source
- **WHEN** the northbound Armis update job prepares a batch
- **THEN** the row SHALL be excluded from the outbound payload
- **AND** the run result SHALL include skipped conflict counts and representative examples

### Requirement: Source Identity Repair Run Visibility
Integration sync and northbound workflows SHALL expose identity repair/audit status when source identity drift prevents safe processing.

#### Scenario: Operator inspects a northbound run with skipped conflicts
- **WHEN** an Armis northbound run skips devices because of source identity conflicts
- **THEN** the run metadata or emitted event SHALL include the skipped count, conflict categories, and enough identifiers to locate the affected device rows
- **AND** the source's inbound sync success status SHALL remain separate from the northbound conflict status
