## ADDED Requirements

### Requirement: Armis northbound jobs use database-backed scheduling
The system SHALL schedule recurring Armis northbound update jobs through Oban/AshOban with database-backed persistence rather than NATS KV coordination.

#### Scenario: Enabled Armis source has recurring update job
- **GIVEN** an Armis integration source has northbound updates enabled with a configured cadence
- **WHEN** scheduling is reconciled
- **THEN** the system SHALL persist a recurring job definition/execution path for that source in the database
- **AND** the job SHALL execute through Oban/AshOban infrastructure

### Requirement: Armis northbound jobs are user-configurable
Operators SHALL be able to change the schedule for an Armis northbound update job and have the new cadence take effect without code changes.

#### Scenario: Operator changes Armis northbound schedule
- **GIVEN** an Armis source already has northbound scheduling configured
- **WHEN** an operator updates the cadence in the UI
- **THEN** the new schedule SHALL be persisted
- **AND** subsequent northbound jobs SHALL use the updated cadence

### Requirement: Armis northbound jobs support manual execution
The system SHALL support manual execution of an Armis northbound update job in addition to its recurring schedule.

#### Scenario: Run now enqueues Armis northbound job
- **GIVEN** an operator requests a manual Armis northbound update
- **WHEN** the request is accepted
- **THEN** the system SHALL enqueue an immediate job for that source
- **AND** the manual execution SHALL appear in job history

### Requirement: Armis northbound jobs prevent overlapping duplicates
The system SHALL apply uniqueness or equivalent guards so overlapping Armis northbound jobs for the same integration source do not execute concurrently unless explicitly allowed.

#### Scenario: Duplicate schedule tick occurs while prior run is still active
- **GIVEN** an Armis northbound job for source X is already running
- **WHEN** another scheduled enqueue attempt occurs for source X within the uniqueness window
- **THEN** the system SHALL avoid creating a duplicate overlapping execution for source X
