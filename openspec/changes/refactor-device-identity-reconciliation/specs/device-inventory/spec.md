## ADDED Requirements

### Requirement: Unified Agent Badge Predicate
The device inventory UI SHALL derive "this device is an agent" from a single predicate — the device's linkage in the agent registry (`ocsf_agents.device_uid`) — in both the device list view and the device detail header. Read models MUST NOT depend on the `agent_list` device column for agent detection.

#### Scenario: Connected agent shows the badge everywhere
- **GIVEN** a connected agent linked to its canonical device
- **WHEN** the /devices list and the device detail page render that device
- **THEN** both display the agent (lightning-bolt) badge

#### Scenario: One badge per connected agent
- **GIVEN** N connected agents on N distinct hosts
- **WHEN** the /devices list renders
- **THEN** exactly N device rows display the agent badge

### Requirement: Canonical Device Visibility
The device list SHALL display the canonical (live) device record for each physical host. A host whose canonical record is linked to an agent MUST NOT be represented in the list solely by a stale duplicate record from another discovery source.

#### Scenario: Stale source duplicate does not mask the canonical record
- **GIVEN** a host with a live agent-linked device record and a stale integration-sourced duplicate
- **WHEN** reconciliation has merged or remediated the duplicate
- **THEN** the /devices list shows one record for the host, carrying the agent badge and both discovery sources
