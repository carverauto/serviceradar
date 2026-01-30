## MODIFIED Requirements

### Requirement: Device Soft Delete Tombstones
The system SHALL support soft deletion of devices by recording a tombstone timestamp and deletion metadata instead of removing the record immediately.

#### Scenario: Soft delete records tombstone metadata
- **GIVEN** an admin or operator deletes a device
- **WHEN** the delete action is processed
- **THEN** the device SHALL remain in `ocsf_devices`
- **AND** `deleted_at` SHALL be set
- **AND** `deleted_by` SHALL record the deleting actor (if available)
- **AND** `deleted_reason` SHALL be stored when provided

#### Scenario: Deletion does not remove device history
- **GIVEN** a device with historical telemetry and service data
- **WHEN** the device is soft deleted
- **THEN** historical records SHALL remain intact
- **AND** only the inventory visibility is affected

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

## ADDED Requirements

### Requirement: Device Deletion Guardrails
The system SHALL block device deletion when the device is agent-managed or has active service checks.

#### Scenario: Block deletion for agent-managed devices
- **GIVEN** a device marked as agent-managed
- **WHEN** an admin attempts to delete the device
- **THEN** the deletion SHALL be rejected
- **AND** the response SHALL indicate the agent-managed constraint

#### Scenario: Block deletion for active service checks
- **GIVEN** a device with enabled service checks
- **WHEN** an admin attempts to delete the device
- **THEN** the deletion SHALL be rejected
- **AND** the response SHALL indicate the active checks constraint

### Requirement: Device Deletion Disables Associated Checks
When a device delete is confirmed, service checks managed by that device/agent SHALL be marked inactive so they no longer appear in default UI views.

#### Scenario: Delete disables checks
- **GIVEN** a device with enabled service checks
- **WHEN** the delete action is processed
- **THEN** those service checks SHALL be marked inactive
- **AND** they SHALL be hidden from default service check views

### Requirement: Device Linkage Visibility
The system SHALL provide a linkage view that surfaces related resources before deletion.

#### Scenario: Device detail shows linked resources
- **GIVEN** a device detail view
- **WHEN** the user opens the delete confirmation
- **THEN** the UI SHALL display linked agents, service checks, and group membership counts
