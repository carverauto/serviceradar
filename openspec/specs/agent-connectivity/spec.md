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

