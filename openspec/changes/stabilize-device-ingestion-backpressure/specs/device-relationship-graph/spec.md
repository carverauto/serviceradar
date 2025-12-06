## ADDED Requirements
### Requirement: AGE graph writes do not stall device ingestion
The system SHALL decouple AGE graph writes from the synchronous registry ingest path so device updates complete even when the graph queue is saturated or timing out.

#### Scenario: Registry ingest proceeds during graph backlog
- **WHEN** AGE graph queue depth grows and individual merges would exceed the request timeout
- **THEN** device ingest finishes without waiting for the blocked graph work, and the skipped graph batches are recorded for later replay.

### Requirement: AGE graph backpressure is bounded and observable
The system SHALL bound AGE graph retries/queueing with metrics and alerts that surface queue depth, wait time, timeout counts, and dropped batches.

#### Scenario: Operators see actionable AGE queue signals
- **WHEN** AGE graph merge attempts start timing out or being dropped because the queue is full
- **THEN** metrics/logs report queue depth, wait durations, and timeout counts with batch sizes so operators can react before ingestion is impacted.
