# Durable alert evaluation rollout

This accompanies the `refactor-durable-alert-admission` implementation. Do not
activate an incomplete development checkpoint. PR BazelCI, the caller cutover,
and the owner recovery and load evidence must pass first.

`prepared` does not evaluate alert rules: records are stored and the batch is
acknowledged, but no rule evaluates them and no alert effects are produced. A
periodic warning reports this in the core log, and web-ng shows "alert
evaluation is not activated" on the dashboard alerts card,
`/observability/alerts` and the alert rules settings page whenever the
coordinator's mode is not `active`. `active` admits work; `draining` rejects
new admission while finishing accepted work. Invalid settings fail release
boot. The alerts Oban queue must be enabled and have a positive worker limit
on each evaluating core node. With the environment variable unset, the process
still starts `prepared`. Helm resolves an empty `core.alertEvaluation.mode` at
render time; that contract is the `alertEvaluation` comment in
`helm/serviceradar/values.yaml`. The steps below are for a deployment that is
still `prepared`.

1. Install the migrations and new consumer-capable image with admission prepared.
2. Retire every old inline evaluator, including disconnected pods. Check the
   complete deployment image cohort, not only connected BEAM peers. Do not route
   inputs to mixed old and new evaluation contracts.
3. Confirm all three evaluation tables, the rule-admission fence trigger, the
   bounded alerts worker queue, and the recovery cron. Connected evaluator peers
   must report the durable capability; legacy Horde registrations reject admission.
4. Set `core.alertEvaluation.mode: active` in Helm values (or
   `SERVICERADAR_ALERT_EVALUATION_MODE=active` directly if you override via
   `core.extraEnv`) on the evaluating cohort. Helm passes the same value to
   web-ng, which uses it only as a fallback before it reaches the coordinator;
   an override in `core.extraEnv` also belongs in `webNg.extraEnv`.
   Observe accepted inputs, committed receipts, and persisted alert effects.
   Monitor rejected upstream deliveries against the bounded retry policy below.
5. Before rollback, set `draining` everywhere and stop upstream admission. Wait
   for the work table to empty and verify receipts and outbox work. Fence and
   stop consumers before changing to an older image. The migration refuses to
   drop an inbox that still contains accepted work; this is an additional guard,
   not proof that all application processes have stopped.

During a rolling restart, `:alert_evaluation_peer_not_ready` and
`{:overloaded, _}` defer the batch. AnalyticsSignals commits episode and event
transitions before admission, so a refusal leaves the transition stored and
retries the unadmitted evaluation. EventWriter delays NAKs for both reasons by
10, 20, 40, and 80 seconds on deliveries 1 through 4. Delivery 5 is the final
delivery: a failure there is dead-lettered and terminally acknowledged. With the
default `max_deliver: 5`, the delays before that last attempt total 150 seconds.
Recovery before then lets admission continue the remainder in order. After the
final delivery, the stored signal and the committed transition remain. A
lifecycle occurrence keeps its pending admission row. The next message for the
same series admits it, and so does `ServiceRadar.EventWriter.LifecycleAdmissionDrainWorker`,
which runs every minute on the `maintenance` queue. A run pages through the
pending series longest-waiting first, admits each in `seq` order up to its
first refusal, and continues with the next series, so series stuck behind a
saturated rule do not starve the rest. It stops after 1,000 admissions or 30
seconds. Other unadmitted
evaluation is lost. This is a
bounded recovery window, not an indefinite retry guarantee. Consumer delivery
limits are unchanged.

Readiness and overload deferrals log at info in AnalyticsSignals and the batch
pipeline, and at debug in the failed-message callback. Delayed acknowledgements retain the `nack` telemetry action. Other
failures, including draining, unavailable capability, and database errors,
retain error batch logs and immediate NAKs until the delivery limit, then a
terminal acknowledgement and an error log. The acknowledgement policy is
implemented in `ServiceRadar.EventWriter.Pipeline`; regression coverage is in
`pipeline_ack_test.exs` and `analytics_signals_process_batch_db_test.exs`
under `elixir/serviceradar_core/test/serviceradar/event_writer/` (the latter in
`processors/`).

Admission bounds use `SERVICERADAR_ALERT_EVALUATION_` followed by
`ADMISSION_TIMEOUT_MS`, `BATCH_RECORDS`, `BATCH_WORK`, `PENDING_COUNT`,
`PENDING_BYTES`, `RULE_COUNT`, or `RULE_BYTES`. Every supplied value must be a
positive integer. Overload commits the longest in-order prefix that fits and
returns an error so the pipeline retries the remainder. `BATCH_WORK` only caps
one admission transaction: a prefix cut by it continues in another transaction
within the same call, so it never costs a redelivery. The acceptance rules
are the durable admission requirement in
`openspec/changes/refactor-durable-alert-admission/specs/observability-signals/spec.md`.
Accepted work is never evicted. An occurrence larger than the byte budget is
skipped for evaluation, counted, and left stored. The skip commits a cancelled
receipt (reason `record_too_large`), so a redelivery counts it only once.

Set `SERVICERADAR_ALERT_EVALUATION_REPLAY_DAYS` to cover the longest supported
source redelivery and operator replay window. `SERVICERADAR_ALERT_EVALUATION_RECEIPT_DAYS`
must be at least that value; both default to seven days. Check custom stream
retention and operator replay procedures before activation. A JetStream message
duplicate window is not the replay horizon. Pending work has no destructive TTL.

Queue depth, bytes, oldest age, retries, failure counts, admission time and effect
time go through `metrics.ingestion_lanes` and EventWriter. Signal labels are fixed;
rule and source IDs are not labels. Queue health is a deployment-wide sample:
compare the latest sample or maximum across core resources, never sum repeated
global samples. A former sampling node's health gauges expire after two minutes.
PubAck-bound pending frames retain their original bytes and observation timestamp.
An absent fresh health sample is unknown health, not an empty queue.

Database failures during capability checks, health sampling, receipt pruning,
and recovery scans increment the `alert_maintenance` lane's `store_unavailable`
rejection counter and log one warning naming the caller. Each emits telemetry
under `[:serviceradar, :stateful_alert_engine, event]`, with `event` respectively
`:capability_query_failed`, `:sample_health_failed`, `:receipt_prune_failed`, or
`:recovery_failed`, and `caller` and `reason` metadata. A failed recovery scan
also increments the retry counter and returns an error for Oban retry, leaving
accepted work intact. Health-sampling and receipt-pruning failures do not stop
recovery wake-ups.

Live mixed-version rollout, disconnected-owner retirement, drain and rollback
remain unverified until their deployment evidence is recorded. Unit success does
not substitute for those checks.

## Writer and caller boundaries

| Boundary | Runtime writers or callers | Durable behavior |
| --- | --- | --- |
| Rule inventory | `StatefulAlertRule` Ash/JSON API actions, `RuleSeeder`, `Plugins.AlertRuleCatalog`, `Inventory.MetricRuleSync`, Rules LiveView, event-to-rule creation, AshEvents replay | Database triggers cover row INSERT/UPDATE/DELETE and replay TRUNCATE. Admission captures one revision; disabling/deleting cancels unclaimed accepted input through the lane watermark. |
| Source acknowledgement | `StatefulEvaluationLedger` used by Events, Falco, Trivy, log promotion, and metric alert admission (`EventWriter.Processors.Metrics`, after the timeseries insert, for points that match an enabled metric rule) | The source marker records acceptance, not completed alert effects. In prepared mode the batch is acknowledged as a skip: records are stored, nothing is evaluated or promoted, and JetStream does not redeliver. Draining and capability failures still fail the batch and return it to the source consumer; receipts deduplicate a replay after accepted work commits. Metric points use a deterministic id from their stored series identity for that replay check. |
| Stateful source transitions | `AnalyticsSignals` and `AnomalyEpisodeRegistry` | Episode and event transitions commit before evaluation admission. A later refusal retries the unadmitted evaluation and leaves the transition stored. Distinct transitions may retain one event row ID; occurrence identities distinguish those transitions. Occurrences of one series are admitted in that series' order. An unadmitted occurrence is a row in `platform.lifecycle_pending_admissions` holding an immutable snapshot of its evaluation input, never event metadata. A newer transition of the same event is stored and gets its own row behind the pending one; each is admitted from its snapshot in `seq` order, and its row is deleted in the admission transaction. A pending series never fails a message by itself. An occurrence id derives from the event id, its observed time before lifecycle pinning, its finding version and its status, so a redelivery reuses it and a finding that re-enters a state gets a new one. |
| Snapshot and rule history | `Owner`, `AlertLifecycle`, `StatefulAlertCleanupWorker` | The owner fence encloses restore, lifecycle changes, every changed snapshot and the receipt. Cleanup rechecks pending work and incident identity under the admission/owner boundaries. |
| Incident and notification control | `Monitoring.Alert`, `AlertGenerator`, `AlertLifecycle`, notification routing/continuation/scheduler workers, operator actions | Existing operator acknowledgement, suppression, escalation and resolution remain control-plane actions. Renotify continuation reacquires the rule fence and rechecks the alert/rule/cadence before enqueue and bookkeeping. |
| Completion-dependent callers | `ResolveStaleAnomaliesWorker`, `AnomalyAlertLivenessCheck` | Maintenance observes ordered receipts and returns actual resolved counts. Liveness observes persisted alert creation and resolution rather than treating acceptance as completion. |

This inventory includes raw SQL and table-level replay, rather than only named
Ash actions. It does not authorize dropping accepted work or a live rollout
without checking the complete evaluator cohort.

The source transition transaction defers the existing node-local, best-effort
rate-governor counter until commit. A rejected transaction does not consume the
retry's budget. Concurrent batches may briefly exceed that best-effort local
counter; it is not a deployment-wide quota and already resets on process restart.
