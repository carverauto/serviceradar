## ADDED Requirements
### Requirement: Platform Tenant Identifier
The system SHALL create a non-nil, random UUID as the platform tenant ID during bootstrap and persist it for platform service identity mapping.

#### Scenario: Platform tenant UUID is generated
- **WHEN** the platform is bootstrapped for the first time
- **THEN** a random UUID is created for the platform tenant
- **AND** the UUID is stored as the platform tenant identifier

#### Scenario: Platform tenant UUID is stable across restarts
- **GIVEN** the platform tenant UUID exists
- **WHEN** services restart
- **THEN** the same platform tenant UUID is reused

### Requirement: Platform Service mTLS Identities
Platform services SHALL use mTLS identities that map to the platform tenant and are distinguishable from tenant-scoped identities.

#### Scenario: Agent-gateway recognizes platform sync identity
- **GIVEN** a sync service presents platform service credentials
- **WHEN** agent-gateway validates the mTLS identity
- **THEN** the service is classified as platform-level
- **AND** the platform tenant ID is associated with the connection

#### Scenario: Tenant service cannot assume platform identity
- **GIVEN** a tenant-scoped service certificate
- **WHEN** it attempts to use platform-only operations
- **THEN** agent-gateway rejects the request
- **AND** logs the tenant identity and attempted operation
