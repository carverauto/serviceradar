## ADDED Requirements

### Requirement: NetFlow map exposes process attribution state

The NetFlow map SHALL surface whether visible flow paths have process attribution
and SHALL allow operators to drill into the same flow details used by the
attributed flows table.

#### Scenario: Attributed map path
- **GIVEN** a NetFlow path corresponds to a flow with process attribution
- **WHEN** the operator views the NetFlow map
- **THEN** the path or tooltip indicates that the flow reached a known process
- **AND** the attribution cue includes concise process and agent context when available

#### Scenario: Map path drill-down
- **GIVEN** an attributed NetFlow map path is visible
- **WHEN** the operator selects the path
- **THEN** the UI opens the corresponding NetFlow flow details with attribution context

### Requirement: NetFlow attribution display includes threat context

NetFlow attribution surfaces SHALL show CTI/OTX indicator state alongside
attribution status when existing threat-intel matching has marked either endpoint
or the flow.

#### Scenario: Attributed flow with CTI hit
- **GIVEN** a visible NetFlow row or map path has process attribution and an OTX/CTI hit
- **WHEN** the operator views the row, tooltip, or details
- **THEN** the UI shows both attribution state and CTI state without hiding the endpoint/process identity
