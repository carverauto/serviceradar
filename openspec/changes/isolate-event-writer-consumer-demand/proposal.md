# Change: Isolate EventWriter consumer demand and fail denied republishes fast

## Why
One stalled edge-record projector stopped every EventWriter consumer (#6328). A
projector republish the NATS broker denied never got a PubAck, so each edge-record
batch waited out the 5 s PubAck timeout and was redelivered. All worker streams shared
one Broadway pipeline, and Broadway routes processor output to batchers through
`GenStage.PartitionDispatcher`: events for a batcher that stops asking queue in its
partition and keep the demand they used until it drains. The stalled edge-record
batcher's partition absorbed all demand, the producer asked JetStream for nothing,
and the `metrics` stream (30 minute `max_age`) discarded telemetry for every producer
before it was delivered.

Three things amplified the stall: an edge-record batch failed as a whole on its first
raising record, so records that had succeeded were redelivered with it; a broker
denial was indistinguishable from a slow broker, so it was retried forever; and
nothing reported that messages were expiring before delivery.

## What Changes
- Every EventWriter consumer group runs in its own Broadway pipeline (producer,
  processors, batchers), so a stalled batcher only holds the demand of its own group.
  A group is the streams whose filter subject routes to the same batcher; in practice
  each stream is its own group except the raw-flow consumers, which share `:flows_raw`.
  Worker, flow and coordinator streams are split this way under their existing
  supervisors. The configured processor concurrency is divided between a supervisor's
  groups. Batch processors, which do the database and warehouse writes, stay one per
  batcher, and only a group's pipeline feeds its batcher, so write concurrency is
  unchanged.
- An edge-record batch succeeds or fails per record: a record that raises is the only
  one redelivered or dead-lettered.
- A publish the broker denies (`Permissions Violation for Publish`) fails as
  `ServiceRadar.NATS.PublishDeniedError` instead of a PubAck timeout, and for a hold window
  later publishes of that subject on that connection fail without being sent. An edge
  record whose republish was denied is dead-lettered on its first delivery. A plain
  timeout stays retryable.
- The consumer lag reporter polls every consumer's stream and reports
  `expired_before_delivery`: the stream sequences a durable lost because its delivered
  sequence trails the stream's first sequence while messages are pending for it. A
  Prometheus rule alerts on it, and the reporter logs the start and end of loss once
  per stream and durable.

## Impact
- Affected specs: `observability-signals`
- Affected code: `ServiceRadar.EventWriter.Pipeline`, `Supervisor`,
  `CoordinatorSupervisor`, `Health`, `ConsumerLagReporter`, `Telemetry`,
  `EdgeRecordDeadLetter`, `Processors.EdgeRecord`; `ServiceRadar.NATS.JetStreamPublish`,
  `BrokerErrorLogFilter`, new `PublishDenials` and `PublishDeniedError`; the Helm Prometheus
  rules; the web-ng dev Broadway dashboard.
- Operational: each core replica opens one NATS connection per consumer group pipeline
  instead of one per supervisor. Pipeline names change to
  `ServiceRadar.EventWriter.{Pipeline,FlowPipeline,CoordinatorPipeline}.<Group>`, and
  EventWriter health drops its single `pipeline`/`producer` keys in favour of the
  per-pipeline map it already carried.
