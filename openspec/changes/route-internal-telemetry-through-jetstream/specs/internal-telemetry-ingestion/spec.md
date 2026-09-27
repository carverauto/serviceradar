## ADDED Requirements

### Requirement: Internal OCSF events have one producer path
The system SHALL produce every internally generated OCSF event through a single publisher that publishes it to JetStream, and no module outside EventWriter SHALL insert into the OCSF events table.
The publisher assigns the event id and time, applies out-of-service device suppression, waits
for the stream's acknowledgement, and returns the event with its id to the caller.

#### Scenario: A producer receives the event id before storage
- **WHEN** the stateful alert engine fires an alert
- **THEN** the alert's event is published to JetStream
- **AND** the alert links the event id returned by the publisher
- **AND** EventWriter stores the event with that same id

#### Scenario: An out-of-service device produces no event
- **GIVEN** a device marked out of service
- **WHEN** a producer publishes an operational event for that device
- **THEN** the publisher returns a suppression result
- **AND** nothing is published

#### Scenario: A direct write fails lint
- **WHEN** a module outside EventWriter inserts into `ocsf_events` or `logs`, creates an
  `OcsfEvent` or `Log`, or calls an EventWriter processor's `process_batch/1`
- **THEN** the project's Credo lint reports it
- **AND** the Elixir Quality check of a pull request touching that project fails

### Requirement: Internal telemetry survives a NATS outage
The system SHALL retain an internally produced event, log or analytics signal that EventWriter stores whenever its JetStream publish fails, and SHALL publish it when NATS is reachable again, storing it exactly once.
Best-effort live feeds that nothing stores (the live log tail, the causal state-change feed) are
outside this requirement.

#### Scenario: Publish fails, then recovers
- **GIVEN** JetStream does not acknowledge a publish
- **WHEN** a producer publishes an internal event
- **THEN** the event is retained in a durable retry queue
- **AND** it is published and stored once when JetStream acknowledges it
- **AND** a replay of the same event stores no second row

#### Scenario: A signal published after a commit is not dropped
- **GIVEN** a scan committed its package changes
- **WHEN** a package change signal cannot be published
- **THEN** it is retained in the durable retry queue rather than logged and dropped

### Requirement: Northbound handlers run once per produced event
The system SHALL run northbound event handlers for an internal event once, after JetStream has acknowledged it, independent of which telemetry backend stores it.

#### Scenario: Handlers after acknowledgement
- **WHEN** an internal event is acknowledged by JetStream
- **THEN** the northbound handlers run once for that event
- **AND** a redelivery of the event to EventWriter runs no handler again

### Requirement: Redelivery never duplicates stored telemetry or its consequences
The system SHALL make redelivery of an events or logs message idempotent: no second event or log row, no second promoted event, no second stateful evaluation and no second promotion alert.
Stateful evaluation is at least once: an event whose evaluation failed is evaluated when its
batch is redelivered, and an event already evaluated is not evaluated again.

#### Scenario: Evaluation fails, then succeeds on redelivery
- **GIVEN** an events batch whose stateful evaluation fails
- **WHEN** JetStream redelivers the batch
- **THEN** the events are evaluated once
- **AND** events of the batch that were already evaluated are not evaluated again

#### Scenario: A log message is redelivered
- **GIVEN** a log message whose batch failed after the rows were inserted
- **WHEN** JetStream redelivers the message
- **THEN** the log rows and their promoted events are not stored again
- **AND** no promotion alert or stateful rule fires a second time

#### Scenario: A processed log is promoted by one consumer
- **GIVEN** a processed log on a `logs.*.processed` subject that matches an event rule
- **WHEN** it is ingested
- **THEN** exactly one event is promoted from it, by EventWriter's logs consumer
- **AND** no durable consumer created for a retired promotion path remains on the stream

### Requirement: Internal probes stay invisible
The system SHALL NOT publish or store the OCSF event of a synthetic liveness probe.

#### Scenario: Liveness probe fires an alert
- **WHEN** the anomaly liveness check drives a synthetic event through the alert engine
- **THEN** the fired alert's event is not published
- **AND** it never appears in the Events UI or either telemetry backend
