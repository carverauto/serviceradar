## ADDED Requirements

### Requirement: Sync ingestion admission is bounded and replies
The sync ingestion queue SHALL admit sync result payloads with a reply, SHALL reject a payload with `{:error, :sync_ingest_queue_full}` when admitting it would exceed the configured ingress, pending-plus-in-flight item, byte, or source/run bound, and SHALL count queued, ingress-reserved, and in-flight payloads toward that bound. Payload decoding SHALL happen in the supervised ingestion task, not in the queue or dispatcher process. Callers SHALL inspect and propagate rejection instead of treating it as successful ingestion.

#### Scenario: Queue full while a task is in flight
- **GIVEN** an ingestion task is running and the queued payloads have reached the configured bound
- **WHEN** another sync payload is admitted
- **THEN** the queue SHALL reply `{:error, :sync_ingest_queue_full}`
- **AND** its retained payload bytes SHALL NOT grow

#### Scenario: A malformed payload does not stall admission
- **GIVEN** a sync payload that is not valid JSON
- **WHEN** it is admitted
- **THEN** the queue SHALL accept it without decoding it in the queue process
- **AND** the ingestion task SHALL reject it and continue with the next payload

### Requirement: A sync run with a rejected chunk is not activated
The system SHALL mark a sync run incomplete when any of its chunks is rejected at admission, and SHALL NOT activate that run's inventory snapshot from the remaining chunks.

#### Scenario: Overflow during a sync run
- **GIVEN** a sync run whose third chunk is rejected because the queue is full
- **WHEN** the run's remaining chunks are ingested
- **THEN** the run SHALL be recorded as incomplete
- **AND** devices present only in the rejected chunk SHALL NOT be retired by snapshot activation

#### Scenario: Unattributable overflow fails closed
- **GIVEN** a raw rejected chunk cannot yet be attributed to a validated sync-run identity
- **WHEN** snapshot activation is considered for the affected incomplete input
- **THEN** activation SHALL fail closed instead of treating an untracked rejection as a complete run
- **AND** run-identity decoding SHALL NOT execute in a queue or dispatcher callback

#### Scenario: A later complete run remains eligible
- **GIVEN** an earlier sync run lost a chunk to admission rejection
- **WHEN** a separate complete run is admitted and satisfies its activation guard
- **THEN** the earlier rejection SHALL NOT be misattributed to the complete run
- **AND** the complete run SHALL retain its existing activation behavior
