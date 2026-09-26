## 1. Publisher and EventWriter changes

- [x] 1.1 Add `ServiceRadar.Events.OcsfEventPublisher.publish/2`:
  - build the event from the `OcsfEvent` field set, assigning `id` and `time` when absent;
  - apply the out-of-service device suppression;
  - publish to `events.internal.<family>` with `JetStreamPublish` (awaiting the PubAck,
    `Nats-Msg-Id` = event id), using a closed family list, sending every field including
    explicit nulls;
  - run the northbound handlers after the PubAck (not for handler-family or synthetic events);
  - skip publishing synthetic-liveness events;
  - return `{:ok, %OcsfEvent{}}`.
  Every internal publish goes through `DurablePublish` (1.2).
- [x] 1.2 Add `DurablePublish` and `DurablePublishWorker` (Oban, durable fallback) for every
  internal publish: string args (subject, body, message id, post-publish action), unique on the
  message id, doubling backoff capped at 30 minutes for 60 attempts, and the post-publish action
  (an event's handlers) run after the worker's own successful publish. `DurablePublish` enqueues
  the worker when the publish fails, and only enqueues it, in the caller's transaction, when
  called inside one (transactional outbox). The Oban failure reporter does not report the
  worker's own failures as events.
- [x] 1.3 Add `StatefulEvaluationLedger`: an Ash resource on `platform.stateful_evaluation_ledger`
  keyed by event id, with a migration and a daily prune job for rows older than three days.
  `Processors.Events`, log promotion, the analytics-signal rows and the Falco and Trivy
  processors evaluate the events the ledger has not recorded, synchronously, fail the batch on
  an evaluation error, and record the events after success; the engine receives UUID text ids.
  Falco and Trivy mirror every promoted row to the warehouse, not only those their CNPG insert
  returned. The engine drops its own events before the shard fan-out. Remove
  `StatefulAlertEvaluationQueue` and its test substitute. `Processors.Events`
  skips the broadcast when nothing was stored.
- [x] 1.4 `Processors.Logs`: derive each log row id as a UUIDv5 of the message identity
  (`Nats-Msg-Id`, else stream name and sequence) and the record index. `LogPromotion` derives
  promoted event ids from the log id and the rule id. Redelivery stores, promotes and alerts
  nothing new.
- [x] 1.5 Tests:
  - the publisher: PubAck path, fallback path, suppression, handler dispatch after ack only,
    synthetic events not published;
  - durable publish: the outbox inside a transaction, the fallback on a failed publish;
  - the ledger: a redelivered batch evaluates only what the failed delivery did not, and an
    evaluation failure fails the batch;
  - logs: a redelivered message leaves exactly one set of logs and promoted events;
  - Falco and Trivy: an evaluation failure fails the batch, and redelivery evaluates once.

## 2. Low-risk producers

- [x] 2.1 Oban failure reporter (`observability/oban_failure_event_reporter.ex`, including the
  geolite worker call).
- [x] 2.2 Bumblebee catalog refresh (`inventory/bumblebee_catalog_refresh_event_writer.ex`).
- [x] 2.3 Camera relay health (`camera/relay_health_event_router.ex`), camera analysis results
  (`camera/analysis_result_ingestor.ex`), camera plugin events (`camera/event_ingestor.ex`).
- [x] 2.4 Sync log failures (`observability/sync_log_writer.ex`), MTR causal signal
  (`observability/mtr_causal_signal_emitter.ex`), Armis northbound run
  (`integrations/armis_northbound_runner.ex`), northbound handler events
  (`automation/northbound/event_handler_runner.ex`), composite-check verdicts
  (`composite_checks/verdict_event_writer.ex`), credential events
  (`credentials/credential_event_writer.ex`).
- [x] 2.5 Prove, against `RuleSeeder`'s event rules, that no migrated family starts matching a
  seeded rule it did not match before. The test enumerates the families' `log_name` values
  and names each producer whose `log_name` is operator-, plugin- or engine-defined.
- [x] 2.6 Remove every producer-side `Events.PubSub` broadcast and one-row
  `Destination.persist_after_cnpg` mirror in the migrated producers.

## 3. Producers that link the event id, and batched producers

- [x] 3.1 Stateful alert engine (`observability/stateful_alert_engine/alert_lifecycle.ex`):
  publish through the publisher and link the returned id and time into the alert and its
  history.
- [x] 3.2 Anomaly liveness check: drop the read-back and `discard_internal_probe` of the fired
  event (decision 5a). Its alert cleanup is unchanged.
- [x] 3.3 Analysis-worker alert router (`camera/analysis_worker_alert_router.ex`): link the
  returned id and time.
- [x] 3.4 Interface threshold worker: publish through the publisher; drop its synchronous
  `evaluate_events/1` and its `PendingLoads` mirror. `PendingLoads` had no other producer, so
  it is removed, and a migration drops `platform.starrocks_pending_loads`, refusing if rows
  remain.
- [x] 3.5 Endpoint inventory scan events and source-fact events: publish through the
  publisher, keeping their deterministic ids.
- [x] 3.6 `LogPromotion.insert_events` callers outside EventWriter (`SyncLogWriter`): publish
  the promoted events through the publisher instead of inserting.

## 4. Internal logs and signals

- [x] 4.1 `InternalLogPublisher.publish/3`: publish `logs.internal.<subject>` through
  `DurablePublish`, instead of calling `Processors.Logs` in-process. The live copy is
  unchanged.
- [x] 4.2 `EndpointVulnerabilityFindingEmitter` and `DeviceRiskIocExposure`: publish their
  signal payloads to `signals.analytics.<family>` through `SignalPublisher` instead of calling
  `Processors.AnalyticsSignals.process_batch/1` in-process.
- [x] 4.3 Tests: a health state change produces its promoted `health.core.state_change` event
  through EventWriter, and fires the seeded rule once.
- [x] 4.4 Endpoint inventory package change signals (`EndpointInventoryHistory`): publish
  through `SignalPublisher`, up to 16 awaiting acknowledgement at once, instead of a core NATS
  publish that dropped the signal on failure.

## 5. Remove the direct write path

- [x] 5.1 Delete the `OcsfEvent` `:record` action, its hooks and `discard_internal_probe`, and
  the `Log` `:create` action; both resources are read-only. Tests that created events or logs
  through those actions publish them or insert rows instead.
- [x] 5.2 Custom Credo check `DirectTelemetryWrite`, registered for core and web-ng: outside
  EventWriter, `LogPromotion` and test files, flag an insert, Ash create or seed of
  `ocsf_events`, `logs`, `OcsfEvent` or `Log`, a processor's `process_batch/1`, and a processor
  module used as a value. Its unit test runs it over sample sources; run over the pre-change
  producers it flags each of them.
- [ ] 5.3 Verify on a deployment, after the rollout completes: every internal event family
  appears in both CNPG and StarRocks for the same window, with equal counts per `log_name`.
