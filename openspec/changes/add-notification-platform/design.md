# Design: Notification Platform

## Context

ServiceRadar has **no working notification delivery today**. This is not a
degraded capability; it is a non-functional one:

- `ServiceRadar.Monitoring.WebhookNotifier` is never started by any supervisor
  in the repository. `send_alert/1` catches `:exit, {:noproc, _}` and returns
  `{:error, :not_running}`
  (`elixir/serviceradar_core/lib/serviceradar/monitoring/webhook_notifier.ex:129`).
- `Alert.send_notification` is an explicit `# TODO` stub that logs and
  increments a counter
  (`elixir/serviceradar_core/lib/serviceradar/monitoring/alert.ex:314`).
- The `webhooks:` block in `helm/serviceradar/files/serviceradar-config.yaml:311`
  is read by nothing.
- `ServiceRadar.Monitoring.Alert` already exposes `acknowledge`, `resolve`,
  `escalate`, `suppress`, and `reopen` actions plus an RBAC permission
  (`observability.alerts.manage`, described verbatim as "Acknowledge and resolve
  alerts") with **zero user interface**. The only reachable acknowledgement is
  `PATCH /api/v2/alerts/:id/acknowledge`.

The scheduling substrate, by contrast, already exists and runs: the AshOban
trigger `:send_notifications` on `alert.ex:128-137` executes every minute
against the declared `:notifications` Oban queue (`config.exs:36`). The wiring
is present; the body was never written.

This change builds the platform that body dispatches into.

## Goals / Non-Goals

### Goals

- Restore working outbound notification delivery, with durable retry and a
  per-attempt audit record.
- Provide routing from alerts to channels with predicate matching, fan-out,
  time-based escalation gated on acknowledgement, and transport failover.
- Make notification providers extensible **without modifying the ServiceRadar
  codebase**, for the common case, via uploadable declarative channel
  definitions.
- Provide a full escape hatch (signed Wasm plugins) for providers that
  declarative templating cannot express, including site-local egress.
- Make the system two-way: acknowledge, snooze, resolve, and suppress from the
  notification itself, not only from the web UI.
- Make suppression **enumerable and auditable**: every notification that is not
  sent leaves a record explaining why.
- Expose the notification stream as an authenticated, RBAC-scoped subscription.

### Non-Goals

These are deliberately excluded. They are the parts of an incident-response
product that ServiceRadar should *integrate with* rather than reimplement:

- **On-call rotation calendars, shift handoffs, and override management.**
  v1 ships simple recurring schedules (business hours / after hours), not
  rotations.
- **Mobile push with retry-until-acknowledged.** That is PagerDuty and Opsgenie;
  ship first-class providers for both instead.
- **Incident timelines, postmortems, and stakeholder status pages.**
- **Per-user contact-method preference management** beyond a channel's own
  configuration.
- **A second Wasm host runtime.** See "Rejected: server-side Wasm host".
- **Multitenancy.** ServiceRadar is single-deployment. `partition_id` is the
  only scoping dimension and it is mTLS-derived and force-bound server-side
  (`plugins/changes/bind_assignment_partition.ex:15`), never operator-supplied.

## Decisions

### D1. The decision engine is Elixir and is not pluggable; only the transport is

Two concerns are routinely conflated in notification systems and want opposite
treatment:

1. **The decision engine** - deduplicate, route, fan out, escalate, suppress,
   track, and close the loop on acknowledgement. This is the product-defining
   part. It is one Elixir state machine in `serviceradar_core`, next to
   `ServiceRadar.Monitoring.Alert`, so that the alert state transition, the
   audit row, and the delivery record commit in the same transaction. **Nothing
   plugs into it.**

2. **The transport** - take a rendered payload and get it to a destination.
   Boring, high-fan-out, and exactly where an ecosystem pays. **This is the
   plugin boundary.**

The plugin boundary is therefore the *provider contract*, not the runtime.

### D2. Three extensibility tiers behind one contract, plus the built-in `:stream` provider

Every provider implements the `ServiceRadar.Notifications.Transport` behaviour,
whose callbacks are `deliver/2`, `validate_config/1`, `capabilities/0`, and
`test/2`. Routing, escalation, deduplication, suppression, and acknowledgement
never learn which tier a channel uses.

| `provider_type` | Extensibility tier? | Implementation | How a new provider is added |
| --- | --- | --- | --- |
| `:native` | yes | Elixir module, allowlisted | In-tree change + release |
| `:declarative` | yes | HTTP request template document | **Upload a file in the UI. No code, no release.** |
| `:wasm_plugin` | yes | Signed OCI bundle on the existing wazero host | Publish a signed plugin package |
| `:stream` | no - built in | Envelope publish to a JetStream subject and an RBAC-scoped Phoenix Channel | Not authorable; ships seeded (D10) |

There are therefore exactly **three extensibility tiers** - `:native`,
`:declarative`, and `:wasm_plugin` - **plus the built-in `:stream` provider
type**. `:stream` is a `provider_type` but is not an extensibility tier, because
operators cannot author one. Its `NotificationProvider` row is seeded as a
first-party managed provider alongside `slack`, `discord`, `webhook`, and
`email`, using the same `managed` / `template_version` / `template_fingerprint`
reconciliation as the others.

`test/2` is not optional. Every provider in every tier implements a test action
and declares `test` in its `capabilities`, so "test-send before saving" works
uniformly; a manifest that declares `capabilities` without both `send` and
`test` is rejected by the manifest validator.

`:declarative` is the tier that answers the extensibility requirement for the
common case. Approximately 85% of notification destinations are "POST this JSON
body to this URL with these headers". Mattermost, Rocket.Chat, Telegram, Gotify,
ntfy, Zulip, Google Chat, Opsgenie, ServiceNow, Jira, Microsoft Teams, Twilio,
and PagerDuty Events API v2 are all expressible this way. Alertmanager and
Grafana both hardcoded their receiver list and cannot accept a community
receiver without a release; this design avoids that.

A first-party seeded `:declarative` catalog ships with the change, so the tier is
demonstrably usable without writing code. Those destination names are examples of
what the catalog may contain, not a closed list, and every seeded entry is
individually disablable by an operator.

`:wasm_plugin` then narrows to what genuinely needs code: request signing, OAuth
exchanges, non-HTTP transports, payload transforms templating cannot express,
and **site-local egress** to a destination reachable only from inside the
customer network.

Rationale for keeping `:native` at all: the four launch providers must work on
day one with no packaging pipeline, and `:native` is the ultimate floor if both
the plugin host and an uploaded definition are unavailable.

### D3. Execution route is a field on the channel, not an architecture

`NotificationChannel.execution_route` is `:control_plane` (default) or
`:edge_agent`.

- `:control_plane` + `:native` -> Elixir transport, direct call.
- `:control_plane` + `:declarative` -> Elixir HTTP engine, guarded by
  `Palisade.OutboundURLPolicy.validate_https_public_url/2`
  (resolved at compile time to `ServiceRadar.Policies.OutboundURLPolicy` (the in-tree port; note `Palisade` is NOT a dependency of `serviceradar_core`, so `Palisade.OutboundURLPolicy` is undefined there)).
- `:control_plane` + `:wasm_plugin` -> `AgentCommandBus.dispatch/4` to the
  **platform-resident** `serviceradar-agent` that already ships
  (`helm/serviceradar/templates/agent.yaml:40`), using the same
  `plugin.run_action` command as any edge dispatch.
- `:edge_agent` + any plugin provider -> `AgentCommandBus.dispatch/4` to the
  named site agent.

This yields exactly **one** Wasm host implementation in the product. A plugin
authored for the edge runs unchanged on the platform agent because it is the
same binary in the same runtime. Relocating a channel from platform egress to
site egress is a data edit plus a `PluginAssignment`, not a repackage.

#### The offline-site problem is the binding constraint

`ServiceRadar.Edge.AgentCommandBus` is **at-most-once with no store-and-forward**.
`dispatch_created_command/2` resolves the control session synchronously; with no
session it marks the row `offline` and returns `{:error, {:agent_offline,
agent_id}}` (`agent_command_bus.ex:204-225`). Nothing re-drains queued or
offline commands on reconnect - the only reconnect hook is release
reconciliation (`agent_gateway_server.ex:1797-1800`).

Therefore an `:edge_agent`-only configuration makes the single most important
page - *this site went dark* - undeliverable by construction, because core is
the component that detects the darkness.

Mitigations, all normative:

1. Every channel may declare `fallback_channel_id`. On
   `{:error, {:agent_offline, _}}` the delivery fails over unless the channel is
   explicitly marked `fail_closed`.
2. The UI **warns** when an escalation policy's only reachable route is an
   `:edge_agent` bound to the same `partition_id` as the alert source. That is
   the configuration that silently guarantees no page exactly when one is owed.
3. The control-plane route is the default and the documented recommendation.
   `:edge_agent` is for destinations unreachable from the platform.

#### The delivery row is always the system of record

The agent command result is a **wake-up signal only**. This mirrors the pattern
documented verbatim at
`elixir/serviceradar_core/lib/serviceradar/automation/ansible/callback_command_result_coordinator.ex:1-10`:
the terminal database row is the truth, the PubSub/command result merely wakes
the reconciler, and a bounded periodic scan recovers whatever the signal missed.

This matters because `ServiceRadar.AgentCommands.StatusHandler` - the only thing
that durably persists command acks, progress, and results - is a coordinator
singleton gated on `:status_handler_enabled`, **default `false`**
(`cluster/coordinator_children.ex:96-113`). With stock configuration an edge
delivery would otherwise leave no record at all. This change requires either
enabling that flag or shipping a poll-based reconciler; `ActionInvocationTarget`
already ships a `:poll_due` read plus a `list_poll_due` code interface with zero
callers, which is a ready-made reconciler shape.

### D4. Retry, failover, and escalation are three distinct mechanisms

Conflating transport failure with human non-acknowledgement is the most common
design error in homegrown notification systems. Zabbix conflates them; PagerDuty
separates them.

| Mechanism | Level | Trigger | Bounded by |
| --- | --- | --- | --- |
| **Retry** | Transport | 5xx, timeout, 429 | `max_attempts`, Oban backoff |
| **Failover** | Transport | Retries exhausted, or agent offline | One hop to `fallback_channel_id` |
| **Escalation** | Human | Step delay elapsed **and** alert still unacknowledged | Policy step count, `repeat_count` |

Fan-out is orthogonal to all three: an escalation **step** holds a **set** of
channels.

```
Step 1  t+0     -> [Slack #noc, Email noc@]          fan-out
Step 2  t+5m    -> [PagerDuty]           if unacked  escalation
Step 3  t+15m   -> [PagerDuty P1, SMS]   if unacked
```

#### Retry keeps a delivery `:pending`; `:failed` is terminal

`max_attempts` is an attribute of `NotificationChannel`, defaulted from the
provider. A retry-eligible delivery stays in `:pending` with `next_attempt_at`
set; it does not pass through `:failed` and come back. Only a **non-retryable**
failure, or exhaustion of `max_attempts`, moves a row to `:failed`, and `:failed`
is **terminal**.

Retry-due selection therefore reads `:pending` rows with
`next_attempt_at <= now()` and `attempt_count < max_attempts`. It MUST NOT select
`:failed` rows - a scan that picks up `:failed` retries forever and defeats the
attempt bound.

Failover is the one hop taken when a delivery reaches `:failed` (or immediately
on `{:error, {:agent_offline, _}}`) and the channel is not `fail_closed`. The
successor delivery carries `originating_delivery_id` pointing back at the row
that failed, so the Delivery Log shows the failover chain rather than two
unrelated attempts.

#### Escalation delay is measured from alert fire time

`NotificationEscalationStep.delay_seconds` is measured from the **alert fire
time**, never from the previous step's dispatch. Chaining delays off the previous
dispatch makes total time-to-page depend on transport latency and retry
behaviour, so an escalation policy no longer means what its author read.

There is exactly **one** exception: after a snooze expires, the remaining step
delays are measured from the **snooze expiry instant**. Snoozing is an explicit
operator statement that the clock should restart.

### D5. Suppression is enumerable, auditable, and re-evaluated at dispatch

A notification that is not sent MUST leave a `NotificationDelivery` row with
`state: :suppressed` and a `suppression_reason`. Silent drops are prohibited.
An operator must always be able to answer "why was I not paged?" - the question
Zabbix and Nagios answer poorly.

Suppression sources evaluated by `ServiceRadar.Notifications.Suppression`:

| Reason | Source |
| --- | --- |
| `:device_out_of_service` | Subject device `is_active == false` (`inventory/device.ex:558`) |
| `:silence` | An active `NotificationSilence` whose matchers match |
| `:schedule` | Outside the route's `NotificationSchedule` window |
| `:snoozed` | Alert snoozed until a future timestamp |
| `:throttled` | Route `throttle_seconds` / rule `cooldown_seconds` |
| `:acknowledged` | Alert acknowledged; escalation halted |
| `:channel_disabled` | Channel disabled or provider deactivated |
| `:no_matching_route` | The alert matched zero enabled `NotificationRoute` rows |
| `:dependency` | Reserved. Parent device/agent/gateway down (see Future Directions) |

`:no_matching_route` is the reason that makes the **unrouted** alert visible.
Without it, an alert nobody configured a route for is the one case that silently
produces nothing, which is exactly the failure operators cannot debug. An
unrouted alert is recorded through the same audit path as every other withheld
notification and is queryable in the Delivery Log alongside them.

Three properties are load-bearing:

1. **Re-evaluation at dispatch, not only at routing.** An escalation step firing
   fifteen minutes after the alert MUST re-run suppression, because the device
   may have been marked out of service in the interim.
2. **Defense in depth for device state.** `openspec/changes/add-device-active-lifecycle`
   already owns suppressing device-scoped *event and alert generation* for
   inactive devices, and this change does not duplicate that. The notification
   layer re-checks anyway, because two alert-creation paths bypass the stateful
   engine entirely and create alerts with no deduplication:
   `LogPromotion.update_alert_counts/2` (`log_promotion.ex:711-717`) and
   `TrivyReports.maybe_create_priority_alert/3` (`trivy_reports.ex:992`).
3. **Recorded once per distinct decision, not once per evaluation.** Every
   dispatch decision that withholds a notification is recorded - there are no
   silent drops - but a repeat of an *identical* decision does not insert a
   duplicate row. Identity is
   `{alert_id, policy_id, step_number, channel_id, dedupe_key, suppression_reason}`;
   a repeat increments an occurrence counter and refreshes `last_evaluated_at` on
   the existing row. This is what keeps "record everything" from turning a
   long-lived silence into unbounded table growth, while still letting an
   operator see both *why* and *how often*.

### D6. Deduplication consumes the existing incident identity; it does not invent one

`openspec/specs/observability-signals/spec.md:446` already mandates that
duplicate event bursts must not each trigger an immediate notification attempt,
and `:108` already owns cooldown and renotify semantics.

The incident identity is the composite `{rule_id, group_key}`, where `group_key`
is `"field=value|field=value"` derived from `StatefulAlertRule.group_by`, made
unique by `stateful_alert_rule_states_unique_state_index`
(`stateful_alert_rule_state.ex:125`). Occurrence counters already live in
`alerts.metadata` under `incident_*` keys, written by
`AlertLifecycle.merge_incident_metadata/5` (`alert_lifecycle.ex:164`).

The notification platform **consumes** `cooldown_seconds`, `renotify_seconds`,
and the `{rule_id, group_key}` identity. It does not re-author them. A route may
supply a `dedupe_key_template` override for cases the rule grouping does not
cover.

#### Cadence precedence: the rule is the floor

Two cadence knobs now exist for the same incident, so their precedence is fixed
rather than left to whichever code path runs last.
`StatefulAlertRule.renotify_seconds` is the **floor**.
`NotificationEscalationPolicy.repeat_interval_seconds` may only make repeats
**less** frequent, so it MUST be `>= renotify_seconds`; a policy configured below
the floor is rejected at save time with an actionable message rather than
silently clamped. Likewise a route may only **narrow** the rule's cadence, never
widen it. The rule owns how noisy an incident is allowed to be; notification
configuration can only be quieter.

#### Routing requests are idempotent

The routing request emitted for an incident is keyed by
`{alert_id, lifecycle_reason, step_number, dedupe_key}`. Re-emitting the same
tuple - a duplicate lifecycle callback, an Oban retry, a scheduler tick that
overlaps the previous one - resolves to the existing work rather than a second
dispatch. `lifecycle_reason` is the field name; it records *why* the lifecycle
emitted (fire, renotify, escalate, resolve), which is what distinguishes two
otherwise identical requests for the same alert and step.

### D7. Acknowledgement ingress: signed capability links first, native interactivity second

**Phase 1 - signed action links.** Every rendered notification carries
`Acknowledge`, `Snooze 1h`, and `Resolve` links bearing a per-delivery
capability token. This works for email, Slack, Discord, generic webhook, and
every declarative provider with **zero per-provider code**. Tokens are minted
per delivery, persisted as sha256 only, TTL-bounded, and single-use per action.
A `Snooze` action records `snooze_until` on the alert, and it is `snooze_until`
everywhere - the resource attribute, the acknowledgement record, and the UI.

**The `:stream` provider is exempt from the action-link requirement.** A
capability token is a single-use credential scoped to one delivery, and the
firehose is a broadcast to every subscriber authorised for the topic; embedding
one there hands an acknowledgement credential to every listener at once. Stream
envelopes therefore carry alert and delivery identifiers that a subscriber
resolves through the authenticated API, never an action link. This exemption
applies wherever action links are otherwise required.

**The exemption covers interactive controls too, and this is not automatic.** A
Slack Block Kit button carries `action_id` (not `action`) inside
`blocks[].elements[]`, and a Discord component carries `custom_id` inside
`components[].components[]`. Neither is URL-shaped and neither key appears in a
denylist written for Phase 1 links, so a guard built only for signed links passes
a live control straight through to every subscriber while the envelope still
looks clean - no token, no URL, nothing a reviewer would spot. The stream
transport's guard is therefore **structural** (drop any entry carrying
`action_id`/`custom_id`, or any block of `"type": "actions"`), not another list
of key names, because the names that matter belong to the provider rather than to
us.

**Phase 2 - native interactive components.** Slack Block Kit buttons, Discord
message components, and PagerDuty acknowledgement webhooks.

**AMENDED after verification against the providers and the codebase.** This
paragraph previously said Phase 2 would "reuse the northbound callback stack
verbatim: token from header/Bearer/body, sha256-only persistence,
`Edge.Crypto`-encrypted HMAC secret, verification via `Plug.Crypto.secure_compare`
plus HMAC-SHA256 over `<timestamp>.<raw_body>` with a 300 s tolerance". That is
not achievable, and pretending otherwise would tick a checkbox against a
requirement nobody met:

- The northbound stack is **token-primary, signature-secondary**
  (`command_result_handler.ex:174-186` rejects unless a bearer token matches
  `callback_token_hash`; the HMAC is a second, optional factor). **Slack and
  Discord present no token of ours at all** - they POST to a URL we register with
  them - so the primary factor has no referent for two of the three providers.
- Each provider signs its own way. Slack: HMAC-SHA256 hex over
  `"v0:" <> ts <> ":" <> body`, prefix `v0=`. Discord: **Ed25519 over
  `ts <> body`**, which has no digest, so `Plug.Crypto.secure_compare/2` is not
  merely different here, it is **inapplicable**; the stored material is a
  *public* key, not a secret. PagerDuty: HMAC-SHA256 over the **body alone**,
  prefix `v1=`, comma-separated list, and **no timestamp header at all**, so a
  300 s tolerance is structurally impossible and replay defence must move to
  `event.id` dedupe.
- Do not import `command_result_handler.ex:172-207`'s auth-mode enum: it maps
  `nil | :token` to `:ok`, which in a tokenless context means "no signature
  header implies authorised".

**The revised contract.** A `ServiceRadar.Notifications.Callbacks.Signature`
behaviour with one module per provider, over a shared primitives module. Genuinely
reused from northbound: `RawBodyReader`, `Plug.Crypto.secure_compare/2` with its
`byte_size` pre-check, the `abs()` skew comparison, the 300 s tolerance constant,
and sha256-only persistence of any token we do mint. The
`<timestamp>.<raw_body>` base string and the `sha256=` prefix are **northbound-only
and must not be copied**. `command_result_handler.ex` is left untouched.

**PagerDuty is the one provider where the literal token half IS achievable**, and
it should be taken: we create its subscription ourselves via
`POST /webhook_subscriptions`, whose HTTP delivery method accepts operator-supplied
custom headers. ServiceRadar can mint a callback token, persist only its sha256,
have PagerDuty present it as `Authorization: Bearer <token>`, and compare with
`Plug.Crypto.secure_compare/2`. That is not redundant with the `v1=` HMAC: the
HMAC proves PagerDuty sent it, the token binds the request to *this* subscription.

**Feasibility, verified against the shipped transports:**

- **Slack works today**, in both `incoming_webhook` and `bot_token` modes. A Slack
  incoming webhook is issued to an installed Slack app, so Block Kit buttons
  posted through it do generate interactions to that app's Request URL. The real
  constraints are different: Slack answers a webhook with the literal body `ok`,
  so `external_correlation_id` is never set and message rewrite must go through
  `response_url`; and nothing in the webhook URL identifies the app, so
  `api_app_id` and the signing-secret ref must be explicit channel config and the
  callback must select the secret by `payload.api_app_id`, never by channel id.
- **Discord interactive components are NOT feasible with the current credential
  model** and are deferred to their own change. `transports/discord.ex` stores a
  pasted `webhook_url`: a user-owned Type 1 incoming webhook with
  `application_id: null`. Discord ignores components on those, and there is no
  application for it to route a MESSAGE_COMPONENT interaction to. Buttons require
  a registered Discord Application plus a per-guild OAuth install - an onboarding
  change, not a rendering change. The refusal is **silent**: Discord returns
  200/204, the message posts without buttons, and the transport records success.
  Discord therefore stays on Phase 1 links and must NOT advertise an interactive
  capability.
- **PagerDuty inbound needed an architectural decision, and the decision is: do
  NOT promote it to a native transport.** The blocker was misstated. What the
  declarative tier forbids is a *provider document* declaring an
  `inbound_callback` capability (`declarative/definition.ex`); it says nothing
  about the platform owning an endpoint. The callback path built for Slack is
  already platform-level and tier-agnostic - the controller dispatches on a
  closed provider map and never consults `provider_type` - so PagerDuty slots
  into `Notifications.Callbacks` exactly as Slack did, and the declarative entry
  stays, because it serves outbound well. Promoting it would have rewritten a
  working outbound path to gain nothing.

  Three PagerDuty specifics the implementation turns on. It signs the **body
  alone** - no timestamp, no separator, no prefix in the signed material - so
  neither the northbound `<ts>.<body>` scheme nor Slack's `v0:<ts>:<body>`
  transfers. `X-PagerDuty-Signature` carries a **comma-separated list** for
  secret rotation, any element may match, and elements that are not `v1=` are
  skipped rather than rejected so a future `v2=` does not take the integration
  down. And there is **no transport-level replay defence**, because the only
  clock is `event.occurred_at` inside the signed body: bounding it does limit
  replay, but the bound must be wider than PagerDuty's own ~20 minute retry span
  or its legitimate retries are rejected and the subscription is disabled.

  Correlation is direct: `event.data.incident_key` is the `dedup_key` we sent,
  and the shipping document sets that to the alert id. The signing secret is
  scoped per **webhook subscription**, named by `X-Webhook-Subscription`, so it
  resolves through the same `NotificationCallbackApp` registry with the
  subscription id as `external_app_id`.

  Two limits are permanent rather than deferred: **snooze can never round-trip**
  (there is no `incident.snoozed` event in the v3 catalogue), and
  `incident.unacknowledged` / `incident.reopened` have **no inverse** in
  `apply_native/2`. Both are refused explicitly rather than ignored, because
  subscribing to an event whose handler silently drops it is how an operator
  concludes an integration works when half of it does not.

`ServiceRadarWebNGWeb.Api.RawBodyReader` buffers raw bodies **only for registered
path prefixes**. `/api/notifications/callbacks/` is now registered alongside
`/api/northbound/action-callbacks/` (`raw_body_reader.ex`). Skipping such a
registration does not fail loudly; it verifies against a re-encoded body and
breaks signatures for exactly the providers that sign bytes. Two further traps
follow from that: the prefix match is `String.starts_with?`, so a bare
`/api/notifications/callbacks` (no trailing slash) is **not** buffered; and a
verifier that defaults a missing raw body to `""` computes a signature over the
empty string and returns an indistinguishable 401. The notification verifier
takes the raw body as a required argument and fails loudly when it is absent.

**Actor identity.** `alerts.acknowledged_by` and `resolved_by` are free-text
strings with no foreign key. This change adds `acknowledged_by_user_id` as a
real FK to `ServiceRadar.Identity.User` while retaining the string column for
external principals, and records the distinction explicitly on
`NotificationAcknowledgement.actor_kind`
(`:platform_user | :external_principal | :system`).

### D8. Reuse the northbound mechanisms; do not reuse its tables

`elixir/serviceradar_core/lib/serviceradar/automation/northbound/` already
contains a production, provider-neutral outbound stack with a mature invocation
state machine, redaction policy, HMAC callbacks, and schema-driven config forms.

**Reuse**: the callback endpoint and token/HMAC scheme, `ActionRedaction`
(policy `northbound-action-redaction-v1`, `action_redaction.ex:11-32`), the Oban
poll/deadline worker shape (`poll_worker.ex:6-14`), the invocation state
vocabulary, and the `ServiceRadarWebNGWeb.PluginConfigForm` schema-driven
renderer
(`elixir/web-ng/lib/serviceradar_web_ng_web/components/plugin_config_form.ex:1`).

**Do not reuse the tables**: `ActionInvocationTarget` is device- and
interface-shaped throughout (`device_uid`, `interface_uid`, `target_snapshot`)
and `ActionScope` is hard-restricted to `device | interface | event` in three
independent places. A recipient or a channel is not a target; forcing it in
produces a bad schema. `NotificationChannel` and `NotificationDelivery` are
**sibling** resources shaped like `ActionProvider` and `ActionInvocation`.

Also: `ActionEventHandler` fires from the `Monitoring.OcsfEvent` `:record`
after-action hook **synchronously on every recorded OCSF event**, with no
batching and no backpressure (`monitoring/ocsf_event.ex:96,132-146`). Notification
dispatch must **not** live on that path; it triggers from the alert lifecycle.

#### What emits routing requests, and what only continues them

The trigger rule has two parts, and they are not interchangeable.

1. `AlertLifecycle` is the **only** path that emits a routing request for a
   **new** incident notification. Nothing else may originate one, because the
   lifecycle is where incident identity, dedup state, and the alert row are
   already consistent.
2. The AshOban scheduler drives **continuation work only** - escalation-step-due,
   retry-due, and renotify - and always against deliveries that already exist. It
   never originates a first notification for an alert that has no delivery
   record.

Stating it as a single "only code path" rule is what breaks: it either forbids
the scheduler (killing escalation and retry) or licenses the scheduler to invent
first notifications (racing the lifecycle and double-paging).

### D9. Templating is restricted substitution, never code

Notification bodies and declarative request templates use a restricted
substitution engine: whitelisted variable paths plus a fixed filter set
(`upper`, `lower`, `truncate`, `json`, `url_encode`, `iso8601`, `default`). No
EEx, no arbitrary code, no `raw/1` on untrusted content.

This is required by the Iron Laws and reinforced by the manifest validator,
which already hard-rejects `html`, `raw_html`, `javascript`, `js`, `component`,
`component_ref`, `live_view`, `react`, and `ui_code` keys in action descriptors
(`plugins/manifest.ex:986-997`). Providers describe their UI declaratively via
JSON Schema and a display contract; they never ship markup.

### D10. The firehose is a provider, not a side door

A `:stream` provider publishes the canonical notification envelope to an
RBAC-scoped Phoenix Channel topic, gated by `notifications.stream.subscribe`.
"Drink from the firehose" therefore traverses the same routing, suppression,
redaction, and audit path as Slack, rather than being a parallel unaudited
egress.

Being on the same path means suppression applies to it identically. A suppressed
dispatch to a `:stream` channel publishes **no envelope** on that stream and
writes a `NotificationDelivery` row with `state: :suppressed`. The suppressed row
is not invisible - it is visible on a *different surface*: the **Delivery Log UI
displays suppressed rows with their `suppression_reason`** rather than omitting
them. Stream subscribers see what was sent; the Delivery Log answers "why was I
not paged?". Conflating the two would put withheld notifications back on the wire
under a different name.

It is backed by a new JetStream subject namespace so that reconnecting consumers
replay from a durable cursor instead of silently losing events. Note that
`events.alert` is a declared-but-dead constant with zero producers and consumers
(`nats/channels.ex:54`), and that **new subject namespaces are denied at the
broker** unless added to the per-CN publish/subscribe allowlists in
`helm/serviceradar/templates/nats.yaml:205-217`.

## Data Model

All tables live in the `platform` schema with `uuid_generate_v7()` primary keys,
created by Elixir migrations under
`elixir/serviceradar_core/priv/repo/migrations/`. The reference migration shape
is `20260515193000_create_northbound_action_tables.exs`.

### `NotificationProvider`

A *kind* of destination. First-party providers are seeded and reconciled across
releases using the `managed` / `template_version` / `template_fingerprint`
pattern from `ServiceRadar.Observability.PresetRuleResource` and
`rule_seeder.ex:312`, so operator edits are not clobbered by upgrades.

| Field | Notes |
| --- | --- |
| `provider_key` | `slack`, `discord`, `webhook`, `email`, `pagerduty`, ... |
| `provider_type` | `:native \| :declarative \| :wasm_plugin \| :stream` |
| `display_name`, `description`, `icon` | |
| `config_schema` | JSON Schema subset, validated by `Plugins.ConfigSchema` |
| `capabilities` | `[:send, :test, :resolve_update, :inbound_callback, :rich_payload, :attachments, :threading]`; `send` and `test` are mandatory |
| `supported_routes` | subset of `[:control_plane, :edge_agent]` |
| `payload_formats` | `[:slack_blocks, :discord_embed, :markdown, :plain, :html, :pagerduty_v2, :json]` |
| `default_max_attempts` | provider-supplied default for `NotificationChannel.max_attempts` |
| `version` | provider definition version, stamped onto each delivery it renders |
| `definition` | `:declarative` only - the request template document |
| `plugin_package_id`, `action_key` | `:wasm_plugin` only |
| `implementation_module` | `:native` only, resolved from a **compile-time allowlist**, never `String.to_atom/1` |
| `source` | `:first_party \| :uploaded \| :plugin` |
| `managed`, `template_version`, `template_fingerprint` | upgrade reconciliation |
| state | `:draft -> :active -> :disabled` |

`action_key` is not free text. It equals a `key` value in the `notifications:`
block of the referenced package's **validated** manifest, so
`{plugin_package_id, action_key}` resolves to exactly one declared notification
entrypoint. Saving a provider whose `action_key` names nothing in that manifest
is rejected rather than deferred to a dispatch-time "no such action" failure.

The `notifications:` block entry keys are owned by the manifest validator and
are: `key`, `display_name`, `description`, `entrypoint`, `config_schema`,
`capabilities`, `payload_formats`, `routes`, `credential_requirements`, and
`inbound`.

### `NotificationChannel`

A *configured instance* - "Slack #noc".

| Field | Notes |
| --- | --- |
| `name`, `provider_id`, `enabled` | |
| `config` | validated against the provider `config_schema` |
| `secret_refs` | `Plugins.SecretRefs`; resolved via `Credentials.SecretBroker` |
| `execution_route` | `:control_plane` (default) \| `:edge_agent` |
| `agent_uid`, `partition_id` | required when `:edge_agent`; partition force-bound server-side |
| `fallback_channel_id` | transport failover target, nullable |
| `fail_closed` | boolean; when true, never fail over |
| `max_attempts` | retry bound for deliveries on this channel; defaults from the provider's `default_max_attempts` |
| `rate_limit_per_minute` | shared, restart-surviving budget |
| `health`, `last_success_at`, `last_failure_at`, `last_error` | |

`max_attempts` lives on the **channel**, not on the provider or the route,
because it is a property of the destination an operator configured: a paging
channel and a chat channel backed by the same provider deserve different
patience. The provider supplies the default so a channel is usable without
tuning.

### `NotificationRoute`

Field set lifted from `ActionEventHandler:154-198`.

`name`, `enabled`, `priority`, `match_expression`, `escalation_policy_id`,
`dedupe_key_template`, `throttle_seconds`, `group_wait_seconds`,
`group_interval_seconds`, `schedule_id`, `continue`, AshPaperTrail.

`continue` carries Alertmanager semantics: when false, the first matching route
wins and evaluation stops.

### `NotificationEscalationPolicy` / `NotificationEscalationStep`

Policy: `name`, `repeat_count`, `repeat_interval_seconds`, `resolve_notifies`.
`repeat_interval_seconds` is validated at save time against the rule floor
described in D6.

Step: `step_number`, `delay_seconds`, `channel_ids` (many-to-many, the fan-out
set), `condition` (`:always | :if_unacknowledged`). `delay_seconds` is measured
from the alert fire time, with the snooze-expiry exception in D4.

### `NotificationSchedule`

`name`, `timezone`, `windows` (list of `{days, start_time, end_time}`), `mode`
(`:active_within | :active_outside`). Deliberately **not** rotations.

### `NotificationSilence`

`matchers`, `starts_at`, `ends_at`, `created_by_user_id`, `comment`, `state`
(`:scheduled | :active | :expired | :cancelled`), with an Oban expiry sweeper.

### `NotificationDelivery`

The system of record - one row per (alert x escalation step x channel).

State vocabulary copied from `ActionInvocationTarget`: `:pending`,
`:dispatching`, `:sent`, `:failed`, `:expired`, `:cancelled`, `:suppressed`,
`:skipped`.

Fields: `alert_id`, `route_id`, `policy_id`, `step_number`, `channel_id`,
`dedupe_key`, `attempt_count`, `max_attempts` (resolved from the channel at
creation), `next_attempt_at`, `originating_delivery_id`, `payload_format`,
`provider_version`, `is_test`, `external_correlation_id` (Slack `ts`, PagerDuty
`dedup_key`), `error_class`, `error_message`, `result_summary`,
`suppression_reason`, `occurrence_count`, `last_evaluated_at`,
`rendered_payload_digest`, `execution_route`, `agent_uid`, `command_id`,
`queued_at`, `started_at`, `finished_at`, `alert_snapshot`.

Four of those exist for reasons worth stating, because each answers a question
the log otherwise cannot:

- `originating_delivery_id` is the **failover back-reference**. Without it a
  failover looks like two unrelated deliveries and the log cannot show that the
  page eventually landed.
- `payload_format` is the format **actually rendered**, after negotiation
  against the channel's provider. A provider advertising several
  `payload_formats` otherwise leaves the log unable to say which one produced a
  given body, which is the first question when a payload renders wrong.
- `provider_version` records **which provider definition version rendered the
  row**. Declarative and uploaded definitions change under operators' hands; a
  delivery must be attributable to the definition that produced it.
- `is_test` marks deliveries produced by the test-send action. Test deliveries
  do **not** count toward any alert's delivery or notification counts, and they
  are visually distinguished in the Delivery Log. Un-flagged test sends corrupt
  exactly the counters operators use to judge notification volume.

`occurrence_count` and `last_evaluated_at` carry the repeat-suppression
collapsing described in D5.

`alert_snapshot` is required, not an optimisation:
`Jobs.AlertsRetentionWorker` hard-deletes resolved and suppressed alerts after a
default of **3 days**, so a delivery record outlives the alert it points at.
Deliveries carry their own, longer retention policy.

### `NotificationAcknowledgement`

`delivery_id`, `alert_id`, `action`
(`:acknowledge | :snooze | :resolve | :suppress | :unacknowledge`), `actor_kind`,
`actor_user_id`, `external_principal`, `note`, `snooze_until`, `source`
(`:ui | :api | :callback | :action_link`), `received_at`.

### `NotificationTemplate`

Fields: `alert_class`, `payload_format`, `provider_key` (nullable, for a
provider-specific override), `subject_template`, `body_template`, `managed`,
`template_version`, `template_fingerprint`.

Rendering is keyed by **(alert class x payload format)**. That is the pairing
that actually determines the output: the same incident renders as Slack blocks,
a plain-text email body, and a PagerDuty v2 payload, and a capacity alert and a
device-down alert want different words in each. Keying on the provider alone
would force every provider to re-author every alert class; keying on the alert
class alone would emit Markdown into a JSON field.

First-party defaults ship **managed**, seeded and reconciled with the same
`managed` / `template_version` / `template_fingerprint` pattern used by
`NotificationProvider` and `PresetRuleResource`. An upgrade advances a managed
template only when its fingerprint still matches what shipped; once an operator
edits a template, their override is preserved and the upgrade leaves it alone
rather than silently restoring the default wording an on-call team has learned to
read.

## Alert Lifecycle Changes

- Snooze is a plain `update :snooze` action that sets a new `snooze_until`
  timestamp. It is deliberately **NOT** a state-machine state. The machine
  (`alert.ex:90-104`) declares `state_attribute :status` with states
  pending/acknowledged/resolved/escalated/suppressed and transitions
  `acknowledge`, `resolve`, `escalate`, `suppress`, `reopen`; there is no state
  a `:snooze` transition could target. "Snoozed" is a **derived** condition -
  `status in [:pending, :escalated] and snooze_until > now()`.

  Rationale: adding a `:snoozed` state would force an audit of every existing
  `status` renderer, filter, and read action (`alert.ex:162-200`) for the new
  value, whereas the derived form keeps snooze-expiry resumption a pure
  timestamp comparison.
- Generalise `read :needs_notification` (`alert.ex:188-200`) to first-notify
  only. It currently filters `notification_count == 0`, so it fires exactly
  once per alert and can never drive renotify, escalation, or retry.

  Continuation work - retry-due, escalation-step-due, and renotify - is keyed on
  **deliveries**, not alerts, so it cannot be driven from an alert-keyed scan. A
  second, delivery-keyed scheduler on the same `:notifications` queue is
  therefore explicitly sanctioned; the two are not redundant because they select
  over different tables.
- Implement `update :send_notification` (`alert.ex:314`) to **enqueue routing**,
  not to deliver inline.
- Add `acknowledged_by_user_id` as a real FK alongside the existing free-text
  column.

## Security

- Operator-supplied outbound URLs MUST pass
  `Palisade.OutboundURLPolicy.validate_https_public_url/2` - HTTPS-only,
  public-IP-only SSRF guard. `WebhookNotifier` does not do this today; the
  replacement must.
- Secrets MUST NOT enter Wasm guest memory or `params_json`. Use
  `CredentialBrokerGrant` with host-side injection
  (`go/pkg/agent/plugin_runtime_actions.go:308-356`) or the trusted-host-only
  proto field `host_params_json` (`proto/monitoring.proto:615-623`). Resolution
  goes through `Credentials.SecretBroker`, never `Vault.decrypt!` directly.
- Every notification payload and log line passes `ActionRedaction`
  (`northbound-action-redaction-v1`) before persistence or display.
- A new `notify:v1` capability is added to `@allowed_capabilities`
  (`plugins/manifest.ex:61-83`) **and** enforced by a `hasCapability` check in
  `go/pkg/agent`. A capability declared only in Elixir is unenforced at runtime;
  `advisory-feed:v1` and `producer-schedule:v1` are existing examples of that
  defect and this change must not add a third.
- Capability narrowing is mandatory: what reaches the agent is
  `effective_capabilities` / `effective_permissions` / `effective_resources`
  computed from package approval then assignment override
  (`edge/agent_config_generator.ex:1848-1877`).

### RBAC

Notifications get a **top-level `notifications` section** in
`Identity.RBAC.Catalog`, using the existing three-part
`<section>.<noun>.<verb>` convention that `observability.alerts.manage` already
follows. Nine keys:

| Key | Grants |
| --- | --- |
| `notifications.channels.view` | Read channels and their health |
| `notifications.channels.manage` | Create, edit, disable channels |
| `notifications.routes.view` | Read routes, escalation policies, schedules |
| `notifications.routes.manage` | Edit routes, escalation policies, schedules |
| `notifications.providers.manage` | Upload, version, enable, disable providers |
| `notifications.deliveries.view` | Read the Delivery Log, including suppressed rows |
| `notifications.test.send` | Test-send from a channel |
| `notifications.silences.manage` | Create, edit, cancel silences |
| `notifications.stream.subscribe` | Subscribe to the `:stream` firehose topic |

Notifications are their own product surface, not a sub-feature of
observability - they route alerts but they also carry credentials, egress
configuration, and an authenticated firehose, so they get a section rather than
being buried under `observability.*`.

### Slack and Discord incoming-webhook URLs

Slack and Discord incoming-webhook URLs carry the secret **in the URL path**,
and no credential-injection mode rewrites a path. The supported modes are
`http_header`, `bearer_token`, `basic_auth`, `query`, `form_urlencoded`, and
`oauth2_password_bearer` (`plugin_runtime_actions.go:317-355`); every one of
them writes a header, a query parameter, or a body field, and none rewrites the
path.

Resolution: on the `:control_plane` route this is a non-issue, because the URL
is channel configuration resolved by `SecretBroker` in Elixir. On the
`:edge_agent` route, such channels either use the bot-token API
(`chat.postMessage` with `bearer_token`, fully supported today with no host
change) or carry the webhook URL through `host_params_json`. Adding a
URL-path injection mode is explicitly out of scope for v1.

## Rejected Alternatives

### Rejected: a second, server-side Wasm host in core

Standing up a Rustler/wasmtime NIF or a Go sidecar so plugins execute centrally
without an agent would require reimplementing the entire guest ABI a second
time: 27 host functions exported into module `env`
(`go/pkg/agent/plugin_runtime_execution.go:94-177`), the ptr/len guest-memory
convention, the `pluginErr*` return codes, per-call capability gating,
domain/port allowlists, redirect suppression on credential-bearing requests, TLS
trust, and credential injection - two implementations that must stay
behaviourally identical forever. That is precisely the parallel-implementation
failure mode `AGENTS.md` bans for the anomaly detector.

It also buys nothing, because a platform-resident `serviceradar-agent` pod
already *is* a central wazero host and already ships.

### Rejected: edge-only execution

Fatal against the offline-site requirement. See D3.

### Rejected: taking a dependency on Ravenx or Notifiex

The patterns are worth borrowing; the libraries are not. Ravenx's strategy
behaviour and its `[{strategy, payload, opts}]` fan-out shape are the right
model, but its configuration is compile-time application config and its
strategies ship as separate Hex packages - so adding a provider still requires a
code deploy, which is the precise constraint this change exists to remove.
`AGENTS.md` also requires wrapping third-party library APIs behind
project-owned modules. The pattern is small enough to own outright.

### Rejected: Elixir Protocols for channel dispatch

Protocols dispatch on struct type at compile time. Channels are selected at
runtime from database rows, and `String.to_atom/1` on user input is prohibited
by the Iron Laws. The correct split is a **Behaviour for transports**
(`deliver/2`, `validate_config/1`, `capabilities/0`, `test/2`, resolved through a
runtime registry lookup) and a **renderer keyed by alert class x payload
format**, which is also what Laravel's `via()` + `toSlack/toMail` model
expresses.

### Rejected: reusing the northbound action tables

See D8.

## Migration Plan

Phased, with Phase 1 independently shippable.

1. **Phase 1 - delivery backbone.** Resources, migrations, routing, escalation,
   suppression, Oban delivery worker, `:native` transports for Slack, Discord,
   generic webhook, and email; the nine `notifications.*` RBAC keys; managed
   `NotificationTemplate` defaults; signed action links for
   acknowledge/snooze/resolve; `/settings/notifications`; acknowledgement
   controls on the alert detail page. Email additionally requires the `gen_smtp`
   dependency and deployment-supplied mailer configuration (see Risks). This
   alone replaces the dead `WebhookNotifier` and restores function.
2. **Phase 2 - declarative providers.** The request-template document format,
   its validator, the upload and versioning UI, and the seeded first-party
   catalog that proves the tier works without code.
3. **Phase 3 - plugin providers and the edge route.** The `notifications:`
   manifest block with its validator-owned entry keys, `notify:v1` capability
   with agent-side enforcement, SDK support in `serviceradar-sdk-go` and
   `serviceradar-sdk-rust`, `:control_plane` plugin execution on the platform
   agent, then the `:edge_agent` route with failover and a reconnect drain.
4. **Phase 4 - stream provider and native interactivity.** The seeded `:stream`
   provider row, the firehose subject and Phoenix Channel gated by
   `notifications.stream.subscribe`, plus Slack Block Kit buttons, Discord
   message components, and PagerDuty acknowledgement webhooks - all three
   verified against the northbound HMAC scheme and requiring the notification
   callback prefix to be registered with `RawBodyReader`.

### Dead code disposition

The following exist, mislead implementers, and are resolved by this change.
Retirement is part of the change, not a follow-on: after it lands the alert path
does not invoke `ServiceRadar.Monitoring.WebhookNotifier` at all, and existing
webhook configuration is migrated to `generic_webhook` `:native` channels so no
operator loses a destination in the swap. Leaving the dead module in place is
what would let a future implementer wire an alert back into a path that returns
`{:error, :not_running}`.

- `ServiceRadar.Monitoring.WebhookNotifier` - never supervised, never
  configured, no tests. Removed, after migrating its configuration onto the
  `generic_webhook` `:native` provider.

  There are **14 references across two modules**, not three:
  `alert_lifecycle.ex:104` and `:114`; `alert_generator.ex:97`, `:176`, `:320`,
  `:334`, `:369`, `:382`, `:395`, `:407`, `:437`, `:447`. The nested modules
  `WebhookNotifier.Alert` (`webhook_notifier.ex:57`) and
  `WebhookNotifier.WebhookConfig` (`:83`) are part of the surface those sites
  depend on.

  The replacement MUST be designed from the alert data, **not** from the dead
  struct shapes. Because nothing supervises the GenServer and nothing tests it,
  every call already takes the `:not_running` branch
  (`webhook_notifier.ex:133`) - so `%WebhookNotifier.Alert{}` is not a
  battle-tested contract, it is a shape that has never executed in production.
- The `webhooks:` block in `helm/serviceradar/files/serviceradar-config.yaml:311`
  is consumed by nothing. Removed.
- `go/pkg/models/config.go:90-112` `WebhookConfig` / `CloudConfig` - removed.
- `alert_events: "events.alert"` (`nats/channels.ex:54`) - either wired to the
  alert lifecycle subject or removed.
- `ServiceRadar.Identity.Senders.EmailDelivery` - orphaned; folded into
  `OutboundMail`.

## Risks / Trade-offs

| Risk | Mitigation |
| --- | --- |
| The control-plane plugin route still traverses the at-most-once `AgentCommandBus` with a 5 s synchronous `GenServer.call` | The delivery row is authoritative and Oban retries; the platform-agent hop is never treated as the record |
| The platform-resident agent pod becomes a single point of failure for plugin-backed channels | `:native` transports are the ultimate floor; a second replica is a deployment option |
| `:status_handler_enabled` defaults to `false`, so edge delivery receipts never persist | Phase 3 requires enabling it or shipping the poll-based reconciler |
| Two egress trust domains to review (platform pod, site agent) with different allowlist mechanisms | Documented explicitly; `Palisade` for control plane, manifest permissions for the agent |
| Declarative templating grows into an accidental programming language | Fixed filter set, whitelisted variable paths, no conditionals beyond `default`; anything more expressive is a Wasm plugin |
| Slack (~1 msg/s per webhook) and PagerDuty quotas need a restart-surviving budget | Per-channel `rate_limit_per_minute` enforced against a durable counter, not in-memory GenServer state as `WebhookNotifier` does |
| SMTP from `serviceradar_core` does not work today - `elixir/serviceradar_core/mix.exs:138` has `swoosh` but no `gen_smtp`, and Helm templates no `SERVICERADAR_MAILER_ADAPTER` / `SMTP_RELAY_*` env | Phase 1 adds the `gen_smtp` dependency and the Helm mailer env; email delivery goes through `OutboundMail.deliver/1`. Missing mailer configuration fails channel configuration validation with an actionable diagnostic; it never silently resolves to a test adapter that reports success while mail goes nowhere |
| Two alert-creation paths bypass dedup entirely | Suppression and dedup re-checked at the notification layer (D5) |

## Future Directions

Explicitly out of scope for this change, recorded so the contracts leave room.

- **Dependency suppression.** Do not page for fifty devices behind one downed
  switch. ServiceRadar already holds the topology graph, so parent-child
  suppression is tractable. The `:dependency` suppression reason is reserved in
  the contract; the topology-driven implementation is a follow-on. This is the
  single highest-value NMS-parity feature after acknowledgement.
- **Composite and correlated alert conditions.** Alerting on *combinations* of
  conditions, where Zabbix trigger expressions and Datadog composite monitors
  live. The Notification-Oriented Paradigm's Facts / Premises / Rules vocabulary
  maps cleanly onto this, and `StatefulAlertEngine` is already push-driven
  (JetStream batches -> Horde-sharded GenServer -> ETS windows), which is that
  shape. Worth revisiting as a rule-engine refactor, not as notification scope.
- **On-call rotations**, if integration with PagerDuty and Opsgenie proves
  insufficient in practice.

## Resolved Questions

### R1. Site egress means the site agent, and the edge route is first class

**RESOLVED.** "Egress from the customer's own network" means exactly what it
says: the customer installs a `serviceradar-agent` inside their network, assigns
a notification plugin to that agent, and every notification for the channels
bound to it routes through that agent over the bidirectional gRPC tunnel. It
does not mean "customer-controlled infrastructure" in the looser sense, and a
self-hosted control plane does not substitute for it.

Consequences, all normative:

- `:edge_agent` is a first-class deployment model, not a minority escape hatch.
  Documentation SHALL present it as the supported answer for "notifications must
  leave from my network", while still recommending `:control_plane` as the
  default when no such constraint exists.
- A notification plugin assignment to a specific agent is the unit of
  configuration. Channel binding follows the existing `PluginAssignment` +
  partition model rather than inventing a parallel targeting scheme.
- The offline-agent mitigations in D3 remain mandatory, because a first-class
  route is used more, not less. See R2 for how their weight changes over time.

### R2. usp-01 does NOT make the command plane durable

**RESOLVED, against the initial assumption.** The `unify-sweep-results-proto`
(`usp-01`) work does not improve `ServiceRadar.Edge.AgentCommandBus`. It is a
one-directional **observation/data plane** change - producer to agent spool to
gateway to JetStream to projector - and it excludes the command plane by design,
not by omission:

- "Live media, interactive tunnels, **commands**, credentials, update plans, and
  large opaque artifacts retain their dedicated transports."
  (`unify-sweep-results-proto/proposal.md:73-75`)
- Stated non-goal: "Turning the record data plane into a universal workflow,
  command, media, tunnel, or artifact-byte transport."
  (`unify-sweep-results-proto/design.md:68`)
- "The command/execution plane, coalescible ephemeral state plane, and blob/media
  plane SHALL remain separate from this durable record plane."
  (`specs/edge-producer-data-plane/spec.md:20-21`)
- The frozen wire contract confirms it: `EdgeRecordServerMessage`
  (gateway to agent) carries exactly `lane_open_ack` and `ack`
  (`proto/edge/v1/record.proto:728-734`). No command message exists in either
  direction.

Its durability guarantees - crash-safe spool, at-least-once, resume-after-
reconnect - describe an **agent-resident spool of agent-produced records flowing
upstream**. There is no core-side outbox, no command spool, and no drain-on-
reconnect. After `usp-01` lands in full, `dispatch/4` remains at-most-once and
`offline` remains terminal, written with a `completed_at` timestamp.

Consequences, all normative:

- Every D3 mitigation - `fallback_channel_id`, the edge-only escalation warning,
  and "the delivery row is the system of record, the command result is only a
  wake-up signal" - is **permanent**, not transitional. The reconciler pattern
  they encode is the same one `CallbackCommandResultCoordinator` already uses.
- Because R1 makes `:edge_agent` a first-class route rather than a minority
  escape hatch, command-plane durability becomes a **prerequisite of Phase 3**,
  owned by a companion change and tracked as **forgejo issue #4902**
  ("AgentCommandBus is at-most-once: commands to a disconnected agent are
  silently lost"). It is not inherited from `usp-01`. Phase 3 SHALL NOT ship an
  `:edge_agent` route that silently drops a notification when an agent is
  briefly disconnected.
- The minimum Phase 3 addition is a core-side dispatch outbox: an edge-routed
  delivery whose dispatch returns `{:error, {:agent_offline, _}}` remains
  `:pending` with `next_attempt_at` set, and a reconnect signal or a bounded
  periodic scan re-drives it, rather than failing over immediately. Failover
  remains the fallback after the spool window expires.
- No requirement in this change may be written such that it only holds after
  `usp-01` lands.

Phase 1 and Phase 2 are entirely control-plane and are unaffected by any of this.

### R3. Sequencing is accepted

**RESOLVED.** The overlap with `add-northbound-action-integrations`,
`add-signed-northbound-action-callbacks`, `add-long-running-northbound-actions`,
and `add-automation-callback-grants` on the callback and HMAC surface is
acknowledged and accepted. This change reuses those mechanisms rather than
forking them, and lands alongside them.

### R4. An external chat identity is recorded verbatim and never mapped to a platform user

**RESOLVED** (Open Question 1). ServiceRadar does not map a Slack user onto a
ServiceRadar user, in v1 or by default later. The acknowledgement is attributed
to the external principal exactly as the provider named it - `"slack:U123"`,
`"pagerduty:PLH1HKV"` - with `NotificationAcknowledgement.actor_kind` set to
`:external_principal` and `acknowledged_by_user_id` left null.

The question framed this as a forgery risk, and inverting the framing is what
resolves it. The risk is not that an unmapped principal is untrustworthy; it is
that a *mapped* one asserts something we cannot back. Slack's signature
authenticates the app, and Slack itself asserts which member clicked; that
assertion is exactly as good as the workspace. Turning it into "alice@corp
acknowledged this alert" adds a claim ServiceRadar cannot verify - a workspace
admin controls display names and profile emails, so verified-email matching is
forgeable by the very party being authenticated.

So the third candidate is chosen: refuse to map. What is recorded is what is
known - a specific Slack member, in a specific workspace, acknowledged this
alert - and the Delivery Log shows precisely that. Any member of a workspace a
channel posts to can acknowledge, which is intended: they were sent the
notification.

A future explicit mapping resource is not precluded, but it must be an operator
asserting the binding, never inferred from a profile field.

### R5. Core availability is the accepted failure domain

**RESOLVED** (Open Question 2). Yes. The alert engine is in core, so a core
outage means there are no alerts to notify about - edge-only delivery would
faithfully deliver nothing. Notification availability is therefore bounded by
core availability by construction, and claiming otherwise would be a high
availability story with no engine behind it.

This is why the `:edge_agent` route exists for **egress locality** (R1) and not
for surviving a core outage. The two are routinely conflated and the distinction
is load-bearing: an agent-routed channel still needs core to decide that a
notification should be sent at all.

A true HA story requires an edge-resident rule engine, which is out of scope for
this change and would be a different design. Recorded in
`docs/docs/architecture.md` so it is not rediscovered as a surprise during an
incident.

### R6. Delivery records live in a plain `platform` table with their own retention

**RESOLVED** (Open Question 3). `notification_deliveries` is an ordinary table in
the `platform` schema, pruned by
`ServiceRadar.Notifications.DeliveryRetentionWorker`, not a Timescale hypertable.

A hypertable buys time-partitioned retention and compression for append-mostly
time series that are read by time range. A delivery row is none of those things:
it is **mutated** through a state machine (`pending -> dispatching -> sent |
failed | retry_due`), it is read by id and by alert, and its most important index
is the `NULLS NOT DISTINCT` partial unique index that makes suppression
idempotent. Hypertable constraints on updates and unique indexes would fight all
three, and chunk management would be overhead for an access pattern that is not
time-ranged.

If fan-out breadth ever makes volume the binding constraint, the answer is to
tighten retention or move *aged* rows to cold storage
(`openspec/changes/add-cold-telemetry-tiering`), not to convert a mutable state
machine into a hypertable.

## Open Questions

None outstanding. The four questions this change opened are resolved above:

- Customer-network egress -> **R1** (it means the site agent specifically).
- External chat identity -> **R4** (recorded verbatim, never mapped).
- Core as the failure domain -> **R5** (accepted, and why edge routing is not an
  HA story).
- Delivery record storage -> **R6** (plain table with retention, not a
  hypertable).
