## MODIFIED Requirements
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

### Requirement: NATS Channel Tenant Prefixing

All NATS messages from edge components SHALL use tenant-prefixed channel names.

#### Scenario: Gateway status uses tenant prefix
- **WHEN** gateway publishes a status update
- **THEN** message is published to `<tenant-id>.gateways.status`
- **AND** only subscribers with matching tenant prefix receive the message

#### Scenario: Agent status uses tenant prefix
- **WHEN** agent publishes status update
- **THEN** message is published to `<tenant-id>.agents.status`
