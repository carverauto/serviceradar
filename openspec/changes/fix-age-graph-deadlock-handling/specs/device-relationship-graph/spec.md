## ADDED Requirements

### Requirement: AGE graph writes are serialized to prevent deadlocks
The system SHALL serialize AGE graph MERGE operations using a mutex so that only one write executes against the graph at any time, eliminating concurrent write contention that causes deadlocks and lock conflicts.

#### Scenario: Concurrent batches do not deadlock
- **GIVEN** multiple workers processing the AGE graph queue
- **WHEN** two workers attempt to execute MERGE batches simultaneously
- **THEN** the mutex ensures only one executes at a time and the other waits, preventing deadlock.

#### Scenario: Queue processing remains responsive
- **GIVEN** a burst of graph updates arriving in the queue
- **WHEN** writes are serialized via mutex
- **THEN** multiple workers can still accept work from the queue, only serializing at the database execution point.

### Requirement: AGE graph writes handle deadlocks with retry
The system SHALL classify PostgreSQL deadlock errors (SQLSTATE 40P01) and serialization failures (SQLSTATE 40001) as transient errors that trigger retry with backoff, so any residual concurrent conflicts do not permanently fail batches.

#### Scenario: Deadlock triggers retry instead of failure
- **GIVEN** a MERGE batch that encounters a deadlock error
- **WHEN** PostgreSQL returns SQLSTATE 40P01
- **THEN** the batch retries with exponential backoff and eventually commits without data loss.

#### Scenario: Serialization failure triggers retry
- **GIVEN** a MERGE batch that encounters a serialization failure
- **WHEN** PostgreSQL returns SQLSTATE 40001
- **THEN** the batch retries with exponential backoff and eventually commits.

### Requirement: Deadlock backoff uses longer delays with randomized jitter
The system SHALL use a longer base backoff (500ms) for deadlock and serialization errors compared to other transient errors (150ms), with exponential growth and randomized jitter to break lock acquisition synchronization patterns.

#### Scenario: Deadlock retries use appropriate backoff
- **GIVEN** a batch that fails with deadlock error
- **WHEN** the batch prepares to retry
- **THEN** the backoff delay starts at 500ms (vs 150ms for other errors) with randomized jitter.

### Requirement: Deadlock metrics are tracked separately
The system SHALL expose distinct metrics for deadlock and serialization failure occurrences to enable monitoring and alerting on contention-specific issues.

#### Scenario: Operator monitors deadlock frequency
- **GIVEN** the Prometheus/OTel metrics endpoint is scraped
- **WHEN** the operator queries `age_graph_deadlock_total`
- **THEN** they can see the count of deadlock errors and alert if frequency increases.

## MODIFIED Requirements

### Requirement: AGE graph writes tolerate contention with retries and backpressure (MODIFIED)
The system SHALL process AGE graph merges through a serialized, backpressure-aware writer that:
1. Serializes writes via mutex to prevent concurrent MERGE conflicts
2. Retries transient AGE errors including:
   - SQLSTATE XX000 "Entity failed to be updated" (lock contention)
   - SQLSTATE 57014 statement timeout
   - SQLSTATE 40P01 deadlock_detected (NEW)
   - SQLSTATE 40001 serialization_failure (NEW)

So overlapping registry/backfill writes do not drop batches due to concurrency conflicts.

#### Scenario: High-volume writes succeed without deadlocks
- **WHEN** pollers and agents generate bursts of device updates
- **THEN** writes are serialized, queue drains successfully, and no deadlock or XX000 errors occur in logs.
