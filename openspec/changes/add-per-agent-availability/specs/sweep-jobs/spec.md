## MODIFIED Requirements

### Requirement: Device Sweep Status Display
The system SHALL display sweep status details in the device detail view, including latest per-agent availability observations when multiple agents have checked the same device.

#### Scenario: View device sweep status
- **GIVEN** a device with an active sweep job
- **WHEN** viewing the device details
- **THEN** the sweep status SHALL be displayed
- **AND** include last sweep time, availability status, and open ports

#### Scenario: View per-agent sweep status
- **GIVEN** a device has latest sweep observations from multiple agents
- **WHEN** viewing the device details
- **THEN** the sweep status SHALL show each agent's latest availability state
- **AND** each state SHALL include freshness and check metadata when available

## ADDED Requirements

### Requirement: Sweep ingestion updates latest per-agent availability
Sweep result ingestion SHALL update the latest per-agent availability state for each device and agent represented in the result payload.

#### Scenario: Agent reports new result for existing device
- **GIVEN** a canonical device already exists
- **AND** agent `agent-a` reports a newer sweep result for that device
- **WHEN** the result batch is ingested
- **THEN** the latest availability state for `(device, agent-a)` SHALL be replaced by the newer observation
- **AND** latest availability states for other agents SHALL remain unchanged

#### Scenario: Out-of-order result does not replace newer state
- **GIVEN** the system has a latest availability observation for `(device, agent-a)` at `10:05`
- **WHEN** an older result for `(device, agent-a)` at `10:00` is ingested
- **THEN** the latest per-agent availability state SHALL remain the `10:05` observation
