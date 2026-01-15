## MODIFIED Requirements
### Requirement: Agent-initiated control plane connection
Agents MUST initiate outbound gRPC connections to the platform control plane using mTLS. The control plane MUST NOT require inbound connections to the agent for routine monitoring operation. The control plane MUST validate the client certificate chain against the platform root CA and MUST reject connections whose issuer CA does not match a stored platform workload scope.

#### Scenario: Agent starts with valid credentials
- **GIVEN** an agent has a configured gateway endpoint and valid mTLS credentials
- **WHEN** the agent starts
- **THEN** the agent establishes an outbound gRPC connection to the control plane
- **AND** no inbound ports are required on the agent host

#### Scenario: Invalid credentials are rejected
- **GIVEN** an agent presents invalid or expired mTLS credentials
- **WHEN** the agent attempts to connect
- **THEN** the control plane rejects the connection
- **AND** the agent records a connection failure

#### Scenario: Unknown issuer CA is rejected
- **GIVEN** an agent presents a valid certificate chain that does not match any stored workload scope
- **WHEN** the agent attempts to connect
- **THEN** the control plane rejects the connection
- **AND** no workload mapping is created

### Requirement: Agent hello and enrollment
Agents MUST send a `Hello` request after establishing a connection. The `Hello` payload SHALL include agent identity metadata (agent ID), hostname, capabilities, and agent version. The control plane SHALL derive workload identity by matching the server-validated issuer CA SPKI hash (SHA-256 of the issuer public key) to the stored workload scope, and SHALL derive component identity and partition from the client certificate CN format `<component-id>.<partition-id>.<scope>.serviceradar`. The control plane SHALL NOT use `Hello` fields to override identity derived from the certificate. The control plane SHALL register new agents or update existing agent status and publish an Ash pubsub event for enrollment updates.

#### Scenario: New agent enrollment
- **GIVEN** the control plane has never seen the agent identity before
- **WHEN** the agent sends `Hello`
- **THEN** the system registers the agent under the identity derived from mTLS
- **AND** the system publishes an enrollment event via Ash pubsub

#### Scenario: Existing agent status refresh
- **GIVEN** the agent is already registered
- **WHEN** the agent sends `Hello`
- **THEN** the system updates the agent's last-seen timestamp and online status
- **AND** the system publishes an enrollment update event via Ash pubsub

#### Scenario: Hello agent ID mismatch
- **GIVEN** the agent sends a `Hello` with an agent ID that does not match the client certificate CN component ID
- **WHEN** the control plane processes the request
- **THEN** the system rejects the `Hello` request
- **AND** no enrollment update is recorded

### Requirement: Configuration retrieval from control plane data
Agents MUST call `GetConfig` after a successful `Hello`. The control plane SHALL return configuration compiled by web-ng config compilers from CNPG-backed Ash resources, including the agent role and checker assignments.

#### Scenario: Initial configuration returned
- **GIVEN** a newly enrolled agent
- **WHEN** the agent calls `GetConfig`
- **THEN** the control plane returns the full configuration for that agent
- **AND** the response includes a configuration version identifier

#### Scenario: Configuration reflects UI changes
- **GIVEN** an operator updates monitoring settings in the UI
- **WHEN** the agent calls `GetConfig` after the update
- **THEN** the control plane returns configuration reflecting the new settings
