## MODIFIED Requirements
### Requirement: Sysmon metrics rendered as graphs
The device detail view SHALL render sysmon CPU, memory, and disk metrics as graphs with normalized utilization semantics.

#### Scenario: Sysmon CPU metrics visualization
- **GIVEN** a device with sysmon CPU metrics
- **WHEN** an admin views the device detail page
- **THEN** the CPU graph shows utilization as a percentage from 0 to 100
- **AND** the current CPU utilization value is visible in the card header

#### Scenario: Sysmon memory metrics visualization
- **GIVEN** a device with sysmon memory metrics
- **WHEN** an admin views the device detail page
- **THEN** the memory graph shows used and available memory as distinct series

#### Scenario: Sysmon disk metrics visualization
- **GIVEN** a device with sysmon disk metrics
- **WHEN** an admin views the device detail page
- **THEN** disk graphs are grouped by disk or partition (mount/device)
- **AND** each graph shows used versus total capacity rather than per-file values
