## ADDED Requirements

### Requirement: Device Detail Delete Action
The web-ng UI SHALL provide a delete action on the device detail page for admin and operator roles, with confirmation.

#### Scenario: Delete device from detail page
- **GIVEN** an admin or operator views a device detail page
- **WHEN** they click Delete and confirm
- **THEN** the device SHALL be soft deleted
- **AND** the UI SHALL navigate away or show a deleted state

### Requirement: Device Restore Action
The web-ng UI SHALL provide a restore action for deleted devices on the device detail page.

#### Scenario: Restore device from detail page
- **GIVEN** an admin or operator views a deleted device detail page
- **WHEN** they click Restore and confirm
- **THEN** the device SHALL be restored
- **AND** the UI SHALL return to the active device state

### Requirement: Show Deleted Devices Toggle
The web-ng UI SHALL provide an option to show deleted devices in the inventory list.

#### Scenario: Toggle shows deleted devices
- **GIVEN** the inventory list page
- **WHEN** the user enables “Show deleted devices”
- **THEN** tombstoned devices SHALL be included in the list
- **AND** deleted rows SHALL display a visual deleted indicator

### Requirement: Inventory Cleanup Settings
The web-ng UI SHALL expose a Network settings tab for inventory cleanup and device retention.

#### Scenario: Configure retention window
- **GIVEN** an admin user on Settings → Network
- **WHEN** they open the Inventory Cleanup tab
- **THEN** they can set the device deletion retention window in days
- **AND** the value is saved for the reaper job

#### Scenario: Configure reaper schedule
- **GIVEN** an admin user on Settings → Network
- **WHEN** they update the cleanup schedule
- **THEN** the reaper job SHALL use the configured schedule

#### Scenario: Run cleanup manually
- **GIVEN** an admin user on Settings → Network
- **WHEN** they click “Run cleanup now”
- **THEN** the reaper job SHALL execute immediately
