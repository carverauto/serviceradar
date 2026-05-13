## ADDED Requirements

### Requirement: Sweep Ingestion Uses Authoritative Identity
The system SHALL resolve sweep result devices through authoritative CNPG/DIRE lookup before creating provisional devices, updating availability, or evaluating mapper promotion.

#### Scenario: Sweep result has stale cached identity
- **GIVEN** the identity cache contains a stale mapping for a swept IP address
- **WHEN** sweep result ingestion processes that IP
- **THEN** the system SHALL perform authoritative lookup before mutating inventory
- **AND** it SHALL NOT attach sweep status or mapper promotion metadata to a missing, deleted, or wrong device.

#### Scenario: Existing active IP receives sweep result
- **GIVEN** CNPG already contains an active device for a swept IP address
- **WHEN** sweep result ingestion receives an available or unavailable result for that IP
- **THEN** the system SHALL update the existing authoritative device
- **AND** it SHALL NOT attempt to create a duplicate provisional device that violates the active IP uniqueness constraint.

### Requirement: Sweep Compiler Source Isolation
The system SHALL compile sweep targets only from sweep group targeting inputs and authoritative inventory data, and SHALL NOT apply integration-source-only filters unless they are explicitly part of the sweep group configuration.

#### Scenario: Armis source blacklist is configured
- **GIVEN** an Armis integration source has blacklist networks used to suppress imported devices
- **AND** a sweep group targets `in:devices`
- **WHEN** the sweep compiler evaluates the sweep group
- **THEN** the compiler SHALL NOT parse or apply the Armis integration blacklist
- **AND** target generation SHALL be based on the sweep group's query, static targets, and scanner profile only.

### Requirement: Sweep Promotion Metadata Requires Loaded Device
The system SHALL persist mapper promotion metadata only for devices resolved through authoritative loaded inventory records.

#### Scenario: Promotion candidate resolves to stale cache entry
- **GIVEN** a live sweep result matches an IP whose cache entry points at a device that cannot be loaded
- **WHEN** mapper promotion metadata is evaluated
- **THEN** the system SHALL perform authoritative lookup
- **AND** it SHALL skip metadata persistence if no authoritative device exists
- **AND** it SHALL emit a diagnostic that identifies the stale lookup without treating the sweep ingestion as failed.
