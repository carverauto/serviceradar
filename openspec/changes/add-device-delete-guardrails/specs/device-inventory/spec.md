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
The system SHALL support restoring soft-deleted devices, and every restore, whatever path performs it, SHALL clear tombstone metadata, increment `identity_revision`, and leave a `device_revival_audit` row. A device soft-deleted because it was merged into another device SHALL NOT be restored by discovery.
A device soft-deleted with `deleted_reason` `source_retired` SHALL be restored only by the
corroborated return of its retired source identifier or by an operator, and a device
soft-deleted with `deleted_reason` `seed_released` only by an operator; no sweep, address-only
or MAC-only sighting SHALL restore either. A sweep SHALL restore a `stale_ephemeral` tombstone
that it matches, whatever the device's discovery sources, and SHALL restore a tombstone with
any other permitted reason only when the device has a discovery source other than the sweep.
No sweep write SHALL change the availability or last-seen time of a tombstone that the sweep
does not restore.

#### Scenario: Restore clears tombstone metadata
- **GIVEN** a device with `deleted_at` set
- **WHEN** an admin or operator restores the device
- **THEN** `deleted_at` SHALL be cleared
- **AND** `deleted_by` and `deleted_reason` SHALL be cleared
- **AND** `identity_revision` SHALL be incremented
- **AND** the device SHALL appear in default inventory reads

#### Scenario: Discovery restores a deleted device
- **GIVEN** a device with `deleted_at` set, a `deleted_reason` other than `merged`, `source_retired` or `seed_released`, and a discovery source other than the sweep
- **WHEN** a sweep, integration sync, or agent check-in matches the device identity
- **THEN** the device SHALL be restored automatically
- **AND** `identity_revision` SHALL be incremented
- **AND** availability/last_seen metadata SHALL be updated from the discovery result

#### Scenario: Discovery does not restore a merged-away device
- **GIVEN** a device soft-deleted with `deleted_reason` `merged`
- **WHEN** a sweep, integration sync, or agent check-in matches it
- **THEN** the match SHALL resolve to the device it was merged into
- **AND** the merged-away device SHALL remain deleted

#### Scenario: A sweep restores an expired sweep-only device
- **GIVEN** a device discovered only by sweeps was soft-deleted with `deleted_reason` `stale_ephemeral` while holding address `192.0.2.20`
- **AND** no live device holds `192.0.2.20`
- **WHEN** a sweep finds `192.0.2.20` answering
- **THEN** the device SHALL be restored
- **AND** `identity_revision` SHALL be incremented and a `device_revival_audit` row SHALL record the `stale_ephemeral` tombstone it cleared
- **AND** its availability and last-seen time SHALL be updated from the sweep result

#### Scenario: A sweep does not write to a tombstone it does not restore
- **GIVEN** a device discovered only by sweeps was soft-deleted by an operator while holding address `192.0.2.21`
- **AND** no live device holds `192.0.2.21`
- **WHEN** a sweep finds `192.0.2.21` answering
- **THEN** the device SHALL remain deleted
- **AND** its availability and last-seen time SHALL NOT change

#### Scenario: Evidence does not restore a source-retired device
- **GIVEN** a device soft-deleted with `deleted_reason` `source_retired` after its Armis device id 1001 was retired
- **WHEN** a sweep, an address-only sighting or a sighting matching only its MAC `00:00:5e:00:53:01` arrives
- **THEN** the device SHALL remain deleted

#### Scenario: A returning source id restores a source-retired device
- **GIVEN** a device soft-deleted with `deleted_reason` `source_retired` after its Armis device id 1001 was retired
- **WHEN** Armis reports id 1001 again with the archived MAC and hostname
- **THEN** the device SHALL be restored and SHALL hold Armis device id 1001
- **AND** `identity_revision` SHALL be incremented and a `device_revival_audit` row SHALL be written

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
