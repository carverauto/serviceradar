# Implementation Tasks

Phases follow design.md "Migration Plan". Phase 1 is independently shippable and
alone restores working notification delivery. Do not start a later phase before
the previous phase's quality gates are green.

Conventions that apply to every phase:

- All schema changes are HAND-WRITTEN migrations under
  `elixir/serviceradar_core/priv/repo/migrations/`, applied with `mix ash.migrate`
  and reverted with `mix ash.rollback`. NEVER `mix ecto.gen.migration`,
  `mix ecto.migrate`, or `mix ash.codegen`. (This repo deliberately diverges from
  the generic Ash codegen guidance in `AGENTS.md`: `priv/resource_snapshots/` was
  deleted in commit 607b40f584 and does not exist, so `mix ash.codegen` has no
  baseline to diff against and would emit a whole-application migration. Of the
  377 migrations in the tree, exactly one references snapshots or codegen.)
- All tables, indexes, and constraints are created with `prefix: "platform"`.
- Docs are ASCII only.
- Cross-repository work is called out explicitly; it does not land in this repo.

## 1. Phase 1 - Delivery backbone

### 1.1 Notifications domain, Ash resources, and migration

- [x] 1.1.1 Create the domain module `elixir/serviceradar_core/lib/serviceradar/notifications.ex`
      (`use Ash.Domain`) and register `ServiceRadar.Notifications` in ALL FIVE
      `ash_domains` lists, not just the core one:
      `elixir/serviceradar_core/config/config.exs:179`,
      `elixir/serviceradar_core/config/test.exs:300`,
      `elixir/web-ng/config/config.exs:129`, and
      `elixir/web-ng/config/config.exs:316`, and - CRITICALLY -
      `elixir/serviceradar_core_elx/config/config.exs:24`, which is the config the
      DEPLOYED core image evaluates and which `runtime.exs:862` reads to expand the
      AshOban scheduler. Missing that fifth one leaves the domain invisible in
      PRODUCTION with its triggers never scheduled, while every local check passes.
- [x] 1.1.2 Add `ServiceRadar.Notifications.NotificationProvider`
      (`lib/serviceradar/notifications/notification_provider.ex`) with
      `provider_key`, `provider_type` (`:native | :declarative | :wasm_plugin | :stream`),
      `display_name`, `description`, `icon`, `config_schema`, `capabilities`,
      `supported_routes`, `payload_formats`, `definition`, `plugin_package_id`,
      `action_key`, `implementation_module`, `source`, `managed`,
      `template_version`, `template_fingerprint`, and state
      `:draft -> :active -> :disabled`. Document in the module doc that there are
      exactly THREE extensibility tiers (`:native`, `:declarative`,
      `:wasm_plugin`) PLUS the built-in `:stream` provider type; `:stream` is a
      `provider_type` but is not an extensibility tier, because operators cannot
      author one.
- [x] 1.1.2a Constrain `NotificationProvider.action_key` to what PHASE 1 can
      actually enforce: an `action_key` without a `plugin_package_id` is invalid,
      and `provider_type: :wasm_plugin` is REJECTED outright until Phase 3. Those
      two rules together mean nothing can be configured in Phase 1 that dispatch
      cannot resolve. The stronger cross-check - that `action_key` equals a `key`
      value in the `notifications:` block of the referenced package's validated
      manifest - is a PHASE 3 task (3.1.1b), because the manifest block itself does
      not exist until 3.1.1 adds it.
- [x] 1.1.3 Add `ServiceRadar.Notifications.NotificationChannel`
      (`notification_channel.ex`) with `name`, `provider_id`, `enabled`, `config`,
      `secret_refs`, `execution_route` (default `:control_plane`), `agent_uid`,
      `partition_id`, `fallback_channel_id`, `fail_closed`, `max_attempts`,
      `rate_limit_per_minute`, `health`, `last_success_at`, `last_failure_at`,
      `last_error`.
- [x] 1.1.3a Make `max_attempts` an attribute of `NotificationChannel`, defaulted
      from the bound provider. It is the transport retry bound consumed by
      retry-due selection in 1.3.8a; it is not an escalation or failover bound.
- [x] 1.1.4 Force-bind `NotificationChannel.partition_id` server-side from the
      mTLS-derived context, mirroring
      `lib/serviceradar/plugins/changes/bind_assignment_partition.ex:15`. The
      operator MUST NOT be able to supply it.
- [x] 1.1.5 Add `ServiceRadar.Notifications.NotificationRoute`
      (`notification_route.ex`) with `name`, `enabled`, `priority`,
      `match_expression`, `escalation_policy_id`, `dedupe_key_template`,
      `throttle_seconds`, `group_wait_seconds`, `group_interval_seconds`,
      `schedule_id`, and `continue` (Alertmanager semantics). This is NEW work, not
      a lift: `automation/northbound/action_event_handler.ex:154-198` declares
      `match_expression`, `target_resolver`, `input_template`,
      `dedupe_key_template`, `cooldown_seconds`, `rate_limit`, `approval_mode`, and
      `service_principal` - it has NO `priority`, `continue`, `throttle_seconds`,
      `group_wait_seconds`, `group_interval_seconds`, `escalation_policy_id`, or
      `schedule_id`. Only about four of these eleven fields have prior art there
      (`match_expression` and `dedupe_key_template` transfer directly;
      `cooldown_seconds` and `rate_limit` are prior art for `throttle_seconds`).
      Plan the remaining seven as fresh design, and read that handler as a
      reference for predicate shape only, never as a copy source.
- [x] 1.1.6 Add `ServiceRadar.Notifications.NotificationEscalationPolicy`
      (`name`, `repeat_count`, `repeat_interval_seconds`, `resolve_notifies`) and
      `ServiceRadar.Notifications.NotificationEscalationStep` (`step_number`,
      `delay_seconds`, `condition` of `:always | :if_unacknowledged`).
- [x] 1.1.7 Add the fan-out join resource
      `ServiceRadar.Notifications.NotificationEscalationStepChannel` so a step
      holds a *set* of channels (many-to-many), not a single channel.
- [x] 1.1.8 Add `ServiceRadar.Notifications.NotificationSchedule` (`name`,
      `timezone`, `windows` as a list of `{days, start_time, end_time}`, `mode` of
      `:active_within | :active_outside`). Do not model rotations.
- [x] 1.1.9 Add `ServiceRadar.Notifications.NotificationSilence` (`matchers`,
      `starts_at`, `ends_at`, `created_by_user_id`, `comment`, state
      `:scheduled | :active | :expired | :cancelled`).
- [x] 1.1.10 Add `ServiceRadar.Notifications.NotificationDelivery` with the state
      vocabulary copied from `ActionInvocationTarget`: `:pending`, `:dispatching`,
      `:sent`, `:failed`, `:expired`, `:cancelled`, `:suppressed`, `:skipped`;
      and fields `alert_id`, `route_id`, `policy_id`, `step_number`, `channel_id`,
      `dedupe_key`, `attempt_count`, `next_attempt_at`, `external_correlation_id`,
      `error_class`, `error_message`, `result_summary`, `suppression_reason`,
      `suppression_occurrence_count`, `last_evaluated_at`,
      `rendered_payload_digest`, `originating_delivery_id`, `payload_format`,
      `provider_version`, `is_test`, `execution_route`, `agent_uid`, `command_id`,
      `queued_at`, `started_at`, `finished_at`, `alert_snapshot`.
- [x] 1.1.10a Define the four delivery attributes added above so implementers
      cannot guess at them:
      - `originating_delivery_id` is the failover back-reference. A successor
        delivery created by a one-hop failover points at the row that failed, so
        the Delivery Log renders one failover chain instead of two unrelated
        attempts. It is null on a delivery that is not a failover successor.
      - `payload_format` is the format actually negotiated and rendered for this
        delivery (one of the declared `payload_formats`), not the channel's
        preference. It is what makes a rendered payload reproducible after the
        provider's format list changes.
      - `provider_version` is the provider definition version that rendered the
        row - `template_version` for a managed or declarative provider, the
        package version for a `:wasm_plugin` provider.
      - `is_test` marks a delivery produced by the test action rather than by an
        alert.
- [x] 1.1.10b Exclude `is_test` deliveries from every alert-facing count. A test
      delivery MUST NOT increment `Alert.notification_count`, MUST NOT appear in
      any delivery or notification total shown against an alert, and MUST NOT
      drive dedupe, throttle, escalation, or renotify state. It is still written,
      audited, and redacted like any other delivery.
- [x] 1.1.11 Make `NotificationDelivery.alert_snapshot` required. It is not an
      optimisation: `Jobs.AlertsRetentionWorker` hard-deletes resolved and
      suppressed alerts after a default of 3 days, so a delivery outlives its alert.
- [x] 1.1.12 Add `ServiceRadar.Notifications.NotificationAcknowledgement`
      (`delivery_id`, `alert_id`, `action` of
      `:acknowledge | :snooze | :resolve | :suppress | :unacknowledge`,
      `actor_kind` of `:platform_user | :external_principal | :system`,
      `actor_user_id`, `external_principal`, `note`, `snooze_until`, `source` of
      `:ui | :api | :callback | :action_link`, `received_at`).
- [x] 1.1.13 Add `ServiceRadar.Notifications.NotificationTemplate`
      (`provider_key` or `format`, `alert_class`, `payload_format`,
      `subject_template`, `body_template`, `managed`, `template_version`,
      `template_fingerprint`).
- [x] 1.1.13a Make template selection resolve per (alert class x payload format),
      falling back to a default template for the format when no alert-class
      specific template exists. Every payload format declared in 1.4.6 MUST have a
      resolvable managed default, so no alert class can render an empty body.
- [x] 1.1.13b Ship the first-party templates as `managed` records reconciled on
      upgrade with the same `managed` / `template_version` / `template_fingerprint`
      pattern used for providers in 1.4.9. An operator override MUST survive an
      upgrade: reconciliation refreshes a managed template only when its stored
      fingerprint still matches the shipped one.
- [x] 1.1.13c Render every template through the restricted substitution engine in
      1.4.5. A template is data, never code; template bodies are subject to the
      same whitelisted-path and fixed-filter rules as declarative definitions.
- [x] 1.1.14 Enable `AshPaperTrail` on provider, channel, route, policy, step,
      schedule, and silence resources so version tables are generated.
- [x] 1.1.15 Add `Ash.Policy.Authorizer` policies to every resource; scope reads
      and writes to the notification RBAC keys defined in 1.8.
- [x] 1.1.16 HAND-WRITE the migration
      `elixir/serviceradar_core/priv/repo/migrations/<timestamp>_create_notification_platform_tables.exs`,
      modeled on
      `elixir/serviceradar_core/priv/repo/migrations/20260515193000_create_northbound_action_tables.exs`,
      then apply it with `cd elixir/serviceradar_core && mix ash.migrate`. Do NOT
      run `mix ash.codegen`: `priv/resource_snapshots/` does not exist in this repo
      (deleted in 607b40f584), so codegen has no baseline and would emit a
      whole-application migration instead of this change's tables.
- [x] 1.1.17 Match the reference shape in
      `elixir/serviceradar_core/priv/repo/migrations/20260515193000_create_northbound_action_tables.exs`
      exactly: `@prefix "platform"`, `primary_key: false`, `add(:id, :uuid,
      null: false, default: fragment("uuid_generate_v7()"), primary_key: true)`,
      `fragment("now()")` defaults on the `inserted_at` / `updated_at` timestamps,
      explicit `prefix: @prefix` on every `create table` / `create index` /
      `references(...)`, a private `create_version_table/2` helper emitting one
      `*_versions` paper-trail table per audited resource, and a `down` that drops
      in reverse creation order.
- [x] 1.1.18 Add indexes for the hot paths: deliveries by
      `(alert_id, step_number, channel_id)`, deliveries by `(state, next_attempt_at)`,
      deliveries by `dedupe_key`, deliveries by `originating_delivery_id` (the
      failover chain lookup), silences by `(state, ends_at)`, routes by
      `(enabled, priority)`.
- [x] 1.1.18a Add a unique index over the suppression decision identity
      `(alert_id, policy_id, step_number, channel_id, dedupe_key, suppression_reason)`
      so the upsert in 1.3.5a cannot race two workers into duplicate rows. The
      index MUST be declared `NULLS NOT DISTINCT` (PostgreSQL 15+), or built as an
      expression index over COALESCE sentinels for the nullable columns. A plain
      unique index does NOT dedupe NULLs in PostgreSQL, and `policy_id`,
      `step_number`, and `channel_id` are all NULL on a `:no_matching_route` row
      (1.3.2a) - so without this, two identical unrouted-alert decisions both
      INSERT and the occurrence collapsing silently fails for exactly the case it
      exists to make visible. Cover it with the test in 1.10.2c.
- [x] 1.1.19 Verify rollback with `mix ash.rollback` and re-apply.

### 1.2 Alert lifecycle changes

- [x] 1.2.1 Add the `snooze_until` attribute to `Alert` plus a plain
      `update :snooze` action that sets it. Snooze SHALL NOT add a state-machine
      state. `elixir/serviceradar_core/lib/serviceradar/monitoring/alert.ex`
      declares `state_attribute :status` (line 93) over the states `pending`,
      `acknowledged`, `resolved`, `escalated`, `suppressed`, with the transitions
      `acknowledge`, `resolve`, `escalate`, `suppress`, `reopen` (lines 98-102);
      there is no target state a `:snooze` transition could move to, so none is
      added. `update :snooze` leaves `status` untouched and "snoozed" is a DERIVED
      condition: `status in [:pending, :escalated] and snooze_until > now()`.
      Rationale: it keeps snooze-expiry resumption a pure timestamp comparison
      (1.2.9), and it avoids auditing every existing alert query and status
      renderer for a new state. The attribute is `snooze_until` everywhere - the
      alert resource, `NotificationAcknowledgement`, the API, and the UI.
      `snoozed_until` is not a spelling this change uses anywhere.
- [x] 1.2.2 Add `acknowledged_by_user_id` as a real foreign key to
      `ServiceRadar.Identity.User` while retaining the existing free-text
      `acknowledged_by` / `resolved_by` columns for external principals.
- [x] 1.2.3 Split the scan by what it is keyed on. Keep `read :needs_notification`
      (`alert.ex:188-200`) ALERT-keyed and FIRST-NOTIFY ONLY, replacing the
      `notification_count == 0` filter with one that also excludes alerts that
      already have delivery rows. Renotify, escalation-step-due, and retry-due are
      properties of a DELIVERY, not of an alert, so they get their own
      delivery-keyed read rather than being folded into this one (1.2.6).
- [x] 1.2.4 Implement `update :send_notification` (`alert.ex:314`, currently a
      `# TODO` stub) to enqueue routing, never to deliver inline.
- [x] 1.2.5 Wire the routing request into
      `Observability.StatefulAlertEngine.AlertLifecycle` trigger points and make
      the request idempotent on
      `{alert_id, lifecycle_reason, step_number, dedupe_key}`. The field is
      `lifecycle_reason` (fire, renotify, escalate, resolve) - never
      `lifecycle_event`. Re-emitting the same tuple (a duplicate lifecycle
      callback, an Oban retry, an overlapping scheduler tick) MUST resolve to the
      existing work rather than produce a second dispatch.
- [x] 1.2.5a Enforce the two-part routing trigger rule in code and in the module
      docs, split by what each path is keyed on:
      - `AlertLifecycle`, together with the ALERT-keyed AshOban trigger
        `:send_notifications` acting as its catch-up safety net, is the only way a
        FIRST notification for a new incident is originated.
      - The DELIVERY-keyed scheduler added in 1.2.6 drives CONTINUATION work only -
        escalation-step-due, retry-due, and renotify - against deliveries that
        already exist.
      Neither crosses into the other's job: the delivery-keyed scheduler MUST NOT
      originate a first notification for an alert that has no delivery rows, and
      the alert-keyed trigger MUST NOT advance an escalation step or a retry.
- [x] 1.2.6 Keep the existing AshOban trigger `:send_notifications`
      (`alert.ex:128-137`) responsible for FIRST-NOTIFY ONLY. It scans ALERTS
      through `read_action :needs_notification`, and continuation work is keyed on
      DELIVERIES, so that scan structurally cannot drive it. Add a SECOND,
      DELIVERY-KEYED scheduler for retry-due, escalation-step-due, and renotify.
      This second scheduler is explicitly sanctioned - "do not add a second
      scheduler" contradicts the delivery-keyed continuation model and is not the
      rule here. Both schedulers run on the already-declared `:notifications` Oban
      queue (`config/config.exs:36`); no new queue is needed.
- [x] 1.2.7 Route the two engine-bypassing alert creators through the
      notification-layer dedupe and suppression path:
      `LogPromotion.update_alert_counts/2` (`log_promotion.ex:711-717`) and
      `TrivyReports.maybe_create_priority_alert/3` (`trivy_reports.ex:992`).
- [x] 1.2.8 Implement resolve-time notification close-out for channels that
      already fired, gated on `NotificationEscalationPolicy.resolve_notifies`.
- [x] 1.2.9 Add a snooze-expiry path that resumes the notification cadence once
      `snooze_until` passes. Because snooze is a derived condition rather than a
      state (1.2.1), resumption is a pure timestamp comparison: no transition
      fires and nothing has to be moved back out of a snoozed state. On
      resumption, the remaining escalation step delays are measured from the snooze
      expiry instant, which is the single exception to the alert-fire-time origin
      fixed in 1.3.7a.
- [x] 1.2.10 Keep every alert action ADDED BY THIS CHANGE atomic: implement
      `atomic/3` where needed and do not add `require_atomic? false`. This is a
      constraint on new actions only. `alert.ex` already carries
      `require_atomic? false` on four existing actions (lines 257, 291, 301, 326);
      those four are OUT OF SCOPE for this change, because converting them is a
      standalone refactor with its own regression surface, not a guard this change
      can satisfy in passing.

### 1.3 Decision engine

- [x] 1.3.1 Add `ServiceRadar.Notifications.Router` implementing predicate
      matching on `match_expression`, `priority` ordering, and `continue`
      semantics (first match wins when `continue == false`).
- [x] 1.3.2 Add `ServiceRadar.Notifications.Suppression` returning an enumerated
      reason from `:device_out_of_service`, `:silence`, `:schedule`, `:snoozed`,
      `:throttled`, `:acknowledged`, `:channel_disabled`, `:no_matching_route`,
      with `:dependency` reserved and unimplemented.
- [x] 1.3.2a Record `:no_matching_route` when an alert matches zero enabled
      `NotificationRoute` rows. The unrouted alert is otherwise the one case that
      silently produces nothing, which is exactly the failure an operator cannot
      debug. It is written through the same audit path as every other withheld
      notification and is filterable in the Delivery Log alongside them (1.7.8).
      Because there is no channel and no policy for an unrouted alert, the
      identity tuple in 1.3.5a carries nulls in those positions and still
      deduplicates on repeat.
- [x] 1.3.3 Implement the `:device_out_of_service` check against subject device
      `is_active == false` (`inventory/device.ex:558`) as defense in depth; do not
      duplicate the generation-side suppression owned by
      `add-device-active-lifecycle`.
- [x] 1.3.4 Re-run suppression at every dispatch, not only at routing, so an
      escalation step firing minutes later sees current device and silence state.
- [x] 1.3.5 Guarantee that every dispatch decision that withholds a notification
      writes a `NotificationDelivery` row with `state: :suppressed` and a
      populated `suppression_reason`. Silent drops are prohibited.
- [x] 1.3.5a Bound the growth that 1.3.5 would otherwise cause: a repeat of an
      IDENTICAL decision
      `{alert_id, policy_id, step_number, channel_id, dedupe_key, suppression_reason}`
      updates the existing row - incrementing `suppression_occurrence_count` and
      refreshing `last_evaluated_at` - instead of inserting a duplicate. This is
      what keeps "record everything" from turning a long-lived silence into
      unbounded table growth while still letting an operator see both why and how
      often. Implement it as an upsert against the unique index in 1.1.18a, and
      keep the update atomic (`atomic/3`, never `require_atomic? false`).
- [x] 1.3.6 Add `ServiceRadar.Notifications.Dedupe` consuming the existing
      `{rule_id, group_key}` incident identity, `cooldown_seconds`, and
      `renotify_seconds` from `StatefulAlertRule`. Do not author a second
      identity scheme; support the route `dedupe_key_template` override only.
- [x] 1.3.6a Fix cadence precedence rather than leaving it to whichever code path
      runs last: `StatefulAlertRule.renotify_seconds` is the FLOOR.
      `NotificationEscalationPolicy.repeat_interval_seconds` may only make repeats
      LESS frequent, so it MUST be `>= renotify_seconds`. Reject a policy
      configured below the floor at save time with an actionable message; do not
      silently clamp it. A route may only narrow the rule's cadence, never widen
      it. The rule owns how noisy an incident is allowed to be; notification
      configuration can only be quieter.
- [x] 1.3.7 Add `ServiceRadar.Notifications.Escalation` advancing steps only when
      the step delay has elapsed AND the alert is still unacknowledged, bounded by
      policy step count, `repeat_count`, and `repeat_interval_seconds`.
- [x] 1.3.7a Measure `NotificationEscalationStep.delay_seconds` from the ALERT
      FIRE TIME, never from the previous step's dispatch. Chaining delays off the
      previous dispatch makes total time-to-page depend on transport latency and
      retry behaviour, so a policy stops meaning what its author read. There is
      exactly ONE exception, and it must be implemented explicitly: after a snooze
      expires, the remaining step delays are measured from the snooze expiry
      instant (1.2.9).
- [x] 1.3.8 Keep retry, failover, and escalation as three separate mechanisms.
      Retry is transport-level and bounded by the channel's `max_attempts` plus
      Oban backoff; failover is exactly one hop to `fallback_channel_id`;
      escalation is human and gated on acknowledgement. No code path may treat one
      as another.
- [x] 1.3.8a Model retry so that `:failed` is TERMINAL. A retry-eligible delivery
      stays `:pending` with `next_attempt_at` set; it does not pass through
      `:failed` and come back. Only a non-retryable failure, or exhaustion of
      `max_attempts`, moves a row to `:failed`. Retry-due selection therefore
      selects `:pending` rows with `next_attempt_at <= now()` AND
      `attempt_count < max_attempts`, and MUST NOT select `:failed` rows - a scan
      that picks up `:failed` retries forever and defeats the attempt bound.
- [x] 1.3.8b On failover, create the successor delivery with
      `originating_delivery_id` pointing at the row that failed, so the Delivery
      Log renders one failover chain rather than two unrelated attempts. Failover
      fires when a delivery reaches `:failed`, or immediately on
      `{:error, {:agent_offline, _}}`, and never when the channel is
      `fail_closed`.
- [x] 1.3.9 Add `ServiceRadar.Notifications.RateLimiter` enforcing
      `rate_limit_per_minute` against a durable, restart-surviving counter (not
      in-memory GenServer state as `WebhookNotifier` used).
- [x] 1.3.10 Add the Oban workers FLAT in `lib/serviceradar/notifications/`:
      `dispatch_worker.ex`, `escalation_worker.ex`, `silence_expiry_worker.ex`,
      `snooze_expiry_worker.ex`, `delivery_retention_worker.ex`. Repo convention
      puts workers directly in the domain directory
      (`lib/serviceradar/jobs/alerts_retention_worker.ex`,
      `lib/serviceradar/plugins/addon_rollout_worker.ex`); the only subdirectories
      used under a domain are `changes/` and `checks/`, so a `workers/`
      subdirectory has no precedent in this repo and is not introduced here. All
      jobs idempotent, string-keyed args, no structs in args.
- [x] 1.3.11 Give `NotificationDelivery` its own retention policy independent of
      `Jobs.AlertsRetentionWorker`, configurable and defaulting longer than 3 days.
- [ ] 1.3.12 Emit `:telemetry` events for routed, suppressed, dispatched, sent,
      failed, failed-over, escalated, and acknowledged, with channel and provider
      tags.

### 1.4 Native transports and rendering

- [x] 1.4.1 Define the `ServiceRadar.Notifications.Transport` behaviour with
      exactly these callbacks: `deliver/2`, `validate_config/1`, `capabilities/0`,
      and `test/2`. There is no `send/2`. Routing, escalation, suppression, and
      acknowledgement never learn a channel's provider tier.
- [x] 1.4.1a Make `test/2` mandatory in every tier. Every provider - `:native`,
      `:declarative`, `:wasm_plugin`, and the built-in `:stream` - implements a
      test action and declares `test` in its `capabilities`, so "test-send before
      saving" (1.7.4) works uniformly. A provider or manifest that declares
      `capabilities` without both `send` and `test` is rejected.
- [ ] 1.4.1b Mark deliveries produced by `test/2` with `is_test: true` so the
      exclusions in 1.1.10b apply automatically rather than at each call site.
- [x] 1.4.2 Implement `Notifications.Transports.Slack`,
      `Notifications.Transports.Discord`,
      `Notifications.Transports.GenericWebhook`, and
      `Notifications.Transports.Email`.
- [x] 1.4.3 Add `Notifications.Transports.Registry` resolving
      `implementation_module` from a compile-time module allowlist. Never
      `String.to_atom/1` on stored or user input.
- [x] 1.4.4 Validate every operator-supplied outbound URL with
      `Palisade.OutboundURLPolicy.validate_https_public_url/2`
  (resolved at compile time to `ServiceRadar.Policies.OutboundURLPolicy` (the in-tree port; note `Palisade` is NOT a dependency of `serviceradar_core`, so `Palisade.OutboundURLPolicy` is undefined there)) before any request.
      `WebhookNotifier` did not do this; the replacement must.
- [x] 1.4.5 Add `Notifications.Renderer` implementing the restricted substitution
      engine: whitelisted variable paths plus exactly the filters `upper`,
      `lower`, `truncate`, `json`, `url_encode`, `iso8601`, `default`. No EEx, no
      arbitrary code, no `raw/1` on untrusted content.
- [x] 1.4.6 Support the declared `payload_formats`
      (`:slack_blocks`, `:discord_embed`, `:markdown`, `:plain`, `:html`,
      `:pagerduty_v2`, `:json`) via per-format renderer modules.
- [x] 1.4.6a Record the negotiated format on the delivery row as `payload_format`,
      and the provider definition version that rendered it as `provider_version`,
      at render time. Both are written before dispatch so a delivery stays
      explicable after the provider's format list or template version moves on.
- [x] 1.4.7 Pass every payload, result summary, and log line through
      `ActionRedaction` (policy `northbound-action-redaction-v1`,
      `automation/northbound/action_redaction.ex:11-32`) before persistence or
      display.
- [x] 1.4.8 Resolve channel secrets through `Credentials.SecretBroker` via
      `Plugins.SecretRefs`. Never call `Vault.decrypt!` directly.
- [x] 1.4.9 Seed the first-party providers (`slack`, `discord`, `webhook`,
      `email`) as `managed` records using the `managed` / `template_version` /
      `template_fingerprint` reconciliation pattern from
      `Observability.PresetRuleResource` and `rule_seeder.ex:312`, so operator
      edits survive upgrades. The built-in `:stream` provider row is seeded by the
      same seeder using the same pattern when Phase 4 lands (4.2.4); write the
      seeder so adding it is a data entry, not a second mechanism.
      `ServiceRadar.Notifications.ProviderSeeder`; the `:stream` row is already
      one more entry in `default_providers/0`, so 4.2.4 is data, not code.
      Templates get the same treatment in
      `ServiceRadar.Notifications.TemplateSeeder` (1.1.13a/b). Both are
      supervised from `Cluster.CoordinatorChildren` alongside
      `Observability.RuleSeeder`.

### 1.5 Email dependency and mailer configuration

- [x] 1.5.1 Add `{:gen_smtp, "~> 1.2"}` to `elixir/serviceradar_core/mix.exs`.
      The project has `swoosh` (`mix.exs:138`) but no `gen_smtp`, so SMTP from
      core does not work today. Commit the updated `mix.lock`.
- [x] 1.5.2 Select the Swoosh adapter at runtime in
      `elixir/serviceradar_core/config/runtime.exs` from
      `SERVICERADAR_MAILER_ADAPTER` (`local` / `smtp`), reading
      `SMTP_RELAY_HOST`, `SMTP_RELAY_PORT`, `SMTP_RELAY_USERNAME`,
      `SMTP_RELAY_PASSWORD`, `SMTP_RELAY_TLS`, `SMTP_RELAY_AUTH`.
- [x] 1.5.3 Route native email delivery through
      `ServiceRadar.OutboundMail.deliver/1`; do not add a second mail path.
- [x] 1.5.3a Fail loudly on incomplete mailer configuration. The email transport
      requires both the `gen_smtp` dependency from 1.5.1 and
      deployment-supplied mailer configuration; when either is missing,
      `validate_config/1` on an email channel MUST fail with an actionable
      diagnostic naming the missing dependency or environment variable. It MUST
      NOT silently resolve to `Swoosh.Adapters.Local` or a test adapter, which
      looks like a successful send and delivers nothing.
- [x] 1.5.4 Add the `SERVICERADAR_MAILER_ADAPTER` and `SMTP_RELAY_*` environment
      to `helm/serviceradar/templates/core.yaml` with a `mailer:` block in
      `helm/serviceradar/values.yaml`, sourcing the password from a Secret
      reference rather than a plain value.
- [x] 1.5.5 Fold `ServiceRadar.Identity.Senders.EmailDelivery` into `OutboundMail`
      and delete the orphaned module; update
      `identity/senders/send_password_reset_email.ex` and
      `identity/senders/send_confirmation_email.ex` call sites.
- [x] 1.5.6 Verify the release still builds:
      `cd elixir/serviceradar_core && MIX_ENV=prod mix release`.

### 1.6 Acknowledgement ingress - signed capability links

- [x] 1.6.1 Add `ServiceRadar.Notifications.ActionToken` minting one token per
      delivery per action (`acknowledge`, `snooze_1h`, `resolve`), persisting
      sha256 only, TTL-bounded, single-use per action.
      Backed by `NotificationActionToken` + `20260809150000_create_notification_action_tokens.exs`.
      `snooze_1h` is the link LABEL; the model is `:snooze` with `snooze_seconds`
      bound into the token, so the duration cannot be chosen by whoever clicks
      and "Snooze 4h" needs no new action name. The digest covers
      `{delivery_id, alert_id, action, secret}`, not the secret alone.
      Presenting a spent token is an idempotent success, not an error - see the
      `ActionToken` moduledoc on mail scanners that GET every link.
      `ServiceRadar.Notifications.ActionLinks` builds the `opts[:links]` set and
      `ActionRedemption` applies it through the existing `Alert` actions.
- [x] 1.6.2 Render `Acknowledge`, `Snooze 1h`, and `Resolve` links into every
      notification body so the mechanism works across all providers with zero
      per-provider code. A `Snooze` action records `snooze_until` on the alert and
      on the `NotificationAcknowledgement` row.
- [x] 1.6.2a Exempt the `:stream` provider from the action-link requirement of
      1.6.2, in code and in the renderer, not merely in prose. A capability token
      is a single-use credential scoped to one delivery, and the firehose is a
      broadcast to every subscriber authorised for the topic; embedding one there
      hands an acknowledgement credential to every listener at once. Stream
      envelopes carry alert and delivery identifiers that a subscriber resolves
      through the authenticated API, never an action link. State the exemption
      wherever action links are required, including the docs in 1.11.1 and 4.4.5.
- [x] 1.6.3 Add `ServiceRadarWebNGWeb.API.NotificationActionController` plus
      routes under `/api/notifications/actions/` in
      `elixir/web-ng/lib/serviceradar_web_ng_web/router.ex`, with a confirmation
      interstitial so link prefetchers cannot fire an action. `GET` renders the
      interstitial and calls only `ActionToken.verify/2` (a read); `POST` is the
      one action that reaches `ActionRedemption.redeem/2`. The route sits on its
      own `:notification_action` pipeline, outside every auth plug and outside
      `protect_from_forgery` - the capability IS the authorisation. Failures
      render one page per `ActionToken.public_reason/1` answer, so the endpoint
      cannot enumerate deliveries.
- [x] 1.6.4 Register the notification callback route prefix with
      `ServiceRadarWebNGWeb.Api.RawBodyReader`. It buffers raw bodies ONLY for
      registered path prefixes, and today the only registered prefix is
      `@callback_prefix "/api/northbound/action-callbacks/"`
      (`elixir/web-ng/lib/serviceradar_web_ng_web/api/raw_body_reader.ex:4`).
      Convert it to a prefix list that also buffers
      `/api/notifications/callbacks/`. Skipping this does not fail loudly: the
      verifier falls back to a re-encoded body and breaks signatures for exactly
      the providers that sign bytes.
- [x] 1.6.4a Add a test that asserts the notification callback prefix is
      registered with `RawBodyReader` and that the raw body reaching the
      controller is byte-identical to what was posted. A prose-only registration
      is the failure mode this task exists to prevent. Covered in
      `elixir/web-ng/test/phoenix/controllers/api/raw_body_reader_test.exs`:
      both prefixes buffer byte-identically (including a chunked read), an
      unrelated path does not, and `/api/notifications/actions/` - a capability
      link rather than a signed callback - is proven NOT buffered.
- [x] 1.6.5 Compare tokens with `Plug.Crypto.secure_compare`; rate-limit and
      audit failed attempts. CORE HALF DONE in `ActionToken.verify/2`: constant-time
      digest comparison, a decoy comparison for an unknown selector so timing does
      not enumerate live capabilities, and `public_reason/1` collapsing every
      failure but expiry to one answer so the response body does not either.
      WEB-NG HALF DONE in 1.6.3: the `:rate_limit_notification_action` pipeline
      applies the `:notification_action` bucket per IP, and every failed
      presentation writes a `:policy_denied` security event carrying the client
      IP and the public reason - never the token or its selector, which would
      put a live credential in the audit log.
- [x] 1.6.6 Write a `NotificationAcknowledgement` row for every accepted action
      with the correct `actor_kind` and `source`, and halt escalation on
      acknowledge. `ActionRedemption.redeem/2` writes
      `actor_kind: :external_principal` / `source: :action_link` (there is no
      platform user behind a link click) and applies the action through the
      existing `Alert` actions inside one transaction with the token consume.
      Escalation halts BY the `:acknowledged` transition, because
      `Suppression.acknowledged?/1` keys on `status` and suppression is
      re-evaluated at dispatch; cancelling scheduled deliveries as well would be a
      second implementation of the same gate.
      NOTE: `transition :acknowledge` was widened to `from: [:pending, :escalated]`.
      With `from: :pending` alone the alerts that `auto_escalate` had moved on -
      exactly the ones a human most needs to take ownership of - were the ones no
      acknowledgement could reach, so an `:if_unacknowledged` ladder could never be
      halted by answering it.

### 1.7 web-ng configuration and operations UI

- [x] 1.7.1 Add the `/settings/notifications` entry to
      `elixir/web-ng/lib/serviceradar_web_ng_web/settings/catalog.ex` with
      `parent_group: :sys_alerts` (group declared at `catalog.ex:143`).
- [x] 1.7.2 Create
      `elixir/web-ng/lib/serviceradar_web_ng_web/live/settings/notifications_live/`
      with tabs: Channels, Routes and Escalation, Silences, Providers, Delivery Log.
- [x] 1.7.3 Channel editor: provider selection, schema-driven config form via the
      existing `ServiceRadarWebNGWeb.PluginConfigForm` renderer
      (`elixir/web-ng/lib/serviceradar_web_ng_web/components/plugin_config_form.ex:1`),
      secret fields that never echo stored values, `execution_route`,
      `fallback_channel_id`, `fail_closed`, `max_attempts`,
      `rate_limit_per_minute`, and health display.
- [x] 1.7.4 Test-send from a channel before saving, surfacing the redacted
      transport result. The resulting delivery row carries `is_test: true` and is
      visually distinguished in the Delivery Log from a real alert delivery.
- [x] 1.7.5 Route editor with predicate builder, priority ordering, `continue`
      toggle, schedule binding, and escalation policy binding.
- [x] 1.7.6 Escalation policy editor with ordered steps and a multi-channel
      fan-out picker per step.
- [x] 1.7.7 Silence authoring, cancellation, and a "currently suppressed" view.
- [x] 1.7.8 Delivery Log answering "why was I not paged?" - filterable by alert,
      channel, state, and `suppression_reason`, with redacted payload digests.
      Suppressed rows are DISPLAYED with their `suppression_reason` and
      occurrence count, never omitted; that includes `:no_matching_route` rows for
      alerts that matched no route at all. Show the failover chain by following
      `originating_delivery_id`, and mark `is_test` rows distinctly.
- [x] 1.7.9 Add Acknowledge / Snooze / Resolve controls to
      `elixir/web-ng/lib/serviceradar_web_ng_web/live/alert_live/show.ex` (today
      read-only) and bulk acknowledge/snooze to `live/alert_live/index.ex`.
      Bulk landed on `ServiceRadarWebNGWeb.LogLive.Index` instead:
      `live/alert_live/index.ex` is a dead route that only `push_navigate`s to
      `/observability/alerts`, which `LogLive.Index` serves. Alert lifecycle
      calls go through `ServiceRadarWebNG.AlertActions`, which authorizes on
      `observability.alerts.manage` and writes the `NotificationAcknowledgement`
      in the same transaction as the transition. The alert page also renders the
      alert's `NotificationDelivery` history, suppressed rows included.
- [x] 1.7.10 Observe the Iron Laws in every new LiveView: no database queries in
      disconnected mount, `connected?/1` before PubSub subscribe, streams for
      lists larger than 100 rows, and authorization in every `handle_event`.

### 1.8 RBAC and settings catalog consistency

- [x] 1.8.1 Add a TOP-LEVEL `notifications` section to
      `elixir/serviceradar_core/lib/serviceradar/identity/rbac/catalog.ex` using
      the existing three-part `<section>.<noun>.<verb>` convention that
      `observability.alerts.manage` already follows. The section holds exactly
      these NINE keys:
      `notifications.channels.view`,
      `notifications.channels.manage`,
      `notifications.routes.view`,
      `notifications.routes.manage`,
      `notifications.providers.manage`,
      `notifications.deliveries.view`,
      `notifications.test.send`,
      `notifications.silences.manage`,
      `notifications.stream.subscribe`.
- [x] 1.8.1a Do not introduce four-part keys and do not nest notifications under
      `observability`. `observability.notifications.*` in any form is wrong; the
      catalog test in 1.8.3 and the RBAC catalog's own shape both assume the
      three-part convention.
- [ ] 1.8.1b Map each key to its surface so no permission is decorative:
      `notifications.channels.view` / `.manage` gate the Channels tab and the
      channel editor; `notifications.routes.view` / `.manage` gate the Routes and
      Escalation tab, route authoring, escalation policies, and schedules;
      `notifications.providers.manage` gates the Providers tab, declarative
      upload (2.3.3), and provider enable/disable; `notifications.deliveries.view`
      gates the Delivery Log (1.7.8); `notifications.test.send` gates test-send
      (1.7.4) separately from channel edit, because a test send performs real
      egress; `notifications.silences.manage` gates silence authoring and
      cancellation; `notifications.stream.subscribe` gates the firehose topic
      (4.2.2).
- [x] 1.8.2 Reuse the existing `observability.alerts.manage` permission for
      acknowledge / snooze / resolve; its description ("Acknowledge and resolve
      alerts") finally becomes true. Do not add a notifications-section duplicate
      of it.
- [x] 1.8.3 Satisfy the Settings.Catalog gate at
      `elixir/web-ng/test/phoenix/settings/catalog_test.exs` - NOT the core RBAC
      `test/serviceradar/identity/rbac/catalog_test.exs`, which is a different
      test. That gate asserts every catalog view's `permission` is in
      `RBAC.Catalog.permission_keys/0` (line 30) AND, critically, that every view's
      `live_view` is reachable in the Phoenix router (the orphan detector, line
      80). ORDERING: the LiveView module (1.7.2) and its router entry MUST land
      BEFORE the catalog entry (1.7.1), or the orphan detector fails.
- [x] 1.8.4 Grant the new keys to the default administrator and operator roles in
      the RBAC seed data.

### 1.9 Dead code disposition

- [x] 1.9.1 Delete `ServiceRadar.Monitoring.WebhookNotifier`
      (`monitoring/webhook_notifier.ex`) and migrate its call sites onto a
      `generic_webhook` `:native` channel. There are FOURTEEN references across TWO
      modules, not three call sites:
      `observability/stateful_alert_engine/alert_lifecycle.ex:104` and `:114`;
      `monitoring/alert_generator.ex:97`, `:176`, `:320`, `:334`, `:369`, `:382`,
      `:395`, `:407`, `:437`, and `:447`; plus the nested modules
      `WebhookNotifier.Alert` (`webhook_notifier.ex:57`) and
      `WebhookNotifier.WebhookConfig` (`:83`). Nothing supervises
      `WebhookNotifier` and nothing tests it, so EVERY one of those calls already
      takes the `:not_running` branch (`webhook_notifier.ex:133`) and delivers
      nothing. Design the replacement from the ALERT DATA available at each call
      site, NOT from the `%WebhookNotifier.Alert{}` / `%WebhookNotifier.WebhookConfig{}`
      struct shapes or the per-webhook cooldown code - those are dead shapes with
      no proven runtime behaviour to preserve, and treating them as a contract
      would carry a never-executed design into the replacement. After this task,
      no alert path invokes
      `WebhookNotifier` - add a compile-or-test-time assertion that the module no
      longer exists rather than relying on review to catch a reintroduced call.
      DONE. Every call site was DELETED rather than replaced: `AlertGenerator`
      creates an `Alert` row, and an alert row with `notification_count == 0` is
      already a routing request through `Alert.:needs_notification` ->
      `:send_notification` -> `:fire`. The two sites that had no alert row -
      `startup_notification/1` and `shutdown_notification/1` - had ZERO callers
      repo-wide and were deleted with the path. `stats_anomaly/2` had no alert
      row either and now creates one (`source_type: :system`), which makes it
      deliver for the first time. `mark_service_recovered/1` reset a map nothing
      ever read; `mark_gateway_recovered/1` re-armed an in-process "Node Offline"
      duplicate guard that is now `Dedupe` + `Suppression` (D6), durable instead
      of lost on restart. The assertion is
      `test/serviceradar/notifications/webhook_notifier_retired_test.exs`.
- [ ] 1.9.1a Migrate existing operator webhook configuration onto
      `generic_webhook` `:native` channels as part of the upgrade, so a
      deployment that had a configured webhook keeps delivering. Document the
      mapping from the removed `webhooks:` keys to channel `config` fields in
      1.11.4. NOTE from 1.9.1/1.9.2: there is no operator configuration to
      migrate. `WebhookNotifier` read
      `Application.get_env(:serviceradar_core, ServiceRadar.Monitoring.WebhookNotifier, [])`
      and NO config file in the repo ever set that key, so `webhooks` was always
      `[]` and `handle_call` returned `{:error, :no_webhooks_configured}` even
      had the process been started. The Helm `webhooks:` block landed in
      `core.json`, which Go decodes into `models.CoreServiceConfig` - a struct
      with no `Webhooks` field, so the key was silently discarded there too. This
      task is therefore documentation of the mapping for operators who hand-wrote
      config, not a data migration.
- [x] 1.9.2 Remove the unread `webhooks:` block from
      `helm/serviceradar/files/serviceradar-config.yaml:311`.
- [x] 1.9.3 Remove `WebhookConfig` and `CloudConfig` from
      `go/pkg/models/config.go:90-112` plus every reference; regenerate BUILD deps
      with gazelle and rebuild. Both were unreferenced across the whole `go/`
      tree, and `Header` - whose only use was `WebhookConfig.Headers` - went with
      them. No gazelle run was needed: `//go/pkg/models` globs `*.go` with a
      `# keep`, and no file was added or removed.
- [ ] 1.9.4 Resolve `alert_events: "events.alert"`
      (`elixir/serviceradar_core/lib/serviceradar/nats/channels.ex:54`, doc line
      16) - either wire it to the alert lifecycle subject or delete the constant.
      Zero producers and consumers exist today.
- [x] 1.9.5 Delete `ServiceRadar.Identity.Senders.EmailDelivery` once 1.5.5 lands.

### 1.10 Phase 1 tests

- [x] 1.10.1 Unit tests for `Router` (priority, `continue`, no-match), `Dedupe`,
      `Escalation` (delay elapsed and unacknowledged), and `RateLimiter`
      (restart-surviving budget).
- [x] 1.10.2 Suppression tests covering every reason value including
      `:no_matching_route`, plus a test that asserts a `:suppressed` delivery row
      is always written.
- [ ] 1.10.2a Suppression-dedupe test: repeating an identical decision tuple N
      times leaves exactly one row with `suppression_occurrence_count == N` and a
      refreshed `last_evaluated_at`; changing any element of the tuple (including
      `suppression_reason`) produces a second row.
- [ ] 1.10.2b Unrouted-alert test: an alert matching zero enabled routes produces
      a `:no_matching_route` suppressed row that is visible through the same
      Delivery Log query as every other withheld notification.
- [ ] 1.10.2c Unrouted-alert COLLAPSE test, distinct from 1.10.2b: repeating the
      same `:no_matching_route` decision - the tuple whose `policy_id`,
      `step_number`, and `channel_id` are all NULL - leaves exactly ONE row with an
      incremented `suppression_occurrence_count`, not a new row per evaluation.
      This is the test that proves the NULL handling required by 1.1.18a is
      actually in the index; a plain unique index passes 1.10.2a and fails here.
- [x] 1.10.3 A regression test proving suppression is re-evaluated at dispatch:
      device marked inactive between routing and the escalation step.
- [x] 1.10.4 Retry / failover / escalation separation tests asserting a transport
      5xx never advances the escalation step and an unacknowledged timer never
      counts as a transport retry.
- [x] 1.10.4a Retry-terminality tests: a retry-eligible failure leaves the row
      `:pending` with `next_attempt_at` set and never transits `:failed`;
      exhausting `max_attempts` moves it to `:failed`; and the retry-due query
      returns no `:failed` row even when its `next_attempt_at` is in the past.
- [x] 1.10.4b Failover-chain test: the successor delivery carries
      `originating_delivery_id` pointing at the failed row, and a `fail_closed`
      channel produces no successor at all.
- [x] 1.10.4c Escalation-timing tests: step delays are measured from alert fire
      time even when step 1 dispatch was delayed by retries, and after a snooze
      expiry the remaining delays are measured from the snooze expiry instant.
- [x] 1.10.4d Cadence-precedence test: saving a policy whose
      `repeat_interval_seconds` is below the rule's `renotify_seconds` is
      rejected with an actionable message and is not silently clamped.
- [x] 1.10.5 Transport tests with a stubbed HTTP client for Slack, Discord, and
      generic webhook, plus an SSRF test asserting a private-IP URL is rejected by
      `Palisade.OutboundURLPolicy.validate_https_public_url/2`.
- [x] 1.10.6 Renderer tests: whitelisted paths only, each of the seven filters,
      and rejection of anything resembling code.
- [x] 1.10.6a Template tests: a managed default resolves for every declared
      payload format; an alert-class specific template wins over the format
      default; an operator-edited template survives a `template_version` bump
      while an untouched managed one is refreshed.
- [x] 1.10.6b Delivery-provenance test: `payload_format` and `provider_version`
      on the row match what actually rendered, and remain correct after the
      provider's `payload_formats` list or `template_version` changes.
- [x] 1.10.6c Transport-behaviour conformance test: every registered transport
      exports `deliver/2`, `validate_config/1`, `capabilities/0`, and `test/2`,
      declares both `send` and `test` in `capabilities`, and no module exports a
      legacy `send/2`.
- [ ] 1.10.6d Test-delivery isolation test: a `test/2` send writes an
      `is_test: true` row that does not change `Alert.notification_count`, dedupe
      state, throttle state, or escalation position.
- [x] 1.10.6e Email-configuration test: with `gen_smtp` or the mailer environment
      absent, `validate_config/1` on an email channel returns an actionable error
      naming the missing piece and does not fall back to a local or test adapter.
- [x] 1.10.7 Redaction test proving no secret reaches a persisted delivery row or
      log line.
- [x] 1.10.8 Alert tests for the new `update :snooze` action and for
      `acknowledged_by_user_id` population: `update :snooze` sets `snooze_until`
      and leaves `status` UNCHANGED; the derived snoozed condition
      (`status in [:pending, :escalated] and snooze_until > now()`) is true before
      expiry and false after; and the state machine still declares exactly the five
      states and five transitions it had before, proving no snoozed state was
      added.
- [x] 1.10.9 Delivery-outlives-alert test: delete the alert, assert the delivery
      row and its `alert_snapshot` still render.
- [x] 1.10.10 Action-token tests: single-use, TTL expiry, sha256-only storage,
      tampered token rejection.
- [ ] 1.10.11 LiveView tests for channel create/edit/test-send, route authoring,
      silence create/cancel, delivery log filtering, and alert acknowledge.
- [ ] 1.10.12 An authorization test asserting each notification LiveView and
      `handle_event` denies a user lacking the permission key.
- [ ] 1.10.12a An RBAC catalog test asserting the `notifications` section holds
      exactly the nine keys from 1.8.1, that every one is three-part, and that no
      `observability.notifications.*` key exists anywhere in the catalog.
- [x] 1.10.13 Integration test (tagged `:integration`, run against the
      `srql-fixtures` CNPG scratch database) exercising alert created -> routed ->
      suppressed-or-delivered -> acknowledged, asserting the delivery rows.

### 1.11 Phase 1 docs

- [ ] 1.11.1 Add `docs/docs/notifications.md` covering channels, routes,
      escalation policies, schedules, silences, every suppression reason
      (including `:no_matching_route`), and the delivery log. Document that
      escalation delays are measured from alert fire time with the snooze-expiry
      exception, that `:failed` is terminal while retries stay `:pending`, and
      that the rule's `renotify_seconds` is the cadence floor. ASCII only.
- [ ] 1.11.1a Document the nine `notifications.*` permission keys and which
      surface each one gates, so an operator can build a least-privilege role
      without reading the catalog module.
- [ ] 1.11.2 Document that `:control_plane` is the default and the recommended
      route, and that `:edge_agent` is only for destinations unreachable from the
      platform.
- [ ] 1.11.3 Document the SMTP configuration surface
      (`SERVICERADAR_MAILER_ADAPTER`, `SMTP_RELAY_*`) in
      `docs/docs/helm-configuration.md` and the new notifications page.
- [ ] 1.11.4 Document the removal of the `webhooks:` config block and the
      migration path to a `generic_webhook` channel.
- [ ] 1.11.5 Register the new page in `docs/sidebars.ts`.

### 1.12 Phase 1 quality gates

- [ ] 1.12.1 `./scripts/elixir_quality.sh --project elixir/serviceradar_core`
- [ ] 1.12.2 `./scripts/elixir_quality.sh --project elixir/web-ng --phoenix`
- [ ] 1.12.3 `cd elixir/web-ng/assets && sfw npm run build:js && sfw npm run build:css`
      if any JS/CSS changed.
- [ ] 1.12.4 `bazel run //:gazelle` and `bazel test --config=remote //go/pkg/models/...`
      after the Go config removal.
- [ ] 1.12.5 `openspec validate add-notification-platform --strict`

## 2. Phase 2 - Declarative providers

### 2.1 Request template document format

- [ ] 2.1.1 Define the declarative definition document
      (`NotificationProvider.definition`): method, URL template, header templates,
      body template, auth mode, success predicate, retryable-status set, and
      response field extraction for `external_correlation_id`.
- [ ] 2.1.2 Add `ServiceRadar.Notifications.Declarative.Definition` with a strict
      validator that rejects unknown keys and any construct outside the restricted
      substitution grammar.
- [ ] 2.1.3 Validate the provider `config_schema` with `Plugins.ConfigSchema`; the
      declarative definition may reference only fields the schema declares.
- [ ] 2.1.4 Reject `html`, `raw_html`, `javascript`, `js`, `component`,
      `component_ref`, `live_view`, `react`, and `ui_code` keys, matching the
      manifest validator at `plugins/manifest.ex:986-997`. Providers describe UI
      declaratively; they never ship markup.

### 2.2 Declarative execution engine

- [ ] 2.2.1 Implement `Notifications.Transports.Declarative` behind the same
      `Transport` behaviour, so routing and escalation cannot tell the tier.
- [ ] 2.2.2 Guard every resolved URL with
      `Palisade.OutboundURLPolicy.validate_https_public_url/2` at request time,
      after substitution, not only at save time.
- [ ] 2.2.3 Resolve secrets through `Credentials.SecretBroker` and inject them
      into headers or the body only at request construction; never persist a
      rendered payload containing a secret.
- [ ] 2.2.4 Map response status to the retry / failover decision using the
      definition's retryable-status set.

### 2.3 Upload, versioning, and catalog UI

- [ ] 2.3.1 Add declarative provider upload to the Providers tab with inline
      validation errors and a rendered preview of the resulting request.
- [ ] 2.3.2 Version uploaded definitions and allow rollback to a previous version;
      surface which channels bind to which version.
- [ ] 2.3.3 Enforce that a definition upload requires
      `notifications.providers.manage`.
- [ ] 2.3.4 Prove the extensibility claim in a test: adding a provider requires no
      repository change and no release.

### 2.4 Seeded declarative catalog

- [ ] 2.4.1 Ship a first-party seeded `:declarative` catalog with the change, so
      the tier is demonstrably usable without writing code. The catalog MUST
      exist and MUST be non-empty at install. Destinations such as Mattermost,
      Rocket.Chat, Telegram, Gotify, ntfy, Zulip, Google Chat, Opsgenie,
      ServiceNow, Jira, Microsoft Teams, Twilio, and PagerDuty Events API v2 are
      EXAMPLES of what the catalog may contain, not a closed list; adding or
      dropping one of these names is not a contract change.
- [ ] 2.4.1a Make every seeded catalog entry individually disablable by an
      operator, and make the disable survive upgrade reconciliation. A seeded
      provider an operator disabled MUST NOT be silently re-enabled by the next
      release.
- [ ] 2.4.1b Give every seeded entry the mandatory `test` capability from 1.4.1a
      so "test-send before saving" works for the catalog exactly as it does for
      the four `:native` providers.
- [ ] 2.4.2 Reconcile seeded definitions on upgrade with
      `managed` / `template_version` / `template_fingerprint` so operator edits are
      never clobbered.

### 2.5 Phase 2 tests, docs, and gates

- [ ] 2.5.1 Definition validator tests including every rejection case.
- [ ] 2.5.2 Golden-request tests for each seeded provider using a stub HTTP client.
- [ ] 2.5.3 Upgrade-reconciliation test: an operator-edited seeded provider is not
      overwritten; an untouched one is refreshed; and an operator-disabled seeded
      provider stays disabled across the upgrade.
- [ ] 2.5.3a Catalog-existence test: the seeded declarative catalog is non-empty
      after install and every entry declares both `send` and `test` capabilities.
- [ ] 2.5.4 LiveView tests for upload, validation failure, and version rollback.
- [ ] 2.5.5 Add `docs/docs/notification-providers.md` documenting the declarative
      document format with a complete worked example. ASCII only.
- [ ] 2.5.6 `./scripts/elixir_quality.sh --project elixir/serviceradar_core` and
      `./scripts/elixir_quality.sh --project elixir/web-ng --phoenix`.

## 3. Phase 3 - Plugin providers and the edge route

### 3.1 Manifest and capability contract

- [ ] 3.1.1 Add the `notifications:` block to `plugin.yaml` parsing and validation
      in `elixir/serviceradar_core/lib/serviceradar/plugins/manifest.ex`. The
      manifest validator owns these entry keys and they are spelled exactly:
      `key`, `display_name`, `description`, `entrypoint`, `config_schema`,
      `capabilities`, `payload_formats`, `routes`, `credential_requirements`,
      `inbound`. There is no `provider_key` key and no `inbound_callback` key in
      the manifest block; reject unknown keys rather than ignoring them.
- [ ] 3.1.1a Reject a `notifications:` entry whose `capabilities` omits `send` or
      `test`. Both are mandatory in every tier (1.4.1a), so a manifest that
      declares one without the other fails validation with a message naming the
      missing capability.
- [ ] 3.1.1b Bind `NotificationProvider.action_key` to a `key` value in the
      validated `notifications:` block of the referenced package (1.1.2a), and
      reject a provider row whose `action_key` the package manifest does not
      declare.
- [ ] 3.1.2 Add `notify:v1` to `@allowed_capabilities`
      (`plugins/manifest.ex:61-83`).
- [ ] 3.1.3 Enforce `notify:v1` with a `hasCapability` check in `go/pkg/agent`
      alongside the existing checks in `plugin_runtime_execution.go`,
      `plugin_runtime_http.go`, and `plugin_runtime_network.go`. A capability
      declared only in Elixir is unenforced; `advisory-feed:v1` and
      `producer-schedule:v1` are existing examples of that defect and this change
      must not add a third.
- [ ] 3.1.4 Add a Go test asserting a plugin without `notify:v1` is denied the
      notification host path.
- [ ] 3.1.5 Run `bazel run //:gazelle` and
      `bazel test --config=remote //go/pkg/agent/...`.

### 3.2 Notification action dispatch on the agent

- [ ] 3.2.1 Implement notification dispatch in `go/pkg/agent` behind the existing
      `plugin.run_action` command type; do not introduce a new command type.
- [ ] 3.2.2 Add notification command payload fields to `proto/monitoring.proto`
      only where the edge route requires them; regenerate the Go and Elixir stubs
      through the single-source codegen path.
- [ ] 3.2.3 Keep secrets out of guest memory and out of `params_json`. Use
      `CredentialBrokerGrant` host-side injection
      (`go/pkg/agent/plugin_runtime_actions.go:308-356`) or the trusted-host-only
      `host_params_json` field (`proto/monitoring.proto:615-623`).
- [ ] 3.2.4 Document and enforce the Slack/Discord incoming-webhook constraint:
      the secret lives in the URL path and no injection mode rewrites a path. The
      supported modes are exactly `http_header`, `bearer_token`, `basic_auth`,
      `query`, `form_urlencoded`, and `oauth2_password_bearer`
      (`go/pkg/agent/plugin_runtime_actions.go:317-355`); use those canonical
      names everywhere and never the shorthand `header`, `bearer`, `basic`, or
      `form`. On `:edge_agent`, such channels use the bot-token API with
      `bearer_token` or carry the URL via `host_params_json`. A URL-path injection
      mode is out of scope for v1.
- [ ] 3.2.5 Compute what reaches the agent through the existing narrowing funnel
      (`effective_capabilities` / `effective_permissions` / `effective_resources`,
      `edge/agent_config_generator.ex:1848-1877`).

### 3.3 Control-plane plugin execution

- [ ] 3.3.1 Implement `:control_plane` + `:wasm_plugin` execution via
      `ServiceRadar.Edge.AgentCommandBus.dispatch/4` targeting the
      platform-resident `serviceradar-agent` that already ships
      (`helm/serviceradar/templates/agent.yaml:40`).
- [ ] 3.3.2 Bind notification providers only to approved plugin packages; a
      provider whose package approval is revoked deactivates.
- [ ] 3.3.3 Assert in a test that there is exactly one Wasm host implementation -
      no Rustler/wasmtime NIF and no second Go host is introduced.

### 3.4 Edge route, failover, and durable receipts

- [ ] 3.4.1 Implement `:edge_agent` dispatch with explicit handling of
      `{:error, {:agent_offline, agent_id}}` from
      `agent_command_bus.ex:204-225`.
- [ ] 3.4.2 On agent-offline, fail over one hop to `fallback_channel_id` unless
      the channel is `fail_closed`; record the failover on the delivery row.
- [ ] 3.4.3 Treat the agent command result as a wake-up signal only; the
      `NotificationDelivery` row is always the system of record, mirroring the
      pattern documented at
      `automation/ansible/callback_command_result_coordinator.ex:1-10`.
- [ ] 3.4.4 Before the edge route ships, either enable
      `:status_handler_enabled` (default `false`,
      `cluster/coordinator_children.ex:96-113`) so
      `ServiceRadar.AgentCommands.StatusHandler` durably persists command acks,
      progress, and results, or ship the poll-based reconciler. If reconciling,
      follow the ready-made shape: the `ActionInvocationTarget` `:poll_due` read
      plus its currently-callerless `list_poll_due` code interface.
- [ ] 3.4.5 Add a bounded periodic scan that recovers deliveries whose wake-up
      signal was lost, and a reconnect drain for commands queued while an agent
      was offline.
- [ ] 3.4.6 Add the Helm value and template wiring for whichever option 3.4.4
      selects, plus its documentation.

### 3.5 Runtime display and config contract resolution

- [ ] 3.5.1 Replace the compile-time `@built_in_contracts` `File.read!` in
      `elixir/web-ng/lib/serviceradar_web_ng/observability/signal_display.ex` with
      runtime resolution from the installed package, so a third-party package can
      ship a renderable contract without recompiling web-ng. The map holds SEVEN
      MAP ENTRIES over SIX DISTINCT PATHS (powerdns 0.1.0 and 0.1.1 share a
      path), so the replacement must key on the (package, version) pair those
      entries already distinguish, not on the file path.
- [ ] 3.5.2 Validate display and config contracts at import time and version them.
- [ ] 3.5.3 Degrade gracefully when a contract is missing or invalid, and make the
      diagnostics enumerable to operators.
- [ ] 3.5.4 Render notification channel config forms, the delivery log, and
      channel health from the package-supplied contracts.

### 3.6 Bundle registration (three hand-synced places)

- [ ] 3.6.1 Register any new first-party notification bundle file in the
      bundle-entry allowlist in
      `elixir/web-ng/lib/serviceradar_web_ng/plugins/first_party_importer.ex`
      (accepted-entry predicate near line 410, plus per-entry size limit).
- [ ] 3.6.2 Register it in `REQUIRED_ENTRIES`, per-entry size limits, and the
      `display/` / `schemas/` prefix rules in
      `scripts/validate-external-wasm-plugin-bundle.py`.
- [ ] 3.6.3 Register it in the bundle file tuples in
      `build/wasm_plugins/plugin_inventory.bzl`.
- [ ] 3.6.4 Verify end to end with `make build_wasm_plugins` and
      `make verify_wasm_plugins`.

### 3.7 UI safety for the edge route

- [ ] 3.7.1 Warn in the escalation policy editor when the only reachable route is
      an `:edge_agent` channel bound to the same `partition_id` as the alert
      source - the configuration that silently guarantees no page exactly when one
      is owed.
- [ ] 3.7.2 Surface `fallback_channel_id` and `fail_closed` prominently on any
      channel using `:edge_agent`.

### 3.8 Cross-repository SDK work (SEPARATE REPOSITORIES)

- [ ] 3.8.1 `serviceradar-sdk-go` (separate repository): add the notifier plugin
      kind, the delivery request and result envelopes, notifier intents,
      capability-gated behaviour, credential-broker helpers for outbound HTTP,
      config decoding against the manifest config schema, and the
      `notifications:` manifest contract builder and validator. The manifest
      emitter MUST emit exactly the keys the validator owns (3.1.1): `key`,
      `display_name`, `description`, `entrypoint`, `config_schema`,
      `capabilities`, `payload_formats`, `routes`, `credential_requirements`,
      `inbound`. An SDK that emits `provider_key` or `inbound_callback` produces
      manifests the platform rejects.
- [ ] 3.8.1a Both SDKs use the canonical credential injection mode names from
      3.2.4 (`http_header`, `bearer_token`, `basic_auth`, `query`,
      `form_urlencoded`, `oauth2_password_bearer`) in their helper APIs and
      fixtures, so a plugin author never learns a shorthand the host does not
      accept.
- [ ] 3.8.2 `serviceradar-sdk-go` (separate repository): add an example notifier
      plugin and a fixture-based conformance test.
- [ ] 3.8.3 `serviceradar-sdk-rust` (separate repository): implement notifier
      parity with the Go SDK against the same fixture corpus.
- [ ] 3.8.4 Version and release both SDKs jointly against one notifier contract
      version; pin the new SDK versions in every in-repo Wasm plugin.
- [ ] 3.8.5 Add notifier logging and payload redaction safety to both SDKs so a
      guest cannot log an injected credential.

### 3.9 Phase 3 tests, docs, and gates

- [ ] 3.9.1 Elixir tests for manifest parsing of the `notifications:` block,
      including rejection of UI-markup keys, of an undeclared capability, of an
      unknown block key (`provider_key` and `inbound_callback` are the two
      near-miss spellings to assert on), and of a `capabilities` list missing
      `send` or `test`.
- [ ] 3.9.1a A test asserting a provider whose `action_key` is absent from the
      referenced package's `notifications:` block is rejected.
- [ ] 3.9.2 Go tests for `notify:v1` enforcement and for credential injection mode
      selection, asserting the canonical mode names from 3.2.4 and that a
      shorthand name is not silently accepted.
- [ ] 3.9.3 Agent-offline failover test and a fail-closed test asserting no
      failover occurs.
- [ ] 3.9.4 Reconciler test proving a delivery whose command result was lost still
      reaches a terminal state.
- [ ] 3.9.5 Contract-resolution tests for a third-party package shipping a display
      contract without a web-ng recompile.
- [ ] 3.9.6 Add `docs/docs/notification-plugin-authoring.md` covering the
      `notifications:` manifest block, `notify:v1`, credential handling, and the
      two supported routes. Restate that `:edge_agent` is only for destinations
      unreachable from the platform and that an edge-only policy cannot deliver
      the "this site went dark" page. ASCII only.
- [ ] 3.9.7 Update `docs/docs/sdks.md` and `docs/docs/edge-agent-onboarding.md`
      for notifier support.
- [ ] 3.9.8 `./scripts/elixir_quality.sh --project elixir/serviceradar_core`,
      `./scripts/elixir_quality.sh --project elixir/web-ng --phoenix`,
      `bazel run //:gazelle`, `bazel test --config=remote //go/pkg/agent/...`, and
      `bazel build --config=remote //rust/...` if any Rust changed.

## 4. Phase 4 - Stream provider and native interactivity

### 4.1 Firehose subject and broker allowlist

- [ ] 4.1.1 Define the notification subject namespace (for example
      `notifications.>`) and its JetStream stream with a durable cursor so
      reconnecting consumers replay instead of losing events.
- [ ] 4.1.2 Add the new namespace to the per-CN publish and subscribe allowlists
      in `helm/serviceradar/templates/nats.yaml:205-217`. New subject namespaces
      are DENIED at the broker by default - omitting this silently breaks the
      firehose.
- [ ] 4.1.3 Add the namespace to every CN that needs it (core publish, web-ng
      subscribe) and to the NATS credential generation job if scoped credentials
      are used.
- [ ] 4.1.4 Verify on a live stack with the `nats` CLI from the tools pod that
      publish and subscribe succeed for the new subject.

### 4.2 Stream provider

- [ ] 4.2.1 Implement the built-in `:stream` provider type behind the same
      `Transport` behaviour (`deliver/2`, `validate_config/1`, `capabilities/0`,
      `test/2`) so the firehose traverses routing, suppression, redaction, and
      audit like any other channel - never a parallel unaudited egress. `:stream`
      is a `provider_type`, not a fourth extensibility tier: operators cannot
      author one.
- [ ] 4.2.1a Implement stream suppression correctly, because two different
      surfaces are involved and conflating them is the easy mistake. A suppressed
      dispatch to a `:stream` channel publishes NO envelope on the stream, and
      writes a `NotificationDelivery` row with `state: :suppressed`. Separately,
      the DELIVERY LOG UI displays those suppressed rows with their
      `suppression_reason` (1.7.8) rather than omitting them. Nothing publishes a
      "suppressed" envelope to subscribers.
- [ ] 4.2.2 Add the RBAC-scoped Phoenix Channel topic in web-ng, authorizing on
      `notifications.stream.subscribe` and filtering the envelope to what the
      subscriber may see.
- [ ] 4.2.3 Define and document the canonical notification envelope shape. It
      carries alert and delivery identifiers that a subscriber resolves through
      the authenticated API, and it carries NO action link or capability token
      (1.6.2a).
- [ ] 4.2.4 Seed the `:stream` `NotificationProvider` row as a first-party
      `managed` provider alongside `slack`, `discord`, `webhook`, and `email`,
      using the same `managed` / `template_version` / `template_fingerprint`
      reconciliation as those four (1.4.9). It is seeded, not operator-authored,
      and an operator may disable it without the next upgrade re-enabling it.

### 4.3 Native interactive acknowledgement

- [ ] 4.3.1 Slack Block Kit acknowledge / snooze / resolve buttons, posting to the
      notification callback route.
- [ ] 4.3.2 Discord message components for the same three actions.
- [ ] 4.3.3 PagerDuty acknowledgement webhooks, mapping a PagerDuty
      acknowledgement onto the alert `acknowledge` transition and a resolve onto
      `resolve`.
- [ ] 4.3.4 Verify all three callback paths reuse the northbound stack verbatim:
      token from header / Bearer / body, sha256-only persistence,
      `Edge.Crypto`-encrypted HMAC secret, `Plug.Crypto.secure_compare`, and
      HMAC-SHA256 over `<timestamp>.<raw_body>` with a 300 s tolerance
      (`automation/northbound/dispatcher.ex:425-466`,
      `command_result_handler.ex:172-207`). Do not author a second verification
      scheme for notifications.
- [ ] 4.3.5 Confirm the notification callback route prefix registered with
      `ServiceRadarWebNGWeb.Api.RawBodyReader` in 1.6.4 actually covers the routes
      these three providers post to. `RawBodyReader` buffers raw bodies only for
      registered prefixes, and an unregistered prefix fails silently by verifying
      against a re-encoded body - which breaks exactly the providers that sign
      bytes. Extend the registered prefix list if a provider needs a route outside
      it, and cover it with the byte-identity test from 1.6.4a.
- [ ] 4.3.6 Record `actor_kind: :external_principal` for identities that are not
      mapped platform users, and write a `NotificationAcknowledgement` row with
      `source: :callback` for every accepted native interaction, exactly as the
      action-link path does in 1.6.6.
- [ ] 4.3.7 Halt escalation on a native acknowledgement on the same code path as
      an action-link acknowledgement. Interactive components are a second ingress
      to one acknowledgement mechanism, not a second acknowledgement mechanism.

### 4.4 Phase 4 tests, docs, and gates

- [ ] 4.4.1 HMAC verification tests: valid signature, wrong secret, replayed
      timestamp beyond tolerance, and tampered body.
- [ ] 4.4.2 Phoenix Channel authorization test asserting a user without
      `notifications.stream.subscribe` cannot join the firehose topic.
- [ ] 4.4.2a Stream-suppression test: a suppressed dispatch to a `:stream` channel
      publishes nothing to subscribers and still writes a `:suppressed` delivery
      row that the Delivery Log renders with its reason.
- [ ] 4.4.2b Stream action-link exemption test: no envelope published on the
      firehose contains an action link or capability token.
- [ ] 4.4.2c Seeded `:stream` provider test: the row exists after install as a
      first-party `managed` provider, and an operator disable survives upgrade
      reconciliation.
- [ ] 4.4.3 JetStream replay test asserting a reconnecting consumer resumes from
      its cursor.
- [ ] 4.4.4 Slack and Discord interaction payload tests using recorded fixtures.
- [ ] 4.4.5 Document the firehose subscription surface and the envelope schema in
      `docs/docs/notifications.md`, including that it is gated on
      `notifications.stream.subscribe`, that suppressed dispatches publish nothing
      while still being recorded, and that stream envelopes deliberately carry no
      action link. ASCII only.
- [ ] 4.4.6 `./scripts/elixir_quality.sh --project elixir/serviceradar_core` and
      `./scripts/elixir_quality.sh --project elixir/web-ng --phoenix`.

## 5. Cross-cutting close-out

- [ ] 5.1 Resolve design.md Open Question 1 (whether customer-network egress means
      the site agent specifically) and record the answer; if the control-plane
      route already satisfies it, drop the `:edge_agent` route out of Phase 3.
- [ ] 5.2 Resolve Open Question 2 (whether core availability is the accepted
      failure domain for notifications) and record it in
      `docs/docs/architecture.md`.
- [ ] 5.3 Resolve Open Question 3 (identity recorded when an external principal
      acknowledges) before Phase 4 native interactivity ships.
- [ ] 5.4 Resolve Open Question 4 (delivery record storage: plain `platform` table
      with its own retention versus a Timescale hypertable) before Phase 1
      migration review is signed off.
- [ ] 5.5 Coordinate sequencing with `add-northbound-action-integrations`,
      `add-signed-northbound-action-callbacks`,
      `add-long-running-northbound-actions`, and `add-automation-callback-grants`,
      which all touch the callback and HMAC surface this change reuses; and with
      `add-device-active-lifecycle`, which owns generation-side device
      suppression.
- [ ] 5.6 Update `CHANGELOG` for the release that carries each phase.
- [ ] 5.7 Hold the canonical vocabulary across code, specs, and docs. These
      spellings are fixed and a near-miss is a defect, not a synonym:
      - RBAC: top-level three-part `notifications.*` keys only (1.8.1). Never
        `observability.notifications.*`, never four-part.
      - Alert snooze timestamp: `snooze_until`. Never `snoozed_until`. Snooze is a
        plain `update :snooze` action plus a derived condition; there is no
        `:snooze` state-machine transition and no snoozed status value.
      - Migrations are hand-written and applied with `mix ash.migrate`. Never
        `mix ash.codegen`; this repo has no `priv/resource_snapshots/`.
      - Oban workers live flat in `lib/serviceradar/notifications/`. There is no
        `workers/` subdirectory.
      - Transport callbacks: `deliver/2`, `validate_config/1`, `capabilities/0`,
        `test/2`. Never `send/2`.
      - Routing-request idempotency key:
        `{alert_id, lifecycle_reason, step_number, dedupe_key}`. The field is
        `lifecycle_reason`, never `lifecycle_event`.
      - Credential injection modes: `http_header`, `bearer_token`, `basic_auth`,
        `query`, `form_urlencoded`, `oauth2_password_bearer`.
      - Manifest `notifications:` entry keys: `key`, `display_name`,
        `description`, `entrypoint`, `config_schema`, `capabilities`,
        `payload_formats`, `routes`, `credential_requirements`, `inbound`.
      - Config form module: `ServiceRadarWebNGWeb.PluginConfigForm`.
      - Tiers: three extensibility tiers plus the built-in `:stream` provider
        type.
- [ ] 5.8 Final `openspec validate add-notification-platform --strict`.
- [ ] 5.9 Mark every task above `- [x]` only after the work is actually complete,
      then archive the change in a separate PR.
