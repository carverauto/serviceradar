## ADDED Requirements

### Requirement: Sysmon metrics only for eligible devices
The device detail view SHALL show sysmon metrics panels only when the device has sysmon metrics data or a sysmon status record.

#### Scenario: Non-sysmon device detail view
- **GIVEN** a device without sysmon metrics data or sysmon status
- **WHEN** an admin views the device detail page
- **THEN** no sysmon metrics panels are displayed

#### Scenario: Sysmon device detail view
- **GIVEN** a device with sysmon metrics data or sysmon status
- **WHEN** an admin views the device detail page
- **THEN** sysmon metrics panels are displayed

### Requirement: Sysmon metrics rendered as graphs
The device detail view SHALL render sysmon CPU, memory, and disk metrics as graphs instead of tables.

#### Scenario: Sysmon CPU metrics visualization
- **GIVEN** a device with sysmon CPU metrics
- **WHEN** an admin views the device detail page
- **THEN** CPU metrics render as a graph

#### Scenario: Sysmon memory metrics visualization
- **GIVEN** a device with sysmon memory metrics
- **WHEN** an admin views the device detail page
- **THEN** memory metrics render as a graph

#### Scenario: Sysmon disk metrics visualization
- **GIVEN** a device with sysmon disk metrics
- **WHEN** an admin views the device detail page
- **THEN** disk metrics render as a graph

### Requirement: Suppress low-value auto visualizations
The device detail view SHALL NOT auto-create a visualization for the dimension "type_id by modified".

#### Scenario: Default device detail visualizations
- **GIVEN** an admin opens a device detail page
- **WHEN** default visualizations are generated
- **THEN** no visualization is created for "Categories: type_id by modified"
