## ADDED Requirements

### Requirement: Distributed Sweep Result Ingestion
The system SHALL ingest sweep result chunks on every core node that handles agent results, rather than inside a single coordinator process, and SHALL bound the number of concurrent sweep ingestions per node by configuration.

#### Scenario: Chunks from different groups ingest in parallel
- **GIVEN** two core nodes each running sweep ingestion workers
- **AND** one agent reporting results for a large sweep group and a small sweep group at the same time
- **WHEN** chunks for both groups arrive
- **THEN** the small group's chunks SHALL be ingested without waiting for the large group's chunks to finish
- **AND** the work SHALL be spread across the available workers

#### Scenario: A node joins the cluster
- **GIVEN** sweep ingestion running on two core nodes
- **WHEN** a third core node starts its sweep ingestion workers
- **THEN** the dispatcher SHALL begin assigning idle partitions to the new workers without a restart or configuration change

#### Scenario: Per-node concurrency is configured
- **GIVEN** `SWEEP_INGESTION_WORKERS_PER_NODE` is set to N on a core node
- **WHEN** that node starts
- **THEN** it SHALL run at most N concurrent sweep ingestions
- **AND** a value of 0 SHALL start no workers on that node

### Requirement: Ordered Sweep Ingestion Per Group And Agent
The system SHALL ingest the chunks reported by one agent for one sweep group in the order they were received, including across consecutive executions, while ingesting different groups or agents concurrently.

#### Scenario: A partition with work in flight keeps its worker
- **GIVEN** chunks for group G from agent A are still being ingested by worker W
- **WHEN** another chunk for group G from agent A arrives
- **THEN** it SHALL be sent to worker W even if another worker is idle

#### Scenario: An idle partition moves to the least-loaded worker
- **GIVEN** every chunk for group G from agent A has been ingested
- **WHEN** the next chunk for group G from agent A arrives
- **THEN** it MAY be assigned to the worker with the fewest chunks in flight

#### Scenario: A worker leaves with work in flight
- **GIVEN** worker W holds in-flight chunks for one or more partitions
- **WHEN** W exits or its node disconnects
- **THEN** those partitions SHALL be reassigned on their next chunk
- **AND** the number of chunks that were in flight on W SHALL be reported as lost through telemetry

### Requirement: Sweep Ingestion Fallback
The system SHALL keep ingesting sweep results through the coordinator's results router when no distributed sweep ingestion worker is available.

#### Scenario: No workers are registered
- **GIVEN** the dispatcher sees no registered sweep ingestion workers
- **WHEN** a sweep result chunk arrives
- **THEN** it SHALL be ingested through the results router as it was before distributed ingestion existed
- **AND** a fallback SHALL be reported through telemetry

### Requirement: Concurrency-Safe Sweep Device Writes
The system SHALL apply sweep availability results from concurrent ingestions to shared device rows without deadlocking and without losing the newest per-agent observation.

#### Scenario: Two agents report the same devices concurrently
- **GIVEN** two agents sweeping the same devices
- **WHEN** their chunks are ingested at the same time on different workers
- **THEN** both ingestions SHALL complete
- **AND** each device SHALL keep one per-agent availability row per agent holding that agent's newest `checked_at`

#### Scenario: A deadlock is detected against another writer
- **GIVEN** a sweep device update is chosen as a deadlock victim
- **WHEN** PostgreSQL reports `deadlock_detected`
- **THEN** the update SHALL be retried once before the failure is logged
