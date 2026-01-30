## ADDED Requirements

### Requirement: Device Soft Delete Tombstones
The system SHALL support soft deletion of devices by recording a tombstone timestamp and deletion metadata instead of removing the record immediately.

#### Scenario: Soft delete records tombstone metadata
- **GIVEN** an admin or operator deletes a device
- **WHEN** the delete action is processed
- **THEN** the device SHALL remain in `ocsf_devices`
- **AND** `deleted_at` SHALL be set
- **AND** `deleted_by` SHALL record the deleting actor (if available)
- **AND** `deleted_reason` SHALL be stored when provided

### Requirement: Inventory Filters Exclude Deleted Devices By Default
The system SHALL exclude tombstoned devices from default inventory reads unless explicitly requested.

#### Scenario: Default reads hide deleted devices
- **GIVEN** a device with `deleted_at` set
- **WHEN** a default device list read is executed
- **THEN** the deleted device SHALL NOT be included

#### Scenario: Include deleted devices on demand
- **GIVEN** a device with `deleted_at` set
- **WHEN** a device list read is executed with `include_deleted = true`
- **THEN** the deleted device SHALL be included

### Requirement: Restore Soft-Deleted Devices
The system SHALL support restoring soft-deleted devices by clearing tombstone metadata.

#### Scenario: Restore clears tombstone metadata
- **GIVEN** a device with `deleted_at` set
- **WHEN** an admin or operator restores the device
- **THEN** `deleted_at` SHALL be cleared
- **AND** `deleted_by` and `deleted_reason` SHALL be cleared
- **AND** the device SHALL appear in default inventory reads

#### Scenario: Discovery restores a deleted device
- **GIVEN** a device with `deleted_at` set
- **WHEN** a sweep or integration discovery result matches the device identity
- **THEN** the device SHALL be restored automatically
- **AND** availability/last_seen metadata SHALL be updated from the discovery result

### Requirement: Device Deletion Authorization
Only admin and operator roles SHALL be permitted to delete devices.

#### Scenario: Viewer cannot delete device
- **GIVEN** a viewer attempts to delete a device
- **WHEN** the delete action is processed
- **THEN** the operation SHALL be rejected

### Requirement: Bulk Device Deletion
The system SHALL support bulk soft deletion for a list of device IDs.

#### Scenario: Bulk delete tombstones multiple devices
- **GIVEN** an admin selects multiple devices
- **WHEN** they perform a bulk delete
- **THEN** each selected device SHALL be soft deleted with tombstone metadata
