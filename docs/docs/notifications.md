---
title: Notifications
---

# Notifications

ServiceRadar turns an alert into a page through a chain of small, separately
configurable objects. This page is the operator guide to that chain: what each
object does, which knob belongs to which object, and - most importantly - how to
answer the question every notification system eventually gets asked, **"why was
I not paged?"**

If you read nothing else, read two sections:
[Retry, failover, and escalation are three different things](#retry-failover-and-escalation-are-three-different-things)
and [Suppression is auditable](#suppression-is-auditable-nothing-is-dropped-silently).
Those two are where almost every misconfiguration lives.

## The object model

| Object | Answers | Where |
| --- | --- | --- |
| **Provider** | What *kind* of destination is this? (Slack, Discord, webhook, email) | Settings > Notifications > Providers |
| **Channel** | One *configured* destination: "Slack #noc" | Channels tab |
| **Route** | Which alerts go where, and in what order routes are considered | Routes and Escalation tab |
| **Escalation policy** | The ladder: who is told first, who is told if nobody answers | Routes and Escalation tab |
| **Escalation step** | One rung of the ladder; holds a *set* of channels (fan-out) | Inside a policy |
| **Schedule** | When a route is active (business hours, after hours) | Routes and Escalation tab |
| **Silence** | A time-bounded, attributed mute over matching alerts | Silences tab |
| **Delivery** | The audit record of one attempt - sent, failed, or withheld | Delivery Log tab |
| **Acknowledgement** | Who took ownership, from where, and when | Alert detail page, Delivery Log |

Everything is at `Settings > Notifications` (`/settings/notifications`).

An alert flows through them in this order:

```
alert fires
  -> routes evaluated by priority        (Route)
  -> escalation policy selected          (Route -> Policy)
  -> step 1 fan-out                      (Step -> [Channel, Channel])
  -> per channel: suppression re-checked (Suppression)
  -> per channel: rendered and delivered (Provider transport)
  -> one NotificationDelivery row written per channel, always
```

That last line has no exception. A dispatch that is deliberately withheld writes
a row too, with a `suppression_reason`. See
[Suppression is auditable](#suppression-is-auditable-nothing-is-dropped-silently).

## Quick start

The smallest working configuration is four objects:

1. **Channel.** Channels tab > New channel. Pick the `slack` provider, paste the
   incoming-webhook URL, name it `Slack #noc`. Leave `execution_route` on
   **Control plane** (the default and the recommendation).
2. **Test-send.** Use the Test button *before* saving. It performs a real send
   with the real configuration and shows you the redacted transport result. The
   resulting row is marked `is_test` in the Delivery Log and counts toward
   nothing.
3. **Escalation policy.** Routes and Escalation tab > New policy. Add step 1 with
   `delay_seconds: 0` and your channel in the fan-out set. That single-step
   policy is a perfectly valid "just tell me once" configuration.
4. **Route.** Routes and Escalation tab > New route. Give it a match expression
   (leave it empty to match every alert), bind the policy, and enable it.

Then confirm it worked in the **Delivery Log**, not in Slack. Slack shows you
what arrived; the Delivery Log shows you everything that was decided, including
what was withheld and why.

## Providers

A provider is a *kind* of destination. Phase 1 ships four first-party providers
plus one built-in:

| Provider | Type | Notes |
| --- | --- | --- |
| `slack` | native | Incoming webhook or bot token |
| `discord` | native | Incoming webhook |
| `webhook` | native | Generic HTTPS POST/PUT/PATCH, see [Migrating from the old `webhooks:` block](#migrating-from-the-removed-webhooks-config-block) |
| `email` | native | Goes through the single outbound mail path, see [Email and SMTP](#email-and-smtp) |
| `stream` | built-in | Publishes the notification envelope to an RBAC-scoped topic. Seeded and dispatchable now; the durable subscribable firehose (its own JetStream subject, and the topic join gated on `notifications.stream.subscribe`) lands in a later phase |

First-party providers are **managed** records: they are seeded on start and
reconciled on upgrade. An upgrade refreshes a managed provider (or a managed
template) only while its stored fingerprint still matches what shipped. Once you
edit one, your edit is preserved and upgrades leave it alone.

You cannot author a `stream` provider, and you cannot yet author `declarative`
or `wasm_plugin` providers - those tiers arrive in later phases. What you can do
today is configure as many **channels** as you like on the shipped providers.

### Every provider supports `test`

Every provider in every tier implements a test action and declares both `send`
and `test` in its capabilities. A provider that declares one without the other
is rejected outright, so "test-send before saving" works uniformly and will keep
working as new provider tiers land.

## Channels

A channel is one configured destination. The fields that matter operationally:

| Field | Meaning |
| --- | --- |
| `enabled` | A disabled channel suppresses with reason `channel_disabled` - it does not silently vanish |
| `config` | Validated against the provider's schema. **Not** a sensitive column: no credentials here |
| `secret_refs` | Where credentials live. Resolved through the credential broker at dispatch time |
| `execution_route` | `control_plane` (default) or `edge_agent`, see [Execution route](#execution-route-control-plane-vs-edge-agent) |
| `fallback_channel_id` | The **one** failover hop taken when this channel's delivery fails terminally |
| `fail_closed` | When true, never fail over. Use for a channel whose destination must not receive a duplicate |
| `max_attempts` | Transport retry bound for this channel (default 3). Not an escalation bound |
| `rate_limit_per_minute` | A durable, restart-surviving send budget for this destination |
| `health`, `last_success_at`, `last_failure_at`, `last_error` | What the channel list shows you at a glance |

`max_attempts` lives on the channel rather than the provider because it is a
property of the destination *you* configured: a paging channel and a chat
channel on the same provider deserve different patience. The provider supplies
the default so a channel is usable with no tuning.

Secret fields never echo a stored value back into the form. Re-entering a secret
replaces it; leaving the field blank keeps what is stored.

### Outbound URL safety

Every operator-supplied outbound URL is validated before any request leaves the
platform: HTTPS only, public addresses only. A webhook URL pointing at a private
address, a link-local address, or a plain-HTTP endpoint is rejected at save time
and again at request time.

## Execution route: control plane vs edge agent

`execution_route` decides *which process performs the egress*.

- **`control_plane` is the default and the recommendation.** The platform makes
  the outbound request itself. Use it unless you have a specific reason not to.
- **`edge_agent`** routes the egress through a `serviceradar-agent` running
  inside your network. It exists for exactly one requirement: **a destination
  that is only reachable from inside the customer network** - an internal
  ticketing system, an on-premises chat server, an SMS gateway on a private
  segment.

### The honest tradeoff

The command path to an agent - `AgentCommandBus` - is **at-most-once with no
store-and-forward**. If the target agent has no live control session at the
moment of dispatch, the command is marked offline and returns an error; nothing
re-drains queued or offline commands when the agent reconnects. This is tracked
as forgejo issue #4902 and it is a property of the current command plane, not a
transient bug.

Three consequences you must design around:

1. **An edge-routed channel whose agent is unreachable relies on retry and then
   failover.** The delivery stays retry-eligible while attempts remain, and when
   they are exhausted (or immediately on an agent-offline error) it takes its one
   failover hop to `fallback_channel_id`. If you set no fallback, or you set
   `fail_closed`, there is no second chance.
2. **An escalation policy whose only route is an edge agent in the same
   partition as the alert source cannot deliver a site-down page.** This is the
   configuration that silently guarantees no page at exactly the moment one is
   owed: the platform is the component that detects the site going dark, and the
   agent it would have paged through went dark with it. The UI warns about this
   shape; the warning is not cosmetic.
3. **Always give an edge-routed channel a control-plane fallback**, unless you
   genuinely prefer silence to a duplicate.

The delivery row is always the system of record. An agent command result is a
wake-up signal, never the truth; if the signal is lost, a bounded periodic scan
recovers the delivery's real state.

## Routes

A route claims alerts and points them at an escalation policy.

| Field | Meaning |
| --- | --- |
| `match_expression` | The predicate deciding which alerts this route claims. An empty object matches everything |
| `priority` | Evaluation order. Lower numbers are considered first |
| `continue` | Alertmanager semantics: when false, the first matching route wins and evaluation stops |
| `escalation_policy_id` | The ladder to run |
| `schedule_id` | Optional. Outside the schedule window, dispatches suppress with reason `schedule` |
| `throttle_seconds` | May only **narrow** the rule's cadence, never widen it |
| `dedupe_key_template` | Optional override of the incident identity, for cases rule grouping does not cover |
| `group_wait_seconds`, `group_interval_seconds` | Grouping cadence |
| `enabled` | A disabled route is not considered at all |

### The match expression grammar

Routes and silences share **one** predicate grammar, because they ask the same
question twice. Two grammars would mean two validators kept in parity by hand,
and a silence that quietly fails to match the route that created it is precisely
the failure the Delivery Log exists to eliminate.

```json
{
  "all": [
    {"field": "alert.severity", "in": ["critical", "high"]},
    {"field": "device.location", "equals": "dc-west"},
    {"not": {"field": "alert.alert_class", "equals": "informational"}}
  ]
}
```

Combinators are `all`, `any`, and `not`, and a combinator key must be the only
key in its object. A predicate carries `field` plus exactly one operator from
`equals`, `in`, `contains`, `exists`, `matches`. A shorthand object of
`path: scalar` pairs is an implicit conjunction of `equals` tests.

A predicate with **no** operator is rejected rather than being demoted to a
presence test - that is how a misspelled operator becomes a rule matching
everything. Nesting depth, node count, and operand list length are bounded, so a
pasted document cannot turn one dispatch decision into an unbounded traversal.

The route editor's predicate builder writes this grammar for you; the raw form is
documented because the same grammar appears on silences.

## Escalation policies, steps, and fan-out

A policy is a ladder. A **step** is one rung and holds a **set** of channels, so
fan-out (tell several places at once) is orthogonal to escalation (tell more
people later).

| Policy field | Meaning |
| --- | --- |
| `repeat_count` | How many times the whole ladder repeats if still unacknowledged |
| `repeat_interval_seconds` | How long between repeats. Subject to the cadence floor below |
| `resolve_notifies` | When true, channels that already fired get a close-out notification on resolve |

| Step field | Meaning |
| --- | --- |
| `step_number` | Order within the policy |
| `delay_seconds` | Measured from the **alert fire time** (see below) |
| `condition` | `always` or `if_unacknowledged` |
| channels | The fan-out set for this rung |

### Delays are measured from alert fire time

`delay_seconds` is measured from when the alert fired, **never** from the
previous step's dispatch. Chaining delays off the previous dispatch makes total
time-to-page depend on transport latency and retry behaviour, so a policy stops
meaning what its author read: a step-1 channel that retried for four minutes
would silently push every later rung four minutes out.

There is exactly **one** exception. After a snooze expires, the remaining step
delays are measured from the **snooze expiry instant**. Snoozing is an explicit
operator statement that the clock should restart.

### The cadence floor

`StatefulAlertRule.renotify_seconds` is the **floor**. A policy's
`repeat_interval_seconds` may only make repeats **less** frequent, so it must be
greater than or equal to `renotify_seconds`. A policy configured below the floor
is **rejected at save time with an actionable message** - it is not silently
clamped, because a silently clamped value is a setting that lies to whoever reads
it next.

The same rule applies to routes: a route's `throttle_seconds` may narrow the
rule's cadence, never widen it.

The principle: **the alert rule owns how noisy an incident is allowed to be.
Notification configuration can only make it quieter.**

## Retry, failover, and escalation are three different things

This is the single most misunderstood part of every notification system, so it
is stated plainly. These are **three separate mechanisms**. No code path treats
one as another, and no setting for one bounds another.

| Mechanism | Level | Fires when | Bounded by |
| --- | --- | --- | --- |
| **Retry** | Transport | 5xx, timeout, 429 - the destination did not accept the message | Channel `max_attempts` plus backoff |
| **Failover** | Transport | Retries exhausted, or the target agent is offline | Exactly **one** hop to `fallback_channel_id` |
| **Escalation** | Human | The step delay elapsed **and** the alert is still unacknowledged | Policy step count, `repeat_count` |

### Worked example

An alert fires at `t+0` against this policy:

```
Step 1  t+0     -> [Slack #noc, Email noc@example.com]   condition: always
Step 2  t+5m    -> [PagerDuty]                           condition: if_unacknowledged
Step 3  t+15m   -> [PagerDuty P1, SMS on-call]           condition: if_unacknowledged
```

Suppose Slack returns HTTP 503 at `t+0`:

- `t+0` - Step 1 fans out to two channels. Two delivery rows. Email succeeds
  (`sent`). Slack fails retryably, so its row stays **`pending`** with
  `next_attempt_at` set and `attempt_count = 1`. **This is retry.** It has not
  advanced any step.
- `t+0` to `t+2m` - Slack is retried up to the channel's `max_attempts`. Still
  step 1. Still one row, updated in place.
- Attempts exhausted -> the Slack row moves to **`failed`**, which is terminal.
  If the channel has a `fallback_channel_id` and is not `fail_closed`, a
  **successor** row is created on the fallback channel carrying
  `originating_delivery_id` pointing back at the failed row. **This is failover.**
  Exactly one hop; the fallback does not fail over again.
- `t+5m` - Independently of all of the above, step 2 becomes due because five
  minutes have passed since the **alert fire time** and the alert is still
  unacknowledged. PagerDuty is paged. **This is escalation.** Note the timing: it
  is `t+5m`, not five minutes after the Slack retries finished.
- If somebody acknowledges at `t+4m`, step 2 and step 3 never fire. Suppression
  is re-run at every dispatch, so the `if_unacknowledged` rungs come back
  `acknowledged` and write suppressed rows saying so.

### The consequences worth internalising

- **`failed` is terminal.** A retry-eligible delivery stays `pending` with
  `next_attempt_at` set; it does not pass through `failed` and come back. Only a
  non-retryable failure or exhausting `max_attempts` moves a row to `failed`. If
  you see a `pending` row with a past `next_attempt_at`, that is a retry waiting
  its turn, not a stuck delivery.
- **A transport failure never advances the ladder.** Raising `max_attempts` does
  not delay escalation, and shortening a step delay does not cause more retries.
- **An unacknowledged timer is never a transport retry.** Step 2 firing does not
  mean step 1 failed. Fan-out at step 1 may have succeeded perfectly.
- **Failover is one hop.** Chains of fallbacks are not a supported shape; if you
  need three destinations, that is a fan-out set on a step, not a fallback chain.
- **`fail_closed` disables failover entirely** for that channel. Nothing is
  created downstream when it fails.

The Delivery Log renders a failover chain as one chain rather than two unrelated
attempts, by following `originating_delivery_id`.

## Deduplication and cadence

The notification platform **does not invent an incident identity**. It consumes
the one the alert engine already has:

- Incident identity is the existing composite `{rule_id, group_key}`, where
  `group_key` is derived from the rule's `group_by` fields.
- Cadence comes from the rule's `cooldown_seconds` and `renotify_seconds`.
- A route may supply a `dedupe_key_template` **override** for cases the rule's
  grouping does not cover. That is the only override; there is no second identity
  scheme to learn.

Because the rule owns the identity and the floor, the rule is also the ceiling on
noise:

> Notification settings can only make pages **less** frequent, never more.

If an incident is paging too often, the fix is the rule's `renotify_seconds`, not
a notification setting. If an incident is paging too rarely, check whether a
route `throttle_seconds` or a policy `repeat_interval_seconds` is narrowing it.

Routing requests are idempotent on `{alert_id, lifecycle_reason, step_number,
dedupe_key}`, where `lifecycle_reason` is one of fire, renotify, escalate, or
resolve. A duplicate lifecycle callback, an Oban retry, or an overlapping
scheduler tick resolves to the existing work rather than producing a second
dispatch.

## Schedules

A schedule gates a route by wall-clock time.

- `windows` is a list of entries, each with `days` (from `mon tue wed thu fri sat
  sun`), `start_time`, and `end_time` as `"HH:MM"` or `"HH:MM:SS"`, with
  `end_time` strictly after `start_time`.
- `mode` is `active_within` (active inside the windows) or `active_outside`
  (active everywhere else).
- `timezone` is an IANA zone name; window evaluation happens in that zone.

A window that wraps past midnight is deliberately **not** expressible as a single
entry, because `end_time > start_time` is what keeps window evaluation a plain
comparison. Express "overnight" either as `active_outside` of the daytime window,
or as two entries on adjacent days.

Schedules are deliberately **not rotations**. On-call rotation calendars, shift
handoffs, and override management are out of scope; ServiceRadar integrates with
PagerDuty and Opsgenie for those rather than reimplementing them.

Outside the active period, a dispatch suppresses with reason `schedule` and
still writes a delivery row.

## Silences

A silence mutes matching alerts for a bounded window. It carries `matchers` (the
same grammar as a route's `match_expression`), `starts_at`, `ends_at`, a required
`comment`, and the user who created it. Its state moves
`scheduled -> active -> expired`, or `cancelled` if you cancel it early.

Two things to know:

- **An empty `matchers` object matches every alert**, which mutes the whole
  deployment. That is a deliberate capability, not an accident, and it is why
  writing a silence needs its own permission
  (`notifications.silences.manage`).
- The Silences tab includes a **"currently suppressed"** view, so you can see
  what a silence is actually catching rather than inferring it from the
  predicate.

A silenced dispatch suppresses with reason `silence` and writes a delivery row
naming the silence.

## Suppression is auditable: nothing is dropped silently

**Every dispatch decision that withholds a notification writes a
`NotificationDelivery` row** with `state: suppressed` and exactly one
`suppression_reason`. Silent drops are prohibited. The **Delivery Log** is where
"why was I not paged?" is answered.

### The nine reasons, in precedence order

Exactly one reason is recorded per withheld dispatch, and evaluation stops at the
first match - so the order below is part of the contract, not an accident of how
the conditionals nest.

| # | Reason | What it means | Where to look |
| --- | --- | --- | --- |
| 1 | `device_out_of_service` | The alert's subject device is marked inactive. Withholds every notification for that device, from every route, channel, and step | Device record: put it back in service |
| 2 | `silence` | An active silence's matchers matched this alert | Silences tab; the row names the silence |
| 3 | `schedule` | The dispatch instant fell outside the route's schedule window | The route's bound schedule |
| 4 | `snoozed` | The alert is snoozed until a future timestamp | Alert detail page: `snooze_until` |
| 5 | `throttled` | Cadence: you were paged for this incident recently | Rule `cooldown_seconds`, route `throttle_seconds` |
| 6 | `acknowledged` | A human already owns the incident, so an `if_unacknowledged` rung has nothing to do | Alert detail page: who acknowledged |
| 7 | `channel_disabled` | The channel is disabled or its provider is deactivated. Per-channel: siblings in the same fan-out set may have gone out normally | Channels tab |
| 8 | `dependency` | **Reserved and not emitted today.** Topology-driven parent/child suppression ("do not page for fifty devices behind one downed switch") is a follow-on. It is in the vocabulary so the enum does not have to change when the feature lands | n/a |
| 9 | `no_matching_route` | The alert matched **zero enabled routes** | Routes tab: nothing claimed this alert |

The ordering runs outward from the subject of the alert, through deliberate
operator statements, through route configuration and cadence, to per-channel
mechanics, and ends with "nothing was configured at all". Ties break toward the
explanation that ends the investigation with the least further digging: an
operator who read a lower reason would go cancel the silence or widen the
schedule and *still* not be paged, because the device is out of service.

`no_matching_route` is last for the same reason: every route-scoped explanation
above it is vacuous when no route matched, while the alert-scoped ones are not.

### `no_matching_route` is the one that saves you

An alert nobody wrote a route for is the single case that would otherwise
produce **nothing at all** - no message, no error, no row - which is exactly the
failure an operator cannot debug. It is recorded through the same audit path as
every other withheld notification and is filterable in the Delivery Log
alongside them. If you commission a new alert rule and hear nothing, filter the
Delivery Log on `no_matching_route` first.

### Suppression is re-evaluated at every dispatch

Suppression is not decided once at routing time and cached. It is re-run
immediately before **every** dispatch attempt - every escalation step, every
policy repeat, every retry, and every failover hop. An alert routed while its
device was in service and escalated fifteen minutes later, after the device was
marked out of service, is correctly withheld on the later attempt.

### Repeat decisions collapse; they do not accumulate

Recording every withheld decision would turn a long-lived silence into unbounded
table growth. So an *identical* repeat decision - one identical on
`{alert_id, policy_id, step_number, channel_id, dedupe_key, suppression_reason}` -
updates the existing row instead of inserting a duplicate: it increments an
occurrence count and refreshes `last_evaluated_at`.

You therefore see both **why** and **how often** in one row. A suppressed row
showing an occurrence count of 240 is one decision re-made 240 times, not 240
distinct problems.

## The Delivery Log

The Delivery Log is the audit surface, and it is deliberately not a "sent
messages" list. It is filterable by alert, channel, state, and
`suppression_reason`.

| State | Meaning |
| --- | --- |
| `pending` | Queued, or waiting on a retry (`next_attempt_at` is set) |
| `dispatching` | An attempt is in flight |
| `sent` | The destination accepted it |
| `failed` | **Terminal.** Non-retryable, or `max_attempts` exhausted |
| `expired` | The delivery aged out before it could be attempted |
| `cancelled` | Cancelled before dispatch |
| `suppressed` | Deliberately withheld. Carries a `suppression_reason` |
| `skipped` | Not applicable to this dispatch |

What the log shows that a chat channel cannot:

- **Suppressed rows are displayed**, with their reason and occurrence count -
  never omitted. That includes `no_matching_route` rows for alerts that matched
  no route at all.
- **Failover chains render as one chain**, followed through
  `originating_delivery_id`, rather than as two unrelated attempts.
- **Test deliveries are marked distinctly.** A row produced by test-send carries
  `is_test`, does not increment any alert's notification count, and does not
  drive dedupe, throttle, escalation, or renotify state. It is still written,
  audited, and redacted like any other delivery.
- **Payloads are digests, not bodies.** Every payload, result summary, and log
  line passes the redaction policy before persistence or display, so no secret
  reaches a stored row.
- **`payload_format` and `provider_version`** record what actually rendered the
  row. A delivery stays explicable after a provider's format list or template
  version moves on.

### Deliveries outlive their alerts

Resolved and suppressed alerts are hard-deleted after a default of three days.
A delivery therefore outlives the alert it points at, which is why every delivery
carries a required `alert_snapshot` - the log still renders after the alert row is
gone. Deliveries have their **own** retention, defaulting to 30 days and
configurable independently.

## Acknowledgement

Acknowledging an alert is what stops an `if_unacknowledged` ladder. There are two
ways to do it.

### From the web UI

The alert detail page has Acknowledge, Snooze, and Resolve controls, and the
alerts list supports bulk acknowledge and snooze. These require
`observability.alerts.manage` - the existing permission whose description
("Acknowledge and resolve alerts") is finally true. The alert page also renders
that alert's delivery history, suppressed rows included.

### From inside the notification: action links

Every rendered notification carries three links: **Acknowledge**, **Snooze 1h**,
and **Resolve**. They work in email, Slack, Discord, generic webhook, and every
future declarative provider with zero per-provider code.

What they are, precisely:

- **A capability.** The link *is* the authorisation. There is no login step,
  which is the entire point: the person holding the notification can act on it
  from a phone at 03:00.
- **Single-use, per action.** One token per delivery per action. Redeeming the
  Acknowledge link consumes only that token; the Resolve link on the same message
  still works.
- **Time-bounded.** Tokens expire, defaulting to three days.
- **Stored as a digest only.** The platform persists sha256, never the token, and
  compares in constant time. A failed presentation is rate-limited and audited -
  the audit record carries the client IP and a public reason, never the token.
- **Confirmed before acting.** Fetching the link renders a confirmation page and
  changes nothing; only the confirmation POST redeems it. Mail scanners and link
  previewers fetch every URL in a message before a human sees it, and an acting
  GET would let a spam filter acknowledge your fleet.
- **Idempotent when spent.** Presenting an already-redeemed token is reported as
  success, not as an error, for the same scanner reason.

Snooze duration is bound into the token, not chosen by whoever clicks. "Snooze
1h" is the link *label*; the model is a snooze action carrying its duration, so
offering "Snooze 4h" later needs no new action name and nobody can extend their
own snooze by editing a URL.

#### Action links record an EXTERNAL principal

This is the part operators get wrong. **Clicking an action link does not record a
platform user.** There is no session behind the click, so the resulting
acknowledgement is written with `actor_kind: external_principal` and
`source: action_link`.

The consequence for your audit trail: an acknowledgement from an action link
tells you *that the incident was claimed* and *through which delivery*, but the
identity behind it is only as strong as the delivery of that notification. If you
need acknowledgements attributed to named platform users, have people
acknowledge from the web UI, which records `actor_kind: platform_user` and a real
user foreign key.

Snoozing through a link records `snooze_until` on both the alert and the
acknowledgement record. Snooze is a derived condition, not an alert status: an
alert is snoozed when its status is `pending` or `escalated` and `snooze_until`
is in the future. Nothing has to be moved back out of a snoozed state when it
expires.

#### Action links need a base URL

Links are only rendered when the deployment knows its own external address. Set
`SERVICERADAR_NOTIFICATION_ACTION_BASE_URL` (or the
`:notification_action_base_url` application setting) to the externally reachable
base of the web UI. Without it, notifications still go out and the delivery
records that links were exempted for an unconfigured base URL - a bare path would
be a dead link in an email client.

#### The `stream` provider is exempt

The `stream` provider does **not** carry action links, in code and not merely in
prose. A capability token is a single-use credential scoped to one delivery, and
the firehose is a broadcast to every subscriber authorised for the topic;
embedding one there would hand an acknowledgement credential to every listener at
once, and the first subscriber to click would consume it. Stream envelopes carry
alert and delivery identifiers instead, which a subscriber resolves through the
authenticated API.

## Templates and rendering

Notification bodies are **data, never code**. Templates use a restricted
substitution engine: whitelisted variable paths plus exactly seven filters -
`upper`, `lower`, `truncate`, `json`, `url_encode`, `iso8601`, `default`. There
is no EEx, no conditionals beyond `default`, and no arbitrary code. Anything
resembling code (`<%`, `{%`, string interpolation) is rejected outright.

```
{{ alert.title }}
{{ alert.title | truncate: 80 }}
{{ alert.first_seen_at | iso8601 }}
{{ alert.severity | upper | default: "unknown" }}
```

Variable namespaces available to a template: `alert.*`, `device.*`, `rule.*`,
`route.*`, `policy.*`, `step.*`, `channel.*`, `provider.*`, `delivery.*`,
`links.*`, and `system.*`, plus the open namespaces `alert.metadata.*`,
`alert.labels.*`, `snapshot.*`, `device.tags.*`, and `rule.labels.*` whose leaves
are your own data.

Templates resolve per **(alert class x payload format)**, falling back to a
managed default for the format when no alert-class-specific template exists.
Every declared payload format - `slack_blocks`, `discord_embed`, `markdown`,
`plain`, `html`, `pagerduty_v2`, `json` - has a resolvable managed default, so no
alert class can render an empty body. First-party templates are managed records
reconciled on upgrade exactly like providers: **your override survives an
upgrade**, and an untouched managed template is refreshed.

## Email and SMTP

Email notifications go through the **single** outbound mail path,
`ServiceRadar.OutboundMail`, shared with identity mail (confirmation, password
reset). There is deliberately no second mailer.

### Why there is a mailer diagnostic

Both `Swoosh.Adapters.Test` and `Swoosh.Adapters.Local` return `{:ok, email}` and
deliver nothing - Test hands the message to the current test process, Local files
it in an in-memory mailbox nobody reads in production. A notification channel
pointed at either one reports **every delivery as `sent` and pages nobody**,
which looks exactly like a working channel until an incident proves otherwise.
That is why a misconfigured mailer used to look healthy.

`OutboundMail.diagnose/1` classifies the resolved mailer configuration and names
the specific reason mail will not leave the deployment. An email channel's
`validate_config/1` refuses to validate while the diagnosis is anything but
`:ok`, so the failure surfaces at configuration time rather than during an
outage. The classes:

| Class | Meaning |
| --- | --- |
| `mail_settings_unavailable` | Configuration could not be resolved at all (for example a briefly unreachable credential store). Transient - worth retrying |
| `mailer_not_configured` | No adapter at all |
| `non_delivering_adapter` | `Swoosh.Adapters.Test` or `.Local` - reports success, delivers nothing |
| `smtp_dependency_missing` | SMTP adapter without the `gen_smtp` dependency |
| `smtp_relay_missing` | SMTP adapter with no relay host |
| `api_key_missing` | An API adapter with no API key |
| `api_client_disabled` | An API adapter while the Swoosh API client is disabled, which makes every send raise |
| `unknown_adapter` | The configured adapter module is not part of this release |

Each message names the setting or environment variable to change, because a
diagnostic you cannot act on is only a slightly better silence.

`gen_smtp` is a dependency of `serviceradar_core` so SMTP works out of the box;
Swoosh declares it optional, which is how an SMTP configuration used to compile,
deploy, and then fail at the first send.

### Environment

| Variable | Meaning |
| --- | --- |
| `SERVICERADAR_MAILER_ADAPTER` | `smtp`, `local`, `test`, or an API adapter name (`sendgrid`, `mailgun`, `postmark`, ...) |
| `SERVICERADAR_CORE_MAILER_ADAPTER` | Same, and takes precedence - lets core differ from web-ng |
| `SMTP_RELAY_HOST` | Relay hostname. **Setting it alone selects the SMTP adapter** |
| `SMTP_RELAY_PORT` | Relay port, default 587 |
| `SMTP_RELAY_HOSTNAME` | HELO/EHLO name this deployment announces |
| `SMTP_RELAY_USERNAME` / `SMTP_RELAY_PASSWORD` | Relay credentials |
| `SMTP_RELAY_AUTH` | `always`, `never`, `if_available` (default) |
| `SMTP_RELAY_TLS` | STARTTLS: `always`, `never`, `if_available` (default) |
| `SMTP_RELAY_SSL` | `true` for implicit TLS (port 465) |
| `SERVICERADAR_MAIL_FROM_NAME` / `SERVICERADAR_MAIL_FROM_EMAIL` | Default `From:` |

The adapter name is resolved through an allowlist, never by turning an
environment variable into a module name. An unrecognised name **fails the boot**
with the accepted list, which is a deployment that does not start rather than one
that starts and mails nowhere.

A bare `SMTP_RELAY_HOST` with no adapter named selects SMTP: an operator who
supplied a relay meant to send mail through it, and a second variable to say so
has exactly one possible outcome.

With nothing set at all the mailer resolves to the Test adapter, and
`diagnose/0` is what makes that state visible instead of silent.

### Helm

`values.yaml` carries a `core.mailer` block; `templates/core.yaml` renders it
into the environment above.

```yaml
core:
  mailer:
    # "smtp", "local", "sendgrid", ... Leave empty to infer SMTP from `relay`.
    adapter: ""
    relay: "smtp.example.com"
    port: 587
    hostname: ""
    auth: "if_available"     # always | never | if_available
    tls: "if_available"      # STARTTLS
    ssl: false               # implicit TLS (port 465)
    from:
      name: "ServiceRadar"
      email: "noreply@example.com"
    # Credentials come from an existing Secret, never from values.
    existingSecret: "serviceradar-smtp"
    usernameKey: "smtp-username"
    passwordKey: "smtp-password"
```

The relay password is **never** a value. A password in `values.yaml` is a
password in the rendered manifest, in `helm get values`, and in whatever GitOps
repository holds the file. Create the Secret with the two keys above and name it
in `existingSecret`.

Operators who prefer not to use Helm for this can configure outbound mail
entirely in the UI under Settings > Mail; a settings row takes precedence over
the deployment environment, and its password resolves through the credential
broker. A missing settings row is not an error - it means "no operator override".

## Permissions

Notifications are a top-level RBAC section with **nine** three-part keys. Build a
least-privilege role from this table rather than reading the catalog module.

| Key | Gates | Default roles |
| --- | --- | --- |
| `notifications.channels.view` | The Channels tab and channel health; also the read side of the Providers tab (a channel is unreadable without knowing what kind of destination it is); also entry to `/settings/notifications` at all | Operator |
| `notifications.channels.manage` | The channel editor - create, edit, enable, disable, delete, including provider configuration and secret references | Admin |
| `notifications.routes.view` | Reading routes, escalation policies, escalation steps, schedules, templates, and silences; the routing preview | Operator |
| `notifications.routes.manage` | Authoring routes, escalation policies, steps, and schedules | Admin |
| `notifications.providers.manage` | The write side of the Providers tab: provider enable/disable, and declarative definition upload when that tier lands | Admin |
| `notifications.deliveries.view` | The Delivery Log, including suppressed rows and their reasons; the delivery history on an alert page | Helpdesk |
| `notifications.test.send` | Test-send from a channel. **Separate from channel edit on purpose**: a test send performs real egress with real credentials | Admin |
| `notifications.silences.manage` | Silence authoring and cancellation. Separate from routes because writing a silence *stops a page* - and an empty matcher set mutes the deployment | Operator |
| `notifications.stream.subscribe` | Subscribing to the `stream` provider firehose topic. **Not yet enforced**: the topic join is Phase 4 work; the key ships now so the vocabulary does not change under existing roles | Operator |

Two deliberate design notes:

- **Silences are read on the routing surface** (`notifications.routes.view`) and
  written with their own key. Reading a silence is reading routing
  configuration; writing one is stopping a page.
- **Acknowledge, snooze, and resolve reuse the existing
  `observability.alerts.manage`.** There is deliberately no notifications-section
  duplicate of it.

Every mutating event in the notifications LiveView is routed through a single
authorization gate before it reaches a handler, and an event with no declared
permission is **refused**, not permitted by default. A forged event from a client
that never rendered the control produces no state change, no outbound request,
and no database write.

## Migrating from the removed `webhooks:` config block

The old `webhooks:` block is gone. It appeared in two places, and it is worth
being precise about what that means for you:

- The Elixir key
  `config :serviceradar_core, ServiceRadar.Monitoring.WebhookNotifier, webhooks: [...]`
  was **never set by any shipped configuration file**, and the GenServer that
  read it was never started by any supervisor. Every call already returned
  `{:error, :not_running}`.
- The Helm `webhooks:` block in `serviceradar-config.yaml` landed in `core.json`,
  which Go decodes into a struct that has **no `Webhooks` field**. The key was
  silently discarded there too.

**There is therefore no operator data to migrate on either side, and no state to
hunt for.** What follows is a **key mapping** for anyone who hand-wrote the
Elixir configuration, not a data migration. If you never hand-wrote it, you had
no working webhook notifications to lose, because the delivery path did not
exist.

Old shape:

```elixir
config :serviceradar_core, ServiceRadar.Monitoring.WebhookNotifier,
  webhooks: [
    %{
      enabled: true,
      url: "https://hooks.example.com/x",
      headers: [%{key: "Authorization", value: "Bearer abc123"}],
      cooldown: :timer.minutes(5),
      template: nil
    }
  ]
```

New shape: one `NotificationChannel` on the seeded `webhook` provider.

| Old key | New home |
| --- | --- |
| `url` | Channel `config["url"]`. Now validated HTTPS-and-public at save time and again at request time |
| `headers` (non-credential) | Channel `config["headers"]` |
| `headers` (credential-bearing) | **Not** a plain header. `Authorization: Bearer abc123` becomes `auth_mode: "bearer"` plus `secret_refs["token"]`. `validate_config/1` rejects credential-shaped header names, so the migration cannot quietly copy a bearer token into a non-sensitive column |
| `cooldown` | Not a transport concern any more. Use the channel's `rate_limit_per_minute` for a send budget, or leave repeat suppression to dedupe and the rule's cadence |
| `template` (EEx) | A `NotificationTemplate` with `payload_format: json`. EEx is not supported; see [Templates and rendering](#templates-and-rendering). The default payload has no direct equivalent and does not need one - the `json` renderer's envelope carries the same fields under stable names |
| `enabled` | Channel `enabled` |

Everything the old block did badly is now somebody else's job and done once:
URL safety in the outbound policy, templating in the restricted renderer,
cooldown in dedupe and rate limiting, and state in delivery rows rather than in a
GenServer that lost it on restart.

## Troubleshooting

**"I was not paged."** Open the Delivery Log and filter by the alert. In order:

1. No rows at all for the alert -> the alert lifecycle never requested routing.
   Check that the alert actually fired.
2. A `suppressed` row with `no_matching_route` -> no enabled route claimed the
   alert. Check route `enabled`, `priority`, and `match_expression`.
3. A `suppressed` row with any other reason -> read the reason table
   [above](#the-nine-reasons-in-precedence-order). The reason names the object
   to go fix.
4. A `pending` row with `next_attempt_at` in the past -> a retry is waiting.
   Normal.
5. A `failed` row -> read `error_class` and `error_message`. If the channel has a
   fallback, look for the successor row carrying `originating_delivery_id`.
6. A `sent` row -> the destination accepted it. The problem is downstream of
   ServiceRadar.

**"I was paged too often."** The rule owns cadence. Raise the rule's
`renotify_seconds`. A policy `repeat_interval_seconds` below that floor is
rejected at save time, so it is not the cause.

**"Escalation fired too early / too late."** Step delays are measured from alert
fire time, not from the previous dispatch. If a step fired at an unexpected
moment, check for a snooze: after a snooze expires, remaining delays are measured
from the snooze expiry instant.

**"The email channel says it is healthy but nothing arrives."** Check the mailer
diagnosis. A `non_delivering_adapter` result means the deployment resolved to the
Test or Local adapter, which reports success and delivers nothing.

**"My edge-routed channel stopped delivering."** The agent likely has no live
control session. There is no store-and-forward on that path; the delivery relies
on retry and then one failover hop. Give the channel a control-plane fallback.
