## ADDED Requirements

### Requirement: Alert lifecycle SHALL be the routing trigger for new incident notifications
`ServiceRadar.Observability.StatefulAlertEngine.AlertLifecycle` SHALL be the only
code path that emits a routing request for a NEW incident notification, and the
AshOban `:send_notifications` scheduler SHALL drive continuation work only. The
rule has two parts:

1. **New incident notification** - when an incident fires, is reopened, or
   resolves, `AlertLifecycle` SHALL emit exactly one routing request to the
   notification platform carrying the alert id, the lifecycle reason
   (`:fired | :reopened | :resolved`), and the `{rule_id, group_key}` incident
   identity. No other code path SHALL originate such a request.
2. **Continuation work** - escalation-step-due, retry-due, and renotify are
   continuations of an incident `AlertLifecycle` has already announced. They
   SHALL be driven by the `:send_notifications` scheduler against deliveries
   that already exist, carrying lifecycle reason `:renotify` or `:escalated`
   with the step number and the same `{rule_id, group_key}` identity. The
   scheduler SHALL NOT originate a first-notify routing request for an incident
   `AlertLifecycle` has not announced.

The full lifecycle reason vocabulary is therefore
`:fired | :renotify | :escalated | :reopened | :resolved`, shared by both parts.

Notification routing SHALL NOT be emitted from the
`ServiceRadar.Monitoring.OcsfEvent` `:record` after-action hook. That hook runs
synchronously on every recorded OCSF event with no batching and no backpressure
(`monitoring/ocsf_event.ex:96,132-146`), so notification dispatch placed there
would scale with raw event volume rather than with incident volume.

The lifecycle SHALL NOT call an outbound transport directly. In particular
`AlertLifecycle.send_renotify/4` SHALL NOT invoke
`ServiceRadar.Monitoring.WebhookNotifier.send_alert/1`
(`alert_lifecycle.ex:98-127`), which is unsupervised and returns
`{:error, :not_running}` for every call.

#### Scenario: Incident fires and emits exactly one routing request
- **GIVEN** a stateful alert rule whose threshold is crossed
- **WHEN** `AlertLifecycle.create_event_and_alert/4` creates the OCSF event and the alert
- **THEN** the lifecycle SHALL emit exactly one notification routing request for that alert with reason `:fired`
- **AND** the routing request SHALL carry the `{rule_id, group_key}` incident identity
- **AND** no notification routing request SHALL originate from the `Monitoring.OcsfEvent` `:record` after-action hook

#### Scenario: Recorded OCSF event that produces no alert produces no routing request
- **GIVEN** OCSF events are being recorded at high volume
- **WHEN** an event is recorded that does not fire a rule and does not create an alert
- **THEN** no notification routing request SHALL be emitted
- **AND** the `:record` after-action hook SHALL NOT perform outbound notification work

#### Scenario: Renotify continuation routes through the platform instead of the dead notifier
- **GIVEN** an active incident that has exceeded its `renotify_seconds` interval
- **WHEN** the `:send_notifications` scheduler drives the renotify continuation and `AlertLifecycle.send_renotify/4` runs
- **THEN** exactly one routing request with reason `:renotify` SHALL be emitted
- **AND** `WebhookNotifier.send_alert/1` SHALL NOT be called
- **AND** the alert notification counters SHALL NOT be incremented merely because the routing request was emitted

#### Scenario: Escalation continuation emits a routing request per escalation step
- **GIVEN** an unacknowledged alert bound to an escalation policy with three steps
- **WHEN** step two becomes due because its `delay_seconds` has elapsed since the alert fire time
- **THEN** the `:send_notifications` scheduler SHALL drive exactly one routing request with reason `:escalated` and the step number
- **AND** the routing request SHALL NOT re-request the channels already dispatched for step one

#### Scenario: Scheduler never originates a new incident notification
- **GIVEN** an alert for which `AlertLifecycle` has emitted no routing request
- **WHEN** the `:send_notifications` scheduler runs
- **THEN** the scheduler SHALL NOT originate a first-notify routing request for that incident
- **AND** the scheduler SHALL act only on escalation-step-due, retry-due, and renotify continuations of deliveries that already exist

#### Scenario: Resolution emits a routing request
- **GIVEN** an alert with at least one delivery in state `:sent`
- **WHEN** `AlertLifecycle.resolve_alert/4` transitions the alert to `:resolved`
- **THEN** the lifecycle SHALL emit exactly one routing request with reason `:resolved`
- **AND** the alert state transition and the routing request SHALL commit together, so a rolled-back resolve leaves no routing request behind

#### Scenario: Reopen emits a fresh routing request
- **GIVEN** a resolved alert
- **WHEN** the alert is reopened through the `:reopen` transition
- **THEN** the lifecycle SHALL emit exactly one routing request with reason `:reopened`
- **AND** the reopened alert SHALL be treated as a first-notify for cadence purposes

### Requirement: Alert lifecycle routing requests SHALL be idempotent
A routing request SHALL be keyed by `{alert_id, lifecycle_reason, step_number,
dedupe_key}` so that a retried lifecycle write, an Oban job retry, or a duplicate
JetStream delivery does not produce a second fan-out. Re-emitting the same key
SHALL be a no-op that returns success rather than creating additional
`NotificationDelivery` rows.

#### Scenario: Lifecycle write is retried after a transient database error
- **GIVEN** a lifecycle transition that emitted a routing request and then failed to commit an unrelated write
- **WHEN** the operation is retried and succeeds
- **THEN** exactly one routing request SHALL exist for that `{alert_id, lifecycle_reason, step_number, dedupe_key}`
- **AND** the retry SHALL NOT create duplicate `NotificationDelivery` rows

#### Scenario: Duplicate event burst does not multiply routing requests
- **GIVEN** an active incident inside its cooldown window as governed by `openspec/specs/observability-signals/spec.md`
- **WHEN** hundreds of duplicate matching events arrive and update the incident occurrence metadata
- **THEN** the lifecycle SHALL NOT emit a routing request per duplicate event
- **AND** occurrence metadata SHALL still be merged by `AlertLifecycle.merge_incident_metadata/5`

### Requirement: Alert state machine SHALL support a snooze transition
`ServiceRadar.Monitoring.Alert` SHALL add a `:snooze` transition to its
`AshStateMachine` block, which today declares only `acknowledge`, `resolve`,
`escalate`, `suppress`, and `reopen` (`alert.ex:96-103`). The transition SHALL
move an alert from `:pending`, `:acknowledged`, or `:escalated` into a new
`:snoozed` state and SHALL require a `snooze_until` argument that is strictly in
the future and within a configured maximum snooze duration.

Snooze SHALL NOT be recorded as acknowledgement: `acknowledged_at`,
`acknowledged_by`, and `acknowledged_by_user_id` SHALL remain unchanged, and the
alert SHALL NOT satisfy the `:if_unacknowledged` escalation step condition merely
because it is snoozed.

`:snoozed` SHALL be included in the actionable set, so the `read :active` filter,
the `is_actionable` calculation, and the `status_label` calculation SHALL treat a
snoozed alert as a live incident rather than hiding it. Transitions `resolve`,
`escalate`, `acknowledge`, and `suppress` SHALL be reachable from `:snoozed`.

Every snooze SHALL persist a `NotificationAcknowledgement` row with
`action: :snooze`, the `snooze_until` timestamp, the `source`
(`:ui | :api | :callback | :action_link`), and the `actor_kind`.

#### Scenario: Operator snoozes a firing alert for one hour
- **GIVEN** a `:pending` alert with an escalation policy attached
- **WHEN** an operator invokes snooze with `snooze_until` one hour in the future
- **THEN** the alert status SHALL become `:snoozed`
- **AND** a `NotificationAcknowledgement` row SHALL be written with `action: :snooze` and that `snooze_until`
- **AND** `acknowledged_at` and `acknowledged_by_user_id` SHALL remain unset

#### Scenario: Snooze with a past or over-long timestamp is rejected
- **WHEN** a snooze request supplies a `snooze_until` in the past, or beyond the configured maximum snooze duration
- **THEN** the transition SHALL be rejected with a validation error
- **AND** the alert status SHALL remain unchanged

#### Scenario: Snoozed alert remains visible as active
- **GIVEN** an alert in state `:snoozed`
- **WHEN** an operator lists active alerts or opens the alert detail page
- **THEN** the alert SHALL appear in the active list
- **AND** `is_actionable` SHALL evaluate true
- **AND** the UI SHALL show the remaining snooze window

#### Scenario: Snooze halts in-flight escalation without cancelling the incident
- **GIVEN** an alert at escalation step two with step three queued
- **WHEN** the alert is snoozed for thirty minutes
- **THEN** the queued step three deliveries SHALL be recorded as `:suppressed` with `suppression_reason: :snoozed` rather than silently dropped
- **AND** the escalation step counter SHALL be retained so escalation can resume from step three

#### Scenario: Resolving a snoozed alert wins
- **GIVEN** an alert in state `:snoozed`
- **WHEN** the underlying condition recovers and `AlertLifecycle.resolve_alert/4` runs
- **THEN** the alert SHALL transition to `:resolved` without an intermediate reopen
- **AND** a routing request with reason `:resolved` SHALL be emitted

### Requirement: Snooze expiry SHALL resume notification cadence
When `snooze_until` elapses, a bounded sweeper SHALL return the alert from
`:snoozed` to the status it held immediately before the snooze, and the
notification platform SHALL resume cadence for that incident. Escalation SHALL
resume at the step the alert had reached, with the remaining step delay measured
from the expiry instant; escalation SHALL NOT restart at step one and SHALL NOT
immediately fire every step whose original delay elapsed while snoozed.

Snooze expiry is the ONE sanctioned exception to measuring escalation
`delay_seconds` from the alert fire time. Outside a snooze, step delays SHALL
remain anchored to the alert fire time and SHALL NOT be re-anchored to any
previous step's dispatch.

If the alert resolved, was acknowledged, or was suppressed during the snooze
window, expiry SHALL be a no-op for that alert.

#### Scenario: Snooze expires while the condition is still active
- **GIVEN** an alert snoozed from `:escalated` at step two, with step three carrying a five-minute delay
- **WHEN** `snooze_until` elapses and the sweeper runs
- **THEN** the alert status SHALL return to `:escalated`
- **AND** step three SHALL become due five minutes after expiry, not immediately
- **AND** exactly one routing request SHALL be emitted when step three becomes due

#### Scenario: Snooze expires after the alert already resolved
- **GIVEN** an alert that was snoozed and then resolved before `snooze_until`
- **WHEN** the sweeper processes the expired snooze
- **THEN** the alert SHALL remain `:resolved`
- **AND** no routing request SHALL be emitted

#### Scenario: Backlogged escalation steps do not stampede on expiry
- **GIVEN** an alert snoozed for four hours whose policy has steps at t+5m, t+15m, and t+60m
- **WHEN** the snooze expires
- **THEN** the platform SHALL advance at most one escalation step per due evaluation
- **AND** the operator SHALL NOT receive one page per skipped step in a single burst

### Requirement: needs_notification SHALL be a delivery-driven selection
The `read :needs_notification` action on `ServiceRadar.Monitoring.Alert` SHALL be
generalised (`alert.ex:188-200`). Its current filter requires
`notification_count == 0`, so it selects each alert exactly once and can never
drive renotify, escalation, or retry. The generalised read SHALL select an alert
when any of the following holds:

1. **First-notify** - the alert is in an active status and has no
   `NotificationDelivery` row for its current incident identity.
2. **Renotify-due** - `now() - last_notification_at >= renotify_seconds` for the
   governing `StatefulAlertRule`.
3. **Escalation-step-due** - the next `NotificationEscalationStep`
   `delay_seconds` has elapsed and the step `condition` is satisfied.
   `delay_seconds` SHALL be measured from the ALERT FIRE TIME, never from the
   previous step's dispatch, so a slow or retried step one does not push step
   two later. The one sanctioned exception is snooze expiry: after a snooze
   expires, the remaining step delays are measured from the snooze expiry
   instant, as governed by "Snooze expiry SHALL resume notification cadence".
4. **Retry-due** - a `NotificationDelivery` for the alert is in state `:pending`
   with `next_attempt_at <= now()` and `attempt_count < max_attempts`, where
   `max_attempts` is the `NotificationChannel` attribute. A retry-eligible
   delivery stays `:pending` with `next_attempt_at` set; `:failed` is terminal
   and SHALL NOT be selected for retry-due.

The read SHALL retain keyset pagination and a bounded default limit, SHALL retain
the existing `(is_nil(suppressed_until) or suppressed_until < now())` guard, and
SHALL exclude alerts in `:snoozed` whose snooze window has not elapsed from
first-notify and renotify selection. The read SHALL NOT reference
`notification_count == 0` as a selection predicate.

An acknowledged alert SHALL NOT be selected for first-notify or
escalation-step-due; it MAY still be selected for retry-due, because a retry is a
transport concern for a delivery decision already taken.

Every dispatch decision that withholds a notification SHALL be recorded; there
SHALL be no silent drops. To bound growth, a repeat of an IDENTICAL decision
`{alert_id, policy_id, step_number, channel_id, dedupe_key, suppression_reason}`
SHALL collapse onto the existing `:suppressed` `NotificationDelivery` row by
incrementing that row's occurrence counter and refreshing its
`last_evaluated_at`, rather than inserting a duplicate row. A change of
`suppression_reason` SHALL be recorded as a new row.

#### Scenario: Alert already notified once is still selected for renotify
- **GIVEN** an alert with `notification_count == 1` whose rule sets `renotify_seconds` to 3600
- **WHEN** the `:send_notifications` scheduler runs more than an hour after `last_notification_at`
- **THEN** the alert SHALL be selected by `:needs_notification`
- **AND** selection SHALL NOT be blocked by the old `notification_count == 0` predicate

#### Scenario: Escalation step becomes due five minutes after the alert fired
- **GIVEN** an unacknowledged alert bound to a policy whose step two has `delay_seconds: 300`
- **WHEN** five minutes have elapsed since the alert fire time
- **THEN** the alert SHALL be selected with an escalation-step-due reason for step two
- **AND** the due time SHALL NOT be recomputed from when step one dispatched, so a step one that dispatched ninety seconds late does not delay step two

#### Scenario: Escalation step delay is not restarted by a retried earlier step
- **GIVEN** an unacknowledged alert whose step one delivery retried twice before reaching `:sent`
- **AND** a policy whose step two has `delay_seconds: 300`
- **WHEN** five minutes have elapsed since the alert fire time
- **THEN** step two SHALL be due
- **AND** the retries of step one SHALL NOT shift the step two due time

#### Scenario: Acknowledged alert is not selected for escalation
- **GIVEN** an acknowledged alert whose next escalation step has `condition: :if_unacknowledged` and whose delay has elapsed
- **WHEN** the scheduler runs
- **THEN** the alert SHALL NOT be selected for escalation-step-due
- **AND** a `NotificationDelivery` row SHALL be recorded as `:suppressed` with `suppression_reason: :acknowledged` for that step decision
- **AND** a later tick reaching the identical decision SHALL collapse onto that row rather than inserting a duplicate

#### Scenario: Retry-eligible pending delivery is selected for retry
- **GIVEN** a `NotificationDelivery` in state `:pending` with `attempt_count: 2`, `max_attempts: 5`, and `next_attempt_at` in the past
- **WHEN** the scheduler runs
- **THEN** the owning alert SHALL be selected with a retry-due reason
- **AND** the selection SHALL identify the specific delivery row to retry

#### Scenario: Failed delivery is terminal and never selected for retry
- **GIVEN** a `NotificationDelivery` in state `:failed`, whether because the failure was non-retryable or because `max_attempts` was exhausted
- **WHEN** the scheduler runs, including when `next_attempt_at` is in the past
- **THEN** that delivery SHALL NOT be selected for retry-due
- **AND** retry-due selection SHALL match only `:pending` rows with `next_attempt_at <= now()` and `attempt_count < max_attempts`

#### Scenario: Exhausted delivery is not reselected forever
- **GIVEN** a `NotificationDelivery` whose `attempt_count` has reached `max_attempts`
- **WHEN** the scheduler runs
- **THEN** that delivery SHALL NOT be selected for retry-due
- **AND** the delivery SHALL either fail over once to `fallback_channel_id` or move to the terminal `:failed` state

#### Scenario: Selection stays bounded under a large active-alert backlog
- **GIVEN** tens of thousands of active alerts
- **WHEN** the minute-cadence `:send_notifications` scheduler runs
- **THEN** `:needs_notification` SHALL return at most its configured page limit per run using keyset pagination
- **AND** the scan SHALL NOT load the full active-alert set into memory

#### Scenario: Repeated identical suppression decisions collapse onto the existing row
- **GIVEN** an alert that is selected on every scheduler tick but is suppressed for the same reason each time
- **WHEN** the platform evaluates suppression
- **THEN** the repeat of the identical decision `{alert_id, policy_id, step_number, channel_id, dedupe_key, suppression_reason}` SHALL update the existing `:suppressed` `NotificationDelivery` row, incrementing its occurrence counter and refreshing `last_evaluated_at`
- **AND** no duplicate `:suppressed` row SHALL be inserted for that identical decision
- **AND** the decision SHALL still be recorded rather than silently dropped
- **AND** a change of `suppression_reason` SHALL be recorded as a new row

### Requirement: send_notification SHALL enqueue routing rather than deliver inline
The `update :send_notification` action on `ServiceRadar.Monitoring.Alert` SHALL
be implemented to enqueue a notification routing request onto the declared
`:notifications` Oban queue (`alert.ex:298-319`) and SHALL NOT perform outbound
delivery inline. The action SHALL NOT open HTTP, SMTP, or agent-command
connections, and SHALL NOT block the AshOban trigger worker on a remote endpoint.

`notification_count` and `last_notification_at` SHALL be advanced only when a
`NotificationDelivery` reaches state `:sent`. They SHALL NOT be advanced merely
because routing was enqueued, and SHALL NOT be used as a proxy for delivery
success.

If enqueueing fails, the action SHALL return an error so Oban retries, and the
alert SHALL NOT be recorded as notified.

#### Scenario: Scheduler tick enqueues routing
- **GIVEN** an alert selected by `:needs_notification`
- **WHEN** the `:send_notifications` AshOban trigger invokes `:send_notification`
- **THEN** the action SHALL enqueue exactly one routing job on the `:notifications` queue
- **AND** the action SHALL return before any transport is contacted

#### Scenario: Slow provider does not stall the scheduler
- **GIVEN** a channel whose provider endpoint is timing out
- **WHEN** the `:send_notifications` trigger fires for one hundred alerts
- **THEN** the trigger workers SHALL complete without waiting on the provider
- **AND** the resulting per-delivery retry backoff SHALL be carried by the delivery worker, not by the trigger action

#### Scenario: Notification counters reflect delivery, not enqueue
- **GIVEN** an alert whose routing was enqueued and whose only delivery ends in `:failed`
- **WHEN** the operator inspects the alert
- **THEN** `notification_count` SHALL NOT have been incremented
- **AND** the `NotificationDelivery` row SHALL carry `error_class` and `error_message`

#### Scenario: Enqueue failure is retried
- **GIVEN** the Oban insert for a routing job fails
- **WHEN** `:send_notification` runs
- **THEN** the action SHALL return an error
- **AND** the alert SHALL remain selectable by `:needs_notification` on the next tick

### Requirement: Acknowledgement actor identity SHALL be a real foreign key for platform users
`ServiceRadar.Monitoring.Alert` SHALL add `acknowledged_by_user_id` as a nullable
foreign key to `ServiceRadar.Identity.User`, alongside the retained free-text
`acknowledged_by` column. The FK SHALL be populated when the acknowledging actor
is an authenticated platform user; the free-text column SHALL remain the record
for external principals such as a Slack user id or a PagerDuty responder.

Every acknowledgement SHALL write a `NotificationAcknowledgement` row whose
`actor_kind` is `:platform_user`, `:external_principal`, or `:system`, with
`actor_user_id` set only for `:platform_user` and `external_principal` set only
for `:external_principal`. The FK SHALL NOT be inferred from a free-text string,
and free-text input SHALL NOT be coerced into a user id.

Existing rows with only `acknowledged_by` populated SHALL remain valid; no
backfill SHALL be required and the FK SHALL be nullable.

#### Scenario: Platform user acknowledges from the alert detail page
- **GIVEN** an authenticated operator viewing a `:pending` alert
- **WHEN** the operator acknowledges it
- **THEN** `acknowledged_by_user_id` SHALL be set to that user's id
- **AND** `acknowledged_by` SHALL carry a human-readable identifier for display
- **AND** the `NotificationAcknowledgement` row SHALL record `actor_kind: :platform_user` and `source: :ui`

#### Scenario: External principal acknowledges from a signed action link
- **GIVEN** a notification delivered to Slack carrying a per-delivery capability token
- **WHEN** the recipient follows the Acknowledge link and the token verifies
- **THEN** the alert SHALL transition to `:acknowledged`
- **AND** `acknowledged_by_user_id` SHALL remain null
- **AND** the `NotificationAcknowledgement` row SHALL record `actor_kind: :external_principal`, the opaque `external_principal`, and `source: :action_link`

#### Scenario: System acknowledgement is distinguishable
- **GIVEN** an automated remediation flow that acknowledges an alert
- **WHEN** the acknowledgement is recorded
- **THEN** `actor_kind` SHALL be `:system`
- **AND** neither `actor_user_id` nor `external_principal` SHALL be required

#### Scenario: Free-text actor is never promoted to a foreign key
- **WHEN** an API caller supplies `acknowledged_by` as an arbitrary string that happens to match a user name
- **THEN** `acknowledged_by_user_id` SHALL remain null
- **AND** the system SHALL NOT resolve the string to a `ServiceRadar.Identity.User` record

#### Scenario: Legacy acknowledged alerts remain readable
- **GIVEN** alert rows acknowledged before this change, carrying only `acknowledged_by`
- **WHEN** the alert list and detail views render
- **THEN** the free-text actor SHALL still be displayed
- **AND** the missing foreign key SHALL NOT produce an error

### Requirement: Acknowledgement SHALL halt escalation and record the decision
Acknowledging an alert SHALL stop further escalation steps whose `condition` is
`:if_unacknowledged`. Steps that have not dispatched SHALL be recorded as
`NotificationDelivery` rows in state `:suppressed` with
`suppression_reason: :acknowledged`; they SHALL NOT be silently discarded, so an
operator can always answer why a later page did not arrive. A repeat of the
identical decision `{alert_id, policy_id, step_number, channel_id, dedupe_key,
suppression_reason}` SHALL collapse onto the existing row, incrementing its
occurrence counter and refreshing `last_evaluated_at`, rather than inserting a
duplicate.

Deliveries already in `:dispatching` at the moment of acknowledgement SHALL be
allowed to settle, and their outcome SHALL be recorded normally.

#### Scenario: Acknowledgement stops the next escalation step
- **GIVEN** an alert at step one with step two due in three minutes
- **WHEN** an operator acknowledges the alert
- **THEN** step two SHALL NOT dispatch
- **AND** a `:suppressed` delivery row with `suppression_reason: :acknowledged` SHALL exist for each channel in step two

#### Scenario: Always-condition steps still run after acknowledgement
- **GIVEN** an escalation step whose `condition` is `:always`
- **WHEN** the alert is acknowledged before that step becomes due
- **THEN** the step SHALL still dispatch
- **AND** the delivery rows SHALL NOT carry `suppression_reason: :acknowledged`

#### Scenario: In-flight delivery is not cancelled mid-transport
- **GIVEN** a delivery in state `:dispatching`
- **WHEN** the alert is acknowledged
- **THEN** the delivery SHALL be allowed to reach `:sent` or `:failed`
- **AND** its terminal state SHALL be recorded rather than rewritten to `:cancelled`

### Requirement: Alerts created outside the stateful engine SHALL be deduplicated and suppressed at the notification layer
Alerts created by paths that bypass the stateful alert engine SHALL still be
routed through `ServiceRadar.Notifications.Suppression` and through
notification-layer deduplication before any delivery is attempted. Two such
paths exist today and create alerts with no deduplication at all:
`LogPromotion.update_alert_counts/2` (`log_promotion.ex:711-717`) and
`TrivyReports.maybe_create_priority_alert/3` (`trivy_reports.ex:992`).

When such an alert carries no `{rule_id, group_key}` incident identity, the
platform SHALL derive a deterministic `dedupe_key` from the matching
`NotificationRoute` `dedupe_key_template`, or from a documented fallback over
stable alert fields when the route supplies no template. Alerts resolving to the
same `dedupe_key` inside the route `throttle_seconds` window SHALL produce one
notification and `:suppressed` delivery rows with
`suppression_reason: :throttled` for the rest.

Device-state suppression SHALL be re-checked here even though
`add-device-active-lifecycle` owns suppressing device-scoped alert generation,
because these paths bypass that gate.

#### Scenario: Trivy report floods alerts for one resource
- **GIVEN** a Trivy report that promotes two hundred high-severity findings for the same resource
- **WHEN** `maybe_create_priority_alert/3` creates alerts for each finding
- **THEN** the notification layer SHALL deliver one notification for the derived `dedupe_key`
- **AND** the remaining decisions SHALL be recorded as `:suppressed` with `suppression_reason: :throttled`
- **AND** no operator SHALL receive two hundred pages

#### Scenario: Log promotion alert for an out-of-service device
- **GIVEN** a device whose `is_active` is false
- **WHEN** `LogPromotion.update_alert_counts/2` creates an alert for that device
- **THEN** the notification layer SHALL record a `NotificationDelivery` in state `:suppressed` with `suppression_reason: :device_out_of_service`
- **AND** no transport SHALL be contacted
- **AND** the suppression SHALL be visible in the delivery log

#### Scenario: Bypass-path alert with no incident identity still gets a dedupe key
- **GIVEN** an alert created without a `rule_id` or `group_key`
- **WHEN** the platform routes it
- **THEN** a deterministic `dedupe_key` SHALL be derived from the route `dedupe_key_template` or the documented fallback
- **AND** two identical alerts from the same bypass path SHALL resolve to the same `dedupe_key`

#### Scenario: Active silence covers a bypass-path alert
- **GIVEN** an active `NotificationSilence` whose matchers match a Trivy-derived alert
- **WHEN** routing is evaluated
- **THEN** the delivery SHALL be recorded as `:suppressed` with `suppression_reason: :silence`
- **AND** the silence SHALL apply regardless of which code path created the alert

### Requirement: Resolution notifications SHALL close the loop on firing channels
When an alert resolves, the platform SHALL send a resolution notification to
every channel that received a `NotificationDelivery` in state `:sent` for that
incident, unless the governing `NotificationEscalationPolicy` sets
`resolve_notifies` to false. Channels whose firing delivery ended in
`:suppressed`, `:cancelled`, `:skipped`, or `:failed` SHALL NOT receive a
resolution notification, so a resolution is never the first thing an operator
hears about an incident.

Resolution notifications SHALL be correlated to the firing notification through
`external_correlation_id`. For a provider whose `capabilities` include
`:resolve_update`, the platform SHALL use the stored correlation id to update the
original message in place rather than posting an unlinked new one; where in-place
update is unsupported, the resolution SHALL still carry the correlation id in the
payload.

Resolution SHALL cancel any queued escalation steps for that alert, recording
those deliveries as `:cancelled`.

Because `Jobs.AlertsRetentionWorker` hard-deletes resolved alerts after a default
of three days, the resolution delivery SHALL carry its own `alert_snapshot` and
SHALL remain readable after the alert row is gone.

#### Scenario: Alert resolves after two escalation steps fired
- **GIVEN** an alert whose step one delivered to Slack and email, and whose step two delivered to PagerDuty, all in state `:sent`
- **WHEN** the alert resolves
- **THEN** Slack, email, and PagerDuty SHALL each receive one resolution notification
- **AND** each resolution delivery SHALL carry the `external_correlation_id` of the corresponding firing delivery

#### Scenario: Policy disables resolution notifications
- **GIVEN** an escalation policy with `resolve_notifies: false`
- **WHEN** the alert resolves
- **THEN** no resolution notification SHALL be sent
- **AND** any queued escalation step deliveries SHALL still be recorded as `:cancelled`

#### Scenario: Suppressed channel receives no resolution
- **GIVEN** a channel whose only delivery for the incident was `:suppressed` with `suppression_reason: :schedule`
- **WHEN** the alert resolves
- **THEN** that channel SHALL NOT receive a resolution notification

#### Scenario: Provider supporting resolve_update closes the original message
- **GIVEN** a Slack channel whose firing delivery stored the message `ts` as `external_correlation_id`
- **AND** the provider `capabilities` include `:resolve_update`
- **WHEN** the alert resolves
- **THEN** the platform SHALL update the original Slack message using the stored correlation id
- **AND** the resolution delivery row SHALL reference the same `external_correlation_id`

#### Scenario: Resolution delivery outlives the alert
- **GIVEN** a resolved alert deleted by `Jobs.AlertsRetentionWorker` after three days
- **WHEN** an operator opens the delivery log
- **THEN** the resolution delivery row SHALL still render its `alert_snapshot`
- **AND** the missing alert row SHALL NOT produce an error

## MODIFIED Requirements

### Requirement: Rule builder SHALL expose incident grouping and suppression controls
The system SHALL allow operators to configure event-derived alert incident behavior through the rules UI using grouping, cooldown, and renotify controls.

The notification platform SHALL consume these values rather than author a second
cadence scheme. Specifically, notification cadence SHALL be driven by the
`StatefulAlertRule` `cooldown_seconds` and `renotify_seconds` fields and by the
composite `{rule_id, group_key}` incident identity, where `group_key` is the
`"field=value|field=value"` string derived from `StatefulAlertRule.group_by` and
made unique by `stateful_alert_rule_states_unique_state_index`. The platform
SHALL NOT introduce a parallel per-alert cooldown or renotify setting that can
disagree with the rule. A `NotificationRoute` MAY narrow cadence further through
`throttle_seconds`, `group_wait_seconds`, and `group_interval_seconds`, and MAY
override the grouping key through `dedupe_key_template` only for alerts the rule
grouping does not cover; a route SHALL NOT widen cadence beyond the rule.

Cadence precedence SHALL be enforced at save time. `StatefulAlertRule`
`renotify_seconds` is the floor. `NotificationEscalationPolicy`
`repeat_interval_seconds` may only make repeats LESS frequent, so it SHALL be
greater than or equal to the `renotify_seconds` of the rules whose incidents the
policy governs. A configuration that violates this SHALL be rejected at save time
with an actionable validation error naming the rule floor, rather than being
accepted and silently clamped at dispatch time.

Cooldown and renotify semantics themselves remain owned by
`openspec/specs/observability-signals/spec.md`; this capability governs only how
the rule builder exposes them and how the notification platform consumes them.

#### Scenario: Operator edits grouping keys for a security alert policy
- **GIVEN** an operator is configuring an event-derived alert policy in the rules UI
- **WHEN** the operator sets incident grouping keys for the policy
- **THEN** the saved policy SHALL persist those grouping keys
- **AND** subsequent matching events SHALL use those keys when deciding whether to create a new incident or update an existing one

#### Scenario: Operator changes cooldown and renotify behavior
- **GIVEN** an operator is configuring an event-derived alert policy in the rules UI
- **WHEN** the operator updates `cooldown_seconds` or `renotify_seconds`
- **THEN** the saved policy SHALL persist those values
- **AND** notification suppression and repeat notification behavior SHALL follow the configured values

#### Scenario: Notification cadence follows the rule, not a second scheme
- **GIVEN** a rule with `cooldown_seconds: 900` and `renotify_seconds: 21600`
- **WHEN** the notification platform decides whether to notify for that incident
- **THEN** it SHALL evaluate cadence against those rule values and the `{rule_id, group_key}` incident identity
- **AND** it SHALL NOT apply a separately configured per-alert cooldown or renotify value

#### Scenario: Grouping key change takes effect for new incidents
- **GIVEN** an active incident grouped by the previous `group_by` keys
- **WHEN** an operator changes the grouping keys and a matching event arrives
- **THEN** the existing incident SHALL retain its original `group_key` and its in-flight notification cadence
- **AND** the next incident created after the change SHALL use the new `group_key` for both grouping and notification deduplication

#### Scenario: Route narrows but does not widen cadence
- **GIVEN** a rule with `renotify_seconds: 3600` and a matching route with `throttle_seconds: 7200`
- **WHEN** the incident remains active for three hours
- **THEN** the effective repeat interval SHALL be the more restrictive of the two
- **AND** a route configured with a shorter interval than the rule SHALL NOT cause more frequent notification than the rule allows

#### Scenario: Policy repeat interval below the rule floor is rejected at save time
- **GIVEN** a rule with `renotify_seconds: 3600`
- **WHEN** an operator saves a `NotificationEscalationPolicy` with `repeat_interval_seconds: 900` governing incidents from that rule
- **THEN** the save SHALL be rejected with a validation error naming the rule `renotify_seconds` floor
- **AND** the policy SHALL NOT be persisted with a repeat interval more frequent than the rule allows

#### Scenario: Policy repeat interval at or above the rule floor is accepted
- **GIVEN** a rule with `renotify_seconds: 3600`
- **WHEN** an operator saves a policy with `repeat_interval_seconds: 7200` governing incidents from that rule
- **THEN** the save SHALL succeed
- **AND** the effective repeat cadence SHALL be the policy value, because it repeats less frequently than the rule floor
