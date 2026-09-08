# tenant-isolation Specification Deltas

## MODIFIED Requirements

### Requirement: Platform Admin Access

Platform administrators SHALL access cross-tenant resources via the Control Plane API, not through tenant instances.

#### Scenario: Platform admin uses Control Plane for cross-tenant access
- **WHEN** platform administrator needs to view resources across tenants
- **THEN** the administrator uses Control Plane API endpoints
- **AND** the Control Plane aggregates data from tenant-specific databases
- **AND** tenant instances do NOT receive cross-tenant queries

#### Scenario: Platform admin cannot bypass tenant instance isolation
- **WHEN** platform administrator authenticates to a tenant instance
- **THEN** the administrator operates within that tenant's context only
- **AND** no cross-tenant data is accessible from the tenant instance

#### Scenario: Cross-tenant audit logging in Control Plane
- **WHEN** platform admin accesses tenant resources via Control Plane
- **THEN** the access is logged in the Control Plane audit log
- **AND** the log includes admin identity, tenants accessed, and actions performed

## ADDED Requirements

### Requirement: Control Plane Separation

The system SHALL separate Control Plane (tenant management) from Tenant Instances (runtime).

#### Scenario: Tenant Instance cannot access other tenant schemas
- **WHEN** a Tenant Instance connects to CNPG
- **THEN** the database connection uses tenant-specific credentials
- **AND** the credentials only grant access to that tenant's schema
- **AND** queries to other schemas fail with permission denied

#### Scenario: Tenant Instance cannot manage tenant lifecycle
- **WHEN** background operations run in a Tenant Instance
- **THEN** the operations cannot create, modify, or delete tenant records
- **AND** tenant lifecycle operations are rejected with authorization error

#### Scenario: Control Plane manages tenant provisioning
- **WHEN** a new tenant is created
- **THEN** the Control Plane creates the tenant record
- **AND** provisions the CNPG schema with restricted user
- **AND** generates NATS account JWT
- **AND** deploys or configures Tenant Instance workloads

### Requirement: JWT-Based Tenant Context

Tenant Instances SHALL derive authorization from JWT claims issued by the Control Plane.

#### Scenario: User JWT contains tenant context
- **WHEN** user authenticates via Control Plane
- **THEN** the issued JWT contains tenant_id claim
- **AND** the JWT contains role claim (admin, operator, viewer)
- **AND** the JWT is signed by Control Plane signing key

#### Scenario: Tenant Instance validates JWT signature
- **WHEN** request arrives at Tenant Instance with JWT
- **THEN** the Tenant Instance validates JWT signature
- **AND** extracts tenant_id and role from claims
- **AND** builds actor context from JWT claims
- **AND** does NOT query TenantMembership table

#### Scenario: Invalid JWT rejected
- **WHEN** request arrives with invalid or expired JWT
- **THEN** the Tenant Instance rejects the request with 401
- **AND** does NOT fall back to database authorization lookup

### Requirement: Single-Tenant OSS Deployment

The OSS deployment SHALL operate as single-tenant without multi-tenant overhead.

#### Scenario: OSS deployment auto-provisions platform tenant
- **WHEN** helm install runs for OSS deployment
- **THEN** platform-bootstrap-job creates default tenant
- **AND** generates initial admin user
- **AND** configures Tenant Instance with tenant context

#### Scenario: OSS deployment has no tenant selection UI
- **WHEN** user accesses OSS deployment web interface
- **THEN** the interface does NOT show tenant selection
- **AND** all operations use the default platform tenant context

#### Scenario: OSS deployment excludes Control Plane components
- **WHEN** OSS helm chart is deployed
- **THEN** tenant-workload-operator is NOT deployed
- **AND** Control Plane API is NOT deployed
- **AND** only single Tenant Instance runs

### Requirement: No authorize?: false in Production Code

Production code SHALL NOT use authorize?: false for Ash operations.

#### Scenario: All Ash operations require explicit actor
- **WHEN** Ash operation is performed in production code
- **THEN** an actor parameter is required
- **AND** the actor is derived from authenticated context (user, JWT, or SystemActor)
- **AND** fallback to nil actor is NOT allowed

#### Scenario: SystemActor used for background operations
- **WHEN** background job needs to perform Ash operations
- **THEN** the job uses ServiceRadar.Actors.SystemActor
- **AND** uses for_tenant/2 for tenant-scoped operations
- **AND** uses platform/1 only for legitimate cross-tenant operations
- **AND** authorize?: false is NOT used

#### Scenario: Credo check enforces authorization pattern
- **WHEN** code review runs Credo checks
- **THEN** any usage of authorize?: false triggers warning
- **AND** the warning references SystemActor as alternative
