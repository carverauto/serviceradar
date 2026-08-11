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
- [x] 1.3.12 Emit `:telemetry` events for routed, suppressed, dispatched, sent,
      failed, failed-over, escalated, and acknowledged, with channel and provider
      tags. `ServiceRadar.Notifications.Telemetry` owns the nine events and the
      `Telemetry.Metrics` definitions for the SLIs the spec names (dispatch
      attempted/succeeded/failed, dispatch latency from alert fire time, ack
      latency, MTTR, and the per-channel error and suppression rates as
      per-channel-tagged counters). Plain `:telemetry` rather than a JetStream
      subject: nothing here is a metric destined for storage, so no row is
      written and no new NATS subject namespace is needed. `alert_id` and
      `delivery_id` are metadata only and are tags on no metric - a per-alert
      label set is unbounded. Tests: `telemetry_test.exs` (DB-free contract,
      including "no emitted metadata value is a map or a struct") and
      `dispatcher_telemetry_test.exs` (the call sites on the real path).
      OPEN, one line, outside this change's file scope: nothing appends
      `Notifications.Telemetry.metrics()` to `ServiceRadar.Telemetry.metrics/0`
      yet, so the SLIs are defined and the events fire, but no Prometheus
      reporter is scraping them.

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
- [x] 1.4.1b Mark deliveries produced by `test/2` with `is_test: true` so the
      exclusions in 1.1.10b apply automatically rather than at each call site.
      Already satisfied and now verified: `NotificationDelivery.:record_test_dispatch`
      sets the flag, the flag is what selects `test/2` over `deliver/2`, and every
      exclusion filters on it centrally - `:countable`, `:countable_for_alert`,
      `existing_dispatches`, `last_dispatch_at`, the escalation scan, and
      `maybe_failover`. The unsaved-channel test send writes no delivery row at
      all. Covered by 1.10.6d.
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
- [x] 1.8.1b Map each key to its surface so no permission is decorative:
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
      AUDITED. Eight of the nine are enforced in TWO independent places - an Ash
      policy on the resource and the LiveView event gate in
      `elixir/web-ng/lib/serviceradar_web_ng_web/live/settings/notifications_live/access.ex`,
      which routes EVERY `handle_event/3` through `authorize_event/2` and refuses
      an undeclared event rather than defaulting to permitted:
      `.channels.view` (notification_channel.ex:57, access.ex tab + settings
      catalog.ex:600), `.channels.manage` (notification_channel.ex:58,
      notification_delivery.ex:99), `.routes.view` (notification_route.ex:86,
      escalation_policy/step/step_channel, schedule, silence, template),
      `.routes.manage` (notification_route.ex:87 and the same five),
      `.providers.manage` (notification_provider.ex:89),
      `.deliveries.view` (notification_delivery.ex:98,
      notification_acknowledgement.ex:66, alert_actions.ex:54),
      `.test.send` (notification_delivery.ex:100, policy on
      `:record_test_dispatch` at :529), `.silences.manage`
      (notification_silence.ex:66).
      TWO deviations from the text above, both deliberate and both documented in
      `access.ex`: the Providers tab READS on `.channels.view` (a channel is
      unreadable without knowing its provider) and only WRITES on
      `.providers.manage`; and silences READ on `.routes.view` and only WRITE on
      `.silences.manage`.
      ONE key is declared and NOT yet enforced: `notifications.stream.subscribe`
      appears only in `Identity.RBAC.Catalog` (catalog.ex:870), a moduledoc
      (`transports/stream.ex:44`), and UI copy. That is correct for Phase 1 - the
      topic join it gates does not exist until 4.2.2 - and it is called out as
      "not yet enforced" in the operator docs (1.11.1a) so nobody builds a role
      believing it restricts anything today.
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
- [x] 1.9.1a Migrate existing operator webhook configuration onto
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
- [x] 1.9.4 Resolve `alert_events: "events.alert"`
      (`elixir/serviceradar_core/lib/serviceradar/nats/channels.ex:54`, doc line
      16) - either wire it to the alert lifecycle subject or delete the constant.
      Zero producers and consumers exist today.
      DELETED, with the reasoning kept in the moduledoc so it is not revived.
      Wiring it is the larger option and the wrong one: a bare alert subject
      published from the lifecycle is a SECOND egress that bypasses routing,
      suppression, redaction, and the `NotificationDelivery` audit row - exactly
      the side door design D10 forbids ("the firehose is a provider, not a side
      door"), and it would answer "why was I not paged?" with nothing. The
      supported way for an alert to reach a bus is the built-in `:stream`
      provider, which traverses the same decision path as Slack. That provider's
      durable half is Phase 4 (4.1.1-4.1.4) and needs its own subject namespace
      plus per-CN publish/subscribe entries in
      `helm/serviceradar/templates/nats.yaml:205-217`, so anything wired here now
      would have to be rewritten against those allowlists anyway. Note for
      accuracy: `events.>` IS already allowlisted for the `serviceradar-core` CN,
      so `events.alert` specifically would not have been denied - it is the Phase
      4 namespace that is. Deleting was still the smaller change: zero producers,
      zero consumers, zero tests, and one grep confirms no reference survives.
      `standard_channels/0` and `standard/1` remain (also callerless - only
      `Channels.build/1` is used, by `events/internal_log_publisher.ex:18`); they
      are outside this change's scope and were left alone rather than widening the
      blast radius.
- [x] 1.9.5 Delete `ServiceRadar.Identity.Senders.EmailDelivery` once 1.5.5 lands.

### 1.10 Phase 1 tests

- [x] 1.10.1 Unit tests for `Router` (priority, `continue`, no-match), `Dedupe`,
      `Escalation` (delay elapsed and unacknowledged), and `RateLimiter`
      (restart-surviving budget).
- [x] 1.10.2 Suppression tests covering every reason value including
      `:no_matching_route`, plus a test that asserts a `:suppressed` delivery row
      is always written.
- [x] 1.10.2a Suppression-dedupe test: repeating an identical decision tuple N
      times leaves exactly one row with `suppression_occurrence_count == N` and a
      refreshed `last_evaluated_at`; changing any element of the tuple (including
      `suppression_reason`) produces a second row. The attribute shipped as
      `occurrence_count`. `test/serviceradar/notifications/suppression_dedupe_test.exs`.
- [x] 1.10.2b Unrouted-alert test: an alert matching zero enabled routes produces
      a `:no_matching_route` suppressed row that is visible through the same
      Delivery Log query as every other withheld notification.
      `dispatcher_routing_test.exs`, "records one suppressed delivery with
      :no_matching_route" plus "is visible through the same Delivery Log read as
      every other withheld one".
- [x] 1.10.2c Unrouted-alert COLLAPSE test, distinct from 1.10.2b: repeating the
      same `:no_matching_route` decision - the tuple whose `policy_id`,
      `step_number`, and `channel_id` are all NULL - leaves exactly ONE row with an
      incremented `suppression_occurrence_count`, not a new row per evaluation.
      This is the test that proves the NULL handling required by 1.1.18a is
      actually in the index; a plain unique index passes 1.10.2a and fails here.
      `dispatcher_routing_test.exs`, "a repeat of the identical decision collapses
      onto the existing row".
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
- [x] 1.10.6d Test-delivery isolation test: a `test/2` send writes an
      `is_test: true` row that does not change `Alert.notification_count`, dedupe
      state, throttle state, or escalation position.
      `test/serviceradar/notifications/test_delivery_isolation_test.exs`. The
      throttle assertion is sharp rather than incidental: the route carries a
      one-hour `throttle_seconds`, so a test send that leaked into
      `last_dispatch_at` would withhold the real dispatch as `:throttled`.
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
- [x] 1.10.11 LiveView tests for channel create/edit/test-send, route authoring,
      silence create/cancel, delivery log filtering, and alert acknowledge.
      Channel create/edit, test-send, route authoring, and silence create/cancel:
      `web-ng/test/phoenix/live/settings/notifications_editors_test.exs`. Delivery
      log filtering was already covered by `notifications_live_test.exs`
      ("the delivery log filters are reflected in the URL", "clearing the filters
      returns to the unfiltered log") plus the pure
      `notifications_delivery_filters_test.exs`; alert acknowledge was already
      covered by `live/alert_live/show_test.exs` and
      `live/log_live/alerts_bulk_test.exs`.
- [x] 1.10.12 An authorization test asserting each notification LiveView and
      `handle_event` denies a user lacking the permission key.
      `web-ng/test/phoenix/live/settings/notifications_authorization_test.exs`
      sweeps all 38 gated events at a mounted LiveView as a `:helpdesk` user (the
      only role that can reach the surface while holding none of the five
      mutating keys), asserts each is refused, asserts no editor or confirmation
      opened, and asserts the notification tables are identical afterwards. A
      coverage test derives the declared event set from the `Access` module's own
      source, so a new event cannot be added without a test. The pure gate logic
      remains in `phoenix/settings/notifications_access_test.exs`.
- [x] 1.10.12a An RBAC catalog test asserting the `notifications` section holds
      exactly the nine keys from 1.8.1, that every one is three-part, and that no
      `observability.notifications.*` key exists anywhere in the catalog.
      `serviceradar_core/test/serviceradar/identity/rbac/catalog_test.exs`,
      `describe "notifications section"` (six tests, including the default-role
      map and "a viewer holds no notification permission at all").
- [x] 1.10.13 Integration test (tagged `:integration`, run against the
      `srql-fixtures` CNPG scratch database) exercising alert created -> routed ->
      suppressed-or-delivered -> acknowledged, asserting the delivery rows.

### 1.11 Phase 1 docs

- [x] 1.11.1 Add `docs/docs/notifications.md` covering channels, routes,
      escalation policies, schedules, silences, every suppression reason
      (including `:no_matching_route`), and the delivery log. Document that
      escalation delays are measured from alert fire time with the snooze-expiry
      exception, that `:failed` is terminal while retries stay `:pending`, and
      that the rule's `renotify_seconds` is the cadence floor. ASCII only.
      DONE. Written for an operator who has never seen the feature. The three
      sections that carry the misunderstandings: "Retry, failover, and escalation
      are three different things" (a worked t+0 / t+5m / t+15m ladder showing a
      503 retrying inside step 1 while step 2 fires on the ALERT FIRE clock),
      "Suppression is auditable" (all nine reasons in precedence order with where
      to go fix each, `:dependency` marked reserved-and-not-emitted, plus the
      occurrence-collapsing rule), and "Deduplication and cadence" (the existing
      `{rule_id, group_key}` identity, `cooldown_seconds` / `renotify_seconds`,
      and the one-line rule: notification settings can only make pages LESS
      frequent, never more). Also covers the delivery-outlives-alert retention
      split and a Troubleshooting section keyed on Delivery Log state.
      Verified ASCII-only (0 non-ASCII bytes) and MDX-safe (every `{` and `<` is
      inside a code span or fence, checked mechanically).
- [x] 1.11.1a Document the nine `notifications.*` permission keys and which
      surface each one gates, so an operator can build a least-privilege role
      without reading the catalog module.
      DONE - the Permissions table in `notifications.md`, one row per key with
      its surface and default roles, including the two deliberate deviations
      audited in 1.8.1b (Providers reads on `.channels.view`, silences read on
      `.routes.view`) and an explicit "not yet enforced" on
      `notifications.stream.subscribe`.
- [x] 1.11.2 Document that `:control_plane` is the default and the recommended
      route, and that `:edge_agent` is only for destinations unreachable from the
      platform.
      DONE - "Execution route: control plane vs edge agent", including the honest
      tradeoff: `AgentCommandBus` is at-most-once with NO store-and-forward
      (forgejo #4902), so an edge-routed channel whose agent is unreachable relies
      on retry and then its single failover hop, and an escalation policy whose
      only route is an edge agent in the same partition as the alert source
      cannot deliver a site-down page.
- [x] 1.11.3 Document the SMTP configuration surface
      (`SERVICERADAR_MAILER_ADAPTER`, `SMTP_RELAY_*`) in
      `docs/docs/helm-configuration.md` and the new notifications page.
      DONE in both: a new "Outbound Mail (SMTP)" section in
      `helm-configuration.md` (the `core.mailer` values block, the Secret, and
      the values-to-env mapping table) and "Email and SMTP" in
      `notifications.md` (the full env table plus every `OutboundMail.diagnose/1`
      class). Both state WHY the diagnostic exists: `Swoosh.Adapters.Test` and
      `.Local` both return `{:ok, email}` and deliver nothing, so a misconfigured
      mailer reported every send as `:sent` and paged nobody.
- [x] 1.11.4 Document the removal of the `webhooks:` config block and the
      migration path to a `generic_webhook` channel.
      DONE - "Migrating from the removed `webhooks:` config block". Documented as
      a KEY MAPPING, not a data migration, and it says so plainly: the Elixir key
      was never set by any shipped config and its GenServer was never supervised,
      and the Helm block landed in `core.json`, which Go decodes into a struct
      with no `Webhooks` field. There is no operator state on either side to hunt
      for. The table maps `url`, non-credential `headers`, credential-bearing
      `headers` (-> `auth_mode` + `secret_refs`, never a plain header),
      `cooldown` (-> `rate_limit_per_minute` / dedupe), `template` (EEx ->
      `NotificationTemplate`, `payload_format: json`), and `enabled`.
- [x] 1.11.5 Register the new page in `docs/sidebars.ts`.
      Added to the "Operate" category after `configuration-system`. Verified by
      evaluating the sidebar module: exactly one `notifications` entry.

### 1.12 Phase 1 quality gates

- [x] 1.12.1 `./scripts/elixir_quality.sh --project elixir/serviceradar_core`
- [x] 1.12.2 `./scripts/elixir_quality.sh --project elixir/web-ng --phoenix`
- [x] 1.12.3 `cd elixir/web-ng/assets && sfw npm run build:js && sfw npm run build:css`
      if any JS/CSS changed.
- [x] 1.12.4 `bazel run //:gazelle` and `bazel test --config=remote //go/pkg/models/...`
      after the Go config removal.
- [x] 1.12.5 `openspec validate add-notification-platform --strict`

## 2. Phase 2 - Declarative providers

### 2.1 Request template document format

- [x] 2.1.1 Define the declarative definition document
      (`NotificationProvider.definition`): method, URL template, header templates,
      body template, auth mode, success predicate, retryable-status set, and
      response field extraction for `external_correlation_id`.
      Auth is expressed as a header template reading `secrets.*` rather than as a
      separate `auth_mode` enum: the credential already resolves through
      `SecretBroker` into `Transport.Request.secrets`, and a second spelling of
      "where the token goes" would be a second place to get it wrong. A
      credential-shaped header whose value carries no `secrets.*` reference is
      rejected, so the enum's guarantee is kept without the enum.
- [x] 2.1.2 Add `ServiceRadar.Notifications.Declarative.Definition` with a strict
      validator that rejects unknown keys and any construct outside the restricted
      substitution grammar. Templates are validated by
      `Template.Syntax.validate_template/2`, which gained an `:extra_paths` option
      for the `config.*` / `secrets.*` leaves that only a document's own
      `config_schema` can enumerate; `validate_template/1` and the notification
      body catalog are unchanged.
- [x] 2.1.3 Validate the provider `config_schema` with `Plugins.ConfigSchema`; the
      declarative definition may reference only fields the schema declares. A
      credential-named property that is not `secretRef: true` is refused, so a
      token cannot reach the non-sensitive `config` column.
- [x] 2.1.4 Reject `html`, `raw_html`, `javascript`, `js`, `component`,
      `component_ref`, `live_view`, `react`, and `ui_code` keys, matching the
      manifest validator at `plugins/manifest.ex:986-997`. Providers describe UI
      declaratively; they never ship markup. Enforced at ANY depth and
      case-insensitively, and paired with a whole-document scan for the
      `Template.Syntax.code_markers/0` constructs in any string.

### 2.2 Declarative execution engine

- [x] 2.2.1 Implement `Notifications.Transports.Declarative` behind the same
      `Transport` behaviour, so routing and escalation cannot tell the tier.
      One engine for every document: `Dispatcher.resolve_provider_transport/1`
      answers `:declarative` with this module and the document itself travels on
      the request, so a new provider adds no module and no allowlist entry.
      Templates are rendered by `Notifications.Renderer.render_string/4` with the
      document's own `config.*` / `secrets.*` as `:extra_paths` - the same
      restricted engine, not a second one. `render_request/2` renders without
      issuing, which is what the upload preview (2.3.1) calls.
- [x] 2.2.2 Guard every resolved URL with
      `Palisade.OutboundURLPolicy.validate_https_public_url/2` at request time,
      after substitution, not only at save time. Reached through
      `Transports.HTTP.request/4`, which runs the guard before a socket exists
      and is the single outbound path; the engine does not call the policy
      separately, so there is one guard rather than two that can disagree.
      (`Palisade` is not a dependency of `serviceradar_core`; the in-tree
      `ServiceRadar.Policies.OutboundURLPolicy` is what `HTTP` resolves to, with
      the same heads and the same error atoms.) A rendered URL carrying
      whitespace or a control character is refused as a permanent configuration
      defect first, because it survives both `URI.parse/1` and the policy and
      would otherwise come back as an unclassified transport error that costs
      the whole retry budget.
- [x] 2.2.3 Resolve secrets through `Credentials.SecretBroker` and inject them
      into headers or the body only at request construction; never persist a
      rendered payload containing a secret. The dispatcher resolves
      `secret_refs` into `Transport.Request.secrets`; the engine substitutes them
      into the URL, a header, or the body at request construction and passes
      every resolved value to `Transports.HTTP` as `:sensitive_values`, so a
      token cannot survive into an error message, a `result_summary`, or a log
      line. An unresolved `secrets.*` reference refuses the delivery instead of
      sending a request with a hole where the credential belongs.
- [x] 2.2.4 Map response status to the retry / failover decision using the
      definition's retryable-status set. `Definition.classify_status/2` decides
      from the document's own sets and anything in neither is terminal, so a 200
      the document does not list as success is a permanent failure rather than a
      silent `:sent`. The success case goes through
      `Transport.result_from_http_status/2`; the retry rule itself stays in
      `Transport.Result.outcome/2` and is never re-derived.
      `failure.retry_after_header` is honoured on a retryable answer and clamped
      to one hour.

### 2.3 Upload, versioning, and catalog UI

- [x] 2.3.1 Add declarative provider upload to the Providers tab with inline
      validation errors and a rendered preview of the resulting request.
      `NotificationsLive.ProviderUpload` (pure) parses the pasted YAML or JSON
      with `Declarative.Definition.parse/1` and renders EVERY error with the path
      it is at and the validator's own sentence - there is no generic
      "invalid document" branch. The preview is rendered by
      `Transports.Declarative.render_request/2`, the same function `deliver/2`
      renders with, against a context in which every legal path resolves to a
      marker naming itself (`<alert.title>`, `<config.webhook_url>`), so a
      preview cannot disagree with what would be sent and no channel value or
      credential is read to build one.
- [x] 2.3.2 Version uploaded definitions and allow rollback to a previous version;
      surface which channels bind to which version. No new column: the provider
      is already audited by `AshPaperTrail`, so `NotificationsLive.ProviderVersions`
      folds the `changes_only` version rows chronologically and emits one entry
      per definition version. A rollback re-uploads the older document as the
      NEXT version rather than rewriting one - `NotificationDelivery.provider_version`
      names the version that rendered each delivery, so history is append-only
      and each version links to the deliveries recorded against it.
- [x] 2.3.3 Enforce that a definition upload requires
      `notifications.providers.manage`. All nine upload, version, and rollback
      events are declared in `NotificationsLive.Access`, which the LiveView routes
      every `handle_event/3` through and which refuses an undeclared event; the
      `NotificationProvider` create/update policies refuse the same write when the
      LiveView is bypassed entirely. Both refusals are tested.
- [x] 2.3.4 Prove the extensibility claim in a test: adding a provider requires no
      repository change and no release.
      `test/phoenix/live/settings/notifications_extensibility_test.exs` first
      asserts the destination is in no seeded catalog and no compile-time
      transport allowlist, then drives one continuous path with a single new
      artifact - a pasted document: upload in the UI, activate in the UI, create a
      channel against the `config_schema` THE DOCUMENT declared, fire an alert,
      and dispatch. The assertion is on the bytes a plug destination received.
      Nothing is compiled, restarted, or reloaded between the paste and the
      delivery.

### 2.4 Seeded declarative catalog

- [x] 2.4.1 Ship a first-party seeded `:declarative` catalog with the change, so
      the tier is demonstrably usable without writing code. The catalog MUST
      exist and MUST be non-empty at install. Destinations such as Mattermost,
      Rocket.Chat, Telegram, Gotify, ntfy, Zulip, Google Chat, Opsgenie,
      ServiceNow, Jira, Microsoft Teams, Twilio, and PagerDuty Events API v2 are
      EXAMPLES of what the catalog may contain, not a closed list; adding or
      dropping one of these names is not a contract change.
      `lib/serviceradar/notifications/declarative/catalog.ex` ships NINE:
      `pagerduty` (Events API v2), `opsgenie`, `mattermost`, `rocketchat`,
      `googlechat`, `teams` (Workflows adaptive card), `telegram`, `ntfy`, and
      `gotify`. Each is a request-template document and nothing else - no Elixir
      module, no registry allowlist entry, no `implementation_module`. Every
      entry is parsed by `Definition.parse/1` at COMPILE time, so a malformed
      one fails the build with the validator's own message rather than a boot
      warning nobody reads. Zulip, Jira, ServiceNow, and Twilio were left out
      deliberately: all four authenticate with HTTP Basic, `base64` is not one of
      `Template.Syntax`'s seven filters, and a document that asks an operator to
      paste a pre-encoded blob into a field labelled "password" is a footgun. A
      catalog entry whose request shape is guessed is worse than one not shipped.
- [x] 2.4.1a Make every seeded catalog entry individually disablable by an
      operator, and make the disable survive upgrade reconciliation. A seeded
      provider an operator disabled MUST NOT be silently re-enabled by the next
      release.
      Free, because the catalog is reconciled by `ProviderSeeder` itself rather
      than by a second seeder: `:seed_managed` excludes `status` from
      `upsert_fields` and the seeder activates only from `:draft`, never from
      `:disabled`. Asserted in `seeder_reconciliation_test.exs` for both an
      ordinary reseed and an upgrade that ships a new `template_version` for the
      disabled entry, plus that disabling one entry leaves every other provider
      untouched.
- [x] 2.4.1b Give every seeded entry the mandatory `test` capability from 1.4.1a
      so "test-send before saving" works for the catalog exactly as it does for
      the four `:native` providers. Every entry declares `[send, test]`;
      `pagerduty`, `opsgenie`, and `teams` add `rich_payload` because their body
      is a structured document rather than a text field.
- [x] 2.4.2 Reconcile seeded definitions on upgrade with
      `managed` / `template_version` / `template_fingerprint` so operator edits are
      never clobbered.
      `ProviderSeeder.managed_fields/1` answers the fingerprint's field list per
      tier: `:declarative` adds `:definition`, because in that tier the document
      IS the provider - without it an operator's edit to a request template would
      not read as divergence and a corrected document could never be applied. It
      is added for that tier ONLY, because adding a field to a fingerprint's
      field list changes every digest computed with it and the `:native` rows in
      the field carry digests an earlier release stamped with the shorter list;
      `definition` is NULL on every non-declarative row anyway, so nothing is
      lost. Same `SeedFingerprint`, same loop, same activation rule.

### 2.5 Phase 2 tests, docs, and gates

- [x] 2.5.1 Definition validator tests including every rejection case.
      `test/serviceradar/notifications/declarative/definition_test.exs`, async and
      table-driven: 92 tests, every rejection asserting the operator-facing
      message rather than only the failure.
- [x] 2.5.2 Golden-request tests for each seeded provider using a stub HTTP client.
      `test/serviceradar/notifications/transports/declarative_test.exs`, async
      and database-free: 41 tests over three differently shaped documents (a
      YAML `POST` with a JSON body and the secret in the URL, a `PUT` with a form
      body and a credential header, a `PATCH` with a text body and the host from
      channel config), each asserting the EXACT method, path, headers, and body
      so a templating regression is a diff rather than "delivery failed". Also
      covers retryable vs permanent status mapping, a document-declared retryable
      409 the built-in classifier would call permanent, `retry_after_header`
      honouring and clamping, a 200 outside `success.status`, every class of
      unresolved variable, the outbound policy running on the RENDERED url, and
      the credential appearing in no result, summary, or log line. The
      destination is a `Plug` injected through `opts[:req_options]`; nothing
      reaches the network. A seeded catalog entry (2.4.1) is exercised by this
      same harness, which is what makes "the catalog needs no code" checkable.
- [x] 2.5.3 Upgrade-reconciliation test: an operator-edited seeded provider is not
      overwritten; an untouched one is refreshed; and an operator-disabled seeded
      provider stays disabled across the upgrade.
      `test/serviceradar/notifications/seeder_reconciliation_test.exs`, DataCase,
      now covers the declarative catalog as well as the native one: six cases
      under "the seeded declarative catalog". The refresh case is deliberately
      not a version bump alone - `wind_back_pristine!/3` rebuilds the state the
      PREVIOUS release actually left behind (that release's document, that
      release's version, and a fingerprint that still matches the document), so
      the assertion proves an upgrade REPLACES a stale document rather than only
      moving a version string.
- [x] 2.5.3a Catalog-existence test: the seeded declarative catalog is non-empty
      after install and every entry declares both `send` and `test` capabilities.
      `test/serviceradar/notifications/declarative/catalog_test.exs`, async and
      database-free: 39 tests. Non-emptiness and the capability contract, plus
      every entry reparsing from its stored canonical form, no entry naming a
      module or appearing in the native allowlist, each schema being a closed
      object whose credential fields accept a stored reference, each secret path
      matching a declared `secretRef` field, and each row surviving its own jsonb
      round-trip. The last section drives `pagerduty`, `gotify`, and `mattermost`
      through `Transports.Declarative` against a function plug and asserts the
      exact method, path, headers, and body - which is what makes "this catalog
      needs no code" checkable rather than asserted. `seeder_reconciliation_test`
      covers the same existence claim against a real database.
- [x] 2.5.4 LiveView tests for upload, validation failure, and version rollback.
      `test/phoenix/settings/notifications_provider_upload_test.exs` (async, 23
      tests) covers the pure half - parse, preview, attribute mapping, and the
      version fold - and asserts the operator-facing MESSAGE rather than only the
      failure. `test/phoenix/live/settings/notifications_provider_upload_test.exs`
      (16 tests, database-backed) drives the surface: a pasted document becomes a
      `:declarative` / `:uploaded` provider, a broken one lists each offending
      path and writes nothing, a second upload is version 2, a rollback lands as
      version 3, and every one of the nine events is refused for a scope without
      `notifications.providers.manage` when pushed DIRECTLY at the mounted
      LiveView - with the resource policy refusing the same write separately.
      `notifications_authorization_test` sweeps the nine new events alongside the
      rest of the surface; its coverage assertion derives the event list from
      `Access` itself, so an event added later without a test fails there.
- [x] 2.5.5 Add `docs/docs/notification-providers.md` documenting the declarative
      document format with a complete worked example. ASCII only.
      The authoring guide, registered in `docs/sidebars.ts` next to
      `notifications` and cross-linked with it in both directions rather than
      repeating it. The worked example is the seeded `gotify` entry written as
      YAML, and it was verified rather than transcribed by eye: every YAML block
      in the page was run through `Definition.parse/1`, and the worked example's
      `to_map/1` output compares EQUAL to `Catalog.documents()`'s `gotify` entry,
      so the page cannot drift from the catalog silently. The wrong-vs-right
      `body_format: json` example asserts the refusal as well as the acceptance.
      Also documents the four things the format cannot express (no Basic auth
      because `base64` is not a filter, no value mapping, no conditional key or
      header omission, every substitution renders a string) and, corrected
      against the code rather than against the moduledoc, two things that were
      documented imprecisely: an unset optional `config.*` path with no
      `default:` is a PERMANENT failure with no request rather than an empty
      string (only a value that is present-but-empty renders empty), and the
      YAML anchor caveat is really three failures - a top-level anchor holder key
      is refused by the closed-key check, `<<:` merge keys are not implemented
      and survive as a literal `<<1` key, and only aliases to FLOW-style
      collections decode to the anchored node's first scalar.
- [x] 2.5.6 `./scripts/elixir_quality.sh --project elixir/serviceradar_core` and
      `./scripts/elixir_quality.sh --project elixir/web-ng --phoenix`.

## 3. Phase 3 - Plugin providers and the edge route

### 3.1 Manifest and capability contract

- [x] 3.1.1 Add the `notifications:` block to `plugin.yaml` parsing and validation
      in `elixir/serviceradar_core/lib/serviceradar/plugins/manifest.ex`. The
      manifest validator owns these entry keys and they are spelled exactly:
      `key`, `display_name`, `description`, `entrypoint`, `config_schema`,
      `capabilities`, `payload_formats`, `routes`, `credential_requirements`,
      `inbound`. There is no `provider_key` key and no `inbound_callback` key in
      the manifest block; reject unknown keys rather than ignoring them.
- [x] 3.1.1a Reject a `notifications:` entry whose `capabilities` omits `send` or
      `test`. Both are mandatory in every tier (1.4.1a), so a manifest that
      declares one without the other fails validation with a message naming the
      missing capability.
- [x] 3.1.1b Bind `NotificationProvider.action_key` to a `key` value in the
      validated `notifications:` block of the referenced package (1.1.2a), and
      reject a provider row whose `action_key` the package manifest does not
      declare.
- [x] 3.1.2 Add `notify:v1` to `@allowed_capabilities`
      (`plugins/manifest.ex:61-83`).
- [x] 3.1.3 Enforce `notify:v1` with a `hasCapability` check in `go/pkg/agent`
      alongside the existing checks in `plugin_runtime_execution.go`,
      `plugin_runtime_http.go`, and `plugin_runtime_network.go`. A capability
      declared only in Elixir is unenforced; `advisory-feed:v1` and
      `producer-schedule:v1` are existing examples of that defect and this change
      must not add a third.
- [x] 3.1.4 Add a Go test asserting a plugin without `notify:v1` is denied the
      notification host path.
- [x] 3.1.5 Run `bazel run //:gazelle` and
      `bazel test --config=remote //go/pkg/agent/...`.

### 3.2 Notification action dispatch on the agent

- [x] 3.2.1 Implement notification dispatch in `go/pkg/agent` behind the existing
      `plugin.run_action` command type; do not introduce a new command type.
      DONE. `control_stream.go` `handlePluginRunAction` decodes the delivery
      envelope once (`plugin_runtime_notify.go` `decodeNotificationDelivery`) and
      differs from the northbound path in exactly two places: how the target
      assignment is addressed, and which correlation identity is stamped on the
      result (`pluginActionResultEnvelope`). No new command type, no new
      execution mode, and no second `RunAction`.
      One agent-side gap CLOSED here: the handler previously refused any payload
      with no `plugin_assignment_id`, so an edge notification - which addresses a
      provider, not an assignment - was dead on arrival. It now resolves through
      `resolveNotificationAssignmentID` (explicit id wins; otherwise
      `plugin_package_id`, failing CLOSED when one package has several
      assignments on the agent, because two assignments of one package are two
      channel configurations and picking either delivers to the wrong
      destination and records it as sent).
      The agent stays a COURIER for the guest result: it passes the submitted
      body through and stamps only `schema` / `status` /
      `delivery_id` / `channel_id` / `action_key`, exactly as the northbound path
      stamps `invocation_id` / `action_id`. Synthesising a notification result
      body here would fork the notifier guest ABI the SDKs own (3.8). The host
      does adapt the command envelope into that existing ABI before execution:
      notifier guests receive top-level `notification_delivery` with schema
      `serviceradar.notification_delivery_request.v1`, never the northbound
      `action_invocation` wrapper.
- [x] 3.2.2 Add notification command payload fields to `proto/monitoring.proto`
      only where the edge route requires them; regenerate the Go and Elixir stubs
      through the single-source codegen path.
      NO PROTO CHANGE REQUIRED, and none was made. Everything the edge route
      needs was already on the wire: the command payload is
      `CommandRequest.payload_json` (opaque JSON, so notification fields there
      are not a wire-contract change); `plugin_assignment_id` /
      `plugin_package_id` already exist on the run_action payload; credential
      grants already ride it as `credential_broker` / `credential_brokers`; and
      trusted-host-only material already has `PluginAssignmentConfig` field 23,
      `host_params_json`. No other language binding needs regenerating.
      The notifier entrypoint also rides the opaque command payload. Core
      resolves it from the matching validated `notifications:` manifest entry;
      the agent applies it to an invocation-local copy of the assignment. This
      honours multi-notifier packages without mutating the assignment's
      package-level entrypoint and without adding a proto field.
- [x] 3.2.3 Keep secrets out of guest memory and out of `params_json`. Use
      `CredentialBrokerGrant` host-side injection
      (`go/pkg/agent/plugin_runtime_actions.go:308-356`) or the trusted-host-only
      `host_params_json` field (`proto/monitoring.proto:615-623`).
      VERIFIED, no host change needed: `buildActionPluginConfig` builds the guest
      config from `assignment.ParamsJSON` plus the invocation envelope only, and
      `newPluginAssignment` never merges `host_params_json` into `ParamsJSON`.
      Covered by `TestNotificationGuestConfigNeverCarriesCredentialMaterial`,
      which asserts the guest config carries the secret REFERENCE and neither the
      resolved material nor the `host_params_json` webhook URL, and then shows
      the same grant injecting that material into an `http.Request` at the host
      boundary. Asserting on that config IS asserting on guest memory:
      `hostGetConfig` (`plugin_runtime_execution.go:188`) returns
      `e.configJSON` verbatim and is its only reader.
- [x] 3.2.4 Document and enforce the Slack/Discord incoming-webhook constraint:
      the secret lives in the URL path and no injection mode rewrites a path. The
      supported modes are exactly `http_header`, `bearer_token`, `basic_auth`,
      `query`, `form_urlencoded`, and `oauth2_password_bearer`
      (`go/pkg/agent/plugin_runtime_actions.go:317-355`); use those canonical
      names everywhere and never the shorthand `header`, `bearer`, `basic`, or
      `form`. On `:edge_agent`, such channels use the bot-token API with
      `bearer_token` or carry the URL via `host_params_json`. A URL-path injection
      mode is out of scope for v1.
      Elixir half VERIFIED already present from Phase 1: refused at save by
      `transports/slack.ex:475-481` `route_errors/2` and `transports/discord.ex:337-341`,
      and again at dispatch by `slack.ex:202` / `discord.ex:150` `check_route/2`.
      Agent half ADDED: `notificationCredentialInjectionModes` is a closed set of
      exactly those six canonical names, enforced at ADMISSION for a notification
      dispatch (`authorizeNotificationDelivery`), on both entrances, before the
      module is loaded. It is deliberately narrower than
      `applyCredentialBrokerHTTPInjection`, which still honours the legacy
      shorthands `header` / `http_basic_auth` / `query_param` / `http_query` for
      existing integrations - so a notifier declaring a shorthand fails in Elixir
      AND at the host, and `url_path` is unrepresentable in either.
      `edge_command_contract_test.exs` reads the Go allowlist and asserts it
      equals `Manifest.allowed_credential_injection_modes/0`, so the two cannot
      drift.
- [x] 3.2.5 Compute what reaches the agent through the existing narrowing funnel
      (`effective_capabilities` / `effective_permissions` / `effective_resources`,
      `edge/agent_config_generator.ex:1848-1877`).
      The funnel already existed and is what the host reads; these tests pin that
      it BINDS a notifier rather than merely describing it.
      `TestNotificationEgressBoundByNarrowedPermissions` builds an assignment
      from a `PluginAssignmentConfig` whose `permissions_json` was narrowed to one
      domain and one port, then asserts
      `pluginHTTPRequestDestinationAllowed` - the same call
      `hostHTTPRequest` makes - denies a host narrowed away, an arbitrary host, a
      port narrowed away, and plaintext on 80. That is the answer to "a
      notification plugin that can reach arbitrary hosts MUST flow through it".
      `TestNotificationCapabilityReflectsNarrowedAssignment` pins the other half:
      `deliversNotifications` and `pluginExecution.hasCapability` read the same
      narrowed map, so neither is decorative.

### 3.3 Control-plane plugin execution

- [x] 3.3.1 Implement `:control_plane` + `:wasm_plugin` execution via
      `ServiceRadar.Edge.AgentCommandBus.dispatch/4` targeting the
      platform-resident `serviceradar-agent` that already ships
      (`helm/serviceradar/templates/agent.yaml:40`).
      DONE. `Dispatcher.invoke_transport/5` now sends a delivery to an agent for
      EITHER reason - `execution_route == :edge_agent`, or a `:wasm_plugin`
      provider on any route - and both land in the same `edge_dispatch/4`, the
      same `plugin.run_action` command, and the same guest ABI. Which agent is
      the only difference, and `ServiceRadar.Notifications.PluginTarget` is what
      resolves it: the channel's `agent_uid` on the edge route, the configured
      platform agent (`SERVICERADAR_NOTIFICATION_PLATFORM_AGENT_ID`, wired by
      Helm from `agent.agentId`) on the control plane.
      The dispatch also resolves the `plugin_assignment_id` rather than leaving
      the agent to infer it. That is not redundant with 3.2.1's
      `resolveNotificationAssignmentID`: resolving in core is the only place
      that can consult package approval and `effective_capabilities` BEFORE a
      command is sent, and it turns the agent-side ambiguity failure (one
      package with several assignments on the agent) into a legible, permanent
      Delivery Log reason.
      There is deliberately no default platform agent id. Guessing one would
      dispatch a customer's notifications to whichever agent happened to match;
      unconfigured fails the delivery with `platform_agent_unconfigured`.
- [x] 3.3.2 Bind notification providers only to approved plugin packages; a
      provider whose package approval is revoked deactivates.
      DONE in three layers, because they fail at different times and only one of
      them can explain itself in a form:
      (a) ACTIVATION - `Validations.ProviderPackageApproved` on
      `NotificationProvider.:activate`. Deliberately not on `:create`
      (registering against a package still in review is a normal workflow:
      reviewer approves, then operator activates) and deliberately not on
      `:disable` (turning a provider off is the correct response to a
      revocation, and a validation there would trap exactly the rows an operator
      needs to clean up, since `:disabled` has no outbound transition).
      (b) DEACTIVATION - `Notifications.PackageApprovalWatcher`, an Ash notifier
      on `PluginPackage`'s `:revoke`/`:deny`. A notifier rather than a change on
      the action because `:revoke` is atomic and an `after_action` inside a
      `change/3` goes silently inert on an atomic update. It disables `:active`
      providers only; a `:draft` one is already inert (`Suppression` withholds
      any dispatch to a channel whose provider is not `:active`) and cannot be
      activated while the package is unapproved.
      (c) ENFORCEMENT - `PluginTarget` re-reads the package status on every
      dispatch. A notifier is a signal, not a guarantee: a bulk update that
      bypasses the action, or a node that dies between commit and notify, skips
      it. This is the layer that actually stops the page.
- [x] 3.3.3 Assert in a test that there is exactly one Wasm host implementation -
      no Rustler/wasmtime NIF and no second Go host is introduced.
      DONE - `test/serviceradar/notifications/single_wasm_host_test.exs`. It
      scans every `elixir/*/mix.exs` for a runtime dependency, every in-tree
      `Cargo.toml` for one, and every `go/**/*.go` for a wazero import, asserting
      the importing package set is exactly `["go/pkg/agent"]`. Verified to FAIL
      by adding a throwaway package that imports wazero. A legitimate second
      instantiation is not silently accommodated: it goes in `@allowed_go_hosts`
      with a reason, which is a decision someone reviews.

### 3.4 Edge route, failover, and durable receipts

- [x] 3.4.1 Implement `:edge_agent` dispatch with explicit handling of
      `{:error, {:agent_offline, agent_id}}` from
      `agent_command_bus.ex:204-225`.
      ALREADY IMPLEMENTED in Phase 1 - `dispatcher.ex` `dispatch_command/4` maps
      `{:error, {:agent_offline, _}}` to `Result.retryable_failure("agent_offline")`
      and every other bus error to `"agent_command_failed"`, both retryable, so
      the row stays `:pending` and the delivery row IS the core-side outbox R2
      requires. It was entirely UNTESTED; `dispatcher_edge_test.exs` now proves
      it (row stays `:pending`, attempt burned, `next_attempt_at` in the future).
- [x] 3.4.2 On agent-offline, fail over one hop to `fallback_channel_id` unless
      the channel is `fail_closed`; record the failover on the delivery row.
      IMPLEMENTED, but NOT "immediately on agent-offline" - and that divergence
      from this task's wording is deliberate and is what R2 asks for. Failing
      over on the first offline reply abandons a site that was briefly
      disconnected, which is precisely the disconnect an escalation ladder
      exists to survive. Offline is retryable; failover fires when the budget is
      spent and the row reaches `:failed`, takes exactly one hop, is skipped for
      a `fail_closed` channel, and stamps `originating_delivery_id` on the
      successor. All four now covered by tests.
      The one contradicting sentence in `docs/docs/notifications.md` ("or
      immediately on an agent-offline error") is corrected here.
- [x] 3.4.3 Treat the agent command result as a wake-up signal only; the
      `NotificationDelivery` row is always the system of record, mirroring the
      pattern documented at
      `automation/ansible/callback_command_result_coordinator.ex:1-10`.
      HOLDS. Nothing in the dispatch path waits synchronously on a command
      result: bus hand-off records `command_id` / `agent_uid` /
      `execution_route` and leaves the row `:dispatching`. The receipt sweep
      later validates the persisted notifier SDK result and settles the delivery
      row; bus acceptance alone is never reported as `:sent`. Proven by tests,
      together with the payload carrying no secret material.
- [x] 3.4.4 Before the edge route ships, either enable
      `:status_handler_enabled` (default `false`,
      `cluster/coordinator_children.ex:96-113`) so
      `ServiceRadar.AgentCommands.StatusHandler` durably persists command acks,
      progress, and results, or ship the poll-based reconciler. If reconciling,
      follow the ready-made shape: the `ActionInvocationTarget` `:poll_due` read
      plus its currently-callerless `list_poll_due` code interface.
      DECIDED: the poll-based reconciler (`Dispatcher.reconcile/2` +
      `Notifications.ReceiptWorker`). `:status_handler_enabled` is NOT flipped.
      Three reasons, in order of weight:
      1. Flipping it is a no-op where it matters and a blast radius where it does
         not. Both deployed releases already default the env var to `"true"`
         (`serviceradar_core/config/runtime.exs`,
         `serviceradar_core_elx/config/runtime.exs`), so production already runs
         the handler; the `false` supervision default is only reached where no
         config sets the key - `config/test.exs` sets it false ON PURPOSE. So the
         change would alter behaviour for sync ingest, DIRE, and the results
         router in exactly the contexts where it is off deliberately, and change
         nothing in production. The design doc's premise ("with stock config an
         edge delivery leaves no receipt") is inaccurate for a release.
      2. It would not deliver a receipt anyway. Nothing maps an `agent_commands`
         row onto a `notification_deliveries` row, so enabling the handler
         persists results no notification reads. The reconciler is needed either
         way; the handler only makes its answer arrive sooner.
      3. A delivery guarantee must not vary with another subsystem's supervision
         flag. `reconcile/2` reads only what CORE writes - the command row the
         bus itself creates, its status, and the `expires_at` it computes from
         the TTL - so it reaches the same answer with the handler on or off.
      Shape: a bounded scan over every `:dispatching` row carrying a
      `command_id` (the `:poll_due` shape this task points at, expressed as an
      Ash filter rather than a new read action). A completed/failed outer command
      is not itself the answer: the reconciler parses the embedded notifier SDK
      result and preserves `delivered | retryable | failed`. An in-flight command
      inside its TTL is left alone; past its TTL it is a
      `command_receipt_timeout` and is owed another attempt. A missing result is
      never guessed delivered.
- [x] 3.4.5 Add a bounded periodic scan that recovers deliveries whose wake-up
      signal was lost, and a reconnect drain for commands queued while an agent
      was offline.
      `due/2` now selects only `:pending` rows. It never hands a `:dispatching`
      command back for blind re-dispatch, because that can send a second
      notification after the first command already ran. `reconcile/2` (3.4.4)
      exclusively owns those rows and settles them from the durable command
      receipt on a one-minute cron; an unreadable receipt gets a bounded grace
      period and then enters the ordinary retry/failover budget.
      Reconnect drain: there are no commands queued at the agent to drain - the
      bus is at-most-once and marks the command `offline` rather than spooling
      it - so what is drained is the delivery row waiting out a backoff in core.
      `reconcile/2` returns a `:drain` list of `:pending` rows whose last error
      was `agent_offline` and whose agent now has a control session
      (`AgentCommandBus.lookup_control_session_entries/1`), and `ReceiptWorker`
      re-queues each with `replace: [scheduled: [:scheduled_at]]` - the only
      thing that moves a job Oban already has, since `DispatchWorker`'s unique
      key spans the incomplete states and a plain enqueue would silently keep the
      old `scheduled_at`. No new process and no cross-app hook into the gateway:
      the scan asks the registry rather than waiting to be told.
- [x] 3.4.6 Add the Helm value and template wiring for whichever option 3.4.4
      selects, plus its documentation.
      DONE. `core.notifications.platformAgent.{agentId,partitionId}` (defaulting
      to `agent.agentId` and the deployment partition) and
      `core.notifications.receiptSweep.enabled` in `values.yaml`, rendered into
      `templates/core.yaml` as `SERVICERADAR_NOTIFICATION_PLATFORM_AGENT_ID`,
      `..._PARTITION`, and `SERVICERADAR_NOTIFICATION_RECEIPT_SWEEP_ENABLED`.
      With `agent.enabled: false` and no explicit override NOTHING is rendered,
      so a control-plane plugin channel fails with `platform_agent_unconfigured`
      instead of dispatching to an arbitrary agent. Verified with
      `helm template` for all three shapes (default, agent disabled, agent
      disabled with an explicit override).
      Cron and bounds are built by `Notifications.DispatchSchedule` so the two
      runtime.exs trees cannot drift, gated by
      `SERVICERADAR_NOTIFICATION_RECEIPT_SWEEP_{ENABLED,CRON}` and
      `SERVICERADAR_NOTIFICATION_RECEIPT_LIMIT`.
      Docs: `docs/docs/notifications.md` gains "Plugin providers run on an agent
      even on the control plane" (including the four permanent `error_class`
      values an operator will see) and "Receipts for agent-routed deliveries".

### 3.5 Runtime display and config contract resolution

- [x] 3.5.1 Replace the compile-time `@built_in_contracts` `File.read!` in
      `elixir/web-ng/lib/serviceradar_web_ng/observability/signal_display.ex` with
      runtime resolution from the installed package, so a third-party package can
      ship a renderable contract without recompiling web-ng. The map holds SEVEN
      MAP ENTRIES over SIX DISTINCT PATHS (powerdns 0.1.0 and 0.1.1 share a
      path), so the replacement must key on the (package, version) pair those
      entries already distinguish, not on the file path.
      DONE, but the compile-time map is DEMOTED rather than replaced, and that is
      deliberate: the six first-party contracts are NOT shipped inside their
      bundles (`build/native_addons/addon_inventory.bzl:72-75` gives powerdns
      exactly `addon.yaml` + `config.schema.json`), so deleting it would stop
      PowerDNS, Axis, UniFi Protect, Proxmox, Trivy, and Falco rendering.
      Resolution is now ordered: caller/application override, then
      `ServiceRadarWebNG.Observability.ContractRegistry` (the runtime index), then
      the built-in map - `signal_display.ex` `resolve_contract_with_source/2`.
      Storage is a new `display_contracts` jsonb column on BOTH package resources
      (migration `20260810120000_add_display_contracts_to_packages.exs`), keyed
      `"<contract_id>@<contract_version>"`; the registry indexes it by the same
      four-part `{producer_id, producer_version, schema_id, schema_version}` key
      the stored signal ref carries, which is the (package, version) pair the old
      seven entries distinguished.
- [x] 3.5.2 Validate display and config contracts at import time and version them.
      Display contracts: new `ServiceRadar.Plugins.DisplayContract` - closed
      top-level key list, closed widget-type and widget-key lists, `id` +
      `version` (semver) as the storage key, `schema_id` + `schema_version` as
      the binding, and a `surface` of `signal` (default) /
      `notification_delivery` / `notification_channel_health`. The nine UI-code
      keys the manifest already refuses on an action are refused here at ANY
      DEPTH, so a contract cannot become a second door into that capability.
      Enforced at three points: the bundle importers, the resource
      (`Validations.DisplayContracts` on `PluginPackage` create/update and
      `AddonPackage` create/update/reimport - the admin API and the packages
      LiveView are writers too), and again on the way out of the database in the
      registry, because a row may predate the current validator.
      Config contracts were ALREADY validated at import from Phase 3.1: a
      `notifications:` entry's `config_schema` goes through
      `ConfigSchema.validate_schema/1` (`manifest.ex` `validate_notification_config_schema/3`).
- [x] 3.5.3 Degrade gracefully when a contract is missing or invalid, and make the
      diagnostics enumerable to operators.
      Three failure modes, three dispositions. A bundle contract this release
      refuses is DROPPED, not fatal to the import (`DisplayContract.partition/1`):
      a `display/` entry cannot change what a plugin does, and an existing
      first-party bundle already ships a placeholder there, so failing the signed
      artifact over it would break installs for a UI file. The reasons are
      recorded in `source_metadata["display_contract_errors"]`. A stored contract
      that fails re-validation is skipped with a diagnostic
      (`ContractRegistry.diagnostics/0`). A contract that renders no widgets
      degrades to `SignalDisplay.generic_widgets/2` - scalars as facts,
      containers as JSON, labels derived from the RECORD's keys so a rejected
      contract cannot smuggle text through the fallback. Both diagnostic sources
      are listed per package in the admin package panel
      (`plugin_package_live/index.ex` "Runtime Display Contracts").
      Note the asymmetry: a contract typed into the API or admin UI still fails
      loudly (`DisplayContract.validate_all/1`), because there a silent drop is a
      lie about what the operator saved.
- [x] 3.5.4 Render notification channel config forms, the delivery log, and
      channel health from the package-supplied contracts.
      `Settings.NotificationsLive.Contracts` resolves all three at runtime.
      The channel config form now reads the notifier's `config_schema` from the
      package's CURRENT `notifications:` manifest block rather than the copy
      taken when the provider row was created, so a package upgrade reaches the
      form; `index.ex` `provider_schema/1` resolves through the SAME function, or
      secret-field detection and the test-send payload would classify a
      package-declared secret as ordinary configuration. The Delivery Log detail
      and channel health render `notification_delivery` and
      `notification_channel_health` surface contracts through the SAME widget
      renderer the events and logs pages use
      (`SignalDisplayComponents.signal_display_widget/1`) - a second renderer
      would be two contracts wearing one name - and fall back to the generic view
      when a package ships none.

### 3.6 Bundle registration (three hand-synced places)

**NOT APPLICABLE to this change. Do not do this work.** 3.6 is conditional on
shipping a FIRST-PARTY notification wasm bundle, and this change deliberately
ships none. Recorded here rather than left dangling, with the reasoning, so a
later reader knows it was decided and not forgotten.

1. Nothing first party belongs on the `:wasm_plugin` tier. D2 reserves that tier
   for request signing, OAuth exchanges, non-HTTP transports, payload transforms
   templating cannot express, and site-local egress. Every destination we would
   ship ourselves is reachable from the platform and is "POST this JSON to this
   URL", which is the `:declarative` tier - the tier D2 says covers ~85% of
   destinations with no code and no release. A first-party notifier bundle would
   be a third in-tree implementation of something `:native` and `:declarative`
   already implement, and the only in-tree consumer of a contract built for
   third parties.
2. The contract does not need a bundle to be proven. What Phase 3 owes is that
   the manifest block validates, that `notify:v1` is enforced at the host, and
   that `action_key` binds to a declared notifier. All three are proven by the
   tests landed under 3.1, none of which needs a signed OCI artifact. The
   example notifier and its fixture corpus already have a home: 3.8.2, in
   `serviceradar-sdk-go`.
3. Two of the three registration points would be no-ops anyway. A notifier
   bundle introduces no new bundle FILE KIND - the `notifications:` block lives
   inside `plugin.yaml`, and a notifier's `config_schema` is inline in that
   block rather than a separate file. `first_party_importer.ex` already accepts
   `plugin.yaml`, `plugin.wasm`, `config.schema.json`, `display_contract.json`,
   `docs/*`, `display/*.json`, and `schemas/*.json`, and
   `validate-external-wasm-plugin-bundle.py` already requires exactly
   `{config.schema.json, plugin.wasm, plugin.yaml}`. So 3.6.1 and 3.6.2 have
   nothing to add; only 3.6.3's inventory tuple and 3.6.4's verification would
   be real work.
4. The cost of registering is permanent and the cost of deferring is not. Each
   hand-synced place is a spot a future bundle can be forgotten, and a missing
   entry fails the RELEASE PUBLISH rather than a local build. Paying that to
   ship an example is a bad trade; if a first-party notifier is later justified
   (a destination that genuinely needs signing or a non-HTTP transport), 3.6.3
   and 3.6.4 are mechanical and nothing in the manifest or capability contract
   has to change to accommodate them.

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

- [x] 3.7.1 Warn in the escalation policy editor when the only reachable route is
      an `:edge_agent` channel bound to the same `partition_id` as the alert
      source - the configuration that silently guarantees no page exactly when one
      is owed.

      **Already satisfied by Phase 1.** `notifications_live/edge_route_safety.ex`
      is the pure decision (`evaluate/2`, `warns?/2`, `reachable_channels/2`),
      `components.ex:1084` is the `edge_route_warning` component, and it renders
      in THREE places, not only the editor: the policy editor
      (`components.ex:1128`), the policy row outside the editor
      (`components.ex:1048`), and a badge on every route bound to the policy
      (`components.ex:538-542`). `index.ex:321` computes the map for saved
      policies and `index.ex:1726` recomputes it live on `validate_policy`.
      Covered by `notifications_edge_route_safety_test.exs` and
      `notifications_components_test.exs` "the warning appears on the policy row,
      outside the editor".

      One deliberate difference from the task text, recorded so it is not read as
      a gap: the implementation does NOT compare against the alert source's
      `partition_id`, because a policy is bound to routes matching many alerts
      and there is no single alert source at editing time. It warns whenever
      EVERY reachable channel is `:edge_agent` - a strict superset of the
      same-partition case - and names the partitions in the message so an
      operator can see which site is affected.

- [x] 3.7.2 Surface `fallback_channel_id` and `fail_closed` prominently on any
      channel using `:edge_agent`.

      `EdgeRouteSafety.channel_advisory/2` answers the policy-level question one
      channel at a time, so the two cannot drift. It accepts either a loaded
      channel (atom keys) or the editor's string-keyed params - a form has no
      `partition_id` yet, so `agent_uid` stands in as the site label - and grades
      the outcome by what the operator loses: `:error` for `fail_closed` (the
      page is dropped) and for a fallback in the SAME site (both die at the same
      instant), `:warning` for no fallback / an unreadable fallback / another
      site's agent, `:ok` for a control-plane fallback.

      `components.ex` `failover_fields/1` lifts the two fields out of the general
      grid into their own emphasised section that states the at-most-once
      constraint, and renders the advisory live on every `phx-change` - so the
      consequence of ticking fail closed is on screen at the moment it is ticked.
      `channel_failover_badge/1` puts the compact form on the saved channel row.
      Covered by `notifications_edge_route_safety_test.exs` "channel_advisory/2"
      and `notifications_components_test.exs` "channel editor failover section".

### 3.8 Cross-repository SDK work (SEPARATE REPOSITORIES)

Both SDKs are committed on a branch named `add-notifier-plugin-kind` in their own
repository, UNPUSHED and with no PR opened, for separate review:

* `serviceradar-sdk-go` `add-notifier-plugin-kind` @ `5879c0a`, branched from
  `origin/main` @ `e892cd5`.
* `serviceradar-sdk-rust` `add-notifier-plugin-kind` @ `c093ef7`, branched from
  `origin/main` @ `1e9fc52`.

Both repositories were checked out on an unmerged, fully-pushed
`add-service-monitoring-sdk-parity` branch. Neither checkout was disturbed: the
work was done in a `git worktree` at `<repo>-notifier`, so the original working
directories are still on that branch at their original commits.

- [x] 3.8.1 `serviceradar-sdk-go` (separate repository): add the notifier plugin
      kind, the delivery request and result envelopes, notifier intents,
      capability-gated behaviour, credential-broker helpers for outbound HTTP,
      config decoding against the manifest config schema, and the
      `notifications:` manifest contract builder and validator. The manifest
      emitter MUST emit exactly the keys the validator owns (3.1.1): `key`,
      `display_name`, `description`, `entrypoint`, `config_schema`,
      `capabilities`, `payload_formats`, `routes`, `credential_requirements`,
      `inbound`. An SDK that emits `provider_key` or `inbound_callback` produces
      manifests the platform rejects.

      `sdk/notification.go` (envelopes, intents, three statuses,
      `ExecuteNotification`), `sdk/secret_ref.go` (opaque `SecretRef`, the six
      canonical injection modes, the leak guard), `sdk/notification_config.go`
      (`DecodeChannelConfig`, `ValidateChannelConfig`),
      `sdk/notification_manifest.go` (`NotificationProviderContract`,
      `Validate`, `RenderNotificationsManifestBlock`), `sdk/notification_http.go`
      (notifier request helpers, `ClassifyNotificationResponse`).

      The renderer emits nine of the ten keys unconditionally, with the same
      defaults the platform validator fills in, and `description` only when set.
      That is deliberate: a block whose key set depends on which optional fields
      happen to be populated is a block two SDKs render differently for the same
      contract, which is the drift the shared corpus exists to catch.

- [x] 3.8.1a Both SDKs use the canonical credential injection mode names from
      3.2.4 (`http_header`, `bearer_token`, `basic_auth`, `query`,
      `form_urlencoded`, `oauth2_password_bearer`) in their helper APIs and
      fixtures, so a plugin author never learns a shorthand the host does not
      accept.

      Go exposes them as `sdk.InjectHTTPHeader` ... `sdk.InjectOAuth2PasswordBearer`
      and returns `sdk.ErrUnsupportedInjection` for anything else;
      `TestOnlyTheSixCanonicalInjectionModesAreAccepted` asserts `bearer`,
      `basic`, `header`, `form`, `query_param`, `http_basic_auth`, `url_path`,
      and `path` are all refused, and that the error lists the alternatives.
      Rust makes the mode a typed enum so a shorthand cannot be spelled, and
      `CredentialInjectionMode::parse` refuses the same list with
      `Error::UnsupportedInjection`.

- [x] 3.8.2 `serviceradar-sdk-go` (separate repository): add an example notifier
      plugin and a fixture-based conformance test.

      `examples/notifier/` builds under `tinygo build -o plugin.wasm
      -target=wasi ./` and the module exports `send_notification`, `alloc`, and
      `dealloc` (verified). Its `plugin.yaml` `notifications:` block is what
      `RenderNotificationsManifestBlock(exampleContract())` emits, and
      `main_test.go` fails if the two drift. The six shared fixtures live in
      `fixtures/notification_*.json` with a `fixtures/README.md` stating they are
      test fixtures, not runtime defaults;
      `sdk/notification_conformance_test.go` decodes each request fixture,
      asserts the typed accessors, re-encodes each result fixture, and asserts
      the rendered manifest block equals `notification_provider_contract.json`.

- [x] 3.8.3 `serviceradar-sdk-rust` (separate repository): implement notifier
      parity with the Go SDK against the same fixture corpus.

      `src/notification.rs`, `src/secret_ref.rs`, `src/notification_config.rs`,
      `src/notification_manifest.rs`, `src/notification_http.rs`, plus
      `examples/notifier/`, which builds for `wasm32-unknown-unknown` and exports
      `send_notification`, `alloc`, and `dealloc` (verified). The API is
      idiomatic Rust - free functions, `Result`, typed enums, no plugin trait and
      no registration macro - while the bytes are identical. The six fixture
      files are byte-identical to the Go SDK's (sha256-verified) and both
      conformance suites assert against them.

      Two Rust-specific decisions worth recording. `decode_channel_config`
      requires `Serialize` on the target type because Rust has no runtime
      reflection to check the destination TYPE the way the Go guard does; it
      re-serializes what it decoded and refuses the result if a sentinel
      survived, which it can only do if the sentinel landed in a `String` rather
      than a `SecretRef`. And intents / payload formats / routes are OPEN enums
      that preserve an unknown value through a round trip, so an older plugin
      never silently rewrites a field a newer control plane sent, while the three
      result statuses are CLOSED - a fourth status is a contract change and must
      fail to decode rather than be guessed at.

- [ ] 3.8.4 Version and release both SDKs jointly against one notifier contract
      version; pin the new SDK versions in every in-repo Wasm plugin.

      **Prerequisites in place; the release itself is not done and cannot be
      until both branches are reviewed and merged.** Both SDKs export the same
      contract version - `sdk.NotifierContractVersion` in Go,
      `NOTIFIER_CONTRACT_VERSION` in Rust, both `"1.0.0"` - and emit it as
      `sdk_contract_version` on EVERY result including the synthesised
      `plugin_no_result` one, so a mismatch is detectable at dispatch. Neither
      repository has been tagged, no crate or module version was bumped, and no
      module under `go/cmd/wasm-plugins/` pins the new SDK. The repository gate
      described in the spec (verify every module whose `plugin.yaml` declares a
      `notifications:` block pins an SDK at or above the notifier release) is
      also not built; it has nothing to check until a first notifier-bearing
      module exists, and 3.6 records that this change deliberately ships none.

- [x] 3.8.5 Add notifier logging and payload redaction safety to both SDKs so a
      guest cannot log an injected credential.

      Neither SDK logs `rendered_payload`, `channel_config`, `alert_snapshot`, or
      any `action_links` value, and neither provides a helper that does.
      `sdk.RedactedRequestSummary` / `redacted_request_summary` return identity
      fields only. `SanitizeNotificationErrorMessage` /
      `sanitize_notification_error_message` bound every SDK-generated
      `error_message` to 512 bytes and strip both a `secretref:` sentinel and a
      full action-link URL - reducing a URL to scheme plus host, which keeps the
      diagnostic while dropping the capability token that would otherwise let
      anyone reading a delivery log acknowledge the alert. `WithError` /
      `with_error` route through it, so an author cannot bypass it by
      constructing a result directly. `SecretRef` renders a placeholder through
      `String()`/`Display`, `MarshalJSON`/`Serialize`, and `%v`/`%s`/`%#v` /
      `{}`/`{:?}`.

### 3.9 Phase 3 tests, docs, and gates

- [x] 3.9.1 Elixir tests for manifest parsing of the `notifications:` block,
      including rejection of UI-markup keys, of an undeclared capability, of an
      unknown block key (`provider_key` and `inbound_callback` are the two
      near-miss spellings to assert on), and of a `capabilities` list missing
      `send` or `test`.

      Already covered by the tests landed with 3.1.1, and nothing was added -
      a second copy of any of these would be a rule asserted in two places that
      can disagree. `test/serviceradar/plugins/manifest_notifications_test.exs`:
      `provider_key` at `:88`, `inbound_callback` at `:94`, the nine UI-markup
      keys at `:100`, missing `send` at `:110`, missing `test` at `:116`, an
      undeclared capability at `:122`. The file goes further than the task text
      in three places worth noting, because they are what make the block a
      contract rather than a shape: `:363-385` asserts the capability, payload
      format, and route vocabularies are EQUAL to
      `NotificationProvider`'s (the two lists are deliberately separate literals
      to avoid a compile cycle, so only a test keeps them from drifting);
      `:213` asserts the four shorthand injection-mode spellings are refused
      rather than silently accepted; and `:232` pins that no accepted mode
      rewrites a URL path, which is the reason Slack and Discord incoming
      webhooks cannot run on the edge route.

- [x] 3.9.1a A test asserting a provider whose `action_key` is absent from the
      referenced package's `notifications:` block is rejected.

      Already covered:
      `test/serviceradar/notifications/provider_action_key_db_test.exs:143`
      ("an undeclared key is rejected and the message lists what is declared"),
      with `:158` covering the adjacent case of a package that declares no
      `notifications:` block at all, and `:125` the positive case.

- [x] 3.9.2 Go tests for `notify:v1` enforcement and for credential injection mode
      selection, asserting the canonical mode names from 3.2.4 and that a
      shorthand name is not silently accepted.

      Already covered by `go/pkg/agent/plugin_runtime_notify_test.go`.
      Enforcement is asserted on BOTH entrances to plugin execution, which is
      the property that makes it a permission rather than a warning:
      `TestRunActionDeniesNotificationWithoutNotifyCapability` (`:156`),
      `TestRunActionAdmitsNotificationWithNotifyCapability` (`:173`),
      `TestRunPluginVerbDeniesNotificationWithoutNotifyCapability` (`:220`),
      and `TestRunActionLeavesNonNotificationActionsUngated` (`:199`) so the
      gate is not simply denying everything. Injection modes:
      `TestNotificationCredentialInjectionModesAreTheCanonicalSix` (`:644`)
      pins the six names against the manifest allowlist and refuses `url_path`;
      `TestNotificationCredentialGrantsServiceable` (`:671`) refuses `header`,
      `http_basic_auth`, `query_param`, `url_path`, and an invented mode;
      `TestRunActionDeniesNotificationWithUnserviceableInjectionMode` (`:722`)
      proves the allowlist is enforced at the same admission point as the
      capability rather than only deep in the HTTP path; and
      `TestNotificationMalformedGrantBlockFailsClosed` (`:744`) proves an
      undecodable grant block is not treated as "no grants".

- [x] 3.9.3 Agent-offline failover test and a fail-closed test asserting no
      failover occurs.

      Already covered by
      `test/serviceradar/notifications/dispatcher_edge_test.exs`:
      "takes exactly one hop and back-references its origin" (`:207`) and
      "a fail_closed channel never fails over" (`:224`). The negative case that
      makes the pair meaningful is also there - "does not fail over while the
      retry budget is unspent" (`:182`) - since a failover test passes just as
      well against an implementation that fails over on the first offline
      reply, which is the behaviour R2 forbids.

- [x] 3.9.4 Reconciler test proving a delivery whose command result was lost still
      reaches a terminal state.

      **Partially covered; the terminal-state half was missing and was written.**
      The 3.4.4 block proved a lost result is settled from the command row
      (`:283` completed, `:300` failed, `:317` in flight, `:326` past its TTL),
      but every one of those ends at `:pending` or is deliberately left alone.
      "Owed another attempt" is not a terminal state, so the block did not
      actually prove the at-most-once command bus (forgejo #4902) cannot strand
      a page.

      New describe block "a lost command result still reaches a terminal state
      (tasks 3.9.4)" at `dispatcher_edge_test.exs:376`, covering the two ways a
      result is lost:

        * `:377` the command row is READABLE but never answered, on a delivery
          with no budget left: the sweep drives it to `:failed` with
          `command_receipt_timeout` and it takes its failover hop, so a lost
          result costs one channel rather than the page. The same pass is then
          re-run to prove the sweep converges - a settled row leaves the
          `:dispatching` scan, so there is no second failover.
        * `:417` the command row is UNREADABLE (purged, or never persisted).
          `reconcile/2` deliberately refuses to invent an outcome there, so the
          backstop has to be the stalled-row sweep in `due/2` - and without it
          the row is selected by nothing in the system, since `read :retry_due`
          takes only `:pending`. This is the case no existing test touched.

- [x] 3.9.5 Contract-resolution tests for a third-party package shipping a display
      contract without a web-ng recompile.

      Already covered:
      `elixir/web-ng/test/serviceradar/observability/contract_registry_test.exs:202`
      ("a third-party package's contract renders with no web-ng recompile")
      installs a package that is not in `@built_in_contracts`, refreshes the
      registry, and asserts the signal resolves `:runtime` and RENDERS - the
      widget values, not just the lookup. The surrounding cases are what make it
      a resolution test rather than a lookup test: `:217` the same signal
      renders nothing once the package is uninstalled, `:228` a first-party
      signal still resolves from the compile-time map (the built-in map is the
      fallback, not a removed layer), `:251` an installed package overrides
      nothing it did not declare, and `:259` a refused contract degrades to no
      contract with an enumerable diagnostic rather than a crash. The notifier
      surfaces are covered at
      `elixir/web-ng/test/phoenix/settings/notifications_contracts_test.exs:161`
      (delivery log) and `:191` (channel health), including the degrade path.

- [x] 3.9.6 Add `docs/docs/notification-plugin-authoring.md` covering the
      `notifications:` manifest block, `notify:v1`, credential handling, and the
      two supported routes. Restate that `:edge_agent` is only for destinations
      unreachable from the platform and that an edge-only policy cannot deliver
      the "this site went dark" page. ASCII only.

      Written. Covers the ten manifest keys with their required/default columns,
      the two near-miss spellings and WHY each is refused, the capability and
      payload-format vocabularies, the `inbound` block, and the
      `notifications:` / `notify:v1` coherence rule. `notify:v1` is presented as
      enforced at the host on both entrances against the NARROWED capability set
      rather than declared in a manifest, with the "two capabilities are
      declared and enforced nowhere; this must not become the third" framing.
      Credentials: secrets never enter guest memory or `params_json`, the grant
      names a secret rather than carrying one, host-side injection at the HTTP
      boundary, the six canonical modes in a table, the refused shorthands, and
      the URL-path constraint with the Slack/Discord consequence and the
      bot-token workaround. The edge route is restated as unreachable
      destinations only, with the site-down page called out in a blockquote and
      forgejo #4902 named. Cross-links to `notifications.md`,
      `notification-providers.md`, `wasm-plugins.md`, `sdks.md`,
      `telemetry-display-contracts.md`, and `edge-agent-onboarding.md` rather
      than repeating them. ASCII only; verified with a static pass for
      non-ASCII, fence balance, bare `{` / `<` outside code spans (the MDX
      hazard), in-page anchors, and relative link targets.

      Two adjacent staleness fixes, since this page is what they should point
      at: `notifications.md:99` said `wasm_plugin` providers "arrive in a later
      phase", which stopped being true when Phase 3 landed, and
      `notification-providers.md:52` now names the page its own tier table
      keeps deferring to.

- [x] 3.9.7 Update `docs/docs/sdks.md` and `docs/docs/edge-agent-onboarding.md`
      for notifier support.

      `sdks.md`: the notifier surface added to both SDK descriptions plus a
      "Notifier plugins" section covering the shared envelopes, the manifest
      builder, the opaque secret reference, the ten keys / six modes both SDKs
      agree on, and the contract version stamped on every result.
      `edge-agent-onboarding.md`: a "Notification Delivery From This Site (Edge
      Route)" section under "Next: Turn On Collection", with the three setup
      steps and the three constraints an operator has to know before routing a
      page through a site agent - the route is for unreachable destinations
      only, the at-most-once bus means an edge-only policy cannot deliver the
      site-down page, and Slack/Discord incoming webhooks are refused there.
      Registered in `docs/sidebars.ts` next to its two sibling notification
      pages; `sidebars.ts` re-verified under node (75 doc entries, no missing
      files, no new duplicate ids).
- [x] 3.9.8 `./scripts/elixir_quality.sh --project elixir/serviceradar_core`,
      `./scripts/elixir_quality.sh --project elixir/web-ng --phoenix`,
      `bazel run //:gazelle`, `bazel test --config=remote //go/pkg/agent/...`, and
      `bazel build --config=remote //rust/...` if any Rust changed.

## 4. Phase 4 - Stream provider and native interactivity

### 4.1 Firehose subject and broker allowlist

- [x] 4.1.1 Define the notification subject namespace (for example
      `notifications.>`) and its JetStream stream with a durable cursor so
      reconnecting consumers replay instead of losing events.
- [x] 4.1.2 Add the new namespace to the per-CN publish and subscribe allowlists
      in `helm/serviceradar/templates/nats.yaml:205-217`. New subject namespaces
      are DENIED at the broker by default - omitting this silently breaks the
      firehose.
- [x] 4.1.3 Add the namespace to every CN that needs it (core publish, web-ng
      subscribe) and to the NATS credential generation job if scoped credentials
      are used.
- [x] 4.1.4 Verify on a live stack with the `nats` CLI from the tools pod that
      publish and subscribe succeed for the new subject.

### 4.2 Stream provider

- [x] 4.2.1 Implement the built-in `:stream` provider type behind the same
      `Transport` behaviour (`deliver/2`, `validate_config/1`, `capabilities/0`,
      `test/2`) so the firehose traverses routing, suppression, redaction, and
      audit like any other channel - never a parallel unaudited egress. `:stream`
      is a `provider_type`, not a fourth extensibility tier: operators cannot
      author one.
- [x] 4.2.1a Implement stream suppression correctly, because two different
      surfaces are involved and conflating them is the easy mistake. A suppressed
      dispatch to a `:stream` channel publishes NO envelope on the stream, and
      writes a `NotificationDelivery` row with `state: :suppressed`. Separately,
      the DELIVERY LOG UI displays those suppressed rows with their
      `suppression_reason` (1.7.8) rather than omitting them. Nothing publishes a
      "suppressed" envelope to subscribers.
- [x] 4.2.2 Add the RBAC-scoped Phoenix Channel topic in web-ng, authorizing on
      `notifications.stream.subscribe` and filtering the envelope to what the
      subscriber may see.
- [x] 4.2.3 Define and document the canonical notification envelope shape. It
      carries alert and delivery identifiers that a subscriber resolves through
      the authenticated API, and it carries NO action link or capability token
      (1.6.2a).
- [x] 4.2.4 Seed the `:stream` `NotificationProvider` row as a first-party
      `managed` provider alongside `slack`, `discord`, `webhook`, and `email`,
      using the same `managed` / `template_version` / `template_fingerprint`
      reconciliation as those four (1.4.9). It is seeded, not operator-authored,
      and an operator may disable it without the next upgrade re-enabling it.

### 4.3 Native interactive acknowledgement

Scope amended after verifying each provider against the shipped transports; see
design.md D7 for the evidence. Slack is buildable on the current credential
model, Discord is not, and PagerDuty inbound is blocked on an architectural
decision. The platform seams below are shared and must land first, because each
one is a silent-failure source if done per-provider.

- [x] 4.3.0a Platform seam: `Content` gains `delivery_id` and `snooze_seconds`,
      plus a single `action_controls/1` accessor whose first clause matches
      `%Content{include_action_links?: false}` exactly as `action_links/1` does,
      so the stream exemption cannot be routed around by a new call site. Without
      these two fields an interactive control can bind only `alert_id` - a weaker
      binding than the Phase 1 link it replaces, which refuses to mint without
      both - and every interactive snooze fails `:missing_snooze_seconds`,
      because `apply_native/2` deliberately refuses a house default.
- [x] 4.3.0b Platform seam: notification callback route plus its own pipeline.
      The existing `/api/notifications` scope pipes `:notification_action`, which
      is `accepts ["html"]` and would 406 a JSON provider POST, and shares its
      rate-limit bucket. Assert `RawBodyReader.buffered?/1` for each concrete
      route: the prefix match is `String.starts_with?`, so a route without the
      trailing slash is silently unbuffered.
- [x] 4.3.0c Platform seam: verify -> enqueue -> ack. Every provider has a 3-5 s
      response budget and `apply_native/2` opens a `Repo.transaction`. Doing that
      work inline is fragile under load; the callback verifies, enqueues, and
      acknowledges, and the job applies the capability.
- [x] 4.3.0d Platform seam: idempotency keyed on the provider's own event id.
      Northbound has no equivalent and all three providers retry.
- [x] 4.3.1 Slack Block Kit acknowledge / snooze / resolve buttons, posting to the
      notification callback route. Interactive mode defaults OFF; when on, `url`
      is removed from the action buttons so the click is a pure interaction.
      `api_app_id` and the signing-secret ref are required channel config, and
      the channel `test` action asserts both - there is no API that detects a
      missing Interactivity Request URL, and inert buttons produce no request and
      no log.
- [x] 4.3.1a App-scoped storage for the Slack signing secret, resolved by
      `api_app_id`. It is deliberately NOT in channel config: the secret belongs
      to the Slack app, so channel config would hold one copy per channel backed
      by the same app, and the inbound interaction names `api_app_id` and never
      our channel, so the callback could not find it by channel. The
      provider-seeder invariant "credential fields are named for the keys the
      transport resolves" also correctly refuses it there, since the transport
      never resolves it at send time - only the inbound callback consumes it.
- [ ] 4.3.2 DEFERRED - Discord message components. Not feasible on the current
      credential model: `transports/discord.ex` stores a pasted user-owned
      webhook URL (`application_id: null`), Discord ignores components on those,
      and there is no application to route an interaction to. Requires a
      registered Application plus per-guild OAuth install, which is an onboarding
      change and belongs in its own proposal. Until then Discord stays on Phase 1
      links and must NOT advertise an interactive capability, because the refusal
      is silent (200/204, message posted without buttons, delivery recorded as a
      success).
- [x] 4.3.3 PagerDuty acknowledgement webhooks. UNBLOCKED by rereading the
      constraint: the declarative tier forbids a provider DOCUMENT declaring an
      inbound capability, not the platform owning an endpoint, and the callback
      path is already tier-agnostic. `Callbacks.PagerDuty` verifies the v1=
      comma-list signature over the body alone, correlates on
      `event.data.incident_key` (the dedup_key we sent, which is the alert id),
      and maps incident.acknowledged / incident.resolved onto the alert
      transitions. Snooze and the two no-inverse event types are refused
      explicitly. Remaining for a live round trip: 4.3.3c.
- [ ] 4.3.3c PagerDuty webhook subscription management. Creating the
      subscription via `POST /webhook_subscriptions` and capturing
      `delivery_method.secret` from the CREATE RESPONSE, which is the only time
      PagerDuty ever returns it - a subscription whose secret was not captured is
      unrecoverable and must be deleted and recreated. Until this exists an
      operator registers the subscription by hand and posts the secret through
      `POST /api/admin/notification-callback-apps` with
      `provider_key: "pagerduty"` and the subscription id as
      `external_app_id`. Consider the custom-header callback token from 4.3.4a at
      the same time, since both are set at subscription-create.
- [x] 4.3.3d PagerDuty inbound idempotency on `event.id`. Lower priority than it
      looks: `apply_native/2` already disposes an alert in the target state as
      `:already_applied`, so a retry cannot double-transition. What a store would
      add is suppressing the duplicate AUDIT row a retry writes. Worth doing
      because PagerDuty has no transport replay defence, but it is an audit
      cleanliness fix, not a correctness hole.
- [x] 4.3.3a PagerDuty action links now ship in the top-level `links` array
      instead of `payload.custom_details`, where PagerDuty rendered them as inert
      text an on-call engineer had to select and paste. Catalog template_version
      bumped to "2" so deployed rows reconcile.

      Two claims investigated and NOT defects, recorded so they are not
      re-reported: `renderers/pagerduty_v2.ex` is unreachable on the shipping
      path, but deliberately so - `template_seeder.ex` documents that
      `:pagerduty_v2` has no first-party native provider yet and the template
      exists so a future one does not land on a format with no default. The
      dedup_key "disagreement" follows from that: the catalog's `{{ alert.id }}`
      is what ships, consistently, and an inbound lookup should be written
      against it.
- [x] 4.3.3b PagerDuty incidents never auto-resolve. Confirmed live defect,
      independent of interactivity. `:resolve` is a dispatched lifecycle reason
      (`routing_worker.ex:83`, `dispatcher.ex:320`), but nothing in the
      notification path ever passes `:event_action` to `Renderer.render/4`, so
      `Content.event_action` is always `:trigger` - and the PagerDuty catalog
      document hardcodes `"event_action" => "trigger"` besides. A ServiceRadar
      alert resolving therefore sends PagerDuty a TRIGGER carrying the same
      `dedup_key`, which updates the open incident instead of closing it. Every
      incident stays open until a human closes it by hand.

      The fix is not a template edit: templates are restricted substitution with
      no conditionals, so `renotify -> trigger` and `resolve -> resolve` cannot
      be expressed in the document and must be derived. It needs the lifecycle
      reason to reach render time, and today it reaches neither
      `notification_deliveries` (no such column) nor `delivery_namespace/1`. So:
      carry the reason on the delivery, expose a derived
      `delivery.event_action` ("trigger" | "resolve") in the template variable
      catalog, pass `:event_action` from the dispatcher for native renderers
      too, and bump the declarative catalog version again.
- [x] 4.3.4 AMENDED. This task previously required all three callback paths to
      "reuse the northbound stack verbatim: token from header / Bearer / body,
      sha256-only persistence, `Edge.Crypto`-encrypted HMAC secret,
      `Plug.Crypto.secure_compare`, and HMAC-SHA256 over
      `<timestamp>.<raw_body>` with a 300 s tolerance". That is not achievable
      and the original wording is retained here only so the change is visible
      rather than silent. The reasons, verified rather than assumed:
      the northbound stack is token-PRIMARY (`command_result_handler.ex:174-186`
      rejects unless a bearer token matches `callback_token_hash`) and Slack and
      Discord present no token of ours at all; Discord signs with Ed25519, which
      has no digest, making `Plug.Crypto.secure_compare/2` inapplicable rather
      than merely different; and PagerDuty signs the body alone and sends no
      timestamp header, so a 300 s tolerance has nothing to enforce a window
      against. See design.md D7.

      What to build instead: a `ServiceRadar.Notifications.Callbacks.Signature`
      behaviour, one module per provider, over a shared primitives module.
      Genuinely reuse `RawBodyReader`, `Plug.Crypto.secure_compare/2` with its
      `byte_size` pre-check, the `abs()` skew comparison, the 300 s tolerance
      constant, and sha256-only persistence of any token WE mint. The
      `<timestamp>.<raw_body>` base string and the `sha256=` prefix are
      northbound-only and MUST NOT be copied, and
      `command_result_handler.ex:172-207`'s auth-mode enum must not be imported:
      it maps `nil | :token` to `:ok`, which in a tokenless context means "no
      signature header implies authorised". Leave
      `command_result_handler.ex` untouched. Still exactly one verification
      scheme per provider, and no ad-hoc scheme of our own invention.
- [ ] 4.3.4a PagerDuty is the one provider where the literal token half IS
      achievable, and it should be taken: we create the subscription via
      `POST /webhook_subscriptions`, whose HTTP delivery method accepts
      operator-supplied custom headers. Mint a callback token, persist only its
      sha256, have PagerDuty present it as `Authorization: Bearer <token>`, and
      compare with `Plug.Crypto.secure_compare/2`. The HMAC proves PagerDuty sent
      it; the token binds the request to this subscription. Verify
      `custom_headers` against the current API schema before committing to it.
- [x] 4.3.5 Confirm the notification callback route prefix registered with
      `ServiceRadarWebNGWeb.Api.RawBodyReader` in 1.6.4 actually covers the routes
      these three providers post to. `RawBodyReader` buffers raw bodies only for
      registered prefixes, and an unregistered prefix fails silently by verifying
      against a re-encoded body - which breaks exactly the providers that sign
      bytes. Extend the registered prefix list if a provider needs a route outside
      it, and cover it with the byte-identity test from 1.6.4a.
- [x] 4.3.6 Record `actor_kind: :external_principal` for identities that are not
      mapped platform users, and write a `NotificationAcknowledgement` row with
      `source: :callback` for every accepted native interaction, exactly as the
      action-link path does in 1.6.6.
- [x] 4.3.7 Halt escalation on a native acknowledgement on the same code path as
      an action-link acknowledgement. Interactive components are a second ingress
      to one acknowledgement mechanism, not a second acknowledgement mechanism.

### 4.4 Phase 4 tests, docs, and gates

- [x] 4.4.1 HMAC verification tests: valid signature, wrong secret, replayed
      timestamp beyond tolerance, and tampered body.
- [x] 4.4.2 Phoenix Channel authorization test asserting a user without
      `notifications.stream.subscribe` cannot join the firehose topic.
- [x] 4.4.2a Stream-suppression test: a suppressed dispatch to a `:stream` channel
      publishes nothing to subscribers and still writes a `:suppressed` delivery
      row that the Delivery Log renders with its reason.
- [x] 4.4.2b Stream action-link exemption test: no envelope published on the
      firehose contains an action link or capability token.
- [x] 4.4.2c Seeded `:stream` provider test: the row exists after install as a
      first-party `managed` provider, and an operator disable survives upgrade
      reconciliation.
- [x] 4.4.3 JetStream replay test asserting a reconnecting consumer resumes from
      its cursor.
- [ ] 4.4.4 Slack and Discord interaction payload tests using recorded fixtures.
- [x] 4.4.5 Document the firehose subscription surface and the envelope schema in
      `docs/docs/notifications.md`, including that it is gated on
      `notifications.stream.subscribe`, that suppressed dispatches publish nothing
      while still being recorded, and that stream envelopes deliberately carry no
      action link. ASCII only.
- [ ] 4.4.7 Wire the repo-scanning architecture guards into a tier that actually
      runs them. `single_wasm_host_test.exs` walks the whole repository to assert
      exactly one Wasm host exists, which cannot work under Bazel: `ex_unit_test`
      stages only declared inputs, so the walk sees a handful of files and the
      guard passes VACUOUSLY. It is tagged `:external` so it fails loudly nowhere
      rather than passing falsely in CI - but nothing runs `:external` today, so
      it currently runs only on demand. Either add a repo-scanning job (a lint
      tier, not a unit-test target) or declare the inputs deliberately; do not
      leave it tagged and forgotten.
- [ ] 4.4.6 BLOCKED ON A PRE-EXISTING FAILURE, not on this change. Both gates
      were run. `mix format --check-formatted` passes and `mix credo --strict`
      reports "found no issues" for both projects (2001 and 25596 mods/funs).
      Both then fail at `mix deps.audit` on third-party advisories: ash
      (EEF-CVE-2026-69659, EEF-CVE-2026-70395), phoenix_live_view
      (EEF-CVE-2026-64941), cowlib (EEF-CVE-2026-43966/43969) and gun
      (GHSA-w4f7-4cxr-rv3c). This branch changes none of those packages - its
      only dependency additions are gen_smtp and ranch for the SMTP transport -
      so the gate is red on staging for the same reason. Leave unchecked until
      the advisories are addressed or ignored deliberately; do not tick it by
      pointing at the passing half.
- [ ] 4.4.6a `./scripts/elixir_quality.sh --project elixir/serviceradar_core` and
      `./scripts/elixir_quality.sh --project elixir/web-ng --phoenix`.

## 5. Cross-cutting close-out

- [x] 5.1 Resolve design.md Open Question 1 (whether customer-network egress means
      the site agent specifically) and record the answer; if the control-plane
      route already satisfies it, drop the `:edge_agent` route out of Phase 3.
- [x] 5.2 Resolve Open Question 2 (whether core availability is the accepted
      failure domain for notifications) and record it in
      `docs/docs/architecture.md`.
- [x] 5.3 Resolve Open Question 3 (identity recorded when an external principal
      acknowledges) before Phase 4 native interactivity ships.
- [x] 5.4 Resolve Open Question 4 (delivery record storage: plain `platform` table
      with its own retention versus a Timescale hypertable) before Phase 1
      migration review is signed off.
- [x] 5.5 Sequencing checked; no design collision found. Status at close-out:
      `add-signed-northbound-action-callbacks` (16/16),
      `add-long-running-northbound-actions` (20/20) and
      `add-device-active-lifecycle` (7/7) are complete, and
      `add-northbound-action-integrations` has one task left - so the HMAC
      surface this change reuses is settled rather than moving under it.

      `add-automation-callback-grants` is the one that is materially incomplete
      (2 done / 22 open), and it was the obvious collision risk. It is not one:
      it owns `/api/v1/automation/callback-grants/*` with its own pipeline and
      grant model, and mentions neither `RawBodyReader`, nor
      `command_result_handler`, nor notifications anywhere in its proposal or
      tasks. The surfaces are disjoint.

      The one real interaction is mechanical rather than architectural: both add
      routes and pipelines to `router.ex`, so expect a merge conflict there and
      not a semantic one. This change also deliberately left
      `command_result_handler.ex` untouched (see 4.3.4), which keeps the
      northbound changes free to move without dragging notifications with them.
- [ ] 5.6 Update `CHANGELOG` for the release that carries each phase. DEFERRED
      TO RELEASE-CUT, deliberately: the CHANGELOG is written per released
      version, no release carries this yet, and AGENTS.md puts the release cut in
      the user's hands. Inventing a version heading here would either collide
      with the real next release or sit stale. The entry is drafted below so
      whoever cuts the release pastes it rather than reconstructing it:

      > - Notifications actually send. ServiceRadar had no working delivery at
      >   all - the webhook notifier was never supervised, so `send_alert/1`
      >   always returned `{:error, :not_running}`, `Alert.send_notification` was
      >   a TODO stub, and the `webhooks:` config block was read by nothing. This
      >   replaces that with a notification platform: routing with predicate
      >   matching and fan-out, escalation policies gated on acknowledgement,
      >   deduplication, schedules, silences, per-channel rate limiting, retry
      >   with failover, and an auditable delivery record for every attempt
      >   including the ones deliberately withheld.
      > - Providers are extensible without a release. Alongside first-party
      >   Slack, Discord, generic webhook and email, an operator can upload a
      >   declarative HTTP definition (a seeded catalog ships with PagerDuty,
      >   Opsgenie and others) or publish a signed Wasm plugin, including one
      >   that runs on an agent inside their own network so notifications egress
      >   locally.
      > - Two-way acknowledgement. Every notification carries signed
      >   single-use Acknowledge / Snooze / Resolve links that work in any
      >   destination, plus native Slack buttons and native PagerDuty
      >   acknowledge/resolve webhooks for deployments that want them. All three
      >   ingresses apply through one code path, so each halts escalation and
      >   writes the same audit row.
      > - A notification firehose. The built-in `stream` provider publishes a
      >   canonical envelope to a JetStream-backed subject and an RBAC-scoped
      >   channel, so a subscriber can consume notifications live and replay what
      >   it missed after a reconnect. Envelopes deliberately carry no action
      >   link or capability token, because a broadcast must not hand one
      >   delivery's single-use credential to every listener.
      > - Fixes two live PagerDuty defects: acknowledgement links rendered as
      >   inert text inside `custom_details` rather than as clickable links, and
      >   incidents never auto-resolved because a resolving alert sent a trigger
      >   on the same dedup key.
- [x] 5.7 Hold the canonical vocabulary across code, specs, and docs. These
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
- [x] 5.8 Final `openspec validate add-notification-platform --strict`.
- [ ] 5.9 Mark every task above `- [x]` only after the work is actually complete,
      then archive the change in a separate PR.
