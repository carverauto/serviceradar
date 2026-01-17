# tenant-isolation Specification

## Purpose
TBD - created by archiving change implement-per-tenant-process-isolation. Update Purpose after archive.
## Requirements
### Requirement: Per-Tenant Certificate Authority

The system SHALL generate a unique intermediate CA for each tenant, signed by the platform root CA.

#### Scenario: New tenant CA generation
- **WHEN** a new tenant is created
- **THEN** the system generates an intermediate CA with CN `tenant-<tenant_id>.serviceradar`
- **AND** the CA is signed by the platform root CA
- **AND** the CA certificate and key are stored securely

#### Scenario: Tenant CA used for edge certificates
- **WHEN** an edge component (agent, checker) is onboarded for a tenant
- **THEN** the component certificate is signed by that tenant's intermediate CA
- **AND** the certificate CN includes the tenant ID (e.g., `agent-001.tenant-12345.serviceradar`)

### Requirement: Edge Component Certificate Validation

Edge components SHALL validate that connecting peers have certificates from the same tenant CA.

#### Scenario: Same-tenant connection accepted
- **WHEN** agent with tenant-A certificate connects to gateway with tenant-A certificate
- **THEN** the mTLS handshake succeeds
- **AND** the connection is established

#### Scenario: Cross-tenant connection rejected
- **WHEN** agent with tenant-A certificate attempts to connect to gateway with tenant-B certificate
- **THEN** the mTLS handshake fails
- **AND** the connection is rejected with certificate validation error

#### Scenario: Unknown tenant certificate rejected
- **WHEN** component with unknown CA attempts to connect
- **THEN** the mTLS handshake fails
- **AND** the connection is rejected

### Requirement: Core-Elx Tenant Extraction from Certificate

The core-elx service SHALL extract tenant ID from the connecting client's certificate CN.

#### Scenario: Tenant ID extracted from certificate
- **WHEN** edge component connects to core-elx gRPC endpoint
- **THEN** the system parses the certificate CN
- **AND** extracts the tenant ID from the CN pattern `<component>.<tenant-id>.serviceradar`
- **AND** uses that tenant ID for all subsequent operations

#### Scenario: Invalid CN format rejected
- **WHEN** certificate has CN that doesn't match expected pattern
- **THEN** the connection is rejected with invalid certificate error

### Requirement: Tenant-Scoped Onboarding Package

The onboarding system SHALL generate download packages containing tenant-specific certificates.

#### Scenario: Onboarding package includes tenant CA
- **WHEN** admin generates onboarding package in tenant context
- **THEN** the package includes the tenant's intermediate CA certificate
- **AND** the package includes a component certificate signed by tenant CA
- **AND** the package includes the component private key
- **AND** the package includes tenant-specific configuration

#### Scenario: Package config uses tenant channel prefix
- **WHEN** onboarding package is generated
- **THEN** NATS channel configuration uses tenant prefix (e.g., `tenant-12345.agents.status`)
- **AND** component will only publish/subscribe to tenant-prefixed channels

### Requirement: NATS Channel Tenant Prefixing

All NATS messages from edge components SHALL use tenant-prefixed channel names.

#### Scenario: Gateway status uses tenant prefix
- **WHEN** gateway publishes a status update
- **THEN** message is published to `<tenant-id>.gateways.status`
- **AND** only subscribers with matching tenant prefix receive the message

#### Scenario: Agent status uses tenant prefix
- **WHEN** agent publishes status update
- **THEN** message is published to `<tenant-id>.agents.status`

### Requirement: Platform Admin Access

Platform administrators with special certificates SHALL have cross-account access for debugging and support. **This access is provided through the Control Plane, not deployment instances.**

#### Scenario: Platform admin can view all accounts
- **WHEN** user has platform admin credentials
- **THEN** the user can access account data through Control Plane APIs
- **AND** the Control Plane has database credentials with cross-schema access

#### Scenario: Platform admin cannot access instance pods directly
- **WHEN** platform admin attempts to access a deployment instance pod
- **THEN** access is controlled by standard authentication (JWT from Control Plane)
- **AND** the instance pod cannot provide cross-account data (DB credentials are scoped)

#### Scenario: Platform admin connections logged
- **WHEN** platform admin accesses account resources via Control Plane
- **THEN** the access is logged with admin identity and account accessed

### Requirement: Tenant-scoped gateway certificates
Gateway instances SHALL present tenant-scoped certificates signed by the tenant's intermediate CA, and gateways SHALL accept only agent certificates signed by the same tenant CA.

#### Scenario: Tenant gateway cert validation
- **GIVEN** a gateway for tenant "acme" presents a tenant-scoped certificate
- **WHEN** an agent for tenant "acme" connects
- **THEN** the mTLS handshake succeeds
- **AND** the gateway validates the agent cert against tenant "acme" CA

#### Scenario: Cross-tenant agent rejected
- **GIVEN** a gateway for tenant "acme"
- **WHEN** an agent with tenant "beta" certificate connects
- **THEN** the mTLS handshake fails
- **AND** the gateway rejects the connection

### Requirement: Schema-Per-Tenant Data Isolation
The system SHALL create a dedicated PostgreSQL schema for each tenant and store all tenant-scoped data exclusively within that schema.

#### Scenario: Tenant schema created on provisioning
- **WHEN** a tenant is created
- **THEN** a schema named `tenant_<tenant_slug>` SHALL be created
- **AND** tenant migrations SHALL be applied to that schema before the tenant is usable

#### Scenario: Platform tenant uses its own schema
- **WHEN** the platform tenant is provisioned
- **THEN** the schema `tenant_platform` SHALL exist
- **AND** platform tenant data SHALL be stored in that schema, not public

### Requirement: Database-Level Account Isolation

Each deployment instance SHALL connect to PostgreSQL with schema-scoped credentials that only permit access to that instance's schema.

#### Scenario: Instance pod connects with scoped credentials
- **WHEN** a deployment instance pod (core-elx, web-ng) starts
- **THEN** it connects to CNPG using deployment-scoped credentials
- **AND** the PostgreSQL user only has access to that instance's schema
- **AND** the connection's `search_path` is set to that schema

#### Scenario: Cross-schema access prevented by database
- **WHEN** account-A pod attempts to query account-B's schema
- **THEN** PostgreSQL denies access with permission error
- **AND** the query fails without returning data

#### Scenario: Application code does not track schema context
- **WHEN** application code executes an Ash query
- **THEN** no explicit schema context parameter is required
- **AND** the query automatically uses the connection's search_path schema

### Requirement: Control Plane Creates Schema-Scoped Users

The Control Plane SHALL create PostgreSQL users with minimal privileges scoped to a single account schema.

#### Scenario: Account provisioning creates database user
- **WHEN** Control Plane provisions a new account
- **THEN** it creates PostgreSQL user `account_{slug}_app`
- **AND** grants USAGE on the account's schema
- **AND** grants ALL PRIVILEGES on tables and sequences in that schema
- **AND** sets the user's default `search_path` to the account's schema
- **AND** stores credentials in a K8s secret

#### Scenario: Database user cannot access public schema
- **WHEN** account database user attempts to access public schema tables
- **THEN** PostgreSQL denies access (except for explicitly granted read-only tables)

### Requirement: Instance Code Has No Multi-Account Awareness

Instance application code (web-ng, core-elx) SHALL NOT contain logic to access multiple accounts.

#### Scenario: No cross-account queries possible
- **WHEN** reviewing instance codebase
- **THEN** there are no `TenantSchemas.list_schemas()` calls
- **AND** there are no functions that iterate across schemas
- **AND** there is no `SystemActor.platform()` usage

#### Scenario: Ash calls do not pass schema context
- **WHEN** reviewing Ash operations in instance code
- **THEN** there are no explicit schema context parameters passed
- **AND** queries rely on the connection's search_path schema

