## ADDED Requirements

### Requirement: Device Details Interfaces Tab

The system SHALL display network interfaces in a dedicated "Interfaces" tab within the Device Details page when the device has discovered interfaces.

#### Scenario: Device with network interfaces shows Interfaces tab
- **GIVEN** a device with one or more entries in the `network_interfaces` array
- **WHEN** the user views the Device Details page
- **THEN** the tab bar SHALL display "Details | Interfaces | Profiles" tabs
- **AND** the "Interfaces" tab SHALL be selectable

#### Scenario: Device without interfaces hides Interfaces tab
- **GIVEN** a device with an empty or null `network_interfaces` array
- **WHEN** the user views the Device Details page
- **THEN** the tab bar SHALL display only "Details | Profiles" tabs
- **AND** no "Interfaces" tab SHALL be visible

#### Scenario: Interfaces tab displays all interfaces
- **GIVEN** a device with N network interfaces (where N > 10)
- **WHEN** the user selects the "Interfaces" tab
- **THEN** all N interfaces SHALL be displayed
- **AND** the display SHALL include Name, IP, MAC, and Type columns

---

## REMOVED Requirements

### Requirement: Standalone Interfaces Navigation

**Reason**: Interface information is contextual to devices and should be viewed within the Device Details page rather than as a separate global list.

**Migration**: Users should access interface information via the Device Details page Interfaces tab.

The system no longer provides a standalone `/interfaces` route or sidebar navigation link. All interface viewing is consolidated into the Device Details page.
