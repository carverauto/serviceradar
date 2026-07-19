## MODIFIED Requirements

### Requirement: Device Interface Tab
The device details UI SHALL fetch interfaces via SRQL `in:interfaces`. The Interfaces tab SHALL be visible when SRQL returns interface rows OR when the device has at least one network discovery job targeting it. An in-progress or inconclusive availability check MUST NOT be presented as a definitive absence. Interface inventory and favorited-interface metrics SHALL load without blocking LiveView navigation. When SRQL returns no interface rows and the tab is visible, the UI SHALL present an empty-state that includes discovery diagnostics and a link to the relevant discovery job settings.

#### Scenario: Interface availability check is pending
- **GIVEN** the device details shell is rendered
- **WHEN** interface availability has not completed
- **THEN** the UI SHALL retain an Interfaces navigation affordance with a checking state
- **AND** it SHALL NOT claim that the device has no interfaces

#### Scenario: Interface availability check is inconclusive
- **WHEN** the interface presence query times out or fails
- **THEN** the Interfaces tab SHALL remain accessible
- **AND** the tab SHALL explain that availability could not be confirmed and allow a retry

#### Scenario: Interface inventory loads independently from charts
- **GIVEN** a device has interfaces with favorited metric charts
- **WHEN** the operator opens the Interfaces tab
- **THEN** interface inventory SHALL render without waiting for favorited-interface metric queries

### Requirement: Device Details Flows Tab
The device details UI SHALL fetch recent flows via a time-bounded SRQL `in:flows device_id:"<device_uid>"` query. The Flows tab SHALL be visible when a completed probe returns flow rows. An in-progress or inconclusive probe MUST NOT be represented as definitive absence, and flow inventory SHALL load outside the LiveView process.

#### Scenario: Flow availability check is pending or inconclusive
- **WHEN** a device flow presence check is pending, times out, or fails
- **THEN** the UI SHALL preserve a Flows navigation/loading affordance
- **AND** it SHALL NOT block other device-detail interactions

#### Scenario: Device flow query is bounded
- **WHEN** the Flows tab loads its default inventory
- **THEN** the SRQL query SHALL include the documented recent time window
- **AND** it SHALL NOT scan the full retained flow history
