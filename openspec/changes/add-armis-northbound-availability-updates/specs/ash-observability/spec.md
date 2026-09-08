## ADDED Requirements

### Requirement: Armis northbound jobs export metrics
The system SHALL export metrics for Armis northbound update execution so operators can monitor run health and throughput.

#### Scenario: Successful run updates metrics
- **GIVEN** an Armis northbound update job completes
- **WHEN** metrics are exported
- **THEN** they SHALL include at least run count, execution duration, updated device count, and skipped device count for that run

#### Scenario: Failed run updates metrics
- **GIVEN** an Armis northbound update job fails
- **WHEN** metrics are exported
- **THEN** they SHALL include a failure count for the source/job
- **AND** SHALL preserve execution duration/error classification data when available

### Requirement: Armis northbound jobs emit persisted events
The system SHALL persist success/failure events for each Armis northbound update run so they are visible in the Events experience.

#### Scenario: Success event is recorded
- **GIVEN** an Armis northbound update run succeeds
- **WHEN** the run completes
- **THEN** the system SHALL persist an event containing the integration source identifier, run outcome, and summary counts

#### Scenario: Failure event is recorded
- **GIVEN** an Armis northbound update run fails
- **WHEN** the run completes
- **THEN** the system SHALL persist an event containing the integration source identifier and failure summary
- **AND** the Events UI SHALL be able to refresh and display that event
