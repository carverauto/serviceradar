## ADDED Requirements
### Requirement: Sysmon process metrics panel
The device detail view SHALL display a Sysmon Processes panel when process metrics are available for the device.

#### Scenario: Process metrics are available
- **GIVEN** a device with sysmon process metrics in the last 24h
- **WHEN** an admin views the device detail page
- **THEN** a "Processes" panel is shown
- **AND** it lists top N processes with process name, PID, CPU%, and memory% columns

#### Scenario: Process metrics are not available
- **GIVEN** a device without sysmon process metrics
- **WHEN** an admin views the device detail page
- **THEN** the "Processes" panel is hidden or shows an explicit empty state
