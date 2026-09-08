## ADDED Requirements
### Requirement: Device Active Lifecycle
The system SHALL support marking inventory devices active or inactive without deleting the device record. Devices SHALL default to active unless explicitly marked inactive.

#### Scenario: Mark device out of service
- **GIVEN** an active device in inventory
- **WHEN** an authorized operator marks the device inactive
- **THEN** the device SHALL remain in inventory
- **AND** the device SHALL record `is_active = false`
- **AND** the UI SHALL identify the device as out of service

#### Scenario: Restore device to service
- **GIVEN** an inactive device in inventory
- **WHEN** an authorized operator marks the device active
- **THEN** the device SHALL record `is_active = true`
- **AND** the UI SHALL identify the device as active

### Requirement: Active Inventory Accounting
Inventory totals used for future license accounting SHALL count only devices with `is_active = true`.

#### Scenario: Inactive device excluded from active count
- **GIVEN** inventory contains one active device and one inactive device
- **WHEN** active inventory totals are calculated
- **THEN** only the active device SHALL be counted
- **AND** the inactive device SHALL remain queryable in inventory history
