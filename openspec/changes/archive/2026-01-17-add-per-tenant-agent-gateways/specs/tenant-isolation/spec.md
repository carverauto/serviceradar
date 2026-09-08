## ADDED Requirements
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
