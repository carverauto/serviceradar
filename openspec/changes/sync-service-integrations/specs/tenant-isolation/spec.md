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

#### Scenario: Zero UUID is rejected for platform tenant
- **GIVEN** a platform tenant identifier of `00000000-0000-0000-0000-000000000000`
- **WHEN** platform services initialize
- **THEN** the platform tenant ID is rejected as invalid

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

#### Scenario: Platform sync certificate issued with stable identifier
- **GIVEN** the platform tenant exists
- **WHEN** platform bootstrap runs
- **THEN** a platform sync certificate is issued
- **AND** the component identifier remains stable across restarts

### Requirement: mTLS-Derived Tenant Identity
The system SHALL derive tenant_id exclusively from the mTLS certificate identity and MUST NOT accept tenant identifiers supplied by clients.

#### Scenario: Tenant ID resolved from mTLS
- **GIVEN** a service connects with a valid mTLS certificate
- **WHEN** the service calls agent-gateway
- **THEN** the tenant_id is resolved from the certificate identity
- **AND** any tenant_id fields in the request are ignored

### Requirement: Reserved Platform Tenant Slug
The platform tenant SHALL use a reserved slug (default: `platform`), and no non-platform tenant may use that slug.

#### Scenario: Reserved slug blocked for non-platform tenant
- **GIVEN** a tenant creation request with the reserved slug
- **WHEN** the tenant is not marked as platform
- **THEN** the request is rejected with a slug validation error

#### Scenario: Platform tenant uses reserved slug
- **GIVEN** a platform tenant
- **WHEN** it is created or updated
- **THEN** its slug matches the reserved platform slug
