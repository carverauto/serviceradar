# ash-domains Specification

## Purpose
TBD - created by archiving change integrate-ash-framework. Update Purpose after archive.
## Requirements
### Requirement: Ash Domain Architecture
The system SHALL organize business logic into Ash domains with clear boundaries and responsibilities.

#### Scenario: Domain isolation
- **WHEN** a developer creates a new resource
- **THEN** the resource MUST belong to exactly one domain
- **AND** cross-domain access MUST go through defined actions

### Requirement: Identity Domain
The system SHALL provide an Identity domain managing users, tenants, sessions, and API tokens.

#### Scenario: Identity domain resources
- **WHEN** the Identity domain is loaded
- **THEN** it SHALL expose User, Tenant, Session, and ApiToken resources
- **AND** all resources SHALL support multi-tenancy

### Requirement: Inventory Domain
The system SHALL provide an Inventory domain managing devices, interfaces, and device groups with OCSF schema alignment.

#### Scenario: Device resource OCSF mapping
- **WHEN** a Device resource is queried
- **THEN** attributes SHALL map to OCSF v1.7.0 Device object columns
- **AND** the source: option SHALL be used for column name mapping

### Requirement: Infrastructure Domain
The system SHALL provide an Infrastructure domain managing pollers, agents, checkers, and partitions.

#### Scenario: Infrastructure resource relationships
- **WHEN** a Poller is queried with agents preloaded
- **THEN** the system SHALL return associated Agent records
- **AND** the relationship SHALL respect tenant and partition boundaries

### Requirement: Monitoring Domain
The system SHALL provide a Monitoring domain managing service checks, alerts, events, and metrics.

#### Scenario: Alert state machine
- **WHEN** an Alert is created
- **THEN** it SHALL start in the pending state
- **AND** state transitions SHALL be enforced by AshStateMachine

### Requirement: Edge Domain
The system SHALL provide an Edge domain managing onboarding packages and events with state machine workflows.

#### Scenario: Package lifecycle
- **WHEN** an OnboardingPackage is created
- **THEN** it SHALL start in the created state
- **AND** valid transitions SHALL include downloaded, installed, expired, and revoked

### Requirement: Multi-Tenant Resource Isolation
All tenant-scoped resources SHALL enforce tenant isolation at the Ash resource level using attribute-based multitenancy.

#### Scenario: Tenant data isolation
- **GIVEN** a user belonging to tenant A
- **WHEN** the user queries for devices
- **THEN** only devices with tenant_id matching tenant A SHALL be returned
- **AND** no manual filtering in controllers SHALL be required

### Requirement: Partition-Aware Queries
Resources in overlapping IP space partitions SHALL support partition-aware authorization policies.

#### Scenario: Partition isolation
- **GIVEN** a user with access to partition P1
- **WHEN** the user queries for pollers
- **THEN** only pollers in partition P1 or global pollers (partition_id = nil) SHALL be returned

