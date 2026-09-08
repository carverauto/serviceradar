defmodule ServiceRadar.Notifications.NotificationDelivery do
  @moduledoc """
  The notification system of record - one row per (alert x escalation step x channel).

  This resource is deliberately **not** paper-trailed. There is no
  `notification_deliveries_versions` table because the row *is* the audit
  surface: every dispatch, retry, failover hop, and withheld decision is its own
  record, and a version table would only duplicate the state machine's own
  history.

  ## The delivery row is authoritative (design D3)

  `execution_route`, `agent_uid`, and `command_id` record *how* a delivery was
  dispatched. When the route is `:edge_agent` (or `:control_plane` against the
  platform-resident agent), the agent command result is a **wake-up signal only** -
  it is never the record. `ServiceRadar.Edge.AgentCommandBus` is at-most-once with
  no store-and-forward, and `ServiceRadar.AgentCommands.StatusHandler` is gated on
  `:status_handler_enabled` which defaults to `false`, so a design that treated the
  command result as the truth would leave stock deployments with no record at all.
  The terminal state on THIS row is the truth; a bounded periodic scan
  (`:retry_due`) recovers whatever the signal missed.

  ## `:failed` is terminal; retries stay `:pending` (design D4, C7)

  This is load bearing and is the single easiest invariant to break.

  A retry-eligible delivery stays in `:pending` with `next_attempt_at` set and
  `attempt_count` incremented (`:record_retry_scheduled`). It does **not** pass
  through `:failed` and come back. Only a non-retryable error, or exhaustion of
  `max_attempts`, moves a row to `:failed`, and `:failed` has no outbound
  transition.

  Consequently `read :retry_due` selects `:pending` rows with a due
  `next_attempt_at` and `attempt_count < max_attempts`. It MUST NOT select
  `:failed` rows - a scan that picks up `:failed` retries forever and defeats the
  attempt bound entirely.

  Failover is a different mechanism from retry: it is the one hop taken after a
  row reaches `:failed` (or immediately on `{:error, {:agent_offline, _}}`) when
  the channel is not `fail_closed`. The successor delivery carries
  `originating_delivery_id` pointing back at the row that failed (design D4/G6),
  so the Delivery Log shows one failover chain rather than two unrelated attempts.

  ## Suppression is recorded, never silently dropped (design D5, C8)

  A notification that is not sent leaves a row with `state: :suppressed` and a
  `suppression_reason`. Silent drops are prohibited - an operator must always be
  able to answer "why was I not paged?", and `:no_matching_route` is the reason
  that makes the *unrouted* alert visible at all.

  Recording every decision must not turn a long-lived silence into unbounded
  table growth, so an identical repeat of
  `{alert_id, policy_id, step_number, channel_id, dedupe_key, suppression_reason}`
  collapses onto the existing row - `occurrence_count` is incremented and
  `last_evaluated_at` refreshed - rather than inserting a duplicate. See
  `create :record_suppression` for why that is an upsert against a partial,
  NULLS-NOT-DISTINCT identity and not a read-then-write.

  The three nullable foreign-key values in that identity are copied into
  immutable `suppression_*_id` columns when the decision is inserted. Parent
  deletion nilifies the relationship columns but not those identity snapshots,
  so retaining two distinct audit rows can never create a uniqueness collision.

  `suppression_reason` is present if and only if `state == :suppressed`, mirroring
  the `notification_deliveries_suppression_reason` database check.

  `:dependency` is **reserved** for the future topology-driven parent/child
  suppression feature (design "Future Directions"). Nothing emits it today.

  ## `alert_snapshot` is required because deliveries outlive alerts

  `ServiceRadar.Jobs.AlertsRetentionWorker` **hard deletes** resolved and
  suppressed alerts after a default of 3 days. The `alert_id` foreign key is
  therefore `on_delete: :nilify_all` and never `:delete_all`, and every delivery
  denormalises the alert into `alert_snapshot` at creation. A delivery whose
  snapshot is empty is unreadable the moment its alert is pruned, so an empty
  snapshot is rejected at create time rather than discovered three days later.

  ## Test deliveries never count (design G9)

  `is_test` marks deliveries produced by the test-send action. A test delivery
  MUST NOT count toward any alert's delivery or notification counts; alert-facing
  counts read through `:countable` / `:countable_for_alert`, which exclude test
  rows. Un-flagged test sends corrupt exactly the counters operators use to judge
  notification volume. Test rows are still shown in the Delivery Log, visually
  distinguished.

  `payload_format` (design G7) records the format actually rendered after
  negotiation against the channel's provider, and `provider_version` (design G8)
  records which provider definition version rendered the row - declarative and
  uploaded definitions change under operators' hands.
  """

  use Ash.Resource,
    domain: ServiceRadar.Notifications,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshStateMachine]

  alias ServiceRadar.Notifications.Validations.NonEmptyAlertSnapshot
  alias ServiceRadar.Policies.Checks.ActorHasPermission
  alias ServiceRadar.Policies.Checks.ActorIsNil

  @view_check {ActorHasPermission, permission: "notifications.deliveries.view"}
  @manage_check {ActorHasPermission, permission: "notifications.channels.manage"}
  @test_send_check {ActorHasPermission, permission: "notifications.test.send"}

  @read_actions [
    :read,
    :by_id,
    :for_alert,
    :for_channel,
    :for_originating_delivery,
    :countable,
    :countable_for_alert,
    :suppressed,
    :retry_due
  ]

  # Every write below the test-send action is driven by the notification
  # pipeline: `AlertLifecycle` originates, the AshOban delivery scheduler
  # continues, the transport dispatcher records results.
  @pipeline_writes [
    :record_dispatch,
    :record_suppression,
    :record_group_member,
    :record_dispatching,
    :record_retry_scheduled,
    :record_sent,
    :record_failed,
    :record_expired,
    :record_cancelled,
    :record_suppressed,
    :record_skipped
  ]

  @dispatch_fields [
    :alert_id,
    :alert_snapshot,
    :route_id,
    :policy_id,
    :step_number,
    :channel_id,
    :originating_delivery_id,
    :dedupe_key,
    :external_correlation_id,
    :max_attempts,
    :next_attempt_at,
    :payload_format,
    :provider_version,
    :rendered_payload_digest,
    :execution_route,
    :agent_uid,
    :command_id,
    :queued_at,
    :lifecycle_reason
  ]

  @suppression_fields [
    :alert_id,
    :alert_snapshot,
    :route_id,
    :policy_id,
    :step_number,
    :channel_id,
    :dedupe_key,
    :suppression_reason,
    :result_summary,
    :execution_route
  ]

  postgres do
    table "notification_deliveries"
    repo ServiceRadar.Repo
    schema "platform"

    # The suppression identity is backed by a hand-written partial index created
    # with a raw `execute` in the migration, so both the index name and its
    # predicate SQL have to be declared here.
    identity_index_names suppression_decision: "notification_deliveries_suppression_uidx"
    identity_wheres_to_sql suppression_decision: "state = 'suppressed'"

    references do
      reference :alert, on_delete: :nilify
      reference :route, on_delete: :nilify
      reference :policy, on_delete: :nilify
      reference :channel, on_delete: :nilify
      reference :originating_delivery, on_delete: :nilify
    end
  end

  state_machine do
    # A suppression decision is born suppressed - it is a record of a dispatch
    # that never happened, not a dispatch that failed.
    initial_states [:pending, :suppressed]
    default_initial_state :pending
    state_attribute :state

    transitions do
      transition :record_dispatching, from: [:pending], to: :dispatching

      # C7: retry keeps the delivery in :pending. This transition exists so a
      # dispatch attempt that failed retryably can be handed back to the
      # scheduler WITHOUT passing through :failed, which is terminal.
      transition :record_retry_scheduled, from: [:pending, :dispatching], to: :pending

      transition :record_sent, from: [:pending, :dispatching], to: :sent

      # Terminal. Reached only on a non-retryable error or on exhausting
      # max_attempts. Nothing transitions out of :failed - failover creates a
      # NEW delivery carrying originating_delivery_id.
      transition :record_failed, from: [:pending, :dispatching], to: :failed

      transition :record_expired, from: [:pending, :dispatching], to: :expired
      transition :record_cancelled, from: [:pending, :dispatching], to: :cancelled
      transition :record_suppressed, from: [:pending, :dispatching], to: :suppressed
      transition :record_skipped, from: [:pending, :dispatching], to: :skipped
    end
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
    define :list_for_alert, action: :for_alert, args: [:alert_id]
    define :list_for_channel, action: :for_channel, args: [:channel_id]

    define :list_failovers_of,
      action: :for_originating_delivery,
      args: [:originating_delivery_id]

    define :list_countable_for_alert, action: :countable_for_alert, args: [:alert_id]
    define :list_suppressed, action: :suppressed
    define :list_retry_due, action: :retry_due
    define :record_dispatch, action: :record_dispatch
    define :record_test_dispatch, action: :record_test_dispatch
    define :record_suppression, action: :record_suppression
    define :record_group_member, action: :record_group_member
    define :record_dispatching, action: :record_dispatching
    define :record_retry_scheduled, action: :record_retry_scheduled
    define :record_sent, action: :record_sent
    define :record_failed, action: :record_failed
    define :record_expired, action: :record_expired
    define :record_cancelled, action: :record_cancelled
    define :record_suppressed, action: :record_suppressed
    define :record_skipped, action: :record_skipped
  end

  actions do
    defaults [:destroy]

    read :read do
      primary? true
    end

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end

    read :for_alert do
      description "Delivery Log for one alert, test rows included."
      argument :alert_id, :uuid, allow_nil?: false

      filter expr(alert_id == ^arg(:alert_id))
      prepare build(sort: [inserted_at: :desc])
    end

    read :for_channel do
      argument :channel_id, :uuid, allow_nil?: false

      filter expr(channel_id == ^arg(:channel_id))
      prepare build(sort: [inserted_at: :desc])
    end

    read :for_originating_delivery do
      description "The failover chain hanging off one delivery (design D4/G6)."
      argument :originating_delivery_id, :uuid, allow_nil?: false

      filter expr(originating_delivery_id == ^arg(:originating_delivery_id))
      prepare build(sort: [inserted_at: :asc])
    end

    read :countable do
      description """
      Deliveries that count toward operator-facing volume. Excludes test sends
      (design G9) - un-flagged test rows corrupt exactly the counters operators
      use to judge notification volume.
      """

      filter expr(is_test == false)
    end

    read :countable_for_alert do
      description """
      The default read for any alert-facing delivery or notification count. A
      test delivery MUST NOT count toward an alert's totals (design G9).
      """

      argument :alert_id, :uuid, allow_nil?: false

      filter expr(alert_id == ^arg(:alert_id) and is_test == false)
      prepare build(sort: [inserted_at: :desc])
    end

    read :suppressed do
      description "Withheld notifications with their reason (design D5, D10)."

      filter expr(state == :suppressed)
      prepare build(sort: [last_evaluated_at: :desc])
    end

    read :retry_due do
      description """
      Retry-due scan (C7). Selects ONLY `:pending` rows whose `next_attempt_at`
      has elapsed and whose attempt budget is not exhausted.

      This action MUST NOT select `:failed` rows. `:failed` is terminal; a scan
      that picks it up retries forever and defeats `max_attempts`.
      """

      argument :now, :utc_datetime_usec do
        allow_nil? false
        default &DateTime.utc_now/0
      end

      filter expr(
               state == :pending and not is_nil(next_attempt_at) and
                 next_attempt_at <= ^arg(:now) and attempt_count < max_attempts
             )

      prepare build(sort: [next_attempt_at: :asc])
    end

    create :record_dispatch do
      description "Originating create for a real (non-test) delivery attempt."
      primary? true
      accept @dispatch_fields

      validate NonEmptyAlertSnapshot
    end

    create :record_test_dispatch do
      description """
      Operator-initiated test send. Carries a synthetic `alert_snapshot` and is
      flagged `is_test` so it never reaches an alert's counters (design G9).
      """

      accept @dispatch_fields

      change set_attribute(:is_test, true)

      validate NonEmptyAlertSnapshot
    end

    create :record_suppression do
      description """
      Record a withheld notification (design D5, C8).

      A repeat of an IDENTICAL decision - same
      `{alert_id, policy_id, step_number, channel_id, dedupe_key, suppression_reason}` -
      collapses onto the existing row: `occurrence_count` is incremented and
      `last_evaluated_at` refreshed, rather than a duplicate being inserted.

      This is an UPSERT and not a read-then-write on purpose. The backing index
      `notification_deliveries_suppression_uidx` is PARTIAL
      (`WHERE state = 'suppressed'`) and NULLS NOT DISTINCT - a
      `:no_matching_route` decision has NULL `policy_id`/`step_number`/`channel_id`,
      and under default NULLS DISTINCT semantics two identical unrouted decisions
      would both INSERT, silently defeating collapsing for exactly the case the
      reason exists to make visible. Postgres enforces that index regardless of
      what Ash knows, so a read-then-create loses the race and raises a unique
      violation whenever two dispatchers evaluate the same withheld decision
      concurrently. The `:suppression_decision` identity therefore carries
      `where expr(state == :suppressed)` plus `nils_distinct? false`, and the
      `postgres` block maps it onto the hand-written index name and its predicate
      SQL.

      `occurrence_count` is incremented with `atomic_update/2`, which the data
      layer renders into the conflict clause, so the counter cannot be lost when
      two evaluations collapse at once.
      """

      accept @suppression_fields

      upsert? true
      upsert_identity :suppression_decision

      # Deliberately excludes :occurrence_count (the atomic below owns it) and
      # :state (the row is already suppressed - that is what the partial index
      # matched on).
      upsert_fields [
        :alert_snapshot,
        :route_id,
        :result_summary,
        :last_evaluated_at,
        :updated_at
      ]

      change set_attribute(:state, :suppressed)
      change set_attribute(:last_evaluated_at, &DateTime.utc_now/0)
      change fn changeset, _context -> copy_suppression_identity(changeset) end
      change atomic_update(:occurrence_count, expr(occurrence_count + 1))

      # Mirrors notification_deliveries_suppression_reason: a suppressed row
      # always names its reason.
      validate present(:suppression_reason)
      validate NonEmptyAlertSnapshot
    end

    update :record_group_member do
      description "Merge another alert into a grouped delivery that has not dispatched yet."
      accept [:alert_id, :alert_snapshot, :next_attempt_at]

      validate attribute_equals(:state, :pending),
        message: "must still be pending to accept a group member"

      validate NonEmptyAlertSnapshot
    end

    update :record_dispatching do
      accept [:execution_route, :agent_uid, :command_id, :external_correlation_id]

      change set_attribute(:started_at, &DateTime.utc_now/0)
      change transition_state(:dispatching)
    end

    update :record_retry_scheduled do
      description """
      C7: hand a retryable failure back to the scheduler WITHOUT leaving
      `:pending`. `attempt_count` is incremented atomically so concurrent
      dispatchers cannot both consume the same attempt slot, and
      `next_attempt_at` carries the backoff.
      """

      accept [:next_attempt_at, :error_class, :error_message, :result_summary]

      change atomic_update(:attempt_count, expr(attempt_count + 1))
      change transition_state(:pending)

      validate present(:next_attempt_at)
    end

    update :record_sent do
      accept [
        :external_correlation_id,
        :result_summary,
        :rendered_payload_digest,
        :payload_format,
        :provider_version
      ]

      change atomic_update(:attempt_count, expr(attempt_count + 1))
      change set_attribute(:next_attempt_at, nil)
      change set_attribute(:finished_at, &DateTime.utc_now/0)
      change transition_state(:sent)
    end

    update :record_failed do
      description """
      TERMINAL (C7). Use this only for a non-retryable error or on exhausting
      `max_attempts`; a retryable failure uses `:record_retry_scheduled` instead.
      Failover from here creates a NEW delivery carrying
      `originating_delivery_id`, it does not reopen this row.
      """

      accept [:error_class, :error_message, :result_summary, :external_correlation_id]

      change atomic_update(:attempt_count, expr(attempt_count + 1))
      change set_attribute(:next_attempt_at, nil)
      change set_attribute(:finished_at, &DateTime.utc_now/0)
      change transition_state(:failed)
    end

    update :record_expired do
      accept [:error_class, :error_message, :result_summary]

      change set_attribute(:next_attempt_at, nil)
      change set_attribute(:finished_at, &DateTime.utc_now/0)
      change transition_state(:expired)
    end

    update :record_cancelled do
      accept [:error_class, :error_message, :result_summary]

      change set_attribute(:next_attempt_at, nil)
      change set_attribute(:finished_at, &DateTime.utc_now/0)
      change transition_state(:cancelled)
    end

    update :record_suppressed do
      description """
      Re-evaluation at dispatch withheld an already-queued delivery (design D5,
      property 1). The decision is recorded on the existing row rather than
      dropped.
      """

      accept [:suppression_reason, :result_summary]

      change set_attribute(:next_attempt_at, nil)
      change set_attribute(:last_evaluated_at, &DateTime.utc_now/0)
      change set_attribute(:finished_at, &DateTime.utc_now/0)
      change transition_state(:suppressed)

      # Mirrors notification_deliveries_suppression_reason.
      validate present(:suppression_reason)
    end

    update :record_skipped do
      accept [:error_class, :error_message, :result_summary]

      change set_attribute(:next_attempt_at, nil)
      change set_attribute(:finished_at, &DateTime.utc_now/0)
      change transition_state(:skipped)
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()

    action_with_permission(@read_actions, @view_check)

    # Writes are driven by the notification pipeline, which runs either as a
    # system actor (bypassed above) or - for the AshOban delivery scheduler -
    # with no actor at all, mirroring alert.ex:366-371.
    policy action(@pipeline_writes) do
      authorize_if ActorIsNil
      authorize_if @manage_check
    end

    policy action(:record_test_dispatch) do
      authorize_if @test_send_check
      authorize_if @manage_check
    end

    # Retention pruning runs as a system actor and is bypassed above. An audit
    # row is deliberately NOT destroyable by an unauthenticated caller.
    policy action_type(:destroy) do
      authorize_if @manage_check
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :alert_id, :uuid do
      allow_nil? true
      public? true

      description """
      Nullable by design. The FK is nilify_all, never delete_all, because
      AlertsRetentionWorker hard deletes alerts after 3 days; read
      `alert_snapshot` once this is nil.
      """
    end

    attribute :alert_snapshot, :map do
      allow_nil? false
      public? true
      default %{}

      description "Alert denormalised at creation so the delivery outlives the alert."
    end

    attribute :route_id, :uuid, allow_nil?: true, public?: true
    attribute :policy_id, :uuid, allow_nil?: true, public?: true
    attribute :step_number, :integer, allow_nil?: true, public?: true
    attribute :channel_id, :uuid, allow_nil?: true, public?: true

    # Immutable identity snapshots for suppressed rows. The relationship FKs
    # above are intentionally nilified when their parents are retained for less
    # time than the delivery audit log; using them directly in a NULLS NOT
    # DISTINCT index makes that nilification collide.
    attribute :suppression_alert_id, :uuid, allow_nil?: true
    attribute :suppression_policy_id, :uuid, allow_nil?: true
    attribute :suppression_channel_id, :uuid, allow_nil?: true

    attribute :originating_delivery_id, :uuid do
      allow_nil? true
      public? true
      description "Failover back-reference to the delivery this one succeeded (design D4/G6)."
    end

    attribute :dedupe_key, :string, allow_nil?: true, public?: true

    attribute :state, :atom do
      allow_nil? false
      public? true
      default :pending

      constraints one_of: [
                    :pending,
                    :dispatching,
                    :sent,
                    :failed,
                    :expired,
                    :cancelled,
                    :suppressed,
                    :skipped
                  ]

      description "State machine state. `:failed` is terminal; retries stay `:pending` (C7)."
    end

    attribute :suppression_reason, :atom do
      allow_nil? true
      public? true

      constraints one_of: [
                    :device_out_of_service,
                    :silence,
                    :schedule,
                    :snoozed,
                    :throttled,
                    :acknowledged,
                    :channel_disabled,
                    # RESERVED: topology-driven parent/child suppression is a
                    # follow-on (design "Future Directions"). Nothing emits this
                    # reason today; it is in the contract so the enum does not
                    # have to change when the feature lands.
                    :dependency,
                    :no_matching_route
                  ]

      description "Present if and only if state == :suppressed."
    end

    attribute :occurrence_count, :integer do
      allow_nil? false
      public? true
      default 1
      constraints min: 1
      description "Repeat count for a collapsed identical suppression decision (C8)."
    end

    attribute :last_evaluated_at, :utc_datetime_usec, allow_nil?: true, public?: true

    attribute :attempt_count, :integer do
      allow_nil? false
      public? true
      default 0
      constraints min: 0
    end

    attribute :max_attempts, :integer do
      allow_nil? false
      public? true
      default 3
      constraints min: 1
      description "Resolved from the channel at creation."
    end

    attribute :next_attempt_at, :utc_datetime_usec do
      allow_nil? true
      public? true
      description "Set while a retry is pending; nil on every terminal state."
    end

    attribute :external_correlation_id, :string do
      allow_nil? true
      public? true
      description "Provider-side handle, such as a Slack ts or a PagerDuty dedup_key."
    end

    attribute :error_class, :string, allow_nil?: true, public?: true
    attribute :error_message, :string, allow_nil?: true, public?: true

    attribute :result_summary, :map do
      allow_nil? false
      public? true
      default %{}
      description "Redacted transport result. Passes ActionRedaction before persistence."
    end

    attribute :rendered_payload_digest, :string, allow_nil?: true, public?: true

    attribute :payload_format, :atom do
      allow_nil? true
      public? true

      constraints one_of: [
                    :slack_blocks,
                    :discord_embed,
                    :markdown,
                    :plain,
                    :html,
                    :pagerduty_v2,
                    :json
                  ]

      description "The format actually rendered after provider negotiation (design G7)."
    end

    attribute :provider_version, :integer do
      allow_nil? true
      public? true
      description "Provider definition version that rendered this row (design G8)."
    end

    attribute :is_test, :boolean do
      allow_nil? false
      public? true
      default false

      description """
      Test sends never count toward an alert's delivery or notification counts
      (design G9). Read through :countable / :countable_for_alert.
      """
    end

    attribute :execution_route, :atom do
      allow_nil? false
      public? true
      default :control_plane
      constraints one_of: [:control_plane, :edge_agent]
    end

    attribute :lifecycle_reason, :atom do
      description """
      Why the lifecycle emitted this delivery: `:fire`, `:renotify`, `:escalate`,
      `:resolve`. Recorded because it is not knowable at render time otherwise,
      and an incident API needs it - a resolving alert must tell PagerDuty to
      resolve rather than trigger on the same dedup_key (task 4.3.3b).

      Nullable: rows written before this existed have no honest value, and a null
      renders as `trigger`, which is what they already did.
      """

      allow_nil? true
      public? true
      constraints one_of: [:fire, :renotify, :escalate, :resolve]
    end

    attribute :agent_uid, :string, allow_nil?: true, public?: true

    attribute :command_id, :uuid do
      allow_nil? true
      public? true

      description """
      AgentCommandBus command this dispatch rode on. A wake-up signal only - this
      row, not the command result, is the system of record (design D3).
      """
    end

    attribute :queued_at, :utc_datetime_usec, allow_nil?: true, public?: true
    attribute :started_at, :utc_datetime_usec, allow_nil?: true, public?: true
    attribute :finished_at, :utc_datetime_usec, allow_nil?: true, public?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :alert, ServiceRadar.Monitoring.Alert do
      attribute_writable? true
      public? true
      define_attribute? false
      source_attribute :alert_id
    end

    belongs_to :route, ServiceRadar.Notifications.NotificationRoute do
      attribute_writable? true
      public? true
      define_attribute? false
      source_attribute :route_id
    end

    belongs_to :policy, ServiceRadar.Notifications.NotificationEscalationPolicy do
      attribute_writable? true
      public? true
      define_attribute? false
      source_attribute :policy_id
    end

    belongs_to :channel, ServiceRadar.Notifications.NotificationChannel do
      attribute_writable? true
      public? true
      define_attribute? false
      source_attribute :channel_id
    end

    belongs_to :originating_delivery, __MODULE__ do
      attribute_writable? true
      public? true
      define_attribute? false
      source_attribute :originating_delivery_id
    end

    has_many :failover_deliveries, __MODULE__ do
      destination_attribute :originating_delivery_id
    end

    has_many :acknowledgements, ServiceRadar.Notifications.NotificationAcknowledgement do
      destination_attribute :delivery_id
    end

    has_many :members, ServiceRadar.Notifications.NotificationDeliveryMember do
      destination_attribute :delivery_id
    end
  end

  identities do
    # Backs the C8 suppression collapse. The keys are the D5 decision identity.
    #
    # `nils_distinct? false` reproduces the index's NULLS NOT DISTINCT: a
    # :no_matching_route decision has NULL policy_id/step_number/channel_id and
    # two such decisions must collide rather than both insert.
    #
    # `where` reproduces the index's partial predicate: only suppressed rows are
    # unique on this tuple, because the same alert/step/channel legitimately has
    # many non-suppressed delivery attempts.
    #
    # There is deliberately no identity for {alert_id, policy_id, step_number,
    # channel_id} on dispatched rows - retries and failover hops are separate
    # records by design.
    identity :suppression_decision,
             [
               :suppression_alert_id,
               :suppression_policy_id,
               :step_number,
               :suppression_channel_id,
               :dedupe_key,
               :suppression_reason
             ] do
      where expr(state == :suppressed)
      nils_distinct? false
      message "an identical suppression decision is already recorded"
    end
  end

  defp copy_suppression_identity(changeset) do
    changeset
    |> Ash.Changeset.change_attribute(
      :suppression_alert_id,
      Ash.Changeset.get_attribute(changeset, :alert_id)
    )
    |> Ash.Changeset.change_attribute(
      :suppression_policy_id,
      Ash.Changeset.get_attribute(changeset, :policy_id)
    )
    |> Ash.Changeset.change_attribute(
      :suppression_channel_id,
      Ash.Changeset.get_attribute(changeset, :channel_id)
    )
  end
end
