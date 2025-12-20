## ADDED Requirements

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
- `poller_id` (TEXT) - Parent poller reference
- `capabilities` (TEXT[]) - Registered checker capabilities
- `ip` (TEXT) - Agent IP address
- `first_seen_time` (TIMESTAMPTZ) - When agent first registered
- `last_seen_time` (TIMESTAMPTZ) - Last heartbeat time
- `metadata` (JSONB) - Additional agent metadata

#### Scenario: Agent registers via poller heartbeat

- **GIVEN** a poller sends a status report containing an agent_id
- **WHEN** the core processes the status report
- **THEN** the agent SHALL be registered in `ocsf_agents` with uid matching the agent_id
- **AND** the agent SHALL NOT be created as a device in `ocsf_devices`

#### Scenario: Agent with version metadata

- **GIVEN** a poller sends a status report with agent version in metadata
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

### Requirement: Agent Registry API

The system SHALL provide REST API endpoints for querying the agent registry:

- `GET /api/agents` - List all agents with pagination
- `GET /api/agents/:id` - Get single agent by UID
- `GET /api/agents/by-poller/:pollerId` - List agents for a specific poller

#### Scenario: List all agents

- **WHEN** a client sends `GET /api/agents`
- **THEN** the response SHALL contain an array of OCSF Agent objects
- **AND** the response SHALL support pagination via `limit` and `offset` query parameters

#### Scenario: Get agent by ID

- **GIVEN** an agent with uid "agent-001" exists in `ocsf_agents`
- **WHEN** a client sends `GET /api/agents/agent-001`
- **THEN** the response SHALL contain the full OCSF Agent object for that agent
- **AND** the response SHALL include `capabilities` and `poller_id`

#### Scenario: List agents by poller

- **GIVEN** agents "agent-001" and "agent-002" are registered under poller "poller-001"
- **WHEN** a client sends `GET /api/agents/by-poller/poller-001`
- **THEN** the response SHALL contain both agents
- **AND** agents from other pollers SHALL NOT be included

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
- **WHEN** a poller sends a status report including that agent
- **THEN** the agent's `last_seen_time` SHALL be updated to the current time

#### Scenario: First registration sets first seen

- **GIVEN** a new agent reporting for the first time
- **WHEN** the agent is registered in `ocsf_agents`
- **THEN** `first_seen_time` SHALL be set to the current time
- **AND** `last_seen_time` SHALL be set to the current time
