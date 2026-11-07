## ADDED Requirements

### Requirement: EventWriter consumers do not share demand
The EventWriter SHALL consume each consumer group's JetStream durables through a Broadway pipeline of its own, so that a batcher that stops processing cannot take GenStage demand from another group's streams. A consumer group SHALL be the streams whose filter subject routes to the same batcher; streams that share a batcher SHALL share a pipeline. Splitting into groups SHALL NOT add batch processors: every batcher keeps one batch processor, and only its own group's pipeline delivers messages to it.

#### Scenario: A stalled batcher does not starve another consumer
- **WHEN** the edge-record batcher stops processing and edge-record deliveries keep arriving
- **THEN** the metrics and events consumers SHALL keep receiving JetStream deliveries
- **AND** their messages SHALL be processed and acknowledged

#### Scenario: Raw-flow consumers stay together
- **WHEN** several raw-flow consumers (live and drain) route to the `:flows_raw` batcher
- **THEN** they SHALL run in one pipeline with one `:flows_raw` batcher

### Requirement: Edge-record projection failures are per record
The EventWriter SHALL fail only the edge records that raised or were refused during projection. Records of the same batch that were ingested SHALL be acknowledged and SHALL NOT be redelivered because another record failed. A failed record SHALL keep the dead-letter handling of `ServiceRadar.EventWriter.EdgeRecordDeadLetter`; a refused record SHALL be dead-lettered on its first delivery, because the same bytes are refused again on every redelivery.

#### Scenario: One failing record in a batch
- **WHEN** an edge-record batch holds a record whose projection raises and a record that projects
- **THEN** the projected record SHALL be committed and acknowledged
- **AND** only the raising record SHALL be redelivered or dead-lettered

### Requirement: A broker-denied republish is terminal
A JetStream publish on the shared connection that the NATS broker denies for permissions SHALL fail as a publish denial, not as a PubAck timeout. For a bounded hold after a denial, publishes of the same subject on the same connection SHALL fail as denied without being sent; the first publish after the hold SHALL be sent to the broker again. A PubAck timeout the broker did not accompany with a denial SHALL remain a retryable timeout. An edge record whose projector republish was denied SHALL be dead-lettered on its first failed delivery. The denial SHALL be logged once per subject and hold, not once per record.

#### Scenario: Denied republish of a metrics batch
- **WHEN** the broker answers a metrics-batch republish with a Permissions Violation
- **THEN** the publish SHALL fail as denied
- **AND** the edge record SHALL be copied to the dead-letter stream and acknowledged on that delivery

#### Scenario: Slow broker
- **WHEN** a publish receives no PubAck within its timeout and the broker reported no denial
- **THEN** the publish SHALL fail as a timeout and the record SHALL be retried with backoff

### Requirement: Messages expiring before delivery are reported
The EventWriter lag reporter SHALL poll the stream of every configured consumer and SHALL report, per stream and durable, the stream sequences the durable lost before delivery: the gap between its delivered stream sequence and the stream's first retained sequence while messages are pending for it. Labels SHALL be limited to the stream, durable and subject class. A Prometheus rule SHALL alert while the value is above zero, and the reporter SHALL log once when a durable starts losing messages on a stream and once when it stops, keyed by stream and durable so consumers of different streams that share a durable name are tracked apart.

#### Scenario: A durable stops being pulled
- **WHEN** a durable's delivered stream sequence trails its stream's first sequence and messages are pending for it
- **THEN** `serviceradar_event_writer_consumer_expired_before_delivery_value` SHALL report the gap for that stream and durable
- **AND** the expired-before-delivery alert SHALL fire after it persists

#### Scenario: A caught-up durable
- **WHEN** a durable has nothing pending or has been delivered up to the stream's first sequence
- **THEN** the reported value SHALL be zero
