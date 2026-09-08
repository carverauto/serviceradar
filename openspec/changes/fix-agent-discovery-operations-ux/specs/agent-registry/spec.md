## MODIFIED Requirements
### Requirement: OCSF Agent Schema Storage
The system SHALL store agent metadata in a dedicated `ocsf_agents` table aligned with OCSF v1.7.0 Agent object schema. Agent hostname/listen-host context SHALL be stored in `host`, and the numeric source address SHALL be stored in `ip`.

The table SHALL contain at least the following fields:

- `uid` (TEXT, PRIMARY KEY) - Unique agent identifier
- `name` (TEXT) - Agent designation name
- `type_id` (INTEGER) - Normalized agent type
- `type` (TEXT) - Human-readable type caption
- `version` (TEXT) - Semantic version of the agent
- `vendor_name` (TEXT) - Agent vendor name
- `uid_alt` (TEXT) - Alternate unique identifier
- `policies` (JSONB) - Applied policies array
- `gateway_id` (TEXT) - Parent gateway reference
- `capabilities` (TEXT[]) - Registered checker capabilities
- `host` (TEXT) - Agent hostname or listen host when reported
- `ip` (TEXT) - Agent source IP address when known
- `first_seen_time` (TIMESTAMPTZ) - When agent first registered
- `last_seen_time` (TIMESTAMPTZ) - Last heartbeat time
- `metadata` (JSONB) - Additional agent metadata

#### Scenario: Agent registers via gateway heartbeat
- **GIVEN** a gateway sends a status report containing an agent_id
- **WHEN** the core processes the status report
- **THEN** the agent SHALL be registered in `ocsf_agents` with uid matching the agent_id
- **AND** the agent SHALL NOT be created as a device solely because it self-registered

#### Scenario: Agent host and source IP are stored separately
- **GIVEN** an agent reports hostname `pve04` and connects from source IP `192.168.2.10`
- **WHEN** the core persists the agent row
- **THEN** `ocsf_agents.host` SHALL contain hostname/listen-host context
- **AND** `ocsf_agents.ip` SHALL contain `192.168.2.10`

#### Scenario: Agent with version metadata
- **GIVEN** a gateway sends a status report with agent version in metadata
- **WHEN** the core processes the status report
- **THEN** the agent record SHALL have the `version` field populated
- **AND** `vendor_name` SHALL be set to "ServiceRadar"

### Requirement: SRQL Agent Query Support
The SRQL service SHALL support querying the `ocsf_agents` table via the `agents` entity type, enabling analytics queries for agent inventory. Agent records SHALL include both `host` and `ip` when present.

#### Scenario: Query all agents via SRQL
- **WHEN** a client sends `POST /api/query` with body `{"query": "in:agents"}`
- **THEN** the response SHALL contain an array of agent records from `ocsf_agents`
- **AND** each record SHALL include uid, name, type_id, type, version, gateway_id, capabilities, host, ip, and last_seen_time

#### Scenario: Filter agents by source host
- **GIVEN** an agent has `host` set to "192.168.2.10"
- **WHEN** a client sends query `in:agents host:192.168.2.10`
- **THEN** the response SHALL contain that agent

#### Scenario: Filter agents by IP
- **GIVEN** an agent has `ip` set to "192.168.2.10"
- **WHEN** a client sends query `in:agents ip:192.168.2.10`
- **THEN** the response SHALL contain that agent
- **AND** the generated SQL SHALL filter `ocsf_agents.ip`

#### Scenario: Filter agents by gateway
- **GIVEN** agents registered under gateway "gateway-001" and "gateway-002"
- **WHEN** a client sends query `in:agents gateway_id:gateway-001`
- **THEN** the response SHALL contain only agents with gateway_id = "gateway-001"

#### Scenario: Filter agents by type
- **WHEN** a client sends query `in:agents type_id:4`
- **THEN** the response SHALL contain only Performance Monitoring agents

#### Scenario: Filter agents by capability
- **WHEN** a client sends query `in:agents capabilities:snmp`
- **THEN** the response SHALL contain only agents with SNMP capability

#### Scenario: Order agents by last seen
- **WHEN** a client sends query `in:agents sort:last_seen_time:desc`
- **THEN** the response SHALL be ordered by last_seen_time descending

### Requirement: Agent List UI View
The web-ng application SHALL provide an Agent List view accessible from the main authenticated operations navigation, displaying all registered agents with key metadata. Agent data MUST be fetched via SRQL queries through the `/api/query` endpoint.

#### Scenario: Navigate to agent list
- **GIVEN** a user is logged into the web-ng application
- **WHEN** the user clicks "Agents" in the operations navigation
- **THEN** the browser SHALL navigate to `/agents`
- **AND** the agent list view SHALL be displayed
- **AND** agent data SHALL be fetched via SRQL without referencing missing database columns

#### Scenario: Agent list table columns
- **WHEN** the agent list view is rendered
- **THEN** the table SHALL display columns: Name, Type, Version, Gateway, Capabilities, Last Seen, Status
- **AND** the Status column SHALL show health based on last_seen_time

### Requirement: Agent Detail UI View
The web-ng application SHALL provide an Agent Detail view showing complete OCSF agent metadata, capabilities, release management status, and effective service checks. Agent inventory data MUST be fetched via SRQL queries through the `/api/query` endpoint, and related release/check data MAY be fetched through authoritative Ash resources.

#### Scenario: Navigate to agent detail
- **GIVEN** a user is viewing the agent list or cluster settings page
- **WHEN** the user clicks on an agent row
- **THEN** the browser SHALL navigate to `/agents/:uid`
- **AND** the agent detail view SHALL be displayed
- **AND** agent inventory data SHALL be fetched via SRQL using the agent uid

#### Scenario: Agent detail content
- **WHEN** the agent detail view is rendered
- **THEN** the view SHALL display all OCSF fields: uid, name, type, type_id, version, vendor_name, uid_alt
- **AND** the view SHALL display ServiceRadar fields: gateway_id, capabilities, host, ip, first_seen_time, last_seen_time
- **AND** capabilities SHALL be displayed as badge tags

#### Scenario: Agent detail shows configured service checks
- **GIVEN** service checks or checker registrations are assigned to an agent
- **WHEN** the agent detail view is rendered
- **THEN** the Service Checks section SHALL list the assigned checks with status/configuration summaries
- **AND** it SHALL show an empty state only when no checks are assigned to that agent

#### Scenario: Agent health indicator
- **GIVEN** an agent with last_seen_time within the past 5 minutes
- **WHEN** the agent detail view is rendered
- **THEN** a healthy status badge SHALL be displayed

## ADDED Requirements
### Requirement: Stale agent pruning and selection filtering
The system SHALL prevent stale historical agent rows from polluting operational selection surfaces. A server-side cleanup process SHALL prune or retire superseded/offline historical agents according to retention policy, and UI selection lists SHALL show active or recently connected agents by default.

#### Scenario: Stale agents are pruned automatically
- **GIVEN** an agent registry row has been superseded by a same-host active agent or has been offline beyond the configured retention period
- **WHEN** the scheduled stale-agent cleanup runs
- **THEN** the stale row SHALL be retired, deleted, or marked hidden according to retention policy
- **AND** active assignment ownership SHALL be transferred or preserved before the stale row disappears from operator-facing lists

#### Scenario: Plugin assignment lists hide stale agents
- **GIVEN** only three agents currently have active or recent control streams
- **WHEN** an operator opens `/settings/agents/plugins`
- **THEN** agent selectors and target lists SHALL show those active/recent agents by default
- **AND** stale historical agents SHALL not appear unless the operator explicitly chooses a historical view

#### Scenario: Credential scope lists hide stale agents
- **GIVEN** an admin creates a credential rule scoped to an agent
- **WHEN** the scope value selector is rendered
- **THEN** it SHALL list active or recently connected registered agents
- **AND** stale historical agents SHALL not be selectable by default
