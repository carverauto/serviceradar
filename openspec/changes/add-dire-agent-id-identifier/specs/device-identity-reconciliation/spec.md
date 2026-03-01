## ADDED Requirements

### Requirement: Agent ID Strong Identifier
The system SHALL treat `agent_id` as the highest-priority strong identifier for agent-managed devices. The `agent_id` is an mTLS-validated, stable identifier that persists across pod restarts and IP changes.

#### Scenario: Agent pod restart with new IP resolves to existing device
- **GIVEN** an agent with ID `k8s-agent-01` previously enrolled with IP `10.0.1.5`
- **AND** a device record and `agent_id` identifier exist for that agent
- **WHEN** the agent pod restarts and re-enrolls with a new IP `10.0.2.12`
- **THEN** DIRE SHALL resolve the update to the same canonical device ID
- **AND** SHALL NOT create a new device record for the new IP

#### Scenario: Agent ID takes priority over all other identifiers
- **GIVEN** a device update containing both `agent_id` and `mac` identifiers
- **WHEN** DIRE determines the highest-priority identifier
- **THEN** `agent_id` SHALL be selected as the highest-priority identifier
- **AND** the deterministic device ID hash SHALL include the `agent_id` seed before all other seeds

#### Scenario: Agent ID registered in device identifiers table
- **GIVEN** a device update with `agent_id` in its metadata
- **WHEN** DIRE registers identifiers for the resolved device
- **THEN** an `agent_id` type identifier SHALL be upserted in `device_identifiers`
- **AND** subsequent lookups by `agent_id` SHALL resolve to the same device

## MODIFIED Requirements

### Requirement: Multi-Identifier Convergence
The system SHALL reconcile device updates that contain multiple strong identifiers to a single canonical device ID, even when those identifiers currently map to different devices, within the same partition. The strong identifier priority order is: `agent_id` > `armis_device_id` > `integration_id` > `netbox_device_id` > `mac`.

#### Scenario: Conflicting MAC identifiers merge into one device
- **GIVEN** a device update in partition `default` containing MAC A and MAC B
- **AND** MAC A maps to device ID X while MAC B maps to device ID Y
- **WHEN** DIRE processes the update
- **THEN** DIRE SHALL select a canonical device ID
- **AND** all identifiers (MAC A and MAC B) SHALL be assigned to the canonical device
- **AND** a `merge_audit` entry SHALL record the merge from the non-canonical device to the canonical device

#### Scenario: Agent ID wins priority over other strong identifiers
- **GIVEN** a device update containing `agent_id` and `armis_device_id`
- **AND** `agent_id` maps to device ID X while `armis_device_id` maps to device ID Y
- **WHEN** DIRE processes the update
- **THEN** device ID X (from `agent_id`) SHALL be selected as the canonical device
- **AND** the `armis_device_id` identifier SHALL be reassigned to the canonical device
