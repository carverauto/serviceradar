## ADDED Requirements

### Requirement: Device Dashboard Stats Cards

The system SHALL display summary statistics cards above the devices table on the devices dashboard page.

The stats cards section SHALL include:
- Total Devices card: Shows total device count
- Available Devices card: Shows available count with success styling
- Unavailable Devices card: Shows unavailable count with error styling when > 0
- Device Types card: Shows breakdown of device types (top 5)
- Top Vendors card: Shows breakdown by vendor (top 5)

#### Scenario: Stats cards display on page load
- **GIVEN** a user navigates to the devices dashboard
- **WHEN** the page loads
- **THEN** stats cards SHALL be displayed above the devices table
- **AND** cards SHALL show current statistics via SRQL queries

#### Scenario: Stats cards show loading state
- **GIVEN** a user navigates to the devices dashboard
- **WHEN** statistics are being fetched
- **THEN** stats cards SHALL display skeleton placeholders

#### Scenario: Unavailable devices highlighted
- **GIVEN** there are unavailable devices in the inventory
- **WHEN** the stats cards are displayed
- **THEN** the Unavailable Devices card SHALL use error styling (red tone)
- **AND** the count SHALL be prominently displayed

#### Scenario: Stats cards are clickable filters
- **GIVEN** the stats cards are displayed
- **WHEN** a user clicks on the "Unavailable Devices" card
- **THEN** the devices table SHALL filter to show only unavailable devices

#### Scenario: Stats loaded via parallel SRQL queries
- **GIVEN** the devices dashboard is loading
- **WHEN** stats are fetched
- **THEN** multiple SRQL queries SHALL execute in parallel
- **AND** each card SHALL load independently
