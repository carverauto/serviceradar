# Design: EventWriter on every core replica

## Context
Issue #5285 tracks scaling EventWriter across core replicas with shared JetStream
durable consumers. Before this change, `CoordinatorChildren` started the whole
`EventWriter.Supervisor`, so one replica ran every pipeline, the lag reporter and
the flow correlator. The producer also created and reconciled streams and durables,
deleted retired durables and ran the stream ownership timer on every connect.

## Decision 1: shared durable pull consumers, one per stream
Every replica binds the same durable for each stream and issues its own pull
requests. JetStream hands each message to one outstanding pull request, so this is
the pull-consumer form of a NATS queue group. A durable per replica would instead
give every replica its own cursor and copy all of the work. The pull inbox carries
a per-subscription random token (`Producer.pull_subject/2`). A reply subject shared
by replicas would fan each delivery out to all of them; the real-broker test fails
when the token is removed.

The coordinator keeps a worker tree as well, so it consumes like any other replica.

## Decision 2: singleton versus N-way split

| Duty | Placement | Reason |
|---|---|---|
| Shared `Pipeline` and `FlowPipeline` | every replica | Consumption scales by binding the shared durables |
| `ServiceCatalogCache`, `AnomalyEpisodeGuardTables` | every replica | Node-local state the pipelines on that node use |
| Stream and durable create/reconcile (`ensure_durable`) | coordinator `ConsumerReconciler` | Replicas would race `STREAM.UPDATE` and, during a rollout, fight over a durable's config; drift on a filter recreates the durable |
| Retired durable deletion | coordinator | Deletes server state; must run after every live durable is up |
| Stream ownership timer (`StreamOwnership`) | coordinator | One grace-period clock per deployment; concurrent claim updates are not compare-and-swap |
| Stream health events | coordinator | One degraded/recovered event per transition, not one per replica. Workers report bind failures as telemetry only |
| `ConsumerLagReporter` | coordinator | Server-side view; replicas would emit duplicate gauges |
| `FlowAttribution.Correlator` | coordinator | One correlation pass; per-replica passes would multiply warehouse query load |
| Coordinator pipeline (6 streams) | coordinator | See Decision 3 |

A worker that cannot find its durable (a fresh install, or the coordinator not yet
elected) retries with the existing 5 s to 60 s backoff and reports not ready.

## Decision 3: ordering and idempotency
Within one replica, Broadway processors already run with concurrency 10 and no
`partition_by`, so arrival order inside and between adjacent batches is not
preserved today. Batchers run with concurrency 1, so one replica never runs two
`handle_batch` calls for the same batcher at once. Shared consumption removes that
last property. Each processor was audited for it:

Safe N-way (idempotent writes keyed by stable ids, or fenced):
- events, PowerDNS, logs, telemetry, OTel metrics and traces, falco: inserts with
  `ON CONFLICT DO NOTHING` on stable ids, StarRocks primary-key tables.
- flows and flow attribution updates: StarRocks primary-key upserts with a
  `merge_condition` on the attribution version.
- exposure transitions and dimensions: cross-replica safety comes from the
  StarRocks `merge_condition` on `transition_seq`. The bucket session locks in
  `ExposureDelivery` are not a correctness dependency of this change.
- k8s nodes: snapshot fence (`WHERE current.snapshot_at < EXCLUDED.snapshot_at`).
- MTR and ad-hoc scans: check-then-insert plus primary keys; a concurrent duplicate
  fails and retries.
- metrics: rows are idempotent. The SNMP fact upsert is last-arrival-wins, which is
  already order-dependent on one replica; replicas widen that window. See Risks.

Kept on the coordinator, with evidence:
- `ANALYTICS_PREDICTIONS`: the anomaly episode upsert reads the open episode in a
  `MATERIALIZED` CTE without a lock and writes merged `producer_states`, and no
  unique index covers one open episode per finding. Two replicas could open two
  episodes for one finding or lose a producer state.
- `BMP_CAUSAL`, `ARANCINI_CAUSAL`, `SIEM_CAUSAL`: causal prediction events decide
  "new transition" from a read of existing ids, then replace, with no lock or
  version guard. Two replicas could both emit the transition and evaluate it twice.
- `K8S_INVENTORY`: public endpoint snapshots soft-delete rows missing from the
  snapshot and record the snapshot time unconditionally. An older snapshot that
  commits last would soft-delete endpoints present in the newer one. The k8s nodes
  processor already has the fence this one lacks.
- `TRIVY`: report and finding upserts are last-arrival-wins outside the advisory
  lock, with unsorted multi-row upserts that can deadlock across replicas.

These six streams move to the worker set once their processors take a per-key lock
or a version fence. That is processor work, outside this change.

Redelivery after a replica dies is at least once, as before: idempotent sinks absorb
it, and the processors above that are not idempotent stay single-writer.

## Decision 4: flow control on shared durables
`max_ack_pending` is the server-side ceiling for the whole durable, shared by every
replica bound to it. A warehouse batcher fills to half of the per-worker value. With
three replicas on an unscaled durable, each replica would hold a third of the
ceiling, none would reach its size trigger, and busy streams would flush only on
`maxAgeMs`. The reconciler therefore sets a shared durable's `max_ack_pending` to the
per-worker value times `EVENT_WRITER_WORKERS`, which keeps each replica's in-flight
budget and batch shape. Coordinator-only durables keep the per-worker value.

`EVENT_WRITER_WORKERS` is the configured replica count (Helm renders it from
`core.replicas`; the chart has no autoscaler for core), not a live membership count.
A replica that is down leaves part of the ceiling unused. The value is
mutable through the existing `CONSUMER.CREATE` upsert, so no durable is recreated.
`ack_wait` (120 s), `max_deliver` and the deliver policy are unchanged. Each replica
keeps one outstanding pull per durable, well inside the default 512 waiting requests.

## Decision 5: Stream Load budget
`LoadAdmission` was a node-wide budget with a note that horizontal workers needed a
deployment-wide one (#5280). Each node now admits `max(1, div(maxInFlight, workers))`
loads, so the deployment stays within `maxInFlight` unless the replicas outnumber
it. The waiting-queue bounds (twice `maxInFlight` callers, `maxBytes * maxInFlight`
bytes) protect node memory and keep the undivided value, so a replica does not turn
ordinary queueing into JetStream redeliveries. A distributed semaphore was not built:
the static split is exact while replicas are up and errs low when one is down.

## Decision 6: health
`Health.status/0` stays node-local and adds the coordinator pipeline and reconciler
on the coordinator. `Health.cluster_status/1` calls every connected node's
`node_status/0` over `:erpc`; nodes that do not host workers, or an older release
during a rollout, are left out, and a node that does not answer is unhealthy.
`ClusterHealth` uses it, so a degraded worker on any replica marks the deployment
degraded. A dead replica's in-flight messages redeliver after `ack_wait` (Decision 3).

## Risks and trade-offs
- Quiet streams: each replica flushes its own warehouse batches after `maxAgeMs`, so
  a quiet dataset can produce up to one load per replica per `maxAgeMs` instead of
  one. Busy streams keep their batch shape (Decision 4).
- The coordinator still carries the six coordinator streams, including BMP routing
  events, plus one share of the worker streams.
- Metrics: the SNMP fact upsert is last-arrival-wins with unsorted multi-row
  chunks, so two replicas can now commit an older poll last, or deadlock and retry;
  rows converge on the next poll. A `collected_at` guard with sorted rows would
  remove both.
- Per-node anomaly guard counters stay correct because `ANALYTICS_PREDICTIONS`
  stays on the coordinator.
- Rolling deploy: the first new replica to become coordinator reconciles durables to
  the scaled `max_ack_pending`; an old coordinator still alive could set it back once
  on reconnect. Durable names and cursors are unchanged in both directions, so a
  rollback resumes without resetting cursors.

## Not built
- Per-key locks or fences in the six coordinator-stream processors.
- A live-membership or distributed Stream Load semaphore.
- Subject-partitioned consumers. With the coordinator split, no stream needs them.
- A measured soak and autoscaling policy (#5285 acceptance; serviceradar-control#177).
