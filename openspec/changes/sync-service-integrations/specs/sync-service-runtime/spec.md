## ADDED Requirements
### Requirement: Sync Service Bootstrap via Agent-Gateway
The sync service SHALL authenticate to agent-gateway using mTLS and SHALL perform Hello + GetConfig on startup to retrieve its runtime configuration.

#### Scenario: Platform sync bootstraps with agent-gateway
- **WHEN** a platform sync service starts
- **THEN** it establishes an mTLS connection to agent-gateway
- **AND** completes the Hello handshake
- **AND** receives its initial configuration via GetConfig

#### Scenario: Edge sync bootstraps with tenant agent
- **WHEN** an edge sync service starts with tenant credentials
- **THEN** it establishes an mTLS connection to the tenant agent/agent-gateway
- **AND** receives configuration scoped to that tenant only

### Requirement: Tenant-Scoped Sync Configuration
The sync service SHALL process integrations in a tenant-scoped manner, where platform sync may handle multiple tenants while edge sync is restricted to its tenant.

#### Scenario: Platform sync processes multiple tenants
- **GIVEN** a platform sync service with platform credentials
- **WHEN** GetConfig returns integration configs for multiple tenants
- **THEN** the sync service runs separate sync loops per tenant
- **AND** device updates are tagged with the originating tenant and integration

#### Scenario: Edge sync rejected for cross-tenant config
- **GIVEN** an edge sync service with tenant-A credentials
- **WHEN** it requests configuration
- **THEN** agent-gateway returns only tenant-A configs
- **AND** any request for tenant-B configs is denied

### Requirement: Sync GetConfig Includes Integration Sources
Sync GetConfig responses SHALL be populated from IntegrationSource records created in the UI, including integration settings required by sync runtimes.

#### Scenario: UI integration source appears in sync config
- **GIVEN** a tenant admin creates an integration source (e.g., Armis or NetBox)
- **WHEN** the sync service calls GetConfig
- **THEN** the response includes that integration source for the tenant
- **AND** the payload includes integration settings required for discovery
- **AND** credentials remain encrypted at rest and are only provided to the sync service at runtime

#### Scenario: Sync config delivered as JSON payload
- **GIVEN** a sync service requests configuration
- **WHEN** the agent-gateway responds
- **THEN** integration configuration is returned via `config_json`
- **AND** the sync service deserializes the JSON payload into its in-memory config

### Requirement: Integration Source Events Stored as OCSF
Integration source lifecycle events SHALL be recorded in the OCSF events table with origin metadata.

#### Scenario: Integration source creation emits OCSF event
- **GIVEN** a tenant admin creates an integration source
- **WHEN** the record is stored
- **THEN** an event is published to the events pipeline
- **AND** the event is stored in `ocsf_events` with tenant metadata, origin service, and source identifiers

### Requirement: Sync Device Updates Flow Through Agent Pipeline
Device updates produced by the sync service SHALL be forwarded through agent -> agent-gateway -> core-elx and processed by DIRE before device records are written.

#### Scenario: Sync update processed by DIRE
- **GIVEN** a sync device update for tenant-A
- **WHEN** the update is sent to the agent pipeline
- **THEN** core-elx routes the update through DIRE
- **AND** the canonical device record is written to tenant-A schema

### Requirement: Sync Results Streaming Compatibility
The sync service SHALL push device updates to agent-gateway using the existing StreamStatus RPC and SHALL chunk payloads using ResultsChunk-compatible semantics to respect gRPC message size limits.

#### Scenario: Streamed results exceed single-message limits
- **GIVEN** sync results exceed the configured single-message size limit (e.g., ~15MB total payload)
- **WHEN** the sync service pushes results via StreamStatus
- **THEN** it splits the payload into ordered chunks that mirror ResultsChunk sequencing
- **AND** each chunk size remains below the configured gRPC max message size
- **AND** the final chunk is marked with `is_final = true`

#### Scenario: Streamed results remain compatible with legacy core
- **GIVEN** the legacy Go core and existing serviceradar-sync use ResultsChunk chunking semantics
- **WHEN** the platform sync service pushes results through agent-gateway
- **THEN** the chunking behavior (indices, totals, sequence, timestamps) matches the existing ResultsChunk contract

### Requirement: Sync Service Does Not Use KV
The sync service SHALL NOT depend on datasvc/KV for configuration or device processing state.

#### Scenario: KV outage does not block sync
- **GIVEN** datasvc/KV is unavailable
- **WHEN** the sync service starts
- **THEN** it still retrieves configuration from agent-gateway
- **AND** continues processing sync updates without KV
