## ADDED Requirements
### Requirement: Object Store Retention Runs As Scheduled Maintenance
The system SHALL run Object Store retention as idempotent Oban-backed maintenance work with uniqueness controls, configurable scheduling, and support for manual enqueue where the job catalog supports manual execution.

#### Scenario: Scheduled retention runs once per interval
- **GIVEN** Object Store retention is enabled
- **WHEN** the configured retention schedule elapses
- **THEN** Oban enqueues the retention worker once for the interval
- **AND** duplicate jobs are not executed concurrently

#### Scenario: Dry-run retention reports cleanup candidates
- **GIVEN** Object Store retention is configured for dry-run mode
- **WHEN** an operator manually enqueues the retention worker
- **THEN** the worker scans configured namespaces and reports eligible objects
- **AND** no object is deleted
