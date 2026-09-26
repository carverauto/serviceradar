# Change: Route internally produced events, logs and signals through JetStream

## Why

Every metric already travels through NATS JetStream and is persisted by EventWriter (the
JetStream-first rule in `AGENTS.md`). Internally produced OCSF events, internal logs and some
analytics signals do not. About fifteen code paths in core write `platform.ocsf_events`
directly: `Ash.create(OcsfEvent, :record)`, or `Repo.insert_all("ocsf_events", ...)`.
`InternalLogPublisher` also persists health, audit, job and onboarding logs by calling the
EventWriter logs processor in-process. Two emitters call the analytics-signal processor
in-process too.

That split has three measured consequences:

- **The warehouse is incomplete.** On the demo deployment, StarRocks is missing every event
  written by a producer that does not mirror to it. Over two days that was about 400 events:
  Oban job-failure events, the stateful alert engine's `alert.*` events, camera relay health
  and Bumblebee catalog refreshes. `events` therefore cannot be cut over to the warehouse
  without silently dropping these rows from the Events UI.
- **Loads are too small.** Producers that do mirror send one Stream Load per event
  (credential events, composite-check verdicts, endpoint inventory, source facts). Load sizing
  (issue #4516) cannot batch writes that never enter a batch.
- **Behaviour depends on the path.** The OCSF `:record` action suppresses events for
  out-of-service devices and runs northbound event handlers. The JetStream path does neither.
  The JetStream path runs stateful alert evaluation and warehouse mirroring, and most direct
  writers do neither. Two events of the same kind are treated differently according to who
  wrote them.

`extend-starrocks-to-all-telemetry` (task 5.2) will make EventWriter the only telemetry
writer when the warehouse is enabled. It cannot do that while producers bypass EventWriter.

## What Changes

- **One way to produce an internal OCSF event.** A core `OcsfEventPublisher`:
  - normalises the event, assigns its id and time, and applies the out-of-service device
    suppression;
  - publishes the event to JetStream under `events.internal.*`, waiting for the stream's PubAck;
  - runs the northbound event handlers once the stream has acknowledged the event;
  - returns the event (with its id) to the caller.

  EventWriter persists it (CNPG or the warehouse, per the active backend), mirrors it and
  evaluates stateful rules.
- **Durable when NATS is unavailable.** If the publish fails, the event is enqueued as an Oban
  job, which is stored in CNPG and retried until the publish succeeds. The event id is the
  `Nats-Msg-Id`, and the table primary key makes the stored row idempotent. No event is
  dropped because NATS was briefly down. A producer inside a database transaction only
  enqueues the job, in that transaction, so a change that rolls back is never announced.
- **Internal logs through JetStream.** `InternalLogPublisher` publishes to `logs.internal.*` on
  JetStream with the same fallback, instead of calling the logs processor in-process. Promotion
  of internal logs to events then happens in EventWriter, like every other log.
- **Analytics signals through JetStream.** The two emitters that call the analytics-signal
  processor in-process publish to `signals.analytics.*` instead.
- **Every direct writer migrates.** This covers every `Ash.create(OcsfEvent, :record)` and
  `Repo.insert_all("ocsf_events")` producer in core. Callers that need the event id get it from
  the publisher's return value.
- **The direct write path is removed.** **BREAKING:** the OCSF `:record` create action and
  its hooks, and the `Log` `:create` action, are removed; both resources are read-only. The
  only writer of `ocsf_events` and `logs` is then EventWriter, and a custom Credo check fails
  lint on any other module that inserts into either table, creates either resource, or calls
  an EventWriter processor in-process. `platform.starrocks_pending_loads`, whose only producer
  was the interface threshold worker's one-row mirror, is dropped.
- **Redelivery never duplicates.** EventWriter evaluates stateful rules at least once and
  records each evaluated event id in a CNPG ledger, so a redelivered batch evaluates only what
  the failed delivery did not, and an evaluation failure fails the batch instead of being
  logged and lost. The in-memory evaluation queue, which lost work on a crash, is removed. The
  logs processor derives log and promoted-event ids from the message identity, so a
  redelivered log message no longer stores, promotes or alerts twice. Today it does, for every
  log. The Falco and Trivy processors use the same ledger, and mirror every promoted row to the
  warehouse rather than only the rows their CNPG insert returned, which a redelivery never
  re-sent.
- **Consumers read persisted rows.** Producers stop broadcasting. The broadcast EventWriter
  sends after the insert is the only one, so the Events tab never re-queries before the row
  exists.
- **Liveness probes stay invisible.** The anomaly liveness check's synthetic events are never
  published. The check no longer reads back and destroys an event, a read that would race an
  asynchronous write and leak the probe into customer views.

## Impact

- Affected specs: `health-events` (MODIFIED: internal health OCSF events and logs go through
  JetStream; NATS is no longer external-only), `internal-telemetry-ingestion` (ADDED).
- Affected code:
  - `elixir/serviceradar_core`: the new publisher, `DurablePublish` and its Oban worker,
    `SignalPublisher`, `StatefulEvaluationLedger` (table, prune job); `InternalLogPublisher`;
    every direct `ocsf_events` writer; `EventWriter.Processors.Events`, `Logs`,
    `AnalyticsSignals`, `FalcoEvents`, `TrivyReports` and `LogPromotion`; the `OcsfEvent` and
    `Log` resources; the anomaly liveness check; the custom Credo check, registered for core
    and web-ng.
  - Migrations: create `platform.stateful_evaluation_ledger`; drop
    `platform.starrocks_pending_loads` (refusing if it holds rows).
  - Tests that created events through `:record` or logs through `:create`.
- Unblocks the `events` cutover and `extend-starrocks-to-all-telemetry` task 5.2.
- Operational: an internal event becomes visible after the EventWriter batch interval (seconds)
  rather than synchronously. JetStream must be available, or the Oban fallback holds events
  until it is.
