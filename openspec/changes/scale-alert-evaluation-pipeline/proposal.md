# Change: Scale alert evaluation and ingestion to a 100,000-device fleet

## Why

ServiceRadar must ingest and alert on logs, events, flows and metrics from
50,000-100,000 devices without losing signals and without falling over under
load. Today's alert path does not reach demo scale. On demo (v1.4.101), alert
admission refused Falco bursts with `{:overloaded, :rule_bytes}` about 2 times a
second; after five JetStream deliveries each refused batch was terminated and
its evaluation was lost. Evaluation runs at about 6 completions/s per rule.
Every eligible (event, rule) pair copies about 12.7 KB into a CNPG inbox row,
and one global admission lock serializes every replica.

`capacity.md` derives the target: about 800,000 records/s of ingest and 40,000
alert candidates/s sustained (100,000/s in a burst). It shows the current path
breaking at five stages. Alert evaluation is about 450x short. A burst fills
the admission budget in seconds. The shared `events` stream evicts accepted,
unprocessed messages after about 25 s of backlog. EventWriter's 100-row batches
would mean about 1,000 StarRocks loads/s. Log collectors publish one record per
round trip.

The user's direction (2026-11-04) is to redesign whatever is needed. Standing
decisions apply. Backpressure never loses a signal or its evaluation. Data is
never truncated. All telemetry goes through JetStream first, and StarRocks is
the only telemetry store when enabled. Runtime knobs live in CNPG with code
defaults, never Helm alone. Legacy paths are removed, not kept beside the new
ones.

## What Changes

- **Compiled rule index.** EventWriter matches each stored record against an
  index of active rules (subject-prefix trie, equality buckets, severity
  floors), so matching costs O(candidate rules). A record that matches no rule
  produces nothing. The same index serves log promotion.
- **JetStream is the evaluation log; CNPG is not.** Matching records become
  compact protobuf candidates on `alerts.candidates.v1.pNN`, partitioned by a
  versioned hash of (rule, group key) into 64 logical partitions mapped onto
  physical streams. The streams use Limits retention, DiscardNew, no MaxAge,
  and an explicit purge behind each checkpoint.
- **Leased partition ownership.** Each partition has exactly one owner among
  the core replicas, chosen by rendezvous hashing. Ownership is a CNPG lease
  whose epoch fences every commit, so ordering holds per key and throughput
  scales with replicas.
- **Deterministic in-memory evaluation.** Windows, cooldown, rollover,
  recovery, renotify and incident counters live in memory per partition and
  depend only on the checkpoint state and the ordered candidates. Incremental
  checkpoints commit the stream sequence with the dirty groups. Alert,
  history, notification and outbox writes are idempotent by deterministic fire
  keys, so a replay after a crash neither double-fires nor skips.
- **Backpressure is lag.** Owners read with ordered consumers, so nothing can
  be redelivered to death. Publishers retry in place and keep order. A full
  stream refuses new publishes and never evicts accepted messages. Only
  classified poison goes to a dead-letter stream. Lag, lag age, checkpoint age
  and stream fill are health signals.
- **CNPG writes only alert lifecycle, checkpoints, leases and rule
  configuration.** Operator alert actions, rule lifecycle changes and
  stale-anomaly maintenance enter partitions as ordered control messages.
- **Ingestion at fleet scale.** Logs, events and metrics move to separate R3,
  DiscardNew streams partitioned with the same map. EventWriter gets concurrent
  batchers per signal and a warehouse load coalescer (rows, bytes, age).
  Collectors batch records per message and pipeline PubAcks. Transient
  failures retry without a delivery cap; poison goes to the DLQ. The
  coordinator-only processors move to key-partitioned ownership.
- **BREAKING internal contract: clean switch.** Removed: the CNPG inbox
  (`alert_evaluation_work`, `alert_evaluation_lanes`,
  `alert_evaluation_receipts`), `stateful_evaluation_ledger`,
  `lifecycle_pending_admissions`, the `alerts` and `alert_recovery` Oban
  queues and workers, `Rollout`/`PeerReadiness`, and the Helm-rendered
  `SERVICERADAR_ALERT_EVALUATION_MODE`. A one-time cutover task imports
  residual inbox and pending rows and existing snapshots in order. There is no
  runtime compatibility layer.
- **Benchmark gates that can fail.** Per-PR RBE gates for the router,
  partition throughput and fault-injected exactly-once. A fleet-scale gate
  runs synthetic load at the target rates and fails on any loss, duplicate,
  terminal delivery or discarded message, or on lag and latency over threshold.

## Impact

- Affected specs: `alert-evaluation` (new), `telemetry-ingestion-capacity`
  (new), `observability-signals`, `jetstream-storage-budget`.
- Affected code: `ServiceRadar.Observability.StatefulAlertEngine.*`,
  `StatefulEvaluationLedger`, `LogPromotion`, the alert/rule Ash resources and
  migrations, every EventWriter processor that evaluates (`Events`,
  `FalcoEvents`, `TrivyReports`, `AnalyticsSignals`, `Logs`, `Metrics`),
  `EventWriter.Config`, `Pipeline` and `ConsumerReconciler`, the StarRocks
  `Destination`, the notification routing outbox, web-ng alert actions, the
  flowgger and trapd NATS outputs, Helm NATS profiles and `buildbuddy.yaml`.
- **Ordering prerequisites.** `refactor-durable-alert-admission` (implemented
  by #5473) must be archived before this change, because this change removes
  the requirements it adds. The pending anomaly-open eligibility fix
  (`RuleMatcher.event_candidate?/2`) is folded into the index as-is and is not
  redone.
- **Depends on** `extend-starrocks-to-all-telemetry` for warehouse-only logs
  and events at the design point. Without StarRocks, the stated CNPG-only
  ceiling applies (`capacity.md` 1.6).
- **Reuses** the versioned 64-partition logical-to-physical map from
  `add-edge-record-stream-partitioning`; it does not duplicate that change's
  edge-record tasks.
- **Supersedes** `scale-event-writer-across-core-replicas` Decision 3 for the
  six coordinator-only streams, once their processors take key-partitioned
  ownership (tasks 6.6).
- **Overlaps** `restore-anomaly-alerting-and-surfacing` ("Alert rule
  evaluation runs only where rules can be loaded"). Partition leases are taken
  only by core replicas with repository access, which satisfies it.
- Operators see new health signals and a larger JetStream footprint (an
  `xlarge` profile at the design point). Rollback to a pre-cutover image is
  not supported; the cutover is forward-only.
- This is a proposal only. User decisions are listed in `design.md` Open
  Questions.
