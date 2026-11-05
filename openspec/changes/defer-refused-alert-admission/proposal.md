# Change: Defer refused alert admission to a durable backlog

## Why

EventWriter stores a signal and then admits it to stateful alert evaluation.
When admission is refused as `{:overloaded, dimension}` or
`:alert_evaluation_peer_not_ready`, the batch failed and JetStream redelivered
it with backoff. At the consumer's final delivery (`max_deliver: 5`) the message
was dead-lettered and terminated. The signal row survived, but its stateful
evaluation was lost. After a rolling restart under load this terminated more
than a thousand Falco deliveries in a quarter hour. Only lifecycle signals,
whose pending admissions were already durable, kept their evaluation.

`scale-alert-evaluation-pipeline` replaces this path next sprint ("lag, not
loss"). This change is the minimal step toward it for release v1.4.102:
backpressure must lag evaluation, never lose it.

## What Changes

- Generalize `platform.lifecycle_pending_admissions` into
  `platform.alert_pending_admissions` with a `lane` column. The `lifecycle`
  lane keeps its per-(class, series) FIFO unchanged. New `event` and `metric`
  lanes are each one FIFO by `seq` and carry no series.
- Add `ServiceRadar.EventWriter.AlertAdmissionBacklog`. Every EventWriter
  family that admits to stateful evaluation goes through it: Falco, Trivy,
  generic events, log promotion and the bulk analytics rows (through
  `StatefulEvaluationLedger.evaluate_once/2`), and metric points (through
  `MetricAlertAdmission`). A retryable refusal writes the records' immutable
  admission snapshots and, for events, the evaluation ledger marker in one
  transaction, and the batch succeeds. While a lane holds rows, new records
  join behind them and the joining batch admits one chunk from the head.
- Lifecycle signals keep their pending rows; a retryable refusal no longer
  fails the message that delivered them.
- Rename `LifecycleAdmissionDrainWorker` to `AlertAdmissionDrainWorker`. Each
  minute it drains the lifecycle series as before, then the event and metric
  lanes from their heads, then reports the backlog.
- Report the backlog: per-lane `pending_count` and `oldest_pending_ms` as a
  telemetry event and as the `alert_admission_backlog` ingestion lane through
  JetStream, and the `alert-admission-backlog` core health check, unhealthy
  once the oldest row has waited 10 minutes or the backlog reaches 100,000
  rows.
- Remove the EventWriter pipeline's backoff and dead-letter handling for
  retryable alert-evaluation refusals, which no processor returns any more.
  Consumer `max_deliver` is unchanged: genuine failures and poison messages
  still dead-letter.

## Impact

- Affected specs: `observability-signals`.
- Affected code: `StatefulEvaluationLedger`, `MetricAlertAdmission`,
  `AnalyticsSignals`, `EventWriter.Pipeline`, the drain worker, the
  `Ingestion.RuntimeMetrics` lane set, migration
  `20261105100000_generalize_alert_pending_admissions`.
- Operators no longer see terminal deliveries for alert-evaluation
  backpressure. A backlog shows instead in the new health check and lane
  gauges, and alert effects for deferred records appear when the backlog
  drains.
- `scale-alert-evaluation-pipeline` imports residual rows of every lane at
  its cutover and removes the table, the backlog module and the worker.
