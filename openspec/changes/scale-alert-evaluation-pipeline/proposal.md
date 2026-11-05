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
  produces nothing. The same index serves log promotion and makes
  `signal: :log` rules evaluate; today they never run.
- **JetStream is the evaluation log; CNPG is not.** Matching records become
  compact protobuf candidates. A frozen, versioned hash of (rule, group key)
  places each key in one of 1,024 virtual partitions, grouped into 128 blocks,
  so a key's subject never changes. The streams use Limits retention,
  DiscardNew, no MaxAge, and an explicit purge behind each checkpoint.
- **Elastic by settings, small by default.** A CNPG map assigns blocks to
  physical streams. A small install runs one candidate stream and one owner
  per core node, with near-zero idle overhead. Large installs add core nodes,
  which rebalance block leases automatically, and raise the stream count
  setting, which splits streams online. An online block-move protocol
  (remove-then-rebind subjects, record the cut sequence, switch after the
  cut) keeps per-key order and exactly-once with no downtime. Health
  recommends splits, merges and added capacity; resharding is
  operator-triggered, with an opt-in automatic mode.
- **Leased block ownership.** Each block has exactly one owner among the core
  replicas, chosen by rendezvous hashing. Ownership is a CNPG lease whose
  per-block epoch fences every commit, so ordering holds per key and
  throughput scales with replicas.
- **Deterministic in-memory evaluation.** Windows, cooldown, rollover,
  recovery, renotify and incident counters live in memory per block and
  depend only on the checkpoint state and the ordered candidates. Incremental
  checkpoints commit each block's stream position with the dirty groups. Alert,
  history, notification and outbox writes are idempotent by deterministic fire
  keys, so a replay after a crash neither double-fires nor skips.
- **Backpressure is lag.** Owners read with ordered consumers, so nothing can
  be redelivered to death. Publishers retry in place and keep order. A full
  stream refuses new publishes and never evicts accepted messages. Only
  classified poison goes to a dead-letter stream. Lag, lag age, checkpoint age
  and stream fill are health signals.
- **CNPG writes only alert lifecycle, checkpoints, leases and rule
  configuration.** Operator alert actions, rule lifecycle changes and
  stale-anomaly maintenance enter blocks as ordered control messages.
- **Ingestion at fleet scale.** Logs, events and metrics move to separate R3,
  DiscardNew streams with block subjects from the same layout. Each signal
  defaults to one stream and splits online by setting with the same move
  protocol. EventWriter gets concurrent
  batchers per signal and a warehouse load coalescer (rows, bytes, age).
  Collectors batch records per message and pipeline PubAcks. Transient
  failures retry without a delivery cap; poison goes to the DLQ. The
  coordinator-only processors move to leased block ownership.
- **BREAKING internal contract: clean switch.** Removed: the CNPG inbox
  (`alert_evaluation_work`, `alert_evaluation_lanes`,
  `alert_evaluation_receipts`), `stateful_evaluation_ledger`,
  `alert_pending_admissions`, the `alerts` and `alert_recovery` Oban
  queues and workers, `Rollout`/`PeerReadiness`, and the Helm-rendered
  `SERVICERADAR_ALERT_EVALUATION_MODE`. A one-time cutover task imports
  residual inbox and pending rows and existing snapshots in order. There is no
  runtime compatibility layer.
- **Benchmark gates that can fail.** Per-PR RBE gates for the router, owner
  throughput, fault-injected exactly-once, semantics and the small-install
  footprint. In-cluster gates run synthetic load at 50,000 and 100,000
  devices, and split and merge streams under that load. They fail on any
  loss, duplicate, per-key order violation, terminal delivery or discarded
  message, or on lag and latency over threshold.

## Impact

- Affected specs: `alert-evaluation` (new), `telemetry-ingestion-capacity`
  (new), `observability-signals`, `jetstream-storage-budget`,
  `docker-compose-stack`.
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
- **Adapts** the versioned logical-to-physical map idea from
  `add-edge-record-stream-partitioning` into a dynamic, online-resharded map;
  it does not duplicate that change's edge-record tasks.
- **Supersedes** `scale-event-writer-across-core-replicas` Decision 3 for the
  six coordinator-only streams, once their processors take leased block
  ownership (task 6.7).
- **Overlaps** `restore-anomaly-alerting-and-surfacing` ("Alert rule
  evaluation runs only where rules can be loaded"). Block leases are taken
  only by core replicas with repository access, which satisfies it.
- Operators see new health signals and recommendations. At the design point
  they need a larger JetStream footprint (an `xlarge` profile) and about
  0.5-1 PB of StarRocks object storage for the default one-year retention.
  Small installs keep their current profile. Rollback to a pre-cutover image
  is not supported; the cutover is forward-only.
- This is a proposal only. The user's decisions of 2026-11-04 are recorded in
  `design.md` Resolved Questions.
