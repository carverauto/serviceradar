## MODIFIED Requirements

### Requirement: Restore Soft-Deleted Devices
The system SHALL support restoring soft-deleted devices, and every restore, whatever path performs it, SHALL clear tombstone metadata, increment `identity_revision`, and leave a `device_revival_audit` row. A device soft-deleted because it was merged into another device SHALL NOT be restored by discovery.

#### Scenario: Restore clears tombstone metadata
- **GIVEN** a device with `deleted_at` set
- **WHEN** an admin or operator restores the device
- **THEN** `deleted_at` SHALL be cleared
- **AND** `deleted_by` and `deleted_reason` SHALL be cleared
- **AND** `identity_revision` SHALL be incremented
- **AND** the device SHALL appear in default inventory reads

#### Scenario: Discovery restores a deleted device
- **GIVEN** a device with `deleted_at` set and a `deleted_reason` other than `merged`
- **WHEN** a sweep, integration sync, or agent check-in matches the device identity
- **THEN** the device SHALL be restored automatically
- **AND** `identity_revision` SHALL be incremented
- **AND** availability/last_seen metadata SHALL be updated from the discovery result

#### Scenario: Discovery does not restore a merged-away device
- **GIVEN** a device soft-deleted with `deleted_reason` `merged`
- **WHEN** a sweep, integration sync, or agent check-in matches it
- **THEN** the match SHALL resolve to the device it was merged into
- **AND** the merged-away device SHALL remain deleted
