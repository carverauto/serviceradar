# Agent Sync Onboarding

## MODIFIED Requirements

### Requirement: Agent onboarding enables sync capability
The platform SHALL treat sync as a capability of the tenant agent. There is no standalone sync service to onboard.

#### Scenario: Agent registers with sync capability
- **GIVEN** a tenant agent has valid mTLS credentials
- **WHEN** the agent calls the AgentGatewayService.Hello RPC
- **THEN** the agent is marked as sync-capable
- **AND** the agent appears in the UI for integration assignment

### Requirement: Edge onboarding generates minimal agent config
Edge onboarding packages MUST include a minimal agent config file suitable for bootstrapping embedded sync.

#### Scenario: Agent onboarding generates minimal config
- **GIVEN** a tenant user initiates edge onboarding for an agent
- **WHEN** the onboarding package is generated
- **THEN** the package includes a minimal agent config file
- **AND** the config contains only identity, gateway address, and TLS paths required to boot
- **AND** the agent fetches full integration configuration via GetConfig after startup

### Requirement: Integration source agent assignment
Integration sources MUST be assigned to a sync-capable agent within the tenant.

#### Scenario: Creating integration with agent assignment
- **GIVEN** at least one sync-capable agent is available for a tenant
- **WHEN** the user creates a new integration source
- **THEN** the user selects which agent runs the integration
- **AND** the integration is saved with the agent assignment

#### Scenario: Integrations gated on agent availability
- **GIVEN** no sync-capable agents are onboarded for a tenant
- **WHEN** the user views the integrations page
- **THEN** the "Add Integration" button is disabled
- **AND** a message explains that an agent must be onboarded first

### Requirement: Agent onboarding entrypoint in Integrations UI
The integrations UI MUST provide an explicit action to onboard an edge agent for sync.

#### Scenario: Integrations UI exposes agent onboarding
- **GIVEN** a user is viewing the integrations page
- **WHEN** they look below the "+ New Source" action
- **THEN** an "Add Edge Agent" button is visible
- **AND** the button starts the agent onboarding flow

## REMOVED Requirements

### Requirement: SaaS sync service auto-onboarding
**Reason**: Sync no longer runs as a platform service; all discovery runs inside tenant agents.
**Migration**: Tenants must onboard at least one agent to use integrations.

#### Scenario: Platform bootstrap does not create a sync service
- **GIVEN** the platform is starting for the first time
- **WHEN** the bootstrap process runs
- **THEN** no platform sync service is created
- **AND** tenants must onboard agents for discovery

### Requirement: Sync service heartbeat tracking
**Reason**: Sync health is tracked via the agent heartbeat rather than a standalone sync service record.
**Migration**: Use agent heartbeat status to determine sync availability.

#### Scenario: Sync health derived from agent status
- **GIVEN** a sync-capable agent
- **WHEN** the agent heartbeat is stale
- **THEN** sync is treated as offline for that tenant
