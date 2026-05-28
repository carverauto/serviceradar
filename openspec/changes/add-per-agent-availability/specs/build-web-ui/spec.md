## ADDED Requirements

### Requirement: Device details expose per-agent availability
The device details UI SHALL show a clean per-agent availability section when one or more agents have reported sweep availability for the device.

#### Scenario: Device has multiple agent observations
- **GIVEN** a device has latest availability from `agent-ot` and `agent-intranet`
- **WHEN** an operator opens the device details page
- **THEN** the UI SHALL show each agent with availability state, latest check time, check summary, response time when present, and open ports when present
- **AND** the UI SHALL avoid rendering raw JSON blobs for this metadata

#### Scenario: Agent observation is stale
- **GIVEN** a device has a stale latest availability observation from an agent
- **WHEN** the per-agent availability section renders
- **THEN** the UI SHALL visibly distinguish the stale observation from fresh observations
- **AND** SHALL still show the last known value and timestamp

### Requirement: Device UI shows canonical availability source
The device list and device details UI SHALL indicate which source drives the canonical availability value when that source is configured or inferable.

#### Scenario: Canonical availability is sourced from a selected agent
- **GIVEN** a device's primary availability source is `agent-intranet`
- **WHEN** an operator views the device details page
- **THEN** the UI SHALL show that `agent-intranet` drives the displayed canonical availability

#### Scenario: Canonical availability uses default fallback
- **GIVEN** a device has no explicit primary availability source
- **WHEN** an operator views the device details page
- **THEN** the UI SHALL indicate that canonical availability is using the default consolidated source

### Requirement: Operators can set primary availability source
The UI SHALL allow authorized operators to choose the primary availability source agent for a device or selected devices.

#### Scenario: Set primary source on one device
- **GIVEN** an operator is viewing a device with per-agent availability observations
- **WHEN** they select `agent-ot` as the primary availability source
- **THEN** the selection SHALL be persisted
- **AND** the canonical availability display SHALL use `agent-ot` after the update is applied

#### Scenario: Bulk set primary source
- **GIVEN** an operator selects multiple devices in the inventory
- **WHEN** they choose a primary availability source agent from bulk actions
- **THEN** the selected devices SHALL use that agent as their primary availability source

### Requirement: Settings UI manages availability source profiles
The settings UI SHALL allow authorized operators to create, preview, enable, disable, reorder, and delete availability source profiles that bind an SRQL device scope to a canonical availability agent.

#### Scenario: Create profile from SRQL scope
- **GIVEN** an operator opens availability source profile settings
- **WHEN** they enter a name, an SRQL device query, and a selected agent
- **THEN** the UI SHALL validate the SRQL query
- **AND** show a preview count and representative matching devices before saving

#### Scenario: Profile precedence is visible
- **GIVEN** multiple enabled profiles exist
- **WHEN** an operator views the profile list
- **THEN** the UI SHALL show each profile's precedence, enabled state, selected agent, and current match count
- **AND** allow authorized operators to change precedence deterministically

#### Scenario: Preview profile effect
- **GIVEN** a profile matches devices that currently use another canonical availability source
- **WHEN** an operator previews the profile
- **THEN** the UI SHALL show that the profile would change the effective source for those devices unless a per-device override applies
