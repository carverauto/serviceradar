## MODIFIED Requirements
### Requirement: Helm deploys agent-gateway with edge mTLS
Helm installs SHALL deploy `serviceradar-agent-gateway` when enabled in values. The workload SHALL serve edge-facing gRPC and gateway-served edge artifact delivery over tenant-issued mTLS certificates only. The gateway SHALL NOT use SPIFFE identities. Deployments that disable the gateway SHALL not render gateway workloads. If the edge-facing certificate bundle is unavailable, the gateway SHALL fail startup rather than serving plaintext edge listeners.

#### Scenario: Agent-gateway is deployed by Helm
- **GIVEN** a Helm install with agent-gateway enabled
- **WHEN** the chart is rendered and applied
- **THEN** a `serviceradar-agent-gateway` Deployment and Service are created
- **AND** the gateway pod reaches Ready state

#### Scenario: Gateway workload omits SPIRE socket
- **GIVEN** the agent-gateway workload is deployed
- **WHEN** the pod specification is inspected
- **THEN** the SPIRE agent socket is not mounted
- **AND** the gateway serves edge gRPC using tenant-issued mTLS only

#### Scenario: Gateway startup fails without edge certificates
- **GIVEN** the agent-gateway workload starts without the required edge-facing certificate files
- **WHEN** the application initializes the edge gRPC and artifact listeners
- **THEN** startup fails closed
- **AND** the gateway does not serve plaintext listeners for edge traffic

#### Scenario: Gateway disabled removes workloads
- **GIVEN** a Helm install with agent-gateway disabled
- **WHEN** the chart is rendered
- **THEN** no `serviceradar-agent-gateway` Deployment or Service is created

### Requirement: Agent-gateway uses tenant CA for edge mTLS
The agent-gateway SHALL use tenant-issued mTLS certificates for edge agent connections and MUST reject edge connections that are not signed by the expected tenant CA. The gateway's internal control-plane communication SHALL use ERTS where applicable and does not require SPIFFE. Gateway-issued edge certificate bundles SHALL be staged using secure temporary paths so private-key material is not written to predictable shared temp locations during issuance.

#### Scenario: Gateway uses tenant CA for edge mTLS
- **GIVEN** an edge agent presents a certificate signed by the tenant CA
- **WHEN** the agent connects to the gateway
- **THEN** the mTLS handshake succeeds
- **AND** the gateway derives tenant identity from the certificate

#### Scenario: Gateway rejects unknown tenant CA
- **GIVEN** an edge agent presents a certificate signed by an unknown CA
- **WHEN** the agent connects to the gateway
- **THEN** the gateway rejects the connection

#### Scenario: Gateway-issued bundle staging uses secure temp paths
- **GIVEN** the gateway issues an edge mTLS bundle for onboarding
- **WHEN** it stages the private key, CSR, and certificate before assembling the bundle
- **THEN** the staging paths are created with secure exclusive temp handling
- **AND** private-key material is removed during cleanup
