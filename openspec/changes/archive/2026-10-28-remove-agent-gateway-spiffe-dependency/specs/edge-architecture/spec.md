## MODIFIED Requirements
### Requirement: mTLS Agent Authentication

Edge agents SHALL authenticate using mTLS client certificates. Hosted edge-agent ingress SHALL work without requiring SPIFFE or SPIRE, and certificates SHALL encode the identity information needed for tenant or partition isolation through the tenant CA chain and certificate subject fields.

#### Scenario: Agent presents tenant certificate
- **WHEN** a gateway connects to an agent
- **THEN** mTLS handshake requires client certificate from gateway
- **AND** agent verifies gateway certificate is from platform CA

#### Scenario: Gateway verifies agent tenant
- **WHEN** a gateway receives data from an agent
- **THEN** the gateway extracts tenant or partition identity from the certificate and trust chain
- **AND** verifies agent belongs to expected tenant scope
- **AND** rejects cross-tenant data

#### Scenario: Certificate identity does not require SPIFFE
- **WHEN** an agent certificate is issued during onboarding
- **THEN** the certificate CN encodes the agent identity and partition identity required by the hosted gateway path
- **AND** the certificate is signed by the expected tenant-specific or partition-specific CA
- **AND** the hosted edge-agent path does not require a SPIFFE URI SAN to authenticate the agent

### Requirement: Agent-gateway uses tenant CA for edge mTLS

The agent-gateway SHALL use tenant-issued mTLS certificates for edge agent connections and MUST reject edge connections that are not signed by the expected tenant CA. The gateway's internal control-plane communication SHALL use ERTS where applicable and does not require SPIFFE. Hosted edge-agent authorization SHALL NOT require a SPIFFE URI SAN to be present in the client certificate.

#### Scenario: Gateway uses tenant CA for edge mTLS
- **GIVEN** an edge agent presents a certificate signed by the tenant CA
- **WHEN** the agent connects to the gateway
- **THEN** the mTLS handshake succeeds
- **AND** the gateway derives tenant identity from the certificate

#### Scenario: Gateway rejects unknown tenant CA
- **GIVEN** an edge agent presents a certificate signed by an unknown CA
- **WHEN** the agent connects to the gateway
- **THEN** the gateway rejects the connection

#### Scenario: Hosted edge-agent certificates remain compatible with legacy SPIFFE SANs
- **GIVEN** an existing agent certificate still includes a SPIFFE URI SAN
- **WHEN** the agent connects to the gateway
- **THEN** the gateway continues to accept the certificate if the tenant CA and subject identity are valid
- **AND** the SPIFFE URI SAN is treated as backward-compatible metadata rather than a required identity input

## ADDED Requirements
### Requirement: Hosted edge-agent identity defaults to agent without SPIFFE

For the hosted edge-agent ingress path, the gateway SHALL authorize certificates without a SPIFFE URI SAN by treating the downstream component type as `agent` unless a different non-SPIFFE identity field is explicitly introduced in the future.

#### Scenario: Hosted agent certificate omits SPIFFE SAN
- **GIVEN** a hosted edge agent presents a valid certificate signed by the expected tenant CA
- **AND** the certificate does not include a SPIFFE URI SAN
- **WHEN** the gateway resolves the client identity
- **THEN** the gateway still accepts the certificate
- **AND** it authorizes the client as component type `agent`
- **AND** the request does not fail solely because SPIFFE metadata is absent
