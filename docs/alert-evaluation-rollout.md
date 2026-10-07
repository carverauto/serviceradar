# Durable alert evaluation rollout

This accompanies the `refactor-durable-alert-admission` implementation. Do not
activate an incomplete development checkpoint. PR BazelCI, the caller cutover,
and the owner recovery and load evidence must pass first.

The default `SERVICERADAR_ALERT_EVALUATION_MODE=prepared` rejects new durable
admission. It does not silently choose inline evaluation. `active` admits work;
`draining` rejects new admission while finishing accepted work. Invalid settings
fail release boot. The alerts Oban queue must be enabled and have a positive
worker limit on each evaluating core node.

1. Install the migrations and new consumer-capable image with admission prepared.
2. Retire every old inline evaluator, including disconnected pods. Check the
   complete deployment image cohort, not only connected BEAM peers. Do not route
   inputs to mixed old and new evaluation contracts.
3. Confirm all three evaluation tables, the rule-admission fence trigger, the
   bounded alerts worker queue, and the recovery cron. Connected evaluator peers
   must report the durable capability; legacy Horde registrations reject admission.
4. Set `SERVICERADAR_ALERT_EVALUATION_MODE=active` on the evaluating cohort.
   Observe accepted inputs, committed receipts, and persisted alert effects.
   Rejected upstream deliveries must remain eligible for retry.
5. Before rollback, set `draining` everywhere and stop upstream admission. Wait
   for the work table to empty and verify receipts and outbox work. Fence and
   stop consumers before changing to an older image. The migration refuses to
   drop an inbox that still contains accepted work; this is an additional guard,
   not proof that all application processes have stopped.

Admission bounds use `SERVICERADAR_ALERT_EVALUATION_` followed by
`ADMISSION_TIMEOUT_MS`, `BATCH_RECORDS`, `BATCH_WORK`, `PENDING_COUNT`,
`PENDING_BYTES`, `RULE_COUNT`, or `RULE_BYTES`. Every supplied value must be a
positive integer. Overload rejects an entire batch and never evicts accepted work.

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

Live mixed-version rollout, disconnected-owner retirement, drain and rollback
remain unverified until their deployment evidence is recorded. Unit success does
not substitute for those checks.

## Writer and caller boundaries

| Boundary | Runtime writers or callers | Durable behavior |
| --- | --- | --- |
| Rule inventory | `StatefulAlertRule` Ash/JSON API actions, `RuleSeeder`, `Plugins.AlertRuleCatalog`, `Inventory.MetricRuleSync`, Rules LiveView, event-to-rule creation, AshEvents replay | Database triggers cover row INSERT/UPDATE/DELETE and replay TRUNCATE. Admission captures one revision; disabling/deleting cancels unclaimed accepted input through the lane watermark. |
| Source acknowledgement | `StatefulEvaluationLedger` used by Events, Falco, Trivy and log promotion | The source marker records acceptance, not completed alert effects. Rejection returns to the source consumer; receipts deduplicate a replay after accepted work commits. |
| Stateful source transitions | `AnalyticsSignals` and `AnomalyEpisodeRegistry` | Episode and event transitions commit with their accepted evaluation. Distinct transitions may retain one event row ID; occurrence identities distinguish those transitions. |
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
