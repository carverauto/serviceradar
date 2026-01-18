## ADDED Requirements
### Requirement: Scheduling clients handle missing Oban instances

Services that insert or enqueue Oban jobs MUST treat a missing Oban instance/configuration as a recoverable condition and avoid crashing user-facing workflows.

#### Scenario: Oban instance missing during enqueue
- **GIVEN** a service that enqueues jobs in response to a user action
- **AND** the Oban instance is not running or configured in that process
- **WHEN** the service attempts to enqueue a job
- **THEN** the user-facing operation SHALL succeed
- **AND** the system SHALL record that the job scheduling is deferred or skipped
- **AND** operators SHALL have a warning or log entry indicating the scheduler is unavailable
