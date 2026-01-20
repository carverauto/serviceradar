## ADDED Requirements

### Requirement: Device details interface tab uses SRQL
The device details UI SHALL fetch interfaces via SRQL `in:interfaces` and only display the Interfaces tab when SRQL returns interface rows.

#### Scenario: Interfaces tab visible
- **GIVEN** SRQL returns interface observations for the device
- **WHEN** the device details page loads
- **THEN** the Interfaces tab is visible and renders the SRQL interface rows

#### Scenario: Interfaces tab hidden
- **GIVEN** SRQL returns no interface observations for the device
- **WHEN** the device details page loads
- **THEN** the Interfaces tab is hidden
