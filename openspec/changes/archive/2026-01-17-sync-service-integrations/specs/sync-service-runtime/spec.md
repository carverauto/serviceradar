# Sync Service Runtime (Agent-Embedded)

## MODIFIED Requirements

### Requirement: Agent Sync Bootstrap via Agent-Gateway
The agent SHALL authenticate to agent-gateway using mTLS and SHALL perform Hello + GetConfig on startup to retrieve its sync runtime configuration.

#### Scenario: Agent sync bootstraps with agent-gateway
- **WHEN** a tenant agent starts
- **THEN** it establishes an mTLS connection to agent-gateway
- **AND** completes the Hello handshake
- **AND** receives its initial configuration via GetConfig

### Requirement: Tenant-Scoped Integration Configuration
The agent SHALL process integrations in a tenant-scoped manner; sync is not executed by platform services.

#### Scenario: Agent receives only tenant-scoped configs
- **GIVEN** a tenant agent with valid mTLS credentials
- **WHEN** it requests configuration
- **THEN** agent-gateway returns only configs for that tenant
- **AND** no cross-tenant integration configs are included

### Requirement: Agent GetConfig Includes Integration Sources
GetConfig responses SHALL be populated from IntegrationSource records created in the UI, including integration settings required by the agent sync runtime.

#### Scenario: UI integration source appears in agent config
- **GIVEN** a tenant admin creates an integration source (e.g., Armis or NetBox)
- **WHEN** the agent calls GetConfig
- **THEN** the response includes that integration source for the tenant
- **AND** the payload includes integration settings required for discovery
- **AND** credentials remain encrypted at rest and are only provided to the agent at runtime

#### Scenario: Agent config delivered as JSON payload
- **GIVEN** an agent requests configuration
- **WHEN** the agent-gateway responds
- **THEN** integration configuration is returned via `config_json`
- **AND** the agent deserializes the JSON payload into its in-memory config

### Requirement: Integration Source Events Stored as OCSF
Integration source lifecycle events SHALL be recorded in the OCSF events table with origin metadata.

#### Scenario: Integration source creation emits OCSF event
- **GIVEN** a tenant admin creates an integration source
- **WHEN** the record is stored
- **THEN** an event is published to the events pipeline
- **AND** the event is stored in `ocsf_events` with tenant metadata, origin service, and source identifiers

### Requirement: Sync Device Updates Flow Through Agent Pipeline
Device updates produced by the agent sync runtime SHALL be forwarded through agent -> agent-gateway -> core-elx and processed by DIRE before device records are written.

#### Scenario: Sync update processed by DIRE
- **GIVEN** a sync device update for tenant-A
- **WHEN** the update is sent to the agent pipeline
- **THEN** core-elx routes the update through DIRE
- **AND** the canonical device record is written to tenant-A schema

### Requirement: Results Streaming Compatibility
The agent sync runtime SHALL push device updates to agent-gateway using the existing StreamStatus RPC and SHALL chunk payloads using ResultsChunk-compatible semantics to respect gRPC message size limits.

#### Scenario: Streamed results exceed single-message limits
- **GIVEN** sync results exceed the configured single-message size limit (e.g., ~15MB total payload)
- **WHEN** the agent pushes results via StreamStatus
- **THEN** it splits the payload into ordered chunks that mirror ResultsChunk sequencing
- **AND** each chunk size remains below the configured gRPC max message size
- **AND** the final chunk is marked with `is_final = true`

#### Scenario: Streamed results remain compatible with legacy core
- **GIVEN** the legacy Go core and existing serviceradar-sync use ResultsChunk chunking semantics
- **WHEN** the agent pushes results through agent-gateway
- **THEN** the chunking behavior (indices, totals, sequence, timestamps) matches the existing ResultsChunk contract

### Requirement: Embedded Sync Does Not Use KV
The agent sync runtime SHALL NOT depend on datasvc/KV for configuration or device processing state.

#### Scenario: KV outage does not block sync
- **GIVEN** datasvc/KV is unavailable
- **WHEN** the agent starts
- **THEN** it still retrieves configuration from agent-gateway
- **AND** continues processing sync updates without KV

## REMOVED Requirements

### Requirement: Platform sync processes multiple tenants
**Reason**: Sync now runs exclusively inside tenant agents; platform services do not perform discovery.
**Migration**: Tenants must onboard at least one agent to run integrations.

#### Scenario: Platform sync service is not supported
- **GIVEN** a platform deployment without tenant agents
- **WHEN** a tenant creates an integration source
- **THEN** the system requires a tenant agent to run the integration
- **AND** no platform sync service is available to process the source
