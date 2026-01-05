# Device Discovery Flow

## ADDED Requirements

### Requirement: Device data storage in CNPG

Discovered devices must be stored in CNPG instead of KV store.

#### Scenario: Sync service sends discovered devices

Given a sync service has discovered devices from an integration
When the sync service streams results via StreamStatus
Then the devices are stored in the discovered_devices table
And each device is associated with the integration_source_id
And the tenant_id is set for multi-tenant isolation

#### Scenario: Device upsert on rediscovery

Given a device was previously discovered
When the same device is discovered again (matched by device_id + source)
Then the existing record is updated
And last_seen_at is refreshed

### Requirement: Sweep config from discovered devices

Agent sweep configuration must be generated from discovered devices in CNPG.

#### Scenario: GetConfig includes sweep targets

Given an agent has discovered devices assigned to it
When the agent calls GetConfig
Then the response includes a sweep config
And the sweep config contains networks derived from device IPs
And the sweep config contains device_targets with specific IPs and ports

#### Scenario: Empty sweep config when no devices

Given an agent has no discovered devices
When the agent calls GetConfig
Then the sweep config is empty or contains only manual sweep config

### Requirement: Agent sweep config application

Agents must apply sweep configuration received from GetConfig.

#### Scenario: Agent applies sweep from GetConfig

Given the agent receives a GetConfig response with sweep config
When the agent processes the config
Then the SweepService is configured with the networks and targets
And the agent no longer requires sweep.json from KV

#### Scenario: Backward compatibility with sweep.json

Given an agent receives a GetConfig response without sweep config
When the agent has a local sweep.json file
Then the agent uses the local sweep.json as fallback

## ADDED Requirements

### Requirement: KV store elimination for edge agents

Edge-deployed agents MUST NOT depend on KV store access.

#### Scenario: Edge agent operates without KV

Given an edge-deployed agent with no network path to KV
When the agent needs sweep configuration
Then the agent receives sweep config via GetConfig RPC
And the agent does not attempt to contact KV store
