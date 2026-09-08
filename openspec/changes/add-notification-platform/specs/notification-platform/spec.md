## ADDED Requirements

### Requirement: Notification decision engine ownership and boundary

The system SHALL implement the notification decision engine as a
`ServiceRadar.Notifications` Ash domain inside `serviceradar_core`, colocated with
`ServiceRadar.Monitoring.Alert`. The decision engine owns deduplication, routing,
fan-out, escalation, suppression, delivery tracking, and acknowledgement closure.

The decision engine SHALL NOT be pluggable. No plugin, uploaded provider
definition, Wasm module, or agent-side code SHALL be able to alter a routing,
suppression, escalation, deduplication, or acknowledgement decision. The only
extensible boundary is the transport, expressed as the
`ServiceRadar.Notifications.Transport` behaviour.

Routing, escalation, deduplication, suppression, and acknowledgement SHALL be
implemented without reference to a channel's `provider_type`. A change of
`provider_type` on a channel SHALL NOT change any decision the engine makes.

Notification dispatch SHALL NOT execute on the `Monitoring.OcsfEvent` `:record`
after-action hook path used by `ActionEventHandler`.

Dispatch triggering SHALL follow a two-part rule:

- `ServiceRadar.Observability.StatefulAlertEngine.AlertLifecycle` SHALL be the only path that emits a
  routing request for a NEW incident notification. No other code path SHALL
  originate the first routing decision for an incident.
- The AshOban scheduler SHALL drive CONTINUATION work only - escalation-step-due,
  retry-due, and renotify - against `NotificationDelivery` rows that already
  exist. It SHALL NOT originate a routing request for an incident that has no
  prior routing decision.

#### Scenario: Provider tier does not influence routing

- **GIVEN** two channels bound to the same route and escalation step
- **AND** one channel uses a `:native` provider and the other uses a `:declarative` provider
- **WHEN** an alert matches the route
- **THEN** the engine SHALL produce the same routing, dedupe, suppression, and escalation decisions for both channels
- **AND** the decisions SHALL differ only in the transport invoked

#### Scenario: Plugin code cannot change a decision

- **GIVEN** a `:wasm_plugin` provider returns a result payload asserting that delivery should be suppressed or escalated
- **WHEN** the transport result is processed
- **THEN** the engine SHALL record only the transport outcome on the `NotificationDelivery` row
- **AND** it SHALL NOT alter routing, suppression, escalation, or acknowledgement state based on transport-supplied content

#### Scenario: Dispatch is not on the OCSF record path

- **WHEN** an OCSF event is recorded
- **THEN** the `:record` after-action hook SHALL NOT perform notification routing or dispatch
- **AND** notification work SHALL be enqueued from the alert lifecycle instead

#### Scenario: New-incident routing originates only in AlertLifecycle

- **GIVEN** an incident with no prior routing decision and no `NotificationDelivery` rows
- **WHEN** the AshOban notification scheduler runs
- **THEN** it SHALL NOT emit a routing request for that incident
- **AND** the first routing request SHALL be emitted only by `AlertLifecycle`

#### Scenario: Scheduler drives continuation work

- **GIVEN** an incident with existing `NotificationDelivery` rows and an escalation step due
- **WHEN** the AshOban notification scheduler runs
- **THEN** it SHALL advance the escalation-step-due, retry-due, and renotify work for those deliveries
- **AND** it SHALL NOT re-evaluate route matching as though the incident were new

### Requirement: Notification channel registry

The system SHALL provide a `NotificationChannel` resource representing a
configured instance of a provider, with at minimum the attributes `name`,
`provider_id`, `enabled`, `config`, `secret_refs`, `execution_route`,
`agent_uid`, `partition_id`, `fallback_channel_id`, `fail_closed`,
`max_attempts`, `rate_limit_per_minute`, `health`, `last_success_at`,
`last_failure_at`, and `last_error`.

`max_attempts` SHALL be an attribute of `NotificationChannel`. The channel's
provider SHALL supply the default value applied when the operator does not set
one, and the effective retry bound used at dispatch time SHALL be the channel's
`max_attempts`. There SHALL NOT be a second, separately authoritative attempt
bound elsewhere in the platform.

Channels SHALL live in the `platform` schema with a `uuid_generate_v7()` primary
key and SHALL be created by an Elixir migration under
`elixir/serviceradar_core/priv/repo/migrations/`.

A channel whose `enabled` is false, or whose provider is not in the `:active`
state, SHALL NOT be dispatched to. Any notification routed to such a channel
SHALL be recorded as suppressed with reason `:channel_disabled`.

`partition_id` on a channel SHALL be force-bound server-side from the
mTLS-derived context and SHALL NOT be accepted from operator input.

#### Scenario: Disabled channel is recorded, not skipped silently

- **GIVEN** an escalation step referencing a channel with `enabled == false`
- **WHEN** the step fires
- **THEN** the system SHALL write a `NotificationDelivery` row with `state: :suppressed`
- **AND** `suppression_reason` SHALL be `:channel_disabled`

#### Scenario: Provider deactivation disables its channels

- **GIVEN** a provider transitions from `:active` to `:disabled`
- **WHEN** a notification routes to a channel bound to that provider
- **THEN** the delivery SHALL be recorded as `:suppressed` with reason `:channel_disabled`

#### Scenario: Operator-supplied partition is rejected

- **WHEN** a channel create or update request supplies `partition_id`
- **THEN** the system SHALL ignore the supplied value and bind `partition_id` from the server-side mTLS-derived context

#### Scenario: Channel max_attempts defaults from the provider

- **GIVEN** a provider declaring a default attempt bound
- **WHEN** an operator creates a channel without setting `max_attempts`
- **THEN** the channel `max_attempts` SHALL be populated from the provider default
- **AND** an operator-supplied `max_attempts` SHALL override that default for that channel only

### Requirement: Channel configuration validation against the provider config schema

The system SHALL validate a channel's `config` against the JSON Schema subset
declared in its provider's `config_schema` using `Plugins.ConfigSchema`, on every
create and update, and SHALL reject a channel whose config does not validate.

Configuration values that reference secrets SHALL be expressed as `secret_refs`
using `Plugins.SecretRefs` and resolved at dispatch time through
`ServiceRadar.Credentials.SecretBroker`. Secret material SHALL NOT be stored in
`config`, SHALL NOT be persisted in a `NotificationDelivery` row, and SHALL NOT be
resolved by calling `Vault.decrypt!` directly.

Any operator-supplied outbound URL used on the `:control_plane` execution route
SHALL pass `Palisade.OutboundURLPolicy.validate_https_public_url/2` before a
request is issued. A URL that fails the policy SHALL cause the delivery to be
recorded as `:failed` with an `error_class` identifying the policy rejection, and
SHALL NOT result in an outbound request.

#### Scenario: Config failing the provider schema is rejected

- **WHEN** an operator saves a channel whose `config` omits a field required by the provider `config_schema`
- **THEN** the system SHALL reject the change with a validation error naming the offending field
- **AND** no channel row SHALL be created or updated

#### Scenario: Secrets resolve through the broker at dispatch

- **GIVEN** a channel with a `secret_refs` entry for its API token
- **WHEN** a delivery is dispatched
- **THEN** the system SHALL resolve the reference through `Credentials.SecretBroker`
- **AND** the resolved value SHALL NOT appear in `config`, `rendered_payload_digest`, `result_summary`, `error_message`, or any log line

#### Scenario: Non-public control-plane URL is refused

- **GIVEN** a `:control_plane` channel configured with an `http://10.0.0.5/hook` endpoint
- **WHEN** dispatch is attempted
- **THEN** `Palisade.OutboundURLPolicy.validate_https_public_url/2` SHALL reject the URL
- **AND** the delivery SHALL be recorded as `:failed` with no outbound request issued

### Requirement: Channel health state tracking

The system SHALL maintain `health`, `last_success_at`, `last_failure_at`, and
`last_error` on each `NotificationChannel`, updated from terminal delivery
outcomes. `last_error` SHALL be redacted content only.

Channel health SHALL be advisory. It SHALL NOT by itself suppress dispatch; only
`enabled`, provider state, and the enumerated suppression reasons do that.

#### Scenario: Successful delivery updates health

- **WHEN** a delivery to a channel reaches `state: :sent`
- **THEN** the channel `last_success_at` SHALL be set to the delivery `finished_at`
- **AND** `health` SHALL reflect a healthy state

#### Scenario: Unhealthy channel is still attempted

- **GIVEN** a channel whose `health` is unhealthy but whose `enabled` is true
- **WHEN** an alert routes to it
- **THEN** the system SHALL still attempt dispatch
- **AND** it SHALL NOT record a suppression for health alone

### Requirement: Notification routing rules

The system SHALL provide a `NotificationRoute` resource with at minimum `name`,
`enabled`, `priority`, `match_expression`, `escalation_policy_id`,
`dedupe_key_template`, `throttle_seconds`, `group_wait_seconds`,
`group_interval_seconds`, `schedule_id`, and `continue`, versioned with
AshPaperTrail.

Routes SHALL be evaluated in ascending `priority` order. `match_expression` SHALL
be a predicate over alert attributes and alert metadata, evaluated without
executing operator-supplied code.

`continue` SHALL carry Alertmanager semantics: when `continue` is false on a
matching route, evaluation SHALL stop at that route; when true, evaluation SHALL
proceed to the next route in priority order.

An alert matching no enabled route SHALL be recorded as a `NotificationDelivery`
row with `state: :suppressed` and `suppression_reason: :no_matching_route`, so
that an unrouted alert is queryable through the same audit path as every other
withheld dispatch, and SHALL NOT be silently discarded.

#### Scenario: First matching route wins when continue is false

- **GIVEN** routes A (priority 10, `continue: false`) and B (priority 20) that both match an alert
- **WHEN** routing is evaluated
- **THEN** only route A's escalation policy SHALL be engaged
- **AND** route B SHALL NOT produce deliveries for that alert

#### Scenario: Continue fans routing to later routes

- **GIVEN** routes A (priority 10, `continue: true`) and B (priority 20) that both match an alert
- **WHEN** routing is evaluated
- **THEN** both route A and route B escalation policies SHALL be engaged
- **AND** each SHALL produce its own `NotificationDelivery` rows

#### Scenario: Unrouted alert is observable

- **GIVEN** an alert that matches no enabled route
- **WHEN** routing completes
- **THEN** the system SHALL write a `NotificationDelivery` row with `state: :suppressed` and `suppression_reason: :no_matching_route`
- **AND** an operator SHALL be able to query it from the delivery log alongside every other suppression reason

### Requirement: Route grouping, throttling, and dedupe key override

A route SHALL support `group_wait_seconds` (delay before the first notification
for a new group, allowing sibling alerts to join) and `group_interval_seconds`
(minimum interval between notifications for an already-notified group).

A route SHALL support `throttle_seconds`, which bounds how frequently the route
may produce a dispatch for the same dedupe key. A dispatch withheld by
`throttle_seconds` SHALL be recorded as suppressed with reason `:throttled`.

A route MAY supply `dedupe_key_template`. When present, it SHALL override the
default dedupe key derived from the incident identity for deliveries produced by
that route. When absent, the default incident identity SHALL be used.

#### Scenario: Group wait batches sibling alerts

- **GIVEN** a route with `group_wait_seconds: 30`
- **WHEN** a new group receives its first matching alert
- **THEN** the first dispatch SHALL be delayed by up to 30 seconds
- **AND** alerts joining the same group during that window SHALL be included in the same notification

#### Scenario: Throttled dispatch is recorded

- **GIVEN** a route with `throttle_seconds: 300` that dispatched for dedupe key `K` 60 seconds ago
- **WHEN** another dispatch for `K` is due
- **THEN** the system SHALL write a `NotificationDelivery` row with `state: :suppressed` and `suppression_reason: :throttled`

#### Scenario: Route dedupe template overrides the default identity

- **GIVEN** a route with a `dedupe_key_template` referencing a whitelisted alert attribute path
- **WHEN** a delivery is created for that route
- **THEN** `dedupe_key` SHALL be rendered from the template
- **AND** deliveries from other routes for the same alert SHALL retain the default incident-identity dedupe key

### Requirement: Escalation policies and ordered steps

The system SHALL provide a `NotificationEscalationPolicy` resource with `name`,
`repeat_count`, `repeat_interval_seconds`, and `resolve_notifies`, and a
`NotificationEscalationStep` resource with `step_number`, `delay_seconds`,
`channel_ids`, and `condition`.

Steps SHALL be ordered by `step_number`. `delay_seconds` SHALL be measured from
the alert fire time, never from the dispatch or completion of the previous step.

There SHALL be exactly one exception to that origin: after an alert's snooze
expires, the delays of the remaining steps SHALL be measured from the snooze
expiry instant rather than from the alert fire time. No other event SHALL rebase
the delay origin.

`condition` SHALL be one of `:always` or `:if_unacknowledged`. A step whose
`condition` is `:if_unacknowledged` SHALL NOT fire while the alert is
acknowledged; the withheld dispatch SHALL be recorded as suppressed with reason
`:acknowledged`.

When `repeat_count` is greater than zero, the policy SHALL repeat its steps up to
`repeat_count` additional times at `repeat_interval_seconds`, and SHALL stop
repeating when the alert is acknowledged or resolved.

`StatefulAlertRule.renotify_seconds` SHALL be the cadence floor.
`NotificationEscalationPolicy.repeat_interval_seconds` MAY only make repeats
LESS frequent, so it SHALL be greater than or equal to the `renotify_seconds` of
the rules that reach it. A policy configuration whose `repeat_interval_seconds`
is smaller than that floor SHALL be rejected at save time with a validation
error, not silently clamped at dispatch time. A route SHALL only narrow rule
cadence, never widen it.

When `resolve_notifies` is true, the policy SHALL emit a resolution notification
to the channels already notified for that alert when the alert resolves.

#### Scenario: Step delay is measured from alert fire time

- **GIVEN** a policy with step 1 at `delay_seconds: 0` and step 2 at `delay_seconds: 300`
- **AND** step 1 dispatch completed 240 seconds after the alert fired
- **WHEN** step 2 becomes due
- **THEN** step 2 SHALL fire at 300 seconds after the alert fire time, not at 540 seconds

#### Scenario: Snooze expiry rebases remaining step delays

- **GIVEN** a policy with step 2 at `delay_seconds: 300` and step 3 at `delay_seconds: 900`
- **AND** the alert was snoozed and its `snooze_until` elapses at t+2000 seconds after the alert fire time
- **WHEN** the remaining steps are scheduled
- **THEN** step 2 SHALL become due 300 seconds after the snooze expiry instant
- **AND** step 3 SHALL become due 900 seconds after the snooze expiry instant

#### Scenario: Repeat interval below the rule renotify floor is rejected

- **GIVEN** a rule with `renotify_seconds: 21600` routed to a policy
- **WHEN** an operator saves that policy with `repeat_interval_seconds: 900`
- **THEN** the save SHALL be rejected with a validation error naming the floor
- **AND** the platform SHALL NOT accept the value and clamp it later at dispatch time

#### Scenario: Acknowledged alert halts an if_unacknowledged step

- **GIVEN** a policy step with `condition: :if_unacknowledged`
- **AND** the alert was acknowledged before the step delay elapsed
- **WHEN** the step becomes due
- **THEN** the system SHALL write a `NotificationDelivery` row with `state: :suppressed` and `suppression_reason: :acknowledged`
- **AND** no transport SHALL be invoked

#### Scenario: Always step fires despite acknowledgement

- **GIVEN** a policy step with `condition: :always`
- **AND** the alert has been acknowledged
- **WHEN** the step becomes due
- **THEN** the system SHALL dispatch to the step channels

#### Scenario: Repeat stops on acknowledgement

- **GIVEN** a policy with `repeat_count: 3` and `repeat_interval_seconds: 900`
- **WHEN** the alert is acknowledged after the first repeat
- **THEN** the system SHALL NOT begin further repeats

#### Scenario: Resolution notification reaches previously notified channels

- **GIVEN** a policy with `resolve_notifies: true` whose alert was notified to channels A and B
- **WHEN** the alert resolves
- **THEN** the system SHALL dispatch a resolution notification to channels A and B
- **AND** it SHALL NOT dispatch a resolution notification to channels that were never notified for that alert

### Requirement: Escalation step fan-out to a channel set

An escalation step SHALL hold a set of channels, and firing that step SHALL
produce one `NotificationDelivery` row per channel in the set. Fan-out SHALL be
orthogonal to retry, failover, and escalation.

A failure on one channel in a fan-out set SHALL NOT prevent, cancel, or delay
dispatch to the other channels in the same set.

#### Scenario: One step fans out to multiple channels

- **GIVEN** step 1 with `channel_ids` naming a Slack channel and an email channel
- **WHEN** step 1 fires
- **THEN** the system SHALL create two `NotificationDelivery` rows, one per channel
- **AND** each row SHALL carry the same `alert_id`, `policy_id`, and `step_number`

#### Scenario: Fan-out sibling failure is isolated

- **GIVEN** a fan-out set of channels A and B
- **WHEN** dispatch to A fails permanently
- **THEN** dispatch to B SHALL proceed and be recorded independently

### Requirement: Transport retry is bounded and idempotent

The system SHALL retry a transport failure that is retryable, which SHALL include
HTTP 5xx responses, HTTP 429, and connection or read timeouts. Retries SHALL be
performed by an Oban worker using Oban backoff and SHALL be bounded by the
channel `max_attempts`.

A retryable failure SHALL increment `attempt_count`, set `next_attempt_at`, and
leave the `NotificationDelivery` row in `state: :pending`. A retry-eligible
delivery SHALL NOT be parked in `:failed` and revived later.

`:failed` SHALL be terminal. A delivery SHALL move to `:failed` only on a
non-retryable failure, which SHALL include HTTP 4xx other than 429 and payload
validation errors, or on exhaustion of `max_attempts`. A `:failed` delivery SHALL
NOT be retried, and SHALL NOT transition back to `:pending` or `:dispatching`.

Retry-due selection SHALL therefore select `NotificationDelivery` rows with
`state: :pending`, `next_attempt_at <= now()`, and
`attempt_count < max_attempts`. It MUST NOT select rows in `state: :failed`.

Delivery Oban jobs SHALL be idempotent, SHALL use string keys in `args`, and
SHALL NOT store structs in `args`. A job that re-executes for a delivery already
in a terminal state SHALL be a no-op.

#### Scenario: 5xx is retried with backoff

- **GIVEN** a channel with `max_attempts: 5`
- **WHEN** the transport returns HTTP 503 on attempt 2
- **THEN** `attempt_count` SHALL become 2, `next_attempt_at` SHALL be set from Oban backoff
- **AND** the delivery SHALL remain in `state: :pending`

#### Scenario: 4xx is not retried

- **WHEN** the transport returns HTTP 400 for a rendered payload
- **THEN** the delivery SHALL move directly to `state: :failed`
- **AND** `attempt_count` SHALL NOT increase further

#### Scenario: Retry-due selection ignores failed rows

- **GIVEN** one delivery in `state: :pending` with `next_attempt_at` in the past and `attempt_count` below `max_attempts`
- **AND** one delivery in `state: :failed` with `next_attempt_at` in the past
- **WHEN** retry-due selection runs
- **THEN** only the `:pending` delivery SHALL be selected
- **AND** the `:failed` delivery SHALL remain terminal and untouched

#### Scenario: Exhausting max_attempts is the only retry path to failed

- **GIVEN** a channel with `max_attempts: 3` and a delivery that has failed retryably three times
- **WHEN** the third attempt is recorded
- **THEN** the delivery SHALL move to `state: :failed`
- **AND** no further attempt SHALL be scheduled for that delivery

#### Scenario: Duplicate job execution is a no-op

- **GIVEN** a delivery already in `state: :sent`
- **WHEN** the Oban job for that delivery id executes again
- **THEN** the worker SHALL make no transport call and SHALL NOT mutate the delivery row

#### Scenario: Job args carry no structs

- **WHEN** a delivery job is enqueued
- **THEN** its `args` SHALL contain only string keys and JSON-encodable scalar or collection values
- **AND** it SHALL NOT contain an Ash resource struct or any other Elixir struct

### Requirement: Transport failover is a single hop to a fallback channel

The system SHALL fail over to the channel named by `fallback_channel_id`, when
one is configured and the originating channel is not marked `fail_closed`, in
exactly two situations: the delivery exhausted its retry budget, or an
`:edge_agent` dispatch returned `{:error, {:agent_offline, _}}`.

Failover SHALL be exactly one hop. The fallback channel's own
`fallback_channel_id` SHALL NOT be followed for the same originating delivery.

Failover SHALL create a new `NotificationDelivery` row for the fallback channel
whose `originating_delivery_id` references the originating delivery, and SHALL
leave the originating delivery in its terminal `:failed` state.

When a channel is marked `fail_closed`, the system SHALL NOT fail over, and SHALL
leave the delivery `:failed`.

#### Scenario: Retries exhausted triggers one failover hop

- **GIVEN** channel A with `fallback_channel_id` pointing at channel B, and B with `fallback_channel_id` pointing at channel C
- **WHEN** delivery to A exhausts `max_attempts`
- **THEN** the system SHALL create a delivery for channel B referencing the failed A delivery
- **AND** it SHALL NOT create a delivery for channel C when B also fails

#### Scenario: fail_closed suppresses failover

- **GIVEN** channel A with `fail_closed: true` and a configured `fallback_channel_id`
- **WHEN** delivery to A exhausts `max_attempts`
- **THEN** the delivery SHALL remain `:failed`
- **AND** no fallback delivery SHALL be created

### Requirement: Human escalation requires elapsed delay and continued non-acknowledgement

Escalation SHALL advance only when the step `delay_seconds` has elapsed from the
alert fire time AND the alert is still unacknowledged, for steps whose
`condition` is `:if_unacknowledged`. The single exception to the delay origin is
a snooze expiry, after which remaining step delays SHALL be measured from the
snooze expiry instant.

Escalation SHALL NOT be triggered by a transport failure. A delivery that fails
on every channel of step 1 SHALL NOT cause step 2 to fire earlier than its
configured `delay_seconds`.

Acknowledgement SHALL halt further `:if_unacknowledged` escalation steps and
policy repeats for that alert.

#### Scenario: Transport failure does not accelerate escalation

- **GIVEN** step 1 at `delay_seconds: 0` and step 2 at `delay_seconds: 600`
- **WHEN** every step 1 delivery fails within the first 30 seconds
- **THEN** step 2 SHALL NOT fire before 600 seconds after the alert fire time

#### Scenario: Acknowledgement between steps halts escalation

- **GIVEN** step 2 is due at 600 seconds with `condition: :if_unacknowledged`
- **WHEN** the alert is acknowledged at 400 seconds
- **THEN** step 2 SHALL be recorded as `:suppressed` with `suppression_reason: :acknowledged`

### Requirement: Retry, failover, and escalation SHALL NOT be conflated

The system SHALL keep transport retry, transport failover, and human escalation
as three distinct mechanisms with distinct triggers, distinct bounds, and
distinct records. Implementations SHALL NOT satisfy one mechanism by reusing
another.

Specifically:

- A transport failure SHALL NOT advance an escalation step.
- A human non-acknowledgement SHALL NOT be recorded as a transport failure, and
  SHALL NOT consume the retry budget.
- Failover SHALL NOT be implemented as an additional escalation step, and an
  escalation step SHALL NOT be implemented as a failover hop.
- Fan-out to multiple channels within one step SHALL NOT be counted as retry,
  failover, or escalation.

Each mechanism SHALL be independently observable on `NotificationDelivery`:
retries via `attempt_count` and `next_attempt_at`, failover via
`originating_delivery_id` on the fallback delivery, and escalation via
`policy_id` and `step_number`.

#### Scenario: The three mechanisms are separately attributable

- **GIVEN** an alert that experienced two retries on channel A, one failover to channel B, and promotion to escalation step 2
- **WHEN** an operator inspects the delivery log for the alert
- **THEN** the retries SHALL be visible as `attempt_count` on the channel A delivery
- **AND** the failover SHALL be visible as a channel B delivery whose `originating_delivery_id` references the channel A delivery
- **AND** the escalation SHALL be visible as a separate delivery with `step_number: 2`

#### Scenario: Non-acknowledgement does not consume retry budget

- **GIVEN** a delivery that reached `state: :sent` and an alert that remains unacknowledged
- **WHEN** the next escalation step becomes due
- **THEN** `attempt_count` on the sent delivery SHALL be unchanged
- **AND** the escalation SHALL create a new delivery rather than retry the sent one

### Requirement: Suppression is an enumerated, auditable decision

The system SHALL implement `ServiceRadar.Notifications.Suppression`, which SHALL
evaluate a candidate dispatch and return either an allow decision or a
suppression reason drawn from exactly this enumeration:

- `:device_out_of_service` - the subject device has `is_active == false`
- `:silence` - an active `NotificationSilence` whose matchers match
- `:schedule` - outside the route's `NotificationSchedule` window
- `:snoozed` - the alert is snoozed until a future timestamp
- `:throttled` - route `throttle_seconds` or rule `cooldown_seconds` withheld the dispatch
- `:acknowledged` - the alert is acknowledged and escalation is halted
- `:channel_disabled` - the channel is disabled or its provider is deactivated
- `:no_matching_route` - the alert matched zero enabled routes
- `:dependency` - reserved for topology-driven parent suppression

The `:dependency` reason SHALL be reserved in the contract and SHALL NOT be
emitted by this change.

An implementation SHALL NOT introduce an unnamed or free-text suppression reason.

#### Scenario: Reason vocabulary is closed

- **WHEN** a dispatch is withheld
- **THEN** `suppression_reason` SHALL be one of the enumerated atoms
- **AND** a value outside the enumeration SHALL be rejected by the resource

#### Scenario: Unrouted alert uses the enumerated no-match reason

- **GIVEN** an alert matching zero enabled routes
- **WHEN** routing completes
- **THEN** the recorded `suppression_reason` SHALL be `:no_matching_route`
- **AND** it SHALL be queryable through the same delivery-log audit path as `:silence` or `:schedule`

#### Scenario: Dependency reason is reserved but unused

- **WHEN** the platform evaluates suppression for any dispatch in this change
- **THEN** it SHALL NOT return `:dependency`
- **AND** the enumeration SHALL still accept `:dependency` so a later change can emit it without a schema migration

### Requirement: Device out-of-service suppression at the notification layer

The system SHALL suppress a dispatch with reason `:device_out_of_service` when
the alert's subject device has `is_active == false` on
`ServiceRadar.Inventory.Device`.

This check SHALL be performed at the notification layer independently of any
suppression performed at alert generation time, because alert-creation paths
exist that bypass the stateful alert engine, specifically
`LogPromotion.update_alert_counts/2` and
`TrivyReports.maybe_create_priority_alert/3`.

The notification layer SHALL NOT assume that an alert reaching it was already
filtered for device activity state.

#### Scenario: Inactive device suppresses notification for a bypass-path alert

- **GIVEN** an alert created by `TrivyReports.maybe_create_priority_alert/3` for a device with `is_active == false`
- **WHEN** routing produces a candidate dispatch
- **THEN** the system SHALL write a `NotificationDelivery` row with `state: :suppressed`
- **AND** `suppression_reason` SHALL be `:device_out_of_service`

#### Scenario: Reactivated device stops suppressing

- **GIVEN** a device previously `is_active == false`
- **WHEN** the device becomes `is_active == true` and a new dispatch is evaluated
- **THEN** the system SHALL NOT suppress with `:device_out_of_service`

### Requirement: Suppression is re-evaluated at every dispatch

The system SHALL re-run the full suppression evaluation immediately before every
dispatch attempt, including every escalation step, every policy repeat, every
retry attempt, and every failover hop. Suppression SHALL NOT be evaluated only
once at routing time and cached for the life of the alert.

A dispatch that was allowed at routing time and is suppressed at dispatch time
SHALL be recorded as suppressed and SHALL NOT invoke a transport.

#### Scenario: State change between routing and a later step is honoured

- **GIVEN** an alert routed at t+0 when the device was active
- **AND** the device is marked `is_active == false` at t+5m
- **WHEN** escalation step 2 fires at t+15m
- **THEN** the step 2 dispatch SHALL be suppressed with `:device_out_of_service`
- **AND** the earlier step 1 delivery SHALL remain unchanged

#### Scenario: Silence created after routing suppresses a later retry

- **GIVEN** a delivery awaiting its next retry attempt
- **AND** an operator creates a matching active `NotificationSilence`
- **WHEN** the retry attempt executes
- **THEN** the delivery SHALL be moved to `:suppressed` with reason `:silence`
- **AND** no transport call SHALL be made

### Requirement: Suppressed notifications SHALL always leave a record

A notification that is not sent MUST leave a `NotificationDelivery` row with
`state: :suppressed` and a populated `suppression_reason`. Silent drops are
prohibited.

There SHALL be no code path in the notification platform that declines to
dispatch without writing a delivery row. This applies to suppression, to
throttling, to acknowledgement halts, to unrouted alerts, and to disabled
channels and providers.

To bound row growth without reintroducing silent drops, a repeat of an IDENTICAL
suppression decision, identified by the tuple
`{alert_id, policy_id, step_number, channel_id, dedupe_key, suppression_reason}`,
SHALL update the existing `:suppressed` row rather than insert a duplicate. The
update SHALL increment an occurrence counter and refresh `last_evaluated_at` on
that row. `NotificationDelivery` SHALL therefore carry an occurrence counter and
a `last_evaluated_at` attribute for suppressed rows.

A decision differing in any element of that tuple, including a different
`suppression_reason` for the same step and channel, SHALL be recorded as a new
row and SHALL NOT be collapsed onto an existing one.

An operator SHALL be able to answer "why was I not paged?" for any alert by
reading its `NotificationDelivery` rows.

#### Scenario: Repeated identical suppression collapses onto one row

- **GIVEN** a dispatch for a given alert, policy, step, channel, and dedupe key suppressed with reason `:silence`
- **WHEN** the same decision is re-evaluated four more times while the silence remains active
- **THEN** exactly one `:suppressed` row SHALL exist for that tuple
- **AND** its occurrence counter SHALL read 5 and its `last_evaluated_at` SHALL reflect the most recent evaluation

#### Scenario: A different reason is not collapsed

- **GIVEN** an existing `:suppressed` row with `suppression_reason: :silence` for a step and channel
- **WHEN** a later evaluation of the same step and channel is withheld with `suppression_reason: :schedule`
- **THEN** a separate `:suppressed` row SHALL be written for the `:schedule` decision
- **AND** the `:silence` row SHALL retain its own occurrence counter

#### Scenario: Every withheld dispatch is queryable

- **GIVEN** an alert whose dispatches were withheld by a silence, a schedule window, and a disabled channel
- **WHEN** an operator queries deliveries for that alert
- **THEN** three `NotificationDelivery` rows SHALL be present with `state: :suppressed`
- **AND** their `suppression_reason` values SHALL be `:silence`, `:schedule`, and `:channel_disabled` respectively

#### Scenario: No silent drop path exists

- **WHEN** any suppression source withholds a candidate dispatch
- **THEN** a `NotificationDelivery` row SHALL be committed before the dispatch decision is considered complete

### Requirement: Silences and maintenance windows

The system SHALL provide a `NotificationSilence` resource with `matchers`,
`starts_at`, `ends_at`, `created_by_user_id`, `comment`, and `state`, where
`state` is one of `:scheduled`, `:active`, `:expired`, or `:cancelled`.

A silence SHALL suppress a dispatch only while its state is `:active` and its
`matchers` match the alert. `matchers` SHALL be evaluated as declarative
predicates over alert attributes without executing operator-supplied code.

The system SHALL run an Oban expiry sweeper that transitions `:scheduled`
silences to `:active` at `starts_at` and `:active` silences to `:expired` at
`ends_at`. Sweeper jobs SHALL be idempotent.

A cancelled silence SHALL stop suppressing immediately and SHALL NOT be
reactivated.

#### Scenario: Scheduled silence activates and expires

- **GIVEN** a silence with `starts_at` in the future and `ends_at` one hour later
- **WHEN** the sweeper runs after `starts_at`
- **THEN** the silence state SHALL be `:active`
- **AND** after `ends_at` a subsequent sweeper run SHALL set the state to `:expired`

#### Scenario: Expired silence no longer suppresses

- **GIVEN** a silence in state `:expired` whose matchers match an alert
- **WHEN** a dispatch is evaluated
- **THEN** the system SHALL NOT suppress with reason `:silence`

#### Scenario: Cancelled silence takes effect immediately

- **GIVEN** an `:active` silence suppressing dispatches for an alert
- **WHEN** an operator cancels it
- **THEN** the next dispatch evaluation SHALL NOT suppress with reason `:silence`

### Requirement: Notification schedules

The system SHALL provide a `NotificationSchedule` resource with `name`,
`timezone`, `windows` as a list of `{days, start_time, end_time}` entries, and
`mode` of `:active_within` or `:active_outside`.

Window evaluation SHALL be performed in the schedule's `timezone`, including
across daylight-saving transitions.

When a route references a schedule and the current time falls outside the
schedule's effective active period, the dispatch SHALL be suppressed with reason
`:schedule`.

Schedules SHALL NOT implement on-call rotations, shift handoffs, or override
management. Those are explicitly out of scope.

#### Scenario: Business-hours schedule suppresses after hours

- **GIVEN** a schedule with `mode: :active_within` and a window of Mon-Fri 09:00-17:00 in `America/New_York`
- **WHEN** a dispatch is evaluated at 02:00 on a Tuesday in that timezone
- **THEN** the dispatch SHALL be suppressed with `suppression_reason: :schedule`

#### Scenario: Inverted schedule pages only after hours

- **GIVEN** the same window with `mode: :active_outside`
- **WHEN** a dispatch is evaluated at 02:00 on a Tuesday in that timezone
- **THEN** the dispatch SHALL NOT be suppressed by the schedule

#### Scenario: Timezone is honoured across DST

- **GIVEN** a schedule window of 09:00-17:00 in `America/New_York`
- **WHEN** the local clock shifts for daylight saving
- **THEN** window boundaries SHALL continue to evaluate against local wall-clock time in the configured timezone

### Requirement: Deduplication consumes the existing incident identity

The notification platform SHALL use the existing incident identity, the composite
`{rule_id, group_key}`, as the default deduplication key, where `group_key` is
derived from `StatefulAlertRule.group_by` and is made unique by
`stateful_alert_rule_states_unique_state_index`.

The platform SHALL consume `StatefulAlertRule.cooldown_seconds` and
`renotify_seconds` as authored on the rule. It SHALL NOT define a second cooldown
or renotify scheme, and it SHALL NOT re-implement occurrence counting; occurrence
metadata written by `AlertLifecycle.merge_incident_metadata/5` under the
`incident_*` keys in `alerts.metadata` SHALL be read, not duplicated.

A dispatch withheld because the incident is inside its `cooldown_seconds` window
SHALL be recorded as suppressed with reason `:throttled`.

`renotify_seconds` SHALL act as the cadence floor for repeats of an incident.
`NotificationEscalationPolicy.repeat_interval_seconds` and route
`throttle_seconds` MAY only make notifications LESS frequent than that floor.
Neither SHALL be used to page more often than the rule authorises, and a
configuration that would widen rule cadence SHALL be rejected at save time.

Deviation from the default identity SHALL only be possible through a route's
`dedupe_key_template`.

#### Scenario: Default dedupe key comes from incident identity

- **GIVEN** a stateful rule with `group_by` producing `group_key` of `device_id=abc|severity=high`
- **WHEN** a delivery is created for an alert from that rule with no route `dedupe_key_template`
- **THEN** `dedupe_key` SHALL be derived from `{rule_id, group_key}`

#### Scenario: Rule cooldown is honoured, not redefined

- **GIVEN** a rule with `cooldown_seconds: 600` whose incident notified 120 seconds ago
- **WHEN** a duplicate event produces another dispatch candidate for the same incident
- **THEN** the dispatch SHALL be suppressed with `suppression_reason: :throttled`
- **AND** the platform SHALL NOT apply a separately configured notification-layer cooldown value

#### Scenario: Renotify interval drives a repeat dispatch

- **GIVEN** an active incident with `renotify_seconds: 21600`
- **WHEN** that interval elapses and the incident remains active and unresolved
- **THEN** the platform SHALL create a new dispatch for the incident
- **AND** it SHALL reuse the same `dedupe_key`

#### Scenario: Route cadence may only narrow, never widen

- **GIVEN** a rule with `renotify_seconds: 21600`
- **WHEN** an operator saves a route or policy whose effective repeat cadence is shorter than 21600 seconds
- **THEN** the save SHALL be rejected with a validation error
- **AND** a cadence longer than 21600 seconds SHALL be accepted

### Requirement: NotificationDelivery is the system of record

The system SHALL provide a `NotificationDelivery` resource with one row per
(alert, escalation step, channel), carrying at minimum `alert_id`, `route_id`,
`policy_id`, `step_number`, `channel_id`, `dedupe_key`, `attempt_count`,
`next_attempt_at`, `external_correlation_id`, `originating_delivery_id`,
`payload_format`, `provider_version`, `is_test`, `occurrence_count`,
`last_evaluated_at`, `error_class`, `error_message`, `result_summary`,
`suppression_reason`, `rendered_payload_digest`, `execution_route`, `agent_uid`,
`command_id`, `queued_at`, `started_at`, `finished_at`, and `alert_snapshot`.

The `state` vocabulary SHALL be exactly `:pending`, `:dispatching`, `:sent`,
`:failed`, `:expired`, `:cancelled`, `:suppressed`, and `:skipped`. `:failed` is
terminal, and a retry-eligible delivery SHALL remain `:pending` with
`next_attempt_at` set.

`external_correlation_id` SHALL record the provider-side identifier returned by a
successful send, such as a Slack message `ts` or a PagerDuty `dedup_key`, so that
follow-up updates, threading, and inbound callbacks can be correlated back to the
originating delivery.

`originating_delivery_id` SHALL be the failover back-reference. It SHALL be null
on a delivery created directly by routing or escalation, and SHALL reference the
exhausted or offline delivery on a delivery created by a failover hop.

`payload_format` SHALL record the format actually negotiated and rendered for
that delivery, so an operator can tell which of the provider's `payload_formats`
was used.

`provider_version` SHALL record the version of the provider definition that
rendered the delivery, so a delivery remains explainable after the provider
definition is edited or upgraded.

`is_test` SHALL be a boolean marking deliveries produced by the provider test
action. Test deliveries SHALL NOT count toward any alert's delivery count,
notification count, escalation progress, retry budget accounting, or renotify
cadence, and SHALL be visually distinguished wherever deliveries are listed.

`occurrence_count` and `last_evaluated_at` SHALL carry the collapsed repeat
count and most recent evaluation time for `:suppressed` rows.

The delivery row SHALL be the authoritative record of the outcome. No other
record, signal, or external system response SHALL be treated as authoritative.

#### Scenario: State vocabulary is enforced

- **WHEN** a delivery is written with a state outside the eight enumerated values
- **THEN** the resource SHALL reject the change

#### Scenario: Failover back-reference is recorded on the fallback row

- **GIVEN** a delivery to channel A that exhausted `max_attempts`
- **WHEN** the single failover hop creates a delivery for channel B
- **THEN** the channel B row `originating_delivery_id` SHALL reference the channel A delivery
- **AND** the channel A row `originating_delivery_id` SHALL be null

#### Scenario: Rendered format and provider version are captured

- **GIVEN** a Slack channel whose provider supports `:slack_blocks` and `:markdown`
- **WHEN** a delivery renders using `:slack_blocks` from provider definition version 3
- **THEN** `payload_format` SHALL be `:slack_blocks` and `provider_version` SHALL be 3
- **AND** editing the provider definition afterwards SHALL NOT change the recorded values on that row

#### Scenario: Test delivery does not count toward alert totals

- **GIVEN** an alert with two real deliveries
- **WHEN** an operator runs a channel test that writes a delivery with `is_test: true`
- **THEN** the alert delivery and notification counts SHALL still report two
- **AND** the test row SHALL be visually distinguished in the delivery log

#### Scenario: Provider identifier is captured for correlation

- **GIVEN** a Slack send returning a message `ts`
- **WHEN** the delivery reaches `state: :sent`
- **THEN** `external_correlation_id` SHALL contain that `ts`
- **AND** a later inbound interaction carrying the same `ts` SHALL resolve to that delivery

#### Scenario: Per-attempt timing is recorded

- **WHEN** a delivery transitions `:pending -> :dispatching -> :sent`
- **THEN** `queued_at`, `started_at`, and `finished_at` SHALL each be populated
- **AND** `attempt_count` SHALL reflect the number of transport attempts made

### Requirement: Delivery records carry an alert snapshot and their own retention

Every `NotificationDelivery` row SHALL carry a populated `alert_snapshot`
containing the redacted alert content needed to explain the delivery without
reading the `alerts` table.

`alert_snapshot` SHALL be required, not optional, because
`Jobs.AlertsRetentionWorker` hard-deletes resolved and suppressed alerts after a
default of three days, so a delivery row outlives the alert it references.

`NotificationDelivery` SHALL have its own retention policy, configured
independently of and longer than the alert retention window. Delivery retention
SHALL NOT be driven by `AlertsRetentionWorker`.

The delivery log SHALL remain readable and explainable after the referenced alert
has been deleted.

#### Scenario: Delivery survives alert hard-delete

- **GIVEN** a delivery for an alert that is subsequently hard-deleted by `AlertsRetentionWorker`
- **WHEN** an operator opens the delivery log entry
- **THEN** the entry SHALL render the alert content from `alert_snapshot`
- **AND** the read SHALL NOT fail on the missing alert row

#### Scenario: Snapshot is required at write time

- **WHEN** a `NotificationDelivery` is created without `alert_snapshot`
- **THEN** the resource SHALL reject the change

#### Scenario: Delivery retention is independent

- **GIVEN** alert retention of three days and delivery retention of ninety days
- **WHEN** the alert retention worker runs
- **THEN** delivery rows older than three days but newer than ninety days SHALL remain

### Requirement: Execution route selection and the platform-resident agent path

The system SHALL honour `NotificationChannel.execution_route`, which SHALL be
`:control_plane` by default or `:edge_agent` when explicitly configured, and
SHALL record the effective route on each `NotificationDelivery` in
`execution_route`.

Route behaviour SHALL be:

- `:control_plane` with a `:native` provider - direct Elixir transport call.
- `:control_plane` with a `:declarative` provider - the Elixir HTTP engine,
  guarded by `Palisade.OutboundURLPolicy.validate_https_public_url/2`.
- `:control_plane` with a `:wasm_plugin` provider - `AgentCommandBus.dispatch/4`
  to the platform-resident `serviceradar-agent`, using the same
  `plugin.run_action` command as any edge dispatch.
- `:edge_agent` with a plugin provider - `AgentCommandBus.dispatch/4` to the
  named site agent identified by `agent_uid`.

`agent_uid` and `partition_id` SHALL be required when `execution_route` is
`:edge_agent`, and `partition_id` SHALL be force-bound server-side.

The system SHALL NOT introduce a second Wasm host runtime in `serviceradar_core`.
Plugin execution on either route SHALL use the existing agent-side wazero host.

A channel SHALL only use an `execution_route` present in its provider's
`supported_routes`.

#### Scenario: Plugin channel on the control plane runs on the platform agent

- **GIVEN** a channel with `provider_type: :wasm_plugin` and `execution_route: :control_plane`
- **WHEN** a delivery is dispatched
- **THEN** the system SHALL call `AgentCommandBus.dispatch/4` targeting the platform-resident agent with a `plugin.run_action` command
- **AND** the delivery `execution_route` SHALL be recorded as `:control_plane`

#### Scenario: Relocating a channel to the edge is a data edit

- **GIVEN** an existing plugin-backed channel on `:control_plane`
- **WHEN** an operator changes `execution_route` to `:edge_agent` and supplies `agent_uid`
- **THEN** subsequent deliveries SHALL dispatch to the named site agent
- **AND** no plugin repackaging or release SHALL be required

#### Scenario: Unsupported route is rejected

- **WHEN** a channel is configured with an `execution_route` not present in the provider `supported_routes`
- **THEN** the system SHALL reject the change with a validation error

### Requirement: Offline-agent contract for edge-routed deliveries

The system SHALL treat `{:error, {:agent_offline, agent_id}}` from
`AgentCommandBus` as a recorded transport outcome: it SHALL write the attempt to
the `NotificationDelivery` row with an `error_class` identifying the offline
agent, and SHALL fail over to `fallback_channel_id` unless the channel is marked
`fail_closed`.

The system SHALL NOT assume store-and-forward. `AgentCommandBus` is at-most-once
with no reconnect drain, so an edge dispatch that was accepted by the bus but
never acknowledged SHALL still reach a terminal delivery state through a bounded
periodic reconciler rather than waiting indefinitely.

The agent command result SHALL be treated as a wake-up signal only. The
`NotificationDelivery` row SHALL be the system of record for whether a
notification was delivered. A delivery SHALL NOT be reported as `:sent` solely
because a command was dispatched, and it SHALL NOT be reported as delivered on
the basis of an unpersisted command result.

Where durable command receipts are not available, the system SHALL either enable
persistent command status handling or provide a poll-based reconciler that moves
stale `:dispatching` deliveries to a terminal state within a bounded interval.

#### Scenario: Offline site agent fails over

- **GIVEN** an `:edge_agent` channel with a `:control_plane` `fallback_channel_id` and `fail_closed: false`
- **WHEN** dispatch returns `{:error, {:agent_offline, "site-a-agent"}}`
- **THEN** the originating delivery SHALL be recorded with an offline `error_class`
- **AND** a fallback delivery SHALL be created for the fallback channel

#### Scenario: fail_closed edge channel does not fail over

- **GIVEN** an `:edge_agent` channel with `fail_closed: true`
- **WHEN** dispatch returns `{:error, {:agent_offline, _}}`
- **THEN** the delivery SHALL terminate as `:failed`
- **AND** no fallback delivery SHALL be created

#### Scenario: Command dispatch alone is not delivery

- **GIVEN** a delivery whose `plugin.run_action` command was accepted by the bus
- **WHEN** no durable result has been recorded
- **THEN** the delivery SHALL remain `:dispatching`
- **AND** it SHALL NOT be reported as `:sent`

#### Scenario: Stale dispatching deliveries are reconciled

- **GIVEN** a delivery that has been `:dispatching` beyond the configured deadline with no recorded result
- **WHEN** the reconciler runs
- **THEN** the delivery SHALL move to a terminal state of `:failed` or `:expired`
- **AND** failover SHALL be evaluated under the same rules as an exhausted retry budget

### Requirement: Signed single-use capability tokens for notification action links

Every rendered notification SHALL carry `Acknowledge`, `Snooze 1h`, and `Resolve`
action links bearing a capability token minted per `NotificationDelivery` and per
action, with exactly one exemption stated below.

The `:stream` provider SHALL be EXEMPT from this requirement. A `:stream`
envelope SHALL NOT carry an action link and SHALL NOT carry a capability token in
any field, because embedding a single-use capability token in a broadcast stream
consumed by every subscriber is a credential leak. Stream subscribers SHALL act
on an alert through the authenticated UI or API ingress instead.

Tokens SHALL be persisted as a sha256 digest only. The plaintext token SHALL NOT
be stored, logged, or included in `result_summary`, `error_message`, or
`alert_snapshot`.

Tokens SHALL be TTL-bounded and single-use per action. Presenting an expired,
revoked, unknown, or already-consumed token SHALL be rejected without mutating
alert state, and the rejection SHALL be auditable.

Token comparison SHALL use a constant-time comparison such as
`Plug.Crypto.secure_compare`.

Action links SHALL work for any provider without per-provider code, including
email, generic webhook, and every `:declarative` provider, other than the exempt
`:stream` provider.

#### Scenario: Acknowledge link acknowledges once

- **GIVEN** a delivery whose acknowledge token has not been used
- **WHEN** the link is followed with a valid token
- **THEN** the alert SHALL be acknowledged
- **AND** a `NotificationAcknowledgement` row SHALL be written with `source: :action_link`

#### Scenario: Replayed token is rejected

- **WHEN** the same acknowledge token is presented a second time
- **THEN** the request SHALL be rejected
- **AND** the alert state SHALL be unchanged
- **AND** the rejection SHALL be recorded for audit

#### Scenario: Expired token is rejected

- **GIVEN** a token whose TTL has elapsed
- **WHEN** the link is followed
- **THEN** the request SHALL be rejected without mutating alert state

#### Scenario: Only the digest is persisted

- **WHEN** a token is minted
- **THEN** the stored record SHALL contain a sha256 digest of the token
- **AND** the plaintext token SHALL NOT be present in any persisted column or log line

#### Scenario: Stream envelope carries no capability token

- **GIVEN** a `:stream` channel bound to an escalation step
- **WHEN** the step fires and the envelope is published
- **THEN** the envelope SHALL contain no `Acknowledge`, `Snooze 1h`, or `Resolve` action link
- **AND** no capability token SHALL be minted for that delivery

### Requirement: Acknowledgement, snooze, resolve, and suppress ingress and audit

The system SHALL accept `acknowledge`, `snooze`, `resolve`, `suppress`, and
`unacknowledge` actions against an alert from the UI, the API, a provider
callback, and a signed action link, and SHALL record each accepted action as a
`NotificationAcknowledgement` row with `delivery_id`, `alert_id`, `action`,
`actor_kind`, `actor_user_id`, `external_principal`, `note`, `snooze_until`,
`source`, and `received_at`.

`actor_kind` SHALL be one of `:platform_user`, `:external_principal`, or
`:system`. When the actor is an authenticated platform user, `actor_user_id`
SHALL be set as a real foreign key to `ServiceRadar.Identity.User` and
`acknowledged_by_user_id` SHALL be set on the alert. When the actor is external,
`external_principal` SHALL record an opaque principal identifier and
`actor_kind` SHALL be `:external_principal`.

`source` SHALL be one of `:ui`, `:api`, `:callback`, or `:action_link`.

A `snooze` action SHALL set `snooze_until` and SHALL cause subsequent dispatches
to be suppressed with reason `:snoozed` until that timestamp passes.

Acting on an alert SHALL be authorized. UI and API ingress SHALL require the
`observability.alerts.manage` permission; action-link and callback ingress SHALL
be authorized by the signed capability token or verified HMAC callback rather
than by an ambient session.

#### Scenario: Platform user acknowledgement records a real FK

- **GIVEN** an authenticated platform user with `observability.alerts.manage`
- **WHEN** the user acknowledges an alert from the UI
- **THEN** `NotificationAcknowledgement.actor_kind` SHALL be `:platform_user`
- **AND** `actor_user_id` and the alert `acknowledged_by_user_id` SHALL reference the user

#### Scenario: External principal acknowledgement is distinguishable

- **GIVEN** an acknowledgement arriving from a provider callback for an external chat identity
- **WHEN** the callback is verified
- **THEN** `actor_kind` SHALL be `:external_principal`
- **AND** `external_principal` SHALL carry the opaque external identifier
- **AND** `actor_user_id` SHALL be null

#### Scenario: Snooze suppresses subsequent dispatches

- **GIVEN** an alert snoozed until one hour in the future
- **WHEN** an escalation step becomes due before that timestamp
- **THEN** the dispatch SHALL be suppressed with `suppression_reason: :snoozed`
- **AND** after the timestamp passes, dispatch evaluation SHALL no longer suppress for `:snoozed`

#### Scenario: Unauthorized UI ingress is refused

- **GIVEN** an authenticated user lacking `observability.alerts.manage`
- **WHEN** the user attempts to acknowledge an alert from the UI or API
- **THEN** the request SHALL be refused
- **AND** no `NotificationAcknowledgement` row SHALL be written

### Requirement: Native interactive acknowledgement components

The system SHALL support native interactive acknowledgement in addition to signed
action links, covering at minimum Slack Block Kit buttons, Discord message
components, and PagerDuty acknowledgement webhooks, so that an operator can
acknowledge, snooze, or resolve from inside the destination application without
following a link.

Native interactive callbacks SHALL be verified with the existing northbound
callback scheme rather than a second scheme:

- The callback token SHALL be accepted from a request header, a `Bearer`
  authorization header, or the request body, and SHALL be persisted as a sha256
  digest only. The plaintext token SHALL NOT be stored or logged.
- The shared HMAC secret SHALL be encrypted at rest with `Edge.Crypto`.
- Verification SHALL compute HMAC-SHA256 over `<timestamp>.<raw_body>` and SHALL
  compare using `Plug.Crypto.secure_compare`.
- A request whose timestamp is outside a 300 second tolerance SHALL be rejected.

The notification callback route prefix SHALL be registered with
`ServiceRadarWebNGWeb.Api.RawBodyReader`, because that reader buffers raw request
bodies only for registered prefixes and HMAC over the raw body is otherwise
impossible to compute. Shipping the callback route without registering its prefix
SHALL be treated as an incomplete implementation.

An accepted native interaction SHALL be recorded as a `NotificationAcknowledgement`
row with `source: :callback`, and SHALL resolve to the originating delivery
through `external_correlation_id`. The actor SHALL be recorded as
`actor_kind: :external_principal` with an opaque `external_principal`, unless the
external identity is mapped to an authenticated platform user.

A callback that fails token verification, HMAC verification, or the timestamp
tolerance SHALL be rejected without mutating alert state, and the rejection SHALL
be auditable.

#### Scenario: Slack Block Kit acknowledgement is accepted

- **GIVEN** a Slack delivery rendered with Block Kit acknowledge and resolve buttons
- **WHEN** a Slack user presses Acknowledge and the interaction callback passes token and HMAC verification
- **THEN** the alert SHALL be acknowledged
- **AND** a `NotificationAcknowledgement` row SHALL be written with `source: :callback` and `actor_kind: :external_principal`
- **AND** the row SHALL reference the delivery resolved through `external_correlation_id`

#### Scenario: Discord component and PagerDuty webhook use the same verification

- **GIVEN** a Discord message component interaction and a PagerDuty acknowledgement webhook
- **WHEN** each callback is received
- **THEN** each SHALL be verified with HMAC-SHA256 over `<timestamp>.<raw_body>` compared using `Plug.Crypto.secure_compare`
- **AND** neither SHALL introduce a provider-specific verification scheme

#### Scenario: Stale timestamp is rejected

- **GIVEN** an otherwise valid interaction callback whose timestamp is 400 seconds old
- **WHEN** the callback is verified
- **THEN** the request SHALL be rejected outside the 300 second tolerance
- **AND** the alert state SHALL be unchanged
- **AND** the rejection SHALL be recorded for audit

#### Scenario: Callback prefix is registered for raw-body buffering

- **WHEN** the notification interaction callback route is mounted
- **THEN** its path prefix SHALL be present in the `ServiceRadarWebNGWeb.Api.RawBodyReader` registered prefix list
- **AND** HMAC verification SHALL operate on the buffered raw body rather than a re-encoded body

### Requirement: Provider test action is mandatory and test deliveries are isolated

Every notification provider SHALL implement a test action and SHALL declare
`test` in its `capabilities`. This applies to every extensibility tier -
`:native`, `:declarative`, and `:wasm_plugin` - and to the built-in `:stream`
provider. A provider manifest or definition declaring `capabilities` without both
`send` and `test` SHALL be rejected at validation time.

The test action SHALL exercise the same transport, credential resolution, and
rendering path as a real dispatch, so that a passing test is evidence the channel
works.

A test dispatch SHALL write a `NotificationDelivery` row with `is_test: true`.
Test deliveries SHALL NOT count toward any alert's delivery count, notification
count, escalation progress, retry budget, renotify cadence, or dedupe state, and
SHALL be visually distinguished wherever deliveries are listed.

Sending a test SHALL require the `notifications.test.send` permission.

#### Scenario: Manifest without test capability is rejected

- **WHEN** a provider declares `capabilities` containing `send` but not `test`
- **THEN** validation SHALL reject the provider definition
- **AND** no provider row SHALL be created or activated

#### Scenario: Test exercises the real transport

- **GIVEN** a channel whose credential reference is misconfigured
- **WHEN** an operator with `notifications.test.send` runs a test
- **THEN** the test SHALL fail with the same `error_class` a real dispatch would produce
- **AND** the failure SHALL be recorded on a delivery row with `is_test: true`

#### Scenario: Test delivery does not disturb incident state

- **GIVEN** an active incident with an established dedupe key and renotify cadence
- **WHEN** a test delivery is written for a channel bound to that incident's route
- **THEN** the incident dedupe state, escalation progress, and renotify schedule SHALL be unchanged

#### Scenario: Unauthorized test is refused

- **GIVEN** an authenticated user lacking `notifications.test.send`
- **WHEN** the user attempts to send a test notification
- **THEN** the request SHALL be refused and no delivery row SHALL be written

### Requirement: Per-channel rate limiting uses a restart-surviving budget

The system SHALL enforce `NotificationChannel.rate_limit_per_minute` against a
durable, shared counter that survives process restarts and is correct across all
nodes in the cluster.

The rate limit SHALL NOT be implemented as in-memory `GenServer` state, which is
the mechanism the removed `WebhookNotifier` used and which loses its budget on
every restart and diverges per node.

A dispatch withheld by the rate limit SHALL be deferred and retried rather than
dropped. It SHALL remain in `state: :pending` with `next_attempt_at` set, SHALL
NOT be recorded as `:failed`, and SHALL NOT consume the transport retry budget.

#### Scenario: Budget survives a restart

- **GIVEN** a channel with `rate_limit_per_minute: 60` that has consumed 55 of its budget in the current window
- **WHEN** the notification worker process restarts
- **THEN** the remaining budget in that window SHALL still be 5

#### Scenario: Budget is shared across nodes

- **GIVEN** two cluster nodes dispatching to the same channel
- **WHEN** the combined dispatch rate would exceed `rate_limit_per_minute`
- **THEN** the system SHALL enforce the limit against the combined rate, not per node

#### Scenario: Rate-limited dispatch is deferred, not failed

- **WHEN** a dispatch is withheld by the channel rate limit
- **THEN** the delivery SHALL remain in `state: :pending` with `next_attempt_at` set
- **AND** `attempt_count` SHALL NOT be incremented as a transport attempt

### Requirement: Payload rendering uses restricted substitution only

The system SHALL render notification subjects, notification bodies, and every
other operator-supplied template such as `dedupe_key_template` using a restricted
substitution engine consisting of whitelisted variable paths plus exactly this
filter set: `upper`, `lower`, `truncate`, `json`, `url_encode`, `iso8601`,
`default`.

The engine SHALL NOT support EEx, arbitrary Elixir, conditionals beyond
`default`, loops, or any other executable construct. `raw/1` SHALL NOT be applied
to template output or to any provider-supplied content.

A template referencing a variable path outside the whitelist SHALL fail
validation at save time, not at dispatch time.

Provider-supplied UI descriptors SHALL be declarative. Keys that carry markup or
code, including `html`, `raw_html`, `javascript`, `js`, `component`,
`component_ref`, `live_view`, `react`, and `ui_code`, SHALL be rejected.

`String.to_atom/1` SHALL NOT be applied to any operator or provider supplied
value in the rendering or dispatch path; module and provider resolution SHALL use
a compile-time allowlist.

#### Scenario: Unknown variable path fails at save time

- **WHEN** an operator saves a template referencing a variable path that is not whitelisted
- **THEN** the save SHALL be rejected with a validation error naming the path
- **AND** no dispatch-time failure SHALL be required to discover the error

#### Scenario: Unsupported filter is rejected

- **WHEN** a template uses a filter outside the fixed set
- **THEN** validation SHALL reject the template

#### Scenario: Code constructs are not evaluated

- **GIVEN** a template body containing EEx-like or script-like syntax
- **WHEN** the payload is rendered
- **THEN** the content SHALL be treated as literal text
- **AND** no code SHALL be evaluated

### Requirement: Redaction of payloads, results, and logs

Every notification payload, transport result, error message, and log line SHALL
pass `ActionRedaction` under policy `northbound-action-redaction-v1` before it is
persisted or displayed.

`NotificationDelivery` SHALL persist `rendered_payload_digest` rather than the
full rendered payload where the payload may contain sensitive content, and any
persisted payload excerpt SHALL be redacted.

Secret material SHALL NOT enter Wasm guest memory or `params_json`. Secrets
required by a plugin transport SHALL be supplied through host-side credential
injection via `CredentialBrokerGrant`, or through the trusted-host-only
`host_params_json` proto field.

`alert_snapshot` SHALL contain redacted content only.

#### Scenario: Sensitive value never reaches persistence

- **GIVEN** an alert whose metadata contains a value matching the redaction policy
- **WHEN** the payload is rendered and the delivery row is written
- **THEN** the persisted content SHALL contain the redacted form
- **AND** the unredacted value SHALL NOT appear in `alert_snapshot`, `result_summary`, or `error_message`

#### Scenario: Plugin transport receives no secret in guest memory

- **GIVEN** a `:wasm_plugin` channel whose provider requires an API token
- **WHEN** the plugin action is dispatched
- **THEN** the token SHALL be supplied through host-side credential injection or `host_params_json`
- **AND** it SHALL NOT be present in `params_json` or in guest-visible memory

### Requirement: Stream provider firehose over a durable subject

The system SHALL provide a `:stream` provider that publishes the canonical
notification envelope to an RBAC-scoped Phoenix Channel topic, backed by a durable
JetStream subject so that a reconnecting consumer replays from a durable cursor
rather than losing events.

The firehose SHALL traverse the same routing, suppression, redaction, and audit
path as every other channel. It SHALL NOT be a parallel, unaudited egress. A
firehose publication SHALL produce a `NotificationDelivery` row exactly as any
other channel does.

When a dispatch to a `:stream` channel is suppressed, the system SHALL publish NO
envelope on the JetStream subject and NO envelope on the Phoenix Channel topic,
and SHALL write a `NotificationDelivery` row with `state: :suppressed` and the
evaluated `suppression_reason`. There SHALL NOT be a "suppressed envelope" on the
stream; the suppression is visible only through the delivery record, which the
Delivery Log surfaces as a separate UI concern.

The `:stream` provider SHALL be exempt from the notification action-link
requirement. A stream envelope SHALL NOT embed a single-use capability token,
because the stream is a broadcast surface and every subscriber would receive the
token.

Subscription to the firehose topic SHALL require an authenticated principal
holding `notifications.stream.subscribe`, and topic scope SHALL be enforced
server-side. An unauthorized subscribe SHALL be refused.

The `:stream` `NotificationProvider` row SHALL be seeded as a first-party managed
provider alongside the seeded slack, discord, webhook, and email providers, using
the same `managed` / `template_version` / `template_fingerprint` reconciliation
pattern.

The new JetStream subject namespace SHALL be added to the per-CN publish and
subscribe allowlists in the NATS configuration, because new subject namespaces
are otherwise denied at the broker.

#### Scenario: Firehose events are routed and audited

- **GIVEN** a `:stream` channel bound to an escalation step
- **WHEN** the step fires
- **THEN** the envelope SHALL be published to the JetStream subject and the Phoenix Channel topic
- **AND** a `NotificationDelivery` row SHALL be written for the stream channel

#### Scenario: Suppression publishes nothing on the stream

- **GIVEN** an active silence matching the alert
- **WHEN** the stream channel dispatch is evaluated
- **THEN** no envelope SHALL be published on the JetStream subject or the Phoenix Channel topic
- **AND** a `NotificationDelivery` row SHALL be written with `state: :suppressed` and reason `:silence`
- **AND** a subscriber connected for the whole window SHALL observe no message for that dispatch

#### Scenario: Unauthorized subscribe is refused

- **WHEN** a principal without `notifications.stream.subscribe` attempts to join the firehose topic
- **THEN** the join SHALL be refused
- **AND** no envelope SHALL be delivered to that connection

#### Scenario: Reconnecting consumer replays

- **GIVEN** a consumer with a durable cursor that disconnects for thirty seconds
- **WHEN** it reconnects
- **THEN** it SHALL receive the envelopes published during the disconnection from the durable subject

#### Scenario: Stream provider is seeded as first-party managed

- **WHEN** the notification provider seeder runs on a fresh deployment
- **THEN** a `:stream` `NotificationProvider` row SHALL exist with `source: :first_party` and `managed: true`
- **AND** an operator edit to that row SHALL be preserved across an upgrade under the `template_fingerprint` reconciliation rules

### Requirement: Notification telemetry and service level indicators

The system SHALL emit telemetry for every dispatch decision and outcome,
including at minimum a dispatch-attempted signal, a dispatch-succeeded signal, a
dispatch-failed signal, and a dispatch-suppressed signal, each carrying the
channel id, provider key, provider type, execution route, escalation step number,
and, for failures and suppressions, the `error_class` or `suppression_reason`.

The system SHALL measure and expose:

- End-to-end dispatch latency from alert fire time to first `:sent` delivery.
- Acknowledgement latency from first `:sent` delivery to the first accepted
  acknowledgement.
- Per-channel error rate and per-channel suppression rate over a rolling window.
- Retry counts, failover counts, and escalation-step counts as separate series,
  consistent with the requirement that the three mechanisms are not conflated.

Telemetry payloads SHALL contain no secret material and no unredacted alert
content.

#### Scenario: Failed dispatch emits a classified signal

- **WHEN** a dispatch fails with an HTTP 500
- **THEN** a dispatch-failed telemetry event SHALL be emitted
- **AND** it SHALL carry the channel id, provider key, execution route, and `error_class`

#### Scenario: Suppression is measurable per reason

- **WHEN** dispatches are suppressed across a window
- **THEN** the suppression rate SHALL be queryable broken down by `suppression_reason`

#### Scenario: Acknowledgement latency is recorded

- **GIVEN** an alert whose first delivery reached `:sent` at t0 and which was acknowledged at t1
- **WHEN** the acknowledgement is accepted
- **THEN** the system SHALL record an acknowledgement latency of t1 minus t0

#### Scenario: Telemetry carries no secrets

- **WHEN** any notification telemetry event is emitted
- **THEN** its metadata SHALL contain no resolved secret value and no unredacted alert content

### Requirement: Legacy webhook notification path is retired and migrated

The alert path SHALL NOT invoke `ServiceRadar.Monitoring.WebhookNotifier`. All
outbound notification delivery SHALL go through the notification platform
described in this specification, and no code path SHALL remain that reaches a
destination without producing a `NotificationDelivery` row.

The following SHALL be removed as part of this change:

- `ServiceRadar.Monitoring.WebhookNotifier` and its `%WebhookNotifier.Alert{}`
  struct, together with its call sites.
- The unused `webhooks:` configuration block in the Helm config file, which is
  read by nothing.
- `WebhookConfig` and `CloudConfig` in `go/pkg/models/config.go`.
- `ServiceRadar.Identity.Senders.EmailDelivery`, whose behaviour SHALL be folded
  into the platform's outbound mail path.

Existing webhook configuration SHALL be migrated, not dropped. Each configured
webhook SHALL become a `NotificationChannel` bound to the `generic_webhook`
`:native` provider, with its URL carried as channel configuration and any secret
material expressed as `secret_refs`. Migration SHALL be performed by an Elixir
migration or a documented one-time migration task, and SHALL be idempotent.

A migrated channel SHALL be subject to
`Palisade.OutboundURLPolicy.validate_https_public_url/2` like any other
`:control_plane` channel. A legacy webhook URL that fails that policy SHALL be
migrated in a `enabled: false` state with a recorded diagnostic rather than
silently discarded, so an operator can see and repair it.

#### Scenario: No alert path reaches the legacy notifier

- **WHEN** an alert fires and produces notifications
- **THEN** `ServiceRadar.Monitoring.WebhookNotifier` SHALL NOT be invoked
- **AND** every destination reached SHALL have a corresponding `NotificationDelivery` row

#### Scenario: Configured webhooks become native channels

- **GIVEN** a deployment with webhook entries in its legacy configuration
- **WHEN** the migration runs
- **THEN** each entry SHALL produce a `NotificationChannel` bound to the `generic_webhook` `:native` provider
- **AND** re-running the migration SHALL NOT create duplicate channels

#### Scenario: Non-conforming legacy URL is surfaced, not dropped

- **GIVEN** a legacy webhook whose URL is plain HTTP to a private address
- **WHEN** the migration runs
- **THEN** a channel SHALL be created with `enabled: false` and a recorded diagnostic naming the policy rejection
- **AND** the channel SHALL NOT dispatch until an operator repairs and enables it

#### Scenario: Dead configuration and structs are gone

- **WHEN** the repository is inspected after this change
- **THEN** the `webhooks:` Helm config block, `go/pkg/models/config.go` `WebhookConfig` and `CloudConfig`, and `ServiceRadar.Identity.Senders.EmailDelivery` SHALL be absent
- **AND** no remaining caller SHALL reference them
