# Change: Add a pluggable notification platform

## Why

ServiceRadar has **no working notification delivery**. Not a weak one - a
non-functional one:

- `ServiceRadar.Monitoring.WebhookNotifier` is never started by any supervisor
  in the repository, so every `send_alert/1` call returns
  `{:error, :not_running}` (`webhook_notifier.ex:129`).
- `Alert.send_notification` is a `# TODO` stub that logs and increments a
  counter (`alert.ex:314`).
- The `webhooks:` block shipped in `serviceradar-config.yaml:311` is read by
  nothing.
- `Alert` already has `acknowledge`, `resolve`, `escalate`, `suppress`, and
  `reopen` actions and an RBAC permission described verbatim as "Acknowledge and
  resolve alerts" - with **zero user interface**.

Operators therefore cannot be told when something breaks, and cannot act on an
alert when they find one. Meanwhile every new subsystem that needs to notify
somebody is pressured to build its own path, which
`openspec/specs/edge-architecture/spec.md:565` and
`openspec/specs/observability-signals/spec.md:334` already forbid.

Adding one more hardcoded transport repeats the mistake. Alertmanager and
Grafana both hardcoded their receiver lists and cannot accept a community
receiver without a release. ServiceRadar needs a notification **platform**:
a routing and escalation engine that operators configure, plus a provider
contract that third parties can extend without touching this codebase.

## What Changes

### Delivery engine (new)

- **Routing** from alerts to channels by predicate match, with priority ordering
  and Alertmanager-style `continue` semantics.
- **Escalation policies**: ordered steps with time-based promotion gated on
  acknowledgement state, each step fanning out to a *set* of channels.
- **Three distinct reliability mechanisms**, deliberately not conflated:
  transport **retry** (5xx/timeout, Oban backoff, bounded by the channel's
  `max_attempts`), transport **failover** (one hop to a fallback channel when
  retries exhaust or an agent is offline), and human **escalation** (step delay
  elapsed *and* still unacknowledged, measured from alert fire time rather than
  from the previous dispatch).
- A retry-eligible delivery stays **`:pending`** with `next_attempt_at` set;
  `:failed` is **terminal**, reached only by a non-retryable error or by
  exhausting `max_attempts`. Retry-due selection never picks up `:failed` rows.
- **Suppression** as an enumerable, audited decision - silences and maintenance
  windows, schedules, snooze, throttling, **devices marked out of service**, and
  **alerts matching no enabled route** - re-evaluated at every dispatch, never as
  a silent drop. A repeat of an identical decision updates the existing row's
  occurrence counter instead of inserting a duplicate, so "record everything"
  stays bounded.
- **Deduplication** consuming the existing `{rule_id, group_key}` incident
  identity and `StatefulAlertRule` cooldown/renotify, not a second scheme.
  `renotify_seconds` is the cadence floor; escalation and route settings may only
  make repeats less frequent, never more.
- **One originating path.** `AlertLifecycle` is the only path that emits a
  routing request for a new incident notification; the AshOban scheduler drives
  continuation work only - escalation-step-due, retry-due, and renotify - against
  deliveries that already exist. Routing requests are idempotent on
  `{alert_id, lifecycle_reason, step_number, dedupe_key}`.
- A durable **`NotificationDelivery`** record per attempt, carrying an alert
  snapshot so it outlives the alert (`AlertsRetentionWorker` hard-deletes alerts
  after 3 days), plus the fields that make the log answerable:
  `originating_delivery_id` (the failover back-reference), `payload_format` (what
  was actually rendered), `provider_version` (which definition rendered it), and
  `is_test` (test sends are excluded from every alert delivery and notification
  count, and are visually distinguished).

### Provider contract (new) - three extensibility tiers, one interface

| Tier | Adding a provider requires |
| --- | --- |
| `:native` Elixir transports | In-tree change plus a release |
| `:declarative` request templates | **Uploading a file in the UI. No code, no release.** |
| `:wasm_plugin` signed bundles | Publishing a signed plugin package |

There are exactly three extensibility tiers, **plus the built-in `:stream`
provider type** described below. `:stream` is a `provider_type` but not an
extensibility tier, because operators cannot author one; it ships seeded as a
first-party managed provider alongside slack, discord, webhook, and email.

Every provider implements the `ServiceRadar.Notifications.Transport` behaviour -
`deliver/2`, `validate_config/1`, `capabilities/0`, `test/2` - and every provider
in every tier implements the test action and declares `test` in its
`capabilities`. Routing, escalation, suppression, and acknowledgement never learn
which tier a channel uses.

Launch providers: **Slack, Discord, generic webhook, and email** as `:native`,
with **PagerDuty** following. A **seeded first-party `:declarative` catalog**
also ships, so the no-code tier is demonstrably usable on day one; its entries
are individually disablable by an operator.

### Execution route (new)

`execution_route` is a field on the channel: `:control_plane` (default) or
`:edge_agent`. Plugin-backed control-plane channels execute on the
platform-resident `serviceradar-agent` that already ships, through the same
`plugin.run_action` path as any edge dispatch - so exactly **one** Wasm host
exists in the product. Relocating a channel to site-local egress is a data edit,
not a repackage.

- **BREAKING (operational)**: `AgentCommandBus` is at-most-once with no
  store-and-forward, so an `:edge_agent`-only configuration cannot deliver the
  "this site went dark" page. Channels declare `fallback_channel_id`, the UI
  warns on an edge-only escalation policy bound to the alert's own partition,
  and the delivery row - never the command result - is the system of record.

### Two-way acknowledgement (new)

- Signed, single-use capability links for **Acknowledge / Snooze / Resolve** in
  every notification body - works across every provider with no per-provider
  code. The `:stream` provider is **exempt**: a broadcast firehose must not carry
  a single-use acknowledgement credential to every subscriber, so stream
  envelopes carry identifiers a subscriber resolves through the authenticated
  API instead.
- Native interactivity (Slack Block Kit buttons, Discord message components,
  PagerDuty acknowledgement webhooks) reusing the northbound HMAC callback stack
  verbatim - token from header/Bearer/body, sha256-only persistence, HMAC-SHA256
  over `<timestamp>.<raw_body>`, 300 s tolerance - which requires registering the
  notification callback route prefix with `ServiceRadarWebNGWeb.Api.RawBodyReader`,
  since it buffers raw bodies only for registered prefixes.
- **BREAKING**: adds a `:snooze` transition to the `Alert` state machine, a
  `snooze_until` timestamp, and an `acknowledged_by_user_id` foreign key
  alongside the existing free-text column.
- **BREAKING**: generalises `Alert.read :needs_notification`, which today
  filters `notification_count == 0` and therefore fires exactly once per alert
  and can never drive renotify, escalation, or retry.

### Configuration and operations UI (new)

- `/settings/notifications` as a single `Settings.Catalog` entry under the
  existing `:sys_alerts` group - Channels, Routes and Escalation, Silences,
  Providers, and a Delivery Log answering "why was I not paged?". The Delivery
  Log **displays suppressed rows with their `suppression_reason`** rather than
  omitting them; that is the surface where a withheld notification becomes
  visible.
- Acknowledge / snooze / resolve controls on the alert detail page, which is
  currently 1371 lines and entirely read-only.
- Test-send from any channel before saving, available for every provider in every
  tier.
- A new top-level `notifications` RBAC section in `Identity.RBAC.Catalog`
  following the existing `<section>.<noun>.<verb>` convention:
  `notifications.channels.view`, `notifications.channels.manage`,
  `notifications.routes.view`, `notifications.routes.manage`,
  `notifications.providers.manage`, `notifications.deliveries.view`,
  `notifications.test.send`, `notifications.silences.manage`, and
  `notifications.stream.subscribe`.

### Stream provider (new)

A built-in `:stream` provider, seeded as a first-party managed provider row,
publishing the canonical envelope to a Phoenix Channel topic gated by
`notifications.stream.subscribe` and backed by a durable JetStream subject so
reconnecting consumers replay rather than lose events. The firehose therefore
traverses the same routing, suppression, redaction, and audit path as every other
channel: a suppressed dispatch to a `:stream` channel publishes **no envelope**
and writes a delivery row with `state: :suppressed`, which the Delivery Log shows
with its reason.

### Plugin contract extensions

- A `notifications:` block in `plugin.yaml`, whose entry keys are owned by the
  manifest validator: `key`, `display_name`, `description`, `entrypoint`,
  `config_schema`, `capabilities`, `payload_formats`, `routes`,
  `credential_requirements`, and `inbound`. A `NotificationProvider.action_key`
  equals a `key` in the referenced package's validated manifest, and a manifest
  declaring `capabilities` without both `send` and `test` is rejected.
- A new `notify:v1` capability added to the manifest allowlist **and enforced by
  a `hasCapability` check in `go/pkg/agent`** - a capability declared only in
  Elixir is unenforced at runtime.
- **Runtime resolution of package-shipped display and config contracts.**
  `SignalDisplay.@built_in_contracts` is a compile-time `File.read!` over
  **seven entries over six distinct first-party paths** (powerdns 0.1.0 and
  0.1.1 share a path), so a third-party package cannot ship a renderable
  contract today without recompiling web-ng. This blocks genuine third-party
  extensibility and is fixed here.
- Notifier support in `serviceradar-sdk-go` and `serviceradar-sdk-rust`
  (separate repositories).

### Removals

- **BREAKING**: `ServiceRadar.Monitoring.WebhookNotifier` is replaced by the
  `generic_webhook` `:native` provider and removed; after this change the alert
  path does not invoke it at all. Its per-webhook cooldown and
  `%WebhookNotifier.Alert{}` struct are the de-facto contract three call sites
  already build against, and existing webhook configuration is migrated to
  `generic_webhook` `:native` channels so no destination is lost in the swap.
- The unused `webhooks:` block in `serviceradar-config.yaml`, the unused
  `WebhookConfig` / `CloudConfig` in `go/pkg/models/config.go:90-112`, and the
  orphaned `ServiceRadar.Identity.Senders.EmailDelivery` are removed.

### Explicit non-goals

On-call rotation calendars and override management, mobile push with
retry-until-acknowledged, incident timelines and postmortems, a second Wasm host
runtime, and multitenancy. ServiceRadar integrates with PagerDuty and Opsgenie
for real on-call rather than reimplementing them.

## Impact

- **Affected specs**: `notification-platform` (new), `notification-providers`
  (new), `notification-ui` (new), `wasm-plugin-system`,
  `plugin-configuration-ui`, `plugin-sdk-go`, `observability-rule-management`.
- **Affected code**:
  - `elixir/serviceradar_core` - new `ServiceRadar.Notifications` domain and
    migrations; `Monitoring.Alert` state machine and read actions;
    `Observability.StatefulAlertEngine.AlertLifecycle` trigger points;
    `Identity.RBAC.Catalog`; `OutboundMail` plus the `gen_smtp` dependency in
    `mix.exs`, which today has `swoosh` but no SMTP adapter; removal of
    `WebhookNotifier`.
  - `elixir/web-ng` - `/settings/notifications` LiveViews, alert detail
    acknowledgement controls, `Settings.Catalog`, notification callback
    controller and `RawBodyReader` path, firehose channel, runtime display
    contract resolution.
  - `go/pkg/agent` - `notify:v1` capability enforcement; notification action
    dispatch.
  - `proto/` - notification command payloads where the edge route requires them.
  - `helm/serviceradar` - NATS subject allowlist, mailer environment, removal of
    the dead `webhooks:` block.
  - `serviceradar-sdk-go`, `serviceradar-sdk-rust` - separate repositories.
- **Coordination**: `add-device-active-lifecycle` owns suppressing device-scoped
  alert *generation*; this change re-checks at the notification layer rather
  than duplicating it. `add-northbound-action-integrations`,
  `add-signed-northbound-action-callbacks`, `add-long-running-northbound-actions`,
  and `add-automation-callback-grants` touch the callback and HMAC surface this
  change reuses.
