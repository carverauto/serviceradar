## MODIFIED Requirements
### Requirement: Device details interface tab uses SRQL
The device details UI SHALL fetch interfaces via SRQL `in:interfaces`. The Interfaces tab SHALL be visible when SRQL returns interface rows OR when the device has at least one network discovery job targeting it. When SRQL returns no interface rows and the tab is visible, the UI SHALL present an empty-state that includes discovery diagnostics (last run timestamp and status) and a link to the relevant discovery job settings.

#### Scenario: Interfaces tab visible with data
- **GIVEN** SRQL returns interface observations for the device
- **WHEN** the device details page loads
- **THEN** the Interfaces tab is visible and renders the SRQL interface rows

#### Scenario: Interfaces tab visible without data
- **GIVEN** SRQL returns no interface observations for the device
- **AND** the device has a discovery job targeting it
- **WHEN** the device details page loads
- **THEN** the Interfaces tab is visible
- **AND** the UI shows an empty-state message including last discovery run timestamp and status
- **AND** the UI provides a link to the discovery job edit page

#### Scenario: Interfaces tab hidden for non-discovery devices
- **GIVEN** SRQL returns no interface observations for the device
- **AND** the device has no discovery job targeting it
- **WHEN** the device details page loads
- **THEN** the Interfaces tab is hidden
