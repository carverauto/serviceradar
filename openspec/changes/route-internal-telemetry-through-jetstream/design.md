# Design: internal events, logs and signals through JetStream

## Context

EventWriter persists everything that arrives on JetStream. For `events.*` that means
`Processors.Events`: a batched insert, stateful rule evaluation, a count broadcast and the
warehouse mirror. Core also writes `platform.ocsf_events` directly from about fifteen places.
Some use `Ash.create(OcsfEvent, :record)`; its before_action suppresses events for
out-of-service devices, and its after_action runs northbound event handlers. Others use
`Repo.insert_all`, with or without a one-row warehouse mirror. `InternalLogPublisher` calls
`Processors.Logs.process_batch/1` in-process. The vulnerability-finding and IOC-exposure
emitters call `Processors.AnalyticsSignals.process_batch/1` in-process.

The inventory of writers, by file, is in `tasks.md` sections 2 to 4.

## Goals / Non-Goals

- Goals: one path from any internal producer to storage, through JetStream, so that
  - both backends (CNPG, or the warehouse when enabled) see every event, log and signal;
  - warehouse loads are batched;
  - every event of a kind gets the same suppression, handler and rule treatment, whoever
    produced it.
- Goals: no event lost because NATS is briefly unavailable.
- Non-goals: moving current-state tables (`HealthEvent`, alerts, invocations) off CNPG;
  changing which northbound handlers or stateful rules exist; the warehouse-only write switch
  itself (`extend-starrocks-to-all-telemetry` 5.2), which this change unblocks.

## Decisions

### 1. `OcsfEventPublisher` is the only producer API for internal events

`ServiceRadar.Events.OcsfEventPublisher.publish(attrs, opts)` does five things, in order:

1. Builds the event from the same accepted field set as the retired `:record` action. It
   assigns `id` (UUID v4) and `time` when absent.
2. Applies `DeviceLifecycle.suppress_operational_event?/1`, returning `{:error, :suppressed}`.
3. Publishes the JSON event to `events.internal.<family>` with
   `ServiceRadar.NATS.JetStreamPublish`, waiting for the PubAck, with `Nats-Msg-Id` set to the
   event id.
4. Once the PubAck arrives, runs the northbound event handlers exactly as the after_action
   did (skipping handler-family and synthetic-liveness events).
5. Returns `{:ok, %OcsfEvent{}}`, a struct carrying the id and every field, so a caller that
   links the event (alerts, alert history, invocations) keeps its id.

`publish_many/2` does the same for a list, as one publish per event with up to 16 in flight,
for the batched writers (interface thresholds, endpoint inventory).

The event is sent with every field, explicit nulls included. `Processors.Events` fills
`log_name` and `raw_data` only when the key is absent, as it always did for external
producers, so an internal producer that sets `raw_data: nil` stores null.

The subject family (`alert`, `automation`, `camera`, `composite_check`, `credential`,
`integration`, `inventory`, `jobs`, `observability`) is a closed list compiled into the
publisher; an unknown family raises. Operator input never mints a subject. `events.internal.>` is
already inside the EVENTS stream (`events.>`) and core's NATS publish allow-list.

### 2. Northbound handlers run at the producer, after the PubAck

The handlers used to run after the row was committed. The PubAck is the new commit point: the
event is durable in JetStream and will be stored. Running the handlers there:

- keeps the at-most-once-per-produced-event semantics;
- does not depend on which telemetry backend stores the row, so it survives the
  warehouse-only switch unchanged;
- needs no claim table.

Running them in EventWriter instead would re-run them on redelivery, unless the processor
learned which rows were new. The processor cannot learn that once CNPG no longer stores
events.

### 3. NATS unavailable: a durable Oban fallback, not a drop

Every internal publish goes through `ServiceRadar.NATS.DurablePublish.publish/3` with a
message id. If the acknowledged publish fails, it enqueues `DurablePublishWorker`, whose args
are the subject, the encoded body, the message id and the post-publish action, all strings.
The job is stored in CNPG, unique on the message id, and retries with doubling backoff capped
at 30 minutes for up to 60 attempts, about 24 hours: the EVENTS stream's own retention. After
its own successful publish it runs the post-publish action, which for an OCSF event is its
northbound handlers. The caller gets `{:ok, event}` either way, because the event will be
delivered. The `health-events` requirement that internal health survives a NATS outage is met
by this job, not by a direct insert. The same path serves internal logs (`logs.internal.*`,
with a fresh message id per publish) and signals (`signals.analytics.*`, through
`SignalPublisher`).

Inside a database transaction (an Ash after_action hook, a processor's `Repo.transaction`)
`DurablePublish` does not publish at all: it only inserts the job, in the caller's
transaction. A rolled-back change is then never announced, and a committed one is published by
the worker. This is a transactional outbox, and it is what lets `k8s_nodes` and the credential
event writer publish from inside their transactions.

The Oban failure reporter does not report `DurablePublishWorker` failures as events: a publish
that keeps failing would otherwise report itself through the path that is failing.

Replays are idempotent at every step:

- the event id is the `Nats-Msg-Id`, so the stream deduplicates within its window;
- the CNPG insert is `on_conflict: :nothing` on `(id, time)`;
- warehouse tables are primary-key tables.

### 4. Stateful evaluation: synchronous, at least once, recorded in a ledger

Today evaluation is at most once, and it still double-counts:

- `Processors.Events` logs and ignores an evaluation failure.
- `LogPromotion` evaluates through an in-memory admission queue, which loses work on a crash.
- A redelivered batch is evaluated again, so its events count against a rule twice. The
  engine's `bucket_counts` have no event identity.
- The one producer that needed more, `k8s_nodes`, evaluated synchronously inside its snapshot
  transaction and rolled back on failure, to get at-least-once node alerts.

That guarantee becomes the rule for every event. `StatefulEvaluationLedger`, a CNPG table keyed
by event id, records which events the engine has evaluated. EventWriter, for each batch of
insert-only event rows it stores (`Processors.Events`, promotion in `Processors.Logs` and
`LogPromotionConsumer`, the Falco and Trivy processors, and the analytics-signal rows):

1. reads which of the batch's event ids the ledger has not recorded;
2. evaluates those events synchronously, and fails the batch if evaluation fails, so JetStream
   redelivers it;
3. records them in the ledger after evaluation succeeds.

A redelivery therefore evaluates exactly the events the failed delivery did not finish. Log
promotion's own alerts ride on the same step: they are raised only for the events evaluated
for the first time. The ledger hands the engine each id as UUID text, because the engine copies
source ids into alert metadata and cannot tell raw 16-byte ids that happen to be valid UTF-8
from text. Analytics-signal lifecycle transitions are the exception: they upsert under a stable
id, so they are evaluated directly and a failure is logged, since a recorded transition cannot
be detected again on redelivery. An
event is counted twice only if the process dies between evaluating and recording. The ledger is
control-plane bookkeeping, not telemetry. It needs no CNPG copy of the events, so it works
unchanged when the warehouse becomes the only event store. Rows older than three days are
pruned by a daily job: three days exceeds every path by which the same event id can arrive
again (stream retention of 24 hours, plus publish retries for up to 25 hours).

The in-memory `StatefulAlertEvaluationQueue` is removed. EventWriter is already the
asynchronous boundary, and JetStream is the durable buffer that absorbs bursts the queue
existed for. `k8s_nodes` publishes its transitions durably inside its snapshot transaction, so a
rolled-back snapshot also rolls back the publish's fallback job.

The engine already refuses its own output: `Record.skip_engine_event?/1` skips events with
`metadata.serviceradar.stateful_rule == true`, which every engine event sets, and the check
reads string keys, so it survives JSON. Now that EventWriter hands the engine every stored
event, its own included, `evaluate_events/1` drops those before fanning out to the shards
rather than sending each of them a batch they all skip; a shard that publishes an event and
has it evaluated in its own process (as the test publisher does) then never waits on itself. The seeded rule prefixes (`health.core.state_change`,
`sweep.device.availability`, `k8s.node.readiness`, `signals.analytics.*`, `falco.`) match no
engine output (`alert.*`). Every other internal event is now evaluated, as JetStream events
already were. Task 2.5 proves that no migrated family newly matches a seeded rule.
`interface_threshold_worker` drops its own synchronous `evaluate_events/1` call.

### 5. Broadcasts come from EventWriter, after storage

The only `Events.PubSub` subscriber is the Events tab LiveView. It ignores the payload and
re-queries after a debounce. Producers therefore stop broadcasting at all; the broadcast
`Processors.Events` already sends after the insert is the correct one, because the row
exists by then. That broadcast is suppressed when a batch stored nothing.

### 5a. Synthetic liveness events are never persisted

The anomaly liveness check drives the engine with synthetic input, and the fired alert's
event is then read back and destroyed with `discard_internal_probe`. That read treats "not
found" as success. Under asynchronous persistence the event would be written after the
cleanup and leak into customer views. The publisher therefore does not publish an event whose
`metadata.serviceradar.synthetic_liveness_check` is true. It returns the event in memory, so
the alert still links an id, and the check stops reading back and destroying an event.
`discard_internal_probe` is removed with `:record`.

### 6. Internal logs and signals, with deterministic ids

`InternalLogPublisher.publish/3` sends `logs.internal.<subject>` through `DurablePublish`,
instead of calling the logs processor in-process. Promotion of
internal logs to events (`health.core.state_change` and others) then runs inside EventWriter,
like every other log. The live-tail copy on `live.logs.internal.*` is unchanged. The
vulnerability-finding and IOC-exposure emitters publish their signal payloads to
`signals.analytics.<family>` through `SignalPublisher`. The sync log writer publishes its log
through `InternalLogPublisher` and its failure event through the publisher.

Routing internal logs through JetStream exposes them to redelivery, and `Processors.Logs`
assigns random ids today: a redelivered message stores its logs again and promotes them again,
creating duplicate events and duplicate promotion alerts. That is already true of every
external log. The logs processor therefore derives each row id as a UUIDv5 of the message
identity plus the record's index within the message. The message identity is the
`Nats-Msg-Id` when present, else the stream name and stream sequence. `LogPromotion` derives
each promoted event id from the log id and the rule id. A redelivery then stores and promotes
nothing new.

### 7. The direct write path is removed

Once the last producer is migrated, the `OcsfEvent` `:record` action, its hooks and
`discard_internal_probe` are deleted, and so is the `Log` `:create` action. Both resources are
read-only. The suppression and handler logic lives in the publisher. An `Ash.create` against
either resource fails at runtime for want of an action.

The rule itself is enforced by a custom Credo check,
`ServiceRadar.Credo.Check.Warning.DirectTelemetryWrite`, registered for core and web-ng. The
Elixir Quality lint runs `mix credo --strict` over the whole project for every PR or staging
push that touches it, so a violation anywhere in the project fails that check. Outside EventWriter, `LogPromotion` (whose only callers are the two JetStream log
consumers) and test files, it flags:

- an Ecto insert or an Ash create or seed whose target is `ocsf_events`, `logs`, `OcsfEvent`
  or `Log`, called or piped, with file aliases resolved;
- a `process_batch` call on an EventWriter processor;
- an EventWriter processor module used as a value, the form in which the in-process emitters
  were injected (`Keyword.get(opts, :processor, AnalyticsSignals)`).

A lint check reads the code as syntax, not as text, and runs where code is reviewed. Run over the pre-change versions of the migrated producers, it
flags every one of them.

## Risks / Trade-offs

- **Visibility latency.** An internal event appears after the EventWriter batch interval.
  The only synchronous reader of a just-created event was the anomaly liveness check, and
  decision 5a removes that read. `/events/<id>` links on a fresh alert can 404 for that
  interval.
- **More stateful evaluation.** Events that were never evaluated now are. Task 2.5 checks the
  seeded rules against the migrated event families before any producer moves.
- **Synchronous evaluation slows a batch.** A slow engine now holds an EventWriter batch.
  That is the backpressure the in-memory queue hid, and the queue dropped work when it was
  full. JetStream buffers the backlog; the consumer's 120-second ack_wait bounds a single
  evaluation.
- **JetStream publish latency on the producer path.** It is one request/reply per event. For
  the high-volume camera-analysis producer this is measured, and `publish_many/2` pipelines
  the publishes rather than awaiting each serially.

## Migration Plan

The work ships as one pull request. Its parts are interdependent: the ledger replaces the
evaluation queue that the migrated producers relied on, and the read-only resources and the
lint check are only true once every producer has moved. Rollout needs no data migration:

1. The ledger migration creates an empty table; the first batches evaluate everything, as
   before.
2. `platform.starrocks_pending_loads` is dropped; the migration refuses if it holds rows, so a
   deployment with an undrained mirror stops rather than losing it.
3. Events in flight during the rollout are either already stored (old pods) or published
   (new pods); both paths store through `on_conflict: :nothing` on the event id.

Rollback is a revert of the pull request, after which producers write directly again. The
ledger table is left in place (its down migration is a plain drop); the pending-loads drop is
irreversible by design and its down migration raises.
