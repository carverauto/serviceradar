# agent-connectivity Specification

## Purpose
TBD - created by archiving change update-agent-saas-connectivity. Update Purpose after archive.
## Requirements
### Requirement: Agent-initiated SaaS connection
Agents MUST initiate outbound gRPC connections to the SaaS control plane using mTLS. The SaaS control plane MUST NOT require inbound connections to the agent for routine monitoring operation.
The SaaS control plane MUST validate the client certificate chain against the platform root CA and MUST reject connections whose issuer CA does not match a stored tenant CA record.

#### Scenario: Agent starts with valid credentials
- **GIVEN** an agent has a configured SaaS endpoint and valid mTLS credentials
- **WHEN** the agent starts
- **THEN** the agent establishes an outbound gRPC connection to the SaaS control plane
- **AND** no inbound ports are required on the agent host

#### Scenario: Invalid credentials are rejected
- **GIVEN** an agent presents invalid or expired mTLS credentials
- **WHEN** the agent attempts to connect
- **THEN** the SaaS control plane rejects the connection
- **AND** the agent records a connection failure

#### Scenario: Unknown tenant CA is rejected
- **GIVEN** an agent presents a valid certificate chain that does not match any stored tenant CA
- **WHEN** the agent attempts to connect
- **THEN** the SaaS control plane rejects the connection
- **AND** no tenant mapping is created

### Requirement: Agent hello and enrollment
Agents MUST send a `Hello` request after establishing a connection. The `Hello` payload SHALL include agent identity metadata (agent ID), hostname, capabilities, and agent version. The SaaS control plane SHALL derive the tenant identity by matching the server-validated issuer CA SPKI hash (SHA-256 of the issuer public key) to the stored tenant CA record, and SHALL derive component identity and partition from the client certificate CN format `<component-id>.<partition-id>.<tenant-slug>.serviceradar`. The SaaS control plane SHALL NOT use `Hello` fields to override tenant identity or component identity derived from the certificate. The SaaS control plane SHALL register new agents or update existing agent status and publish an Ash pubsub event for enrollment updates.

#### Scenario: New agent enrollment
- **GIVEN** the SaaS control plane has never seen the agent identity before
- **WHEN** the agent sends `Hello`
- **THEN** the system registers the agent under the tenant identified by mTLS
- **AND** the system publishes an enrollment event via Ash pubsub

#### Scenario: Existing agent status refresh
- **GIVEN** the agent is already registered
- **WHEN** the agent sends `Hello`
- **THEN** the system updates the agent's last-seen timestamp and online status
- **AND** the system publishes an enrollment update event via Ash pubsub

#### Scenario: Hello agent ID mismatch
- **GIVEN** the agent sends a `Hello` with an agent ID that does not match the client certificate CN component ID
- **WHEN** the SaaS control plane processes the request
- **THEN** the system rejects the `Hello` request
- **AND** no enrollment update is recorded

### Requirement: Configuration retrieval from tenant data
Agents MUST call `GetConfig` after a successful `Hello`. The SaaS control plane SHALL return configuration generated from tenant data stored in CNPG via Ash resources, including the agent role and checker assignments.

#### Scenario: Initial configuration returned
- **GIVEN** a newly enrolled agent
- **WHEN** the agent calls `GetConfig`
- **THEN** the SaaS control plane returns the full configuration for that agent
- **AND** the response includes a configuration version identifier

#### Scenario: Configuration reflects UI changes
- **GIVEN** a tenant admin updates monitoring settings in the UI
- **WHEN** the agent calls `GetConfig` after the update
- **THEN** the SaaS control plane returns configuration reflecting the new settings

### Requirement: Versioned config polling
Agents MUST poll `GetConfig` at least every 5 minutes and include the last applied configuration version. The SaaS control plane SHALL return `not_modified` when no changes are available.

#### Scenario: No config changes
- **GIVEN** the agent has applied configuration version "v1"
- **WHEN** the agent polls `GetConfig` with version "v1"
- **THEN** the SaaS control plane responds with `not_modified`

#### Scenario: Config update detected
- **GIVEN** the agent has applied configuration version "v1"
- **AND** the SaaS control plane has generated version "v2"
- **WHEN** the agent polls `GetConfig` with version "v1"
- **THEN** the SaaS control plane returns the new configuration with version "v2"

### Requirement: Minimal bootstrap configuration
The on-disk agent bootstrap configuration MUST only include the SaaS endpoint, mTLS credentials, and optional agent identity overrides. All monitoring roles, checks, and schedules MUST be delivered by `GetConfig`.

#### Scenario: Agent starts with minimal bootstrap config
- **GIVEN** the agent bootstrap config contains only endpoint and credential settings
- **WHEN** the agent starts and completes `Hello`
- **THEN** the agent retrieves its monitoring role and assignments from `GetConfig`
- **AND** no per-check configuration is required on disk

### Requirement: Tenant gateway endpoint selection
Agents MUST connect to a tenant-specific gateway endpoint that resolves to the tenant's gateway pool. The endpoint MUST be delivered via onboarding/config and SHOULD be a stable DNS name.

#### Scenario: Onboarding provides tenant gateway endpoint
- **GIVEN** a tenant admin downloads an onboarding package
- **WHEN** the agent starts
- **THEN** the agent connects to the tenant-specific gateway endpoint from its config
- **AND** the endpoint matches the tenant's DNS convention

#### Scenario: Endpoint load-balances across gateway pool
- **GIVEN** the tenant gateway endpoint resolves to multiple gateway instances
- **WHEN** the agent connects
- **THEN** the connection is established to any healthy gateway in the pool
- **AND** retries can reach other instances if the first is unavailable

### Requirement: Agents fetch rollout artifacts through agent-gateway
Agents SHALL fetch rollout artifact payloads through `agent-gateway` rather than requiring direct connectivity to external repository hosts. The rollout command SHALL carry a gateway-servable artifact reference or URL for the selected artifact.

#### Scenario: Agent downloads a mirrored release from gateway
- **GIVEN** an active rollout target references a mirrored artifact for version `v1.2.3`
- **WHEN** the gateway dispatches the release command to the connected agent
- **THEN** the command payload includes the gateway-served artifact reference or download URL
- **AND** the agent downloads the artifact from `agent-gateway`

#### Scenario: Agent remains blocked from unauthorized artifact access
- **GIVEN** an agent attempts to fetch a release artifact that is not associated with one of its authorized rollout targets
- **WHEN** the request reaches `agent-gateway`
- **THEN** the gateway rejects the request
- **AND** the agent does not receive the artifact payload

### Requirement: Desired-version reconciliation on reconnect
After an agent completes `Hello` and establishes its control stream, the control plane SHALL compare the agent's reported current version against any stored desired version or active rollout target. If the agent is eligible for an update, the gateway SHALL deliver the update instruction without waiting for the next config poll.

#### Scenario: Reconnected agent resumes pending rollout
- **GIVEN** an agent has a pending rollout target for version `v1.2.3`
- **AND** the agent was offline when the rollout began
- **WHEN** the agent reconnects, completes `Hello`, and reports current version `v1.2.2`
- **THEN** the control plane reconciles the pending target
- **AND** the gateway delivers the update instruction over the control stream if the rollout batch is currently eligible

#### Scenario: No update when agent already matches desired version
- **GIVEN** an agent reconnects and reports current version `v1.2.3`
- **AND** the stored desired version for that agent is `v1.2.3`
- **WHEN** version reconciliation runs
- **THEN** no update instruction is sent
- **AND** the agent remains compliant with the desired state

### Requirement: Agent control stream
Agents SHALL establish a long-lived, agent-initiated gRPC control stream to the agent-gateway after successful Hello. The control stream SHALL carry command messages and push-config updates. The stream MUST use mTLS and MUST NOT require inbound connections to the agent.

#### Scenario: Agent opens control stream
- **GIVEN** an agent has completed Hello and is connected to the gateway
- **WHEN** the agent starts its control channel
- **THEN** the agent establishes a long-lived gRPC control stream to the gateway
- **AND** the gateway records the agent as online for command delivery

### Requirement: Push-config delivery
The gateway SHALL be able to push configuration updates to connected agents over the control stream. Agents SHALL apply pushed configs immediately and acknowledge the applied config version.

#### Scenario: Push config to connected agent
- **GIVEN** an agent is connected on the control stream
- **AND** the control plane generates a new config version
- **WHEN** the gateway pushes the config update
- **THEN** the agent applies the config without waiting for the next poll
- **AND** the agent acknowledges the new config version

### Requirement: Command bus for on-demand actions
The system SHALL provide a command bus over the control stream that can trigger agent capabilities on demand. Commands SHALL include an id, type, payload, and TTL, and agents SHALL respond with ack/progress/result messages.

#### Scenario: Command is acknowledged and completed
- **GIVEN** an agent is connected and supports the requested capability
- **WHEN** the gateway sends a command with a valid payload
- **THEN** the agent sends an acknowledgment
- **AND** the agent reports progress or completion
- **AND** the gateway exposes the result to the UI API

#### Scenario: Offline agent command fails fast
- **GIVEN** an admin triggers a command for an agent that is not connected
- **WHEN** the command is submitted
- **THEN** the API returns an immediate error indicating the agent is offline
- **AND** the command is not queued for later delivery

### Requirement: Persistent command lifecycle
The system SHALL persist agent commands with a stateful lifecycle, including queued, sent, acknowledged/running, completed, failed, expired, canceled, and offline states. Commands SHALL transition to `offline` immediately when submitted for a disconnected agent. Command history SHALL be retained for 2 days before cleanup.

#### Scenario: Command completes successfully
- **GIVEN** an on-demand command is submitted for a connected agent
- **WHEN** the agent acknowledges and completes the command
- **THEN** the command record transitions from `queued` → `sent` → `acknowledged`/`running` → `completed`
- **AND** the completion result is persisted for audit for 2 days

#### Scenario: Command expires without completion
- **GIVEN** an on-demand command has exceeded its TTL
- **WHEN** the command has not completed
- **THEN** the command record transitions to `expired`
- **AND** the command is retained for 2 days before cleanup

#### Scenario: Command fails because agent is offline
- **GIVEN** an on-demand command is submitted for an offline agent
- **WHEN** the command is dispatched
- **THEN** the command record transitions immediately to `offline`

