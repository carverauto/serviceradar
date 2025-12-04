## ADDED Requirements
### Requirement: AGE graph writes tolerate contention with retries and backpressure
The system SHALL process AGE graph merges through a backpressure-aware writer that retries transient AGE errors (e.g., SQLSTATE XX000 “Entity failed to be updated”, SQLSTATE 57014 statement timeout) so overlapping registry/backfill writes do not drop batches.

#### Scenario: Concurrent merges do not lose updates
- **WHEN** registry ingestion and a graph rebuild both issue overlapping MERGE batches
- **THEN** the writer queues the work, retries conflicts with bounded backoff, and the batch eventually commits without emitting `Entity failed to be updated` warnings.

#### Scenario: Queue prevents overloading AGE
- **WHEN** the AGE write rate exceeds what CNPG can service
- **THEN** the writer applies bounded queueing/backpressure, exports queue-depth metrics, and avoids timing out statements while keeping ingestion lossless.

### Requirement: AGE backfill coexists with live ingestion
The system SHALL allow the age-backfill utility to run alongside live core graph writes without causing XX000 or statement timeout errors.

#### Scenario: Backfill during steady-state ingestion
- **WHEN** age-backfill runs in the demo namespace while pollers and agents continue publishing updates
- **THEN** graph merges succeed via the coordinated writer path, and core logs do not emit `Entity failed to be updated` or `statement timeout` warnings.
