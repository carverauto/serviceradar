## ADDED Requirements

### Requirement: Device Tombstone Reaper Job
The system SHALL run a scheduled job that permanently deletes devices whose tombstones are older than a configurable retention window.

#### Scenario: Reaper removes expired tombstones
- **GIVEN** a device with `deleted_at` older than the retention window
- **WHEN** the reaper job runs
- **THEN** the device record SHALL be permanently removed

#### Scenario: Retention window is configurable
- **GIVEN** an admin updates the retention days setting
- **WHEN** the reaper job runs next
- **THEN** it SHALL use the updated retention window
