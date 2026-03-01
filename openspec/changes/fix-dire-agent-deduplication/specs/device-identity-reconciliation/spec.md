## ADDED Requirements

### Requirement: Agent Identity Registration on Enrollment

The system SHALL register the agent's `agent_id` as a strong identifier in `device_identifiers` when an agent enrolls or re-enrolls via the agent gateway, so that subsequent enrollments from different IP addresses resolve to the same canonical device.

#### Scenario: Agent enrollment registers agent_id identifier
- **WHEN** an agent with `agent_id = "k8s-agent"` enrolls via `AgentGatewaySync.ensure_device_for_agent`
- **THEN** a `device_identifiers` row with `identifier_type = :agent_id` and `identifier_value = "k8s-agent"` SHALL be created for the resolved device

#### Scenario: Agent re-enrollment from new IP resolves to existing device
- **GIVEN** agent `k8s-agent` previously enrolled and its `agent_id` is registered in `device_identifiers`
- **WHEN** the same agent enrolls again from a different IP address
- **THEN** DIRE SHALL resolve to the same canonical device ID
- **AND** SHALL NOT create a new device record

### Requirement: Agent Identity Registration via Sync Ingestion

The system SHALL register `agent_id` as a strong identifier during sync ingestion, and SHALL use `agent_id` as the highest-priority cache lookup key, so that bulk ingestion correctly deduplicates agent-reported device updates.

#### Scenario: Sync ingestion registers agent_id in device_identifiers
- **WHEN** a sync ingestion batch includes updates with `metadata.agent_id` set
- **THEN** each update's `agent_id` SHALL be registered in `device_identifiers` with `confidence: :strong`

#### Scenario: Cached agent_id lookup prevents duplicate resolution
- **GIVEN** a sync batch contains multiple updates from the same `agent_id` but different IPs
- **WHEN** the batch is processed
- **THEN** all updates SHALL resolve to the same canonical device ID via cached `agent_id` lookup
