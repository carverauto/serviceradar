## MODIFIED Requirements
### Requirement: Interface Details Screen

The system SHALL provide a dedicated interface details page showing comprehensive interface information.

#### Scenario: Navigate to interface details
- **GIVEN** a user viewing the interfaces table
- **WHEN** they click on an interface row or the details icon
- **THEN** they navigate to `/devices/:device_id/interfaces/:interface_id`
- **AND** the interface details page loads

#### Scenario: Display interface properties
- **GIVEN** the interface details page
- **THEN** it SHALL display:
  - Interface name and description
  - Interface ID
  - OID information
  - Interface type (human-readable)
  - Speed and duplex settings
  - MAC address
  - IP addresses
  - Operational and admin status with colorized indicators

#### Scenario: Enable metrics collection from details
- **GIVEN** the interface details page for an interface without metrics collection
- **WHEN** the user toggles the "Enable Metrics Collection" switch
- **THEN** metrics collection is enabled for this interface
- **AND** the toggle reflects the enabled state

#### Scenario: Disable metrics collection from details
- **GIVEN** the interface details page for an interface with metrics collection enabled
- **WHEN** the user toggles the "Enable Metrics Collection" switch off or removes all selected metrics
- **THEN** metrics collection is disabled for this interface
- **AND** the toggle reflects the disabled state
- **AND** any related metrics charts and indicators update to the disabled state

---

### Requirement: Favorited Interface Metrics Visualization

The device details view SHALL display metrics visualizations for favorited interfaces with metrics collection enabled, positioned above the interfaces table.

#### Scenario: Display metrics for favorited interfaces
- **GIVEN** a device with interfaces that are favorited AND have metrics collection enabled
- **WHEN** the device details page loads the Interfaces tab
- **THEN** a metrics visualization section appears above the interfaces table
- **AND** displays graphs for each favorited interface's metrics

#### Scenario: Auto-select visualization type
- **GIVEN** a favorited interface with counter-type metrics (e.g., bytes in/out)
- **WHEN** the visualization renders
- **THEN** a line or area chart is displayed showing the metric over time

#### Scenario: Gauge metric visualization
- **GIVEN** a favorited interface with gauge-type metrics (e.g., utilization percentage)
- **WHEN** the visualization renders
- **THEN** a gauge or percentage chart is displayed

#### Scenario: Favorited interface metrics disabled
- **GIVEN** a device with a favorited interface that has metrics collection disabled
- **WHEN** the device details page loads the Interfaces tab
- **THEN** the metrics visualization section SHALL omit that interface's charts

#### Scenario: No favorited interfaces
- **GIVEN** a device with no favorited interfaces with metrics enabled
- **WHEN** the device details page loads the Interfaces tab
- **THEN** the metrics visualization section is not displayed
- **OR** shows an empty state message
