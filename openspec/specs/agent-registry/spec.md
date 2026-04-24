# agent-registry Specification

## Purpose
TBD - created by archiving change add-ocsf-agent-schema-alignment. Update Purpose after archive.
## Requirements
### Requirement: OCSF Agent Schema Storage

The system SHALL store agent metadata in a dedicated `ocsf_agents` table aligned with OCSF v1.7.0 Agent object schema, containing the following fields:

- `uid` (TEXT, PRIMARY KEY) - Unique agent identifier
- `name` (TEXT) - Agent designation name
- `type_id` (INTEGER) - Normalized agent type (0=Unknown, 1=EDR, 4=Performance, 6=Log, etc.)
- `type` (TEXT) - Human-readable type caption
- `version` (TEXT) - Semantic version of the agent
- `vendor_name` (TEXT) - Agent vendor name
- `uid_alt` (TEXT) - Alternate unique identifier
- `policies` (JSONB) - Applied policies array
- `gateway_id` (TEXT) - Parent gateway reference
- `capabilities` (TEXT[]) - Registered checker capabilities
- `ip` (TEXT) - Agent IP address
- `first_seen_time` (TIMESTAMPTZ) - When agent first registered
- `last_seen_time` (TIMESTAMPTZ) - Last heartbeat time
- `metadata` (JSONB) - Additional agent metadata

#### Scenario: Agent registers via gateway heartbeat

- **GIVEN** a gateway sends a status report containing an agent_id
- **WHEN** the core processes the status report
- **THEN** the agent SHALL be registered in `ocsf_agents` with uid matching the agent_id
- **AND** the agent SHALL NOT be created as a device in `ocsf_devices`

#### Scenario: Agent with version metadata

- **GIVEN** a gateway sends a status report with agent version in metadata
- **WHEN** the core processes the status report
- **THEN** the agent record SHALL have the `version` field populated
- **AND** `vendor_name` SHALL be set to "ServiceRadar"

---

### Requirement: Agent Type Classification

The system SHALL classify agents using the OCSF type_id enum:

| type_id | type | Description |
|---------|------|-------------|
| 0 | Unknown | Unclassified agent |
| 1 | Endpoint Detection and Response | EDR agent |
| 4 | Performance Monitoring and Observability | Metrics/monitoring agent |
| 6 | Log Management | Log forwarding agent |
| 99 | Other | Other agent types |

#### Scenario: Performance monitoring agent classification

- **GIVEN** a serviceradar-agent registering with capabilities including "icmp" or "snmp"
- **WHEN** the agent is registered in `ocsf_agents`
- **THEN** the agent SHALL have `type_id = 4` and `type = "Performance Monitoring and Observability"`

#### Scenario: Log forwarding agent classification

- **GIVEN** a serviceradar-agent registering with capabilities including "syslog"
- **WHEN** the agent is registered in `ocsf_agents`
- **THEN** the agent SHALL have `type_id = 6` and `type = "Log Management"`

---

### Requirement: Agent Separation from Devices

The system SHALL NOT create device entries for agents during self-registration. Agents are monitoring infrastructure, not monitored assets.

#### Scenario: Agent registration does not create device

- **GIVEN** a new agent reports to the core for the first time
- **WHEN** the agent self-registration flow executes
- **THEN** an entry SHALL be created in `ocsf_agents`
- **AND** no entry SHALL be created in `ocsf_devices` for that agent

#### Scenario: Checker registration references agent

- **GIVEN** a checker service reports via an agent
- **WHEN** the checker is registered
- **THEN** the checker MAY be created as a device with `agent_id` referencing the `ocsf_agents` entry
- **AND** the device's `agent_list` SHALL contain an OCSF Agent object referencing the monitoring agent

---

### Requirement: Agent Capability Tracking

The system SHALL track agent capabilities based on the checker services they support.

#### Scenario: Agent with multiple checkers

- **GIVEN** an agent running SNMP and ICMP checker services
- **WHEN** the agent's capabilities are recorded
- **THEN** the `capabilities` array SHALL contain `["snmp", "icmp"]`

#### Scenario: Capability update on new checker

- **GIVEN** an agent with capabilities `["icmp"]`
- **WHEN** the agent reports a new sysmon checker service
- **THEN** the `capabilities` array SHALL be updated to include "sysmon"

---

### Requirement: Agent Heartbeat Tracking

The system SHALL update `last_seen_time` on each agent heartbeat.

#### Scenario: Heartbeat updates last seen

- **GIVEN** an agent with `last_seen_time` of 10 minutes ago
- **WHEN** a gateway sends a status report including that agent
- **THEN** the agent's `last_seen_time` SHALL be updated to the current time

#### Scenario: First registration sets first seen

- **GIVEN** a new agent reporting for the first time
- **WHEN** the agent is registered in `ocsf_agents`
- **THEN** `first_seen_time` SHALL be set to the current time
- **AND** `last_seen_time` SHALL be set to the current time

---

### Requirement: SRQL Agent Query Support

The SRQL service SHALL support querying the `ocsf_agents` table via the `agents` entity type, enabling analytics queries for agent inventory.

#### Scenario: Query all agents via SRQL

- **WHEN** a client sends `POST /api/query` with body `{"query": "agents"}`
- **THEN** the response SHALL contain an array of agent records from `ocsf_agents`
- **AND** each record SHALL include uid, name, type_id, type, version, gateway_id, capabilities, last_seen_time

#### Scenario: Filter agents by gateway

- **GIVEN** agents registered under gateway "gateway-001" and "gateway-002"
- **WHEN** a client sends query `agents | filter gateway_id = "gateway-001"`
- **THEN** the response SHALL contain only agents with gateway_id = "gateway-001"

#### Scenario: Filter agents by type

- **WHEN** a client sends query `agents | filter type_id = 4`
- **THEN** the response SHALL contain only Performance Monitoring agents

#### Scenario: Filter agents by capability

- **WHEN** a client sends query `agents | filter capabilities contains "snmp"`
- **THEN** the response SHALL contain only agents with SNMP capability

#### Scenario: Order agents by last seen

- **WHEN** a client sends query `agents | order last_seen_time desc`
- **THEN** the response SHALL be ordered by last_seen_time descending (most recent first)

#### Scenario: Agent count statistics

- **WHEN** a client sends query `agents | stats count`
- **THEN** the response SHALL contain the total count of registered agents

---

### Requirement: Agent List UI View

The web-ng application SHALL provide an Agent List view accessible from the main navigation, displaying all registered agents with key metadata. All agent data MUST be fetched via SRQL queries through the `/api/query` endpoint.

#### Scenario: Navigate to agent list

- **GIVEN** a user is logged into the web-ng application
- **WHEN** the user clicks "Agents" in the sidebar navigation
- **THEN** the browser SHALL navigate to `/agents`
- **AND** the agent list view SHALL be displayed
- **AND** agent data SHALL be fetched via SRQL query `agents | order last_seen_time desc`

#### Scenario: Agent list table columns

- **WHEN** the agent list view is rendered
- **THEN** the table SHALL display columns: Name, Type, Version, Gateway, Capabilities, Last Seen, Status
- **AND** the Status column SHALL show health based on last_seen_time (healthy if < 5 minutes, warning if < 15 minutes, offline otherwise)

#### Scenario: Agent list pagination

- **GIVEN** more than 25 agents are registered
- **WHEN** the agent list view is rendered
- **THEN** the list SHALL display 25 agents per page
- **AND** pagination controls SHALL allow navigation between pages
- **AND** pagination SHALL use SRQL `limit` and `offset` parameters

---

### Requirement: Agent Detail UI View

The web-ng application SHALL provide an Agent Detail view showing complete OCSF agent metadata and capabilities. Agent data MUST be fetched via SRQL queries through the `/api/query` endpoint.

#### Scenario: Navigate to agent detail

- **GIVEN** a user is viewing the agent list
- **WHEN** the user clicks on an agent row
- **THEN** the browser SHALL navigate to `/agents/:uid`
- **AND** the agent detail view SHALL be displayed
- **AND** agent data SHALL be fetched via SRQL query `agents | filter uid = ":uid"`

#### Scenario: Agent detail content

- **WHEN** the agent detail view is rendered
- **THEN** the view SHALL display all OCSF fields: uid, name, type, type_id, version, vendor_name, uid_alt
- **AND** the view SHALL display ServiceRadar fields: gateway_id, capabilities, ip, first_seen_time, last_seen_time
- **AND** capabilities SHALL be displayed as badge tags

#### Scenario: Agent health indicator

- **GIVEN** an agent with last_seen_time within the past 5 minutes
- **WHEN** the agent detail view is rendered
- **THEN** a green "Healthy" status badge SHALL be displayed

---

### Requirement: Dashboard Agent Summary

The web-ng dashboard SHALL display an agent count summary card providing quick visibility into the monitoring infrastructure. Agent counts MUST be fetched via SRQL queries through the `/api/query` endpoint.

#### Scenario: Dashboard agent card

- **WHEN** the dashboard/overview page is rendered
- **THEN** an "Agents" summary card SHALL be displayed
- **AND** the card SHALL show total agent count via SRQL query `agents | stats count`
- **AND** the card SHALL show count of healthy vs offline agents

#### Scenario: Click through to agent list

- **GIVEN** the dashboard is displayed with the agent summary card
- **WHEN** the user clicks on the agent summary card
- **THEN** the browser SHALL navigate to `/agents`

---

### Requirement: Connected Agent Runtime Metadata

The web-ng application SHALL display connected-agent runtime metadata in the `/settings/cluster` "Connected Agents" card so operators can review live version and platform details for each connected agent. The agent-gateway SHALL populate `ServiceRadar.AgentTracker` with runtime metadata from the live agent control-stream handshake and status pushes, including version, operating system, architecture, hostname, source IP, and gateway details, so the cluster settings experience reflects currently connected agents without relying on persisted registry records.

#### Scenario: Connected-agent row shows runtime metadata

- **GIVEN** the cluster settings page has one or more connected agents
- **WHEN** the "Connected Agents" card is rendered
- **THEN** each connected agent row SHALL display the agent identifier, connection status, last seen timestamp, service count, version, operating system, and architecture

#### Scenario: Live runtime metadata survives reconnects and refreshes

- **GIVEN** a connected agent establishes the live control stream with the gateway
- **AND** the agent includes runtime metadata in its control-stream hello payload or status push payload
- **WHEN** the gateway initializes or refreshes the live session state
- **THEN** `ServiceRadar.AgentTracker` SHALL store the reported version, hostname, operating system, architecture, source IP, and gateway metadata for that agent
- **AND** the `/settings/cluster` connected-agent row SHALL render those live runtime details for the active session

#### Scenario: Unknown placeholders render only when metadata is unavailable

- **GIVEN** a connected agent row has no version, operating system, or architecture value in the authoritative live tracker state
- **WHEN** the "Connected Agents" card is rendered
- **THEN** the row SHALL show explicit unknown or unavailable placeholders for the missing values
- **AND** the row SHALL remain visible in the connected agent list

### Requirement: Cluster Connected Agent Runtime Metadata

The system SHALL retain connected-agent runtime metadata needed by the cluster settings experience, including agent version, operating system, architecture, and existing connection details, so operators can inspect the live fleet state without leaving `/settings/cluster`.

#### Scenario: Connected agent reports runtime metadata

- **GIVEN** an agent is connected through a gateway
- **AND** the connected-agent snapshot includes version, operating system, and architecture metadata
- **WHEN** the cluster settings page loads its connected-agent data
- **THEN** the connected-agent entry SHALL retain version, operating system, and architecture values alongside its existing status, partition, and source IP details

#### Scenario: Connected agent omits runtime metadata

- **GIVEN** an agent is connected through a gateway
- **AND** the connected-agent snapshot omits one or more runtime metadata fields
- **WHEN** the cluster settings page loads its connected-agent data
- **THEN** the connected-agent entry SHALL still be returned
- **AND** the missing runtime metadata SHALL remain unset rather than being replaced with misleading derived values

### Requirement: Cluster Connected Agents Card Details

The web-ng application SHALL display connected-agent runtime metadata in the `/settings/cluster` "Connected Agents" card so operators can review live version and platform details for each connected agent.

#### Scenario: Connected agents card shows runtime details

- **GIVEN** the cluster settings page has one or more connected agents
- **WHEN** the "Connected Agents" card is rendered
- **THEN** each connected agent row SHALL display the agent identifier, connection status, last seen timestamp, service count, version, operating system, and architecture

#### Scenario: Connected agents card shows unknown metadata clearly

- **GIVEN** a connected agent row has no version, operating system, or architecture value
- **WHEN** the "Connected Agents" card is rendered
- **THEN** the row SHALL show explicit unknown or unavailable placeholders for the missing values
- **AND** the row SHALL remain visible in the connected agent list

### Requirement: Agent inventory includes release state
The system SHALL expose agent release-management fields through inventory and query surfaces, including current version, desired version, rollout state, last update time, and last update error.

#### Scenario: Query agent release state
- **GIVEN** an agent has current version `v1.2.2` and desired version `v1.2.3`
- **AND** its rollout target is in `downloading`
- **WHEN** an operator queries agent inventory
- **THEN** the returned agent record includes current version, desired version, rollout state, and last update timestamp

### Requirement: Agent inventory UI supports rollout operations
The web-ng agent inventory UI SHALL allow operators to view fleet version distribution, filter agents by version and rollout state, and inspect per-agent rollout history and failure diagnostics.

#### Scenario: Filter inventory by rollout state
- **GIVEN** the agent inventory contains agents in `healthy`, `pending`, and `failed` rollout states
- **WHEN** an operator filters the list by `failed`
- **THEN** only failed rollout targets are shown
- **AND** the list includes the current version, desired version, and failure summary for each matching agent

#### Scenario: Inspect rollout history for one agent
- **GIVEN** an operator opens an agent detail page
- **WHEN** the agent has prior rollout attempts
- **THEN** the detail view shows the rollout timeline
- **AND** failed or rolled-back attempts include the recorded error details
