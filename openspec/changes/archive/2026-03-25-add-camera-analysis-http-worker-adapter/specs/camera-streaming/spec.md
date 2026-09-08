## ADDED Requirements
### Requirement: Analysis branches may dispatch to external HTTP workers
The system SHALL allow a relay-scoped analysis branch to dispatch bounded `camera_analysis_input.v1` payloads to configured external HTTP workers without creating another upstream camera pull.

#### Scenario: Relay sample is delivered to a worker
- **GIVEN** an active relay session with an attached analysis branch
- **AND** an HTTP worker is configured for that branch
- **WHEN** the branch emits a bounded analysis input
- **THEN** the platform SHALL dispatch the normalized input payload to the worker
- **AND** SHALL keep the dispatch associated with the originating relay session and branch identity

### Requirement: Analysis dispatch must remain bounded
The system SHALL bound analysis worker dispatch so relay playback and ingest remain prioritized over analysis delivery.

#### Scenario: Worker pressure exceeds dispatch limits
- **GIVEN** an active relay session with an attached analysis branch
- **AND** the configured worker is slower than the sample rate
- **WHEN** dispatch concurrency or timeout limits are exceeded
- **THEN** the platform SHALL drop or reject excess analysis work
- **AND** SHALL NOT block viewer playback or require another upstream camera pull
