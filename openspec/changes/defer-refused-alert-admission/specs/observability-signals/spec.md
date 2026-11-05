## ADDED Requirements

### Requirement: Refused alert admission is deferred durably
EventWriter SHALL defer every stored signal's stateful alert admission that is refused as `{:overloaded, dimension}` or `:alert_evaluation_peer_not_ready` to the durable `platform.lifecycle_pending_admissions` backlog, and SHALL acknowledge the source message once the signal and its deferred admission snapshots are committed, so that alert-evaluation backpressure lags evaluation and never loses it.

A refusal of either kind SHALL NOT fail the batch or consume a JetStream delivery. Any other failure, including a failed deferral write, SHALL still fail the batch, and the consumer's delivery limit and dead-lettering SHALL remain unchanged. Each signal's deferred records SHALL form one FIFO lane: while a lane holds rows, new records SHALL join behind them rather than be admitted ahead. Lifecycle occurrences SHALL keep their per-series FIFO in the `lifecycle` lane. A deferred row SHALL be deleted only in a transaction that admitted every record it covers, and a retried admission SHALL continue after the prefix the inbox already accepted. The backlog SHALL NOT be capped or truncated.

#### Scenario: Overload past the delivery limit is not dead-lettered
- **GIVEN** a Falco event whose stateful admission is refused as overloaded
- **WHEN** its message is delivered again up to and past the consumer's `max_deliver`
- **THEN** every delivery SHALL be acknowledged and none terminated or dead-lettered
- **AND** the event SHALL be stored once
- **AND** its admission snapshot SHALL stay pending until a drain admits it

#### Scenario: Newer records wait behind the backlog
- **GIVEN** a lane holds deferred records
- **WHEN** a later batch of the same signal is admitted
- **THEN** its records SHALL be deferred behind the backlog
- **AND** the backlog SHALL be admitted in `seq` order before them

#### Scenario: A genuine refusal still fails the batch
- **WHEN** admission is refused for any reason other than capacity or peer readiness
- **THEN** the batch SHALL fail
- **AND** no record SHALL be deferred

### Requirement: The deferred admission backlog is observable
The system SHALL report the deferred admission backlog's pending count and oldest pending age per lane at least once a minute as telemetry published through JetStream, and SHALL record an `alert-admission-backlog` core health check that is unhealthy while the oldest pending row has waited at least 10 minutes or the backlog holds at least 100,000 rows.

#### Scenario: A lagging backlog is unhealthy
- **GIVEN** a deferred row that has waited longer than 10 minutes
- **WHEN** the backlog is reported
- **THEN** the report SHALL include that row in its lane's pending count and age
- **AND** the `alert-admission-backlog` health check SHALL be unhealthy
