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

#### Scenario: Reaper schedule is configurable
- **GIVEN** an admin updates the reaper schedule
- **WHEN** the reaper job runs next
- **THEN** it SHALL use the configured schedule

#### Scenario: Manual cleanup execution
- **GIVEN** an admin triggers a manual cleanup
- **WHEN** the cleanup action runs
- **THEN** the reaper job SHALL execute immediately using current settings
