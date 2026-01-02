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
- **WHEN** an edge component (agent, poller, checker) is onboarded for a tenant
- **THEN** the component certificate is signed by that tenant's intermediate CA
- **AND** the certificate CN includes the tenant ID (e.g., `agent-001.tenant-12345.serviceradar`)

### Requirement: Edge Component Certificate Validation

Edge components SHALL validate that connecting peers have certificates from the same tenant CA.

#### Scenario: Same-tenant connection accepted
- **WHEN** agent with tenant-A certificate connects to poller with tenant-A certificate
- **THEN** the mTLS handshake succeeds
- **AND** the connection is established

#### Scenario: Cross-tenant connection rejected
- **WHEN** agent with tenant-A certificate attempts to connect to poller with tenant-B certificate
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

#### Scenario: Poller heartbeat uses tenant prefix
- **WHEN** poller publishes heartbeat message
- **THEN** message is published to `<tenant-id>.pollers.heartbeat`
- **AND** only subscribers with matching tenant prefix receive the message

#### Scenario: Agent status uses tenant prefix
- **WHEN** agent publishes status update
- **THEN** message is published to `<tenant-id>.agents.status`

#### Scenario: Job dispatch uses tenant prefix
- **WHEN** poller dispatches job to agent
- **THEN** message is published to `<tenant-id>.jobs.<agent-id>`

### Requirement: Platform Admin Access

Platform administrators with special certificates SHALL have cross-tenant access for debugging and support.

#### Scenario: Platform admin can view all tenants
- **WHEN** user has certificate from platform services CA
- **AND** the certificate CN matches `admin.platform.serviceradar`
- **THEN** the user can access resources from any tenant

#### Scenario: Platform admin connections logged
- **WHEN** platform admin accesses tenant resources
- **THEN** the access is logged with admin identity and tenant accessed

