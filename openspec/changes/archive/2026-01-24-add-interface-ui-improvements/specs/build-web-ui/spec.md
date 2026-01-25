## ADDED Requirements

### Requirement: Interface Row Selection

The interfaces table SHALL support row selection for bulk operations.

#### Scenario: Select single interface
- **GIVEN** a user viewing the interfaces table in device details
- **WHEN** they click the checkbox on an interface row
- **THEN** the row is selected and highlighted
- **AND** the bulk action toolbar becomes visible

#### Scenario: Select all interfaces
- **GIVEN** a user viewing the interfaces table
- **WHEN** they click the select-all checkbox in the header
- **THEN** all visible interface rows are selected
- **AND** the bulk action toolbar shows the count of selected items

#### Scenario: Deselect all interfaces
- **GIVEN** multiple interfaces are selected
- **WHEN** the user clicks the select-all checkbox again or clicks "Clear selection"
- **THEN** all interfaces are deselected
- **AND** the bulk action toolbar is hidden

---

### Requirement: Interface Bulk Edit

The interfaces table SHALL provide bulk edit functionality for selected interfaces.

#### Scenario: Bulk enable metrics collection
- **GIVEN** multiple interfaces are selected
- **WHEN** the user clicks "Bulk Edit" and enables "Metrics Collection"
- **THEN** all selected interfaces have metrics collection enabled
- **AND** the metrics indicator icon appears on those rows

#### Scenario: Bulk favorite interfaces
- **GIVEN** multiple interfaces are selected
- **WHEN** the user clicks "Bulk Edit" and clicks "Add to Favorites"
- **THEN** all selected interfaces are marked as favorites
- **AND** the star icon fills in on those rows

#### Scenario: Bulk apply tags
- **GIVEN** multiple interfaces are selected
- **WHEN** the user clicks "Bulk Edit" and adds tags
- **THEN** the specified tags are applied to all selected interfaces

---

### Requirement: Interface Favorite Icon

The interfaces table SHALL display a favorite/star icon column that users can click to toggle favorite status.

#### Scenario: Favorite an interface
- **GIVEN** an interface row with an unfilled star icon
- **WHEN** the user clicks the star icon
- **THEN** the star fills in to indicate favorited status
- **AND** the favorite state is persisted to the backend

#### Scenario: Unfavorite an interface
- **GIVEN** an interface row with a filled star icon
- **WHEN** the user clicks the star icon
- **THEN** the star becomes unfilled
- **AND** the interface is removed from favorites

---

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

---

### Requirement: Interface Metrics Collection Indicator

The interfaces table SHALL display an icon indicating whether metrics collection is enabled for each interface, and the icon SHALL be clickable to navigate to interface details.

#### Scenario: Metrics enabled indicator
- **GIVEN** an interface with metrics collection enabled
- **WHEN** the interfaces table renders
- **THEN** a metrics/chart icon is displayed in that row
- **AND** the icon is visually distinct (filled or colored)

#### Scenario: Click metrics indicator
- **GIVEN** an interface row with the metrics indicator icon
- **WHEN** the user clicks the metrics icon
- **THEN** they navigate to the interface details page
- **AND** the metrics/graphs section is visible

#### Scenario: No metrics indicator
- **GIVEN** an interface without metrics collection enabled
- **WHEN** the interfaces table renders
- **THEN** the metrics indicator is either absent or shown as disabled/outline style

---

### Requirement: Interface Status Colorized Display

The interfaces table status column SHALL display operational and admin status using colorized labels/badges that are color-blind accessible.

#### Scenario: Operational up status
- **GIVEN** an interface with operational status "up"
- **WHEN** the interfaces table renders
- **THEN** the status shows a green badge with "Up" text
- **AND** includes an upward arrow or checkmark icon for color-blind accessibility

#### Scenario: Operational down status
- **GIVEN** an interface with operational status "down"
- **WHEN** the interfaces table renders
- **THEN** the status shows a red badge with "Down" text
- **AND** includes a downward arrow or X icon for color-blind accessibility

#### Scenario: Admin disabled status
- **GIVEN** an interface with admin status "down" (disabled)
- **WHEN** the interfaces table renders
- **THEN** the status shows a gray or yellow badge with "Admin Down" text
- **AND** includes a pause or disabled icon

#### Scenario: Nil status handling
- **GIVEN** an interface with nil/unknown status value
- **WHEN** the interfaces table renders
- **THEN** the status shows a neutral badge with "Unknown" text
- **AND** does not display "nil" literally

---

### Requirement: Interface Type Human-Readable Mapping

The interfaces table type column SHALL display human-readable interface type names instead of raw IANA ifType values.

#### Scenario: Ethernet interface type
- **GIVEN** an interface with type `ethernetCsmacd` (ifType 6)
- **WHEN** the interfaces table renders
- **THEN** the type column displays "Ethernet"

#### Scenario: Loopback interface type
- **GIVEN** an interface with type `softwareLoopback` (ifType 24)
- **WHEN** the interfaces table renders
- **THEN** the type column displays "Loopback"

#### Scenario: Unknown interface type
- **GIVEN** an interface with an unmapped ifType value
- **WHEN** the interfaces table renders
- **THEN** the type column displays the original value with "(Unknown)" suffix

---

### Requirement: Interface ID Column

The interfaces table SHALL include an interface ID column.

#### Scenario: Display interface ID
- **GIVEN** the interfaces table with interface ID column enabled
- **WHEN** the table renders
- **THEN** each row displays the interface's unique identifier

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

#### Scenario: No favorited interfaces
- **GIVEN** a device with no favorited interfaces with metrics enabled
- **WHEN** the device details page loads the Interfaces tab
- **THEN** the metrics visualization section is not displayed
- **OR** shows an empty state message

---

### Requirement: Interface Threshold Configuration

The interface details page SHALL allow users to configure thresholds on utilization metrics that generate events when exceeded.

#### Scenario: Create utilization threshold
- **GIVEN** the interface details page for an interface with metrics enabled
- **WHEN** the user configures a threshold (e.g., "bandwidth utilization > 80%")
- **THEN** the threshold is saved
- **AND** the system will generate an event when the condition is met

#### Scenario: Threshold generates event
- **GIVEN** an interface with a configured threshold
- **WHEN** the metric value exceeds the threshold
- **THEN** an event is created in the events system
- **AND** the event references the interface and threshold condition

---

### Requirement: Interface Alert Creation

The interface details page SHALL allow users to create alerts on interface threshold events using the existing alert editor component.

#### Scenario: Create alert from threshold
- **GIVEN** a threshold configured on an interface
- **WHEN** the user clicks "Create Alert" on the threshold
- **THEN** the alert editor opens pre-populated with the threshold event source
- **AND** the user can configure alert parameters (e.g., "exceeds threshold for 5 minutes")

#### Scenario: Alert editor reuse
- **GIVEN** the alert creation flow on interface details
- **THEN** it SHALL use the same alert editor component as the Settings page
- **AND** support the same alert configuration options
