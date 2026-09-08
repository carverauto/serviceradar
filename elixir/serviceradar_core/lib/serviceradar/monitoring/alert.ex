defmodule ServiceRadar.Monitoring.Alert do
  @moduledoc """
  Alert resource with state machine lifecycle.

  Manages the lifecycle of monitoring alerts through states:
  - `pending` -> `acknowledged` -> `resolved`
  - `pending` -> `escalated` (via timeout)
  - `acknowledged` -> `resolved`
  - `acknowledged` -> `escalated`
  - `escalated` -> `acknowledged`

  ## Alert Severities

  - `:info` - Informational alert
  - `:warning` - Warning condition
  - `:critical` - Critical issue requiring attention
  - `:emergency` - Emergency condition

  ## Alert States

  - `pending` - Alert raised, awaiting acknowledgement
  - `acknowledged` - Alert acknowledged by operator
  - `resolved` - Alert condition cleared
  - `escalated` - Alert escalated due to timeout or manual action
  - `suppressed` - Alert suppressed (maintenance window, etc.)
  """

  use Ash.Resource,
    domain: ServiceRadar.Monitoring,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    notifiers: [ServiceRadar.Monitoring.AlertNotifier],
    extensions: [AshStateMachine, AshOban, AshJsonApi.Resource]

  alias ServiceRadar.Events.InternalLogPublisher
  alias ServiceRadar.Inventory.DeviceLifecycle
  alias ServiceRadar.Monitoring.Alert.AutoEscalateScheduler
  alias ServiceRadar.Monitoring.Alert.AutoEscalateWorker
  alias ServiceRadar.Monitoring.Alert.SendNotificationsScheduler
  alias ServiceRadar.Monitoring.Alert.SendNotificationsWorker
  alias ServiceRadar.Monitoring.Changes.EnqueueRoutingRequest
  alias ServiceRadar.Monitoring.Changes.RecordNotificationSent
  alias ServiceRadar.Oban.AshObanQueueResolver
  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @alert_trigger_fields [
    :title,
    :description,
    :severity,
    :source_type,
    :source_id,
    :event_id,
    :event_time,
    :service_check_id,
    :device_uid,
    :agent_uid,
    :metric_name,
    :metric_value,
    :threshold_value,
    :comparison,
    :metadata,
    :tags
  ]
  @alert_metadata_fields [:metadata, :tags]
  @alert_operator_actions [
    :trigger,
    :publish_k8s_node_not_ready,
    :publish_k8s_node_ready,
    :record_notification,
    :update_metadata
  ]

  # The operator-facing lifecycle actions, gated below on the role OR on the
  # existing RBAC key `observability.alerts.manage`, catalogued verbatim as
  # "Acknowledge and resolve alerts".
  #
  # Two reasons this is its own list. `:snooze` and `:unsnooze` previously
  # appeared in NO policy at all, and Ash forbids a request that no policy
  # applies to, so snooze was reachable only by a system actor - the emailed
  # action-link path - and no operator interface could ever have used it.
  # `:helpdesk` holds `observability.alerts.manage` by default but is not
  # `is_operator()`, so acknowledgement authority granted in the RBAC catalog
  # has to be honoured here or the catalog entry is a lie.
  @alert_acknowledgement_actions [:acknowledge, :snooze, :unsnooze, :resolve]
  @alert_admin_actions [:escalate, :suppress, :reopen]

  postgres do
    table "alerts"
    repo ServiceRadar.Repo
    schema "platform"
  end

  json_api do
    type "alert"

    routes do
      base "/alerts"

      get :by_id
      index :read
      index :active, route: "/active"
      index :pending, route: "/pending"
      post :trigger
      route :post, "/k8s-node-not-ready-test", :publish_k8s_node_not_ready
      route :post, "/k8s-node-ready-test", :publish_k8s_node_ready
      patch :acknowledge, route: "/:id/acknowledge"
      patch :resolve, route: "/:id/resolve"
    end
  end

  state_machine do
    initial_states [:pending]
    default_initial_state :pending
    state_attribute :status
    deprecated_states []

    transitions do
      # Normal lifecycle
      #
      # `:escalated` is an acknowledgeable source state, and it is the important
      # one. `auto_escalate` moves a critical alert out of `:pending` after 30
      # minutes, and `Notifications.Suppression.acknowledged?/1` keys strictly on
      # `status == :acknowledged` (`notifications/suppression.ex:306`). With
      # `from: :pending` alone, the alerts that escalated - exactly the ones a
      # human most needs to take ownership of - were the ones no acknowledgement
      # could reach, so an `:if_unacknowledged` ladder could never be halted by
      # answering it. `resolve` and `suppress` already accept `:escalated`.
      transition :acknowledge, from: [:pending, :escalated], to: :acknowledged
      transition :resolve, from: [:pending, :acknowledged, :escalated], to: :resolved
      transition :escalate, from: [:pending, :acknowledged], to: :escalated
      transition :suppress, from: [:pending, :acknowledged, :escalated], to: :suppressed
      transition :reopen, from: [:resolved, :suppressed], to: :pending
    end
  end

  oban do
    triggers do
      # Scheduled trigger for auto-escalation of pending alerts
      trigger :auto_escalate do
        queue :alerts
        extra_args &AshObanQueueResolver.job_meta/1
        read_action :pending
        scheduler_cron "*/5 * * * *"
        action :escalate

        scheduler_module_name AutoEscalateScheduler
        worker_module_name AutoEscalateWorker

        # Only escalate alerts that have been pending for 30+ minutes
        where expr(
                status == :pending and
                  triggered_at < ago(30, :minute) and
                  severity in [:critical, :emergency]
              )
      end

      # First-notification safety net for new/escalated alerts.
      #
      # `read :needs_notification` is `notification_count == 0` and skips a
      # suppressed or snoozed alert, so this scan can only ever originate a
      # FIRST notification - never a renotify, an escalation rung, or a retry.
      # Those are keyed on NotificationDelivery rows rather than on alerts and
      # are driven by the delivery-keyed workers that now share this queue
      # (`:notifications`, concurrency 5, `config.exs:36`, which also carries
      # the routing, dispatch, continuation, silence-expiry, and
      # delivery-retention workers under `ServiceRadar.Notifications`).
      trigger :send_notifications do
        queue :notifications
        extra_args &AshObanQueueResolver.job_meta/1
        read_action :needs_notification
        scheduler_cron "* * * * *"
        action :send_notification

        scheduler_module_name SendNotificationsScheduler
        worker_module_name SendNotificationsWorker
      end
    end
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
    define :list_active, action: :active
    define :list_pending, action: :pending
    define :list_by_device, action: :by_device, args: [:device_uid]
  end

  actions do
    defaults [:read]

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end

    read :by_status do
      argument :status, :atom, allow_nil?: false
      filter expr(status == ^arg(:status))
    end

    read :active do
      description "All active (non-resolved) alerts"
      filter expr(status in [:pending, :acknowledged, :escalated])
    end

    read :pending do
      description "Alerts awaiting acknowledgement"
      filter expr(status == :pending)
      pagination keyset?: true, default_limit: 100
    end

    read :by_severity do
      argument :severity, :atom, allow_nil?: false
      filter expr(severity == ^arg(:severity))
    end

    read :by_device do
      argument :device_uid, :string, allow_nil?: false
      filter expr(device_uid == ^arg(:device_uid))
    end

    read :recent do
      description "Alerts from last 24 hours"
      filter expr(created_at > ago(24, :hour))
    end

    read :needs_notification do
      description "Alerts awaiting their FIRST notification"

      # Deliberately first-notify only (`notification_count == 0`).
      #
      # Continuation work - retry-due, escalation-step-due, and renotify - is
      # keyed on NotificationDelivery rows, not on alerts, so it cannot be
      # driven from an alert-keyed scan. A separate delivery-keyed scheduler on
      # the same `:notifications` queue owns that; the two are not redundant
      # because they select over different tables.
      #
      # An alert is skipped here while suppressed or snoozed. Both are
      # timestamp comparisons, so an expiring snooze becomes eligible again on
      # the next scheduler tick with no state transition required.
      filter expr(
               status in [:pending, :escalated] and
                 notification_count == 0 and
                 (is_nil(suppressed_until) or suppressed_until < now()) and
                 (is_nil(snooze_until) or snooze_until < now())
             )

      pagination keyset?: true, default_limit: 100
    end

    read :snooze_expired do
      description "Alerts whose snooze has lapsed and that are still actionable"

      filter expr(
               status in [:pending, :escalated] and
                 not is_nil(snooze_until) and
                 snooze_until < now()
             )

      pagination keyset?: true, default_limit: 100
    end

    create :trigger do
      description "Trigger a new alert"

      accept @alert_trigger_fields

      change fn changeset, _context ->
        Ash.Changeset.before_action(changeset, fn changeset ->
          attrs = %{
            device_uid: changeset_input(changeset, :device_uid),
            metadata: changeset_input(changeset, :metadata)
          }

          if DeviceLifecycle.suppress_operational_event?(attrs) do
            Ash.Changeset.add_error(changeset,
              field: :device_uid,
              message: "device is marked out of service"
            )
          else
            changeset
          end
        end)
      end

      change set_attribute(:triggered_at, &DateTime.utc_now/0)
    end

    action :publish_k8s_node_not_ready, :map do
      description "Emit a node.not_ready internal log so StatefulAlertEngine groups by cluster+node"

      argument :cluster_id, :string, allow_nil?: false, public?: true
      argument :node, :string, allow_nil?: false, public?: true
      argument :role, :string, allow_nil?: true, public?: true

      run fn input, _context ->
        publish_k8s_node_readiness(input, "node.not_ready")
      end
    end

    action :publish_k8s_node_ready, :map do
      description "Emit a node.ready internal log that clears an open k8s_node_not_ready incident"

      argument :cluster_id, :string, allow_nil?: false, public?: true
      argument :node, :string, allow_nil?: false, public?: true
      argument :role, :string, allow_nil?: true, public?: true

      run fn input, _context ->
        publish_k8s_node_readiness(input, "node.ready")
      end
    end

    update :reassign_device do
      description "Reassign alert to a new device (used during merges)"
      accept [:device_uid]
    end

    update :acknowledge do
      description "Acknowledge an alert"
      argument :acknowledged_by, :string, allow_nil?: false
      argument :note, :string

      # Set when the acknowledging principal maps to a platform user. Left nil
      # for an external principal (a chat or paging identity), which is why the
      # free-text `acknowledged_by` is retained alongside it.
      accept [:acknowledged_by_user_id]

      change transition_state(:acknowledged)
      change set_attribute(:acknowledged_at, &DateTime.utc_now/0)
      change set_attribute(:acknowledged_by, arg(:acknowledged_by))

      # Acknowledging ends any active snooze: a human has taken ownership, so
      # the deferral no longer applies.
      change set_attribute(:snooze_until, nil)
    end

    update :snooze do
      description "Defer notification dispatch for this alert until a future time"

      argument :snooze_until, :utc_datetime_usec, allow_nil?: false
      argument :note, :string

      # Snooze is NOT a state-machine transition. It leaves `status` untouched
      # and records a timestamp; "snoozed" is derived as
      # `status in [:pending, :escalated] and snooze_until > now()`.
      validate compare(:snooze_until, greater_than: &DateTime.utc_now/0) do
        message "must be in the future"
      end

      change set_attribute(:snooze_until, arg(:snooze_until))
    end

    update :unsnooze do
      description "Clear an active snooze so dispatch resumes immediately"

      change set_attribute(:snooze_until, nil)
    end

    update :resolve do
      description "Resolve an alert"
      argument :resolved_by, :string
      argument :resolution_note, :string

      change transition_state(:resolved)
      change set_attribute(:resolved_at, &DateTime.utc_now/0)
      change set_attribute(:resolved_by, arg(:resolved_by))
      change set_attribute(:resolution_note, arg(:resolution_note))
    end

    update :escalate do
      description "Escalate an alert"
      # Non-atomic: increments escalation_level based on current value
      require_atomic? false
      argument :reason, :string

      change transition_state(:escalated)
      change set_attribute(:escalated_at, &DateTime.utc_now/0)
      change set_attribute(:escalation_reason, arg(:reason))

      change fn changeset, _context ->
        current_level = changeset.data.escalation_level || 0
        Ash.Changeset.change_attribute(changeset, :escalation_level, current_level + 1)
      end
    end

    update :suppress do
      description "Suppress alert notifications"
      argument :until, :utc_datetime

      change transition_state(:suppressed)
      change set_attribute(:suppressed_until, arg(:until))
    end

    update :reopen do
      description "Reopen a resolved or suppressed alert"
      argument :reason, :string

      change transition_state(:pending)
      change set_attribute(:resolved_at, nil)
      change set_attribute(:resolved_by, nil)
      change set_attribute(:suppressed_until, nil)
    end

    update :record_notification do
      description "Record that a notification was sent"

      # Bookkeeping only. The caller already emitted its own routing request -
      # `AlertLifecycle.send_renotify/4` is the one in tree - so enqueueing a
      # second one here would page twice for one decision.
      change RecordNotificationSent
    end

    update :send_notification do
      description "Route notifications for an alert (called by AshOban scheduler)"

      # Enqueue, never deliver. This action runs on the `:notifications` queue
      # from the `:send_notifications` trigger above, and the work it starts -
      # matching, dedup, escalation, suppression, rendering, the transport call,
      # and the retry rule - belongs to the notification platform. Sending from
      # here would put a network call inside the alert's transaction.
      #
      # `:fire` is the lifecycle reason for a first notification, and this action
      # is reachable only through `read :needs_notification`, which is
      # `notification_count == 0`. `AlertLifecycle` emits the same `:fire`
      # request when the incident is created; the two converge on one
      # `Dedupe.routing_request_key/1` and `Dispatcher.route/3` resolves the
      # second to the work the first created rather than a second page. Using a
      # different reason in either place is what would break that.
      change RecordNotificationSent
      change {EnqueueRoutingRequest, lifecycle_reason: :fire}
    end

    update :update_metadata do
      accept @alert_metadata_fields
    end

    destroy :discard_internal_probe do
      require_atomic? false

      change fn changeset, _context ->
        metadata = changeset.data.metadata || %{}

        if metadata["synthetic_liveness_check"] == true do
          changeset
        else
          Ash.Changeset.add_error(changeset,
            field: :metadata,
            message: "only synthetic liveness alerts can use this action"
          )
        end
      end
    end
  end

  defp changeset_input(changeset, field) do
    Ash.Changeset.get_argument_or_attribute(changeset, field) ||
      Map.get(changeset.params || %{}, field) ||
      Map.get(changeset.params || %{}, Atom.to_string(field))
  end

  defp publish_k8s_node_readiness(input, event_type) do
    role =
      case Ash.ActionInput.get_argument(input, :role) do
        "control-plane" -> "control-plane"
        _ -> "worker"
      end

    node = Ash.ActionInput.get_argument(input, :node)
    cluster_id = Ash.ActionInput.get_argument(input, :cluster_id)

    payload = %{
      "event_type" => event_type,
      "severity" => k8s_node_readiness_severity(event_type),
      "message" => k8s_node_readiness_message(event_type, role, node),
      "attributes" => %{
        "event_type" => event_type,
        "cluster_id" => cluster_id,
        "node" => node,
        "node.role" => role,
        "hostname" => node
      }
    }

    case InternalLogPublisher.publish("k8s", payload) do
      :ok ->
        {:ok,
         %{
           published: true,
           event_type: event_type,
           cluster_id: cluster_id,
           node: node,
           role: role
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp k8s_node_readiness_severity("node.not_ready"), do: "critical"
  defp k8s_node_readiness_severity("node.ready"), do: "info"

  defp k8s_node_readiness_message("node.not_ready", role, node) do
    "Kubernetes #{role} node #{node} is NotReady"
  end

  defp k8s_node_readiness_message("node.ready", role, node) do
    "Kubernetes #{role} node #{node} is Ready"
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    read_viewer_plus()
    operator_action(@alert_operator_actions)
    admin_action(@alert_admin_actions)

    policy action(@alert_acknowledgement_actions) do
      authorize_if is_operator()
      authorize_if {ActorHasPermission, permission: "observability.alerts.manage"}
    end

    # Send notification: Operators/admins, or AshOban (no actor)
    policy action(:send_notification) do
      authorize_if is_operator()

      # Allow AshOban scheduler (no actor) to send notifications
      authorize_if ServiceRadar.Policies.Checks.ActorIsNil
    end
  end

  changes do
  end

  attributes do
    uuid_primary_key :id

    attribute :title, :string do
      allow_nil? false
      public? true
      description "Alert title/summary"
    end

    attribute :description, :string do
      public? true
      description "Detailed alert description"
    end

    attribute :severity, :atom do
      allow_nil? false
      default :warning
      public? true
      constraints one_of: [:info, :warning, :critical, :emergency]
      description "Alert severity level"
    end

    attribute :status, :atom do
      allow_nil? false
      default :pending
      public? true
      constraints one_of: [:pending, :acknowledged, :resolved, :escalated, :suppressed]
      description "Current alert state (state machine managed)"
    end

    attribute :source_type, :atom do
      public? true
      constraints one_of: [:service_check, :device, :gateway, :agent, :event, :system, :external]
      description "Type of source that generated this alert"
    end

    attribute :source_id, :string do
      public? true
      description "ID of the source entity"
    end

    # Related entity IDs
    attribute :service_check_id, :uuid do
      public? true
      description "Related service check"
    end

    attribute :device_uid, :string do
      public? true
      description "Related device"
    end

    attribute :agent_uid, :string do
      public? true
      description "Related agent"
    end

    attribute :event_id, :uuid do
      public? true
      description "Related OCSF event ID"
    end

    attribute :event_time, :utc_datetime_usec do
      public? true
      description "Related OCSF event timestamp"
    end

    # Alert details
    attribute :metric_name, :string do
      public? true
      description "Name of the metric that triggered the alert"
    end

    attribute :metric_value, :float do
      public? true
      description "Value of the metric at alert time"
    end

    attribute :threshold_value, :float do
      public? true
      description "Threshold that was exceeded"
    end

    attribute :comparison, :atom do
      public? true
      constraints one_of: [:greater_than, :less_than, :equals, :not_equals]
      description "How value compared to threshold"
    end

    # State tracking timestamps
    attribute :triggered_at, :utc_datetime do
      public? true
      description "When the alert was triggered"
    end

    attribute :acknowledged_at, :utc_datetime do
      public? true
      description "When alert was acknowledged"
    end

    attribute :acknowledged_by, :string do
      public? true
      description "User who acknowledged"
    end

    attribute :resolved_at, :utc_datetime do
      public? true
      description "When alert was resolved"
    end

    attribute :resolved_by, :string do
      public? true
      description "User or system that resolved"
    end

    attribute :resolution_note, :string do
      public? true
      description "Note about resolution"
    end

    attribute :escalated_at, :utc_datetime do
      public? true
      description "When alert was escalated"
    end

    attribute :escalation_level, :integer do
      default 0
      public? true
      description "Current escalation level"
    end

    attribute :escalation_reason, :string do
      public? true
      description "Reason for escalation"
    end

    # Notification tracking
    attribute :notification_count, :integer do
      default 0
      public? true
      description "Number of notifications sent"
    end

    attribute :last_notification_at, :utc_datetime do
      public? true
      description "When last notification was sent"
    end

    attribute :suppressed_until, :utc_datetime do
      public? true
      description "Suppress notifications until this time"
    end

    attribute :snooze_until, :utc_datetime_usec do
      public? true

      description """
      Suppress notification dispatch for this alert until this time.

      Deliberately NOT a state-machine state: `state_attribute` is `:status`
      and no declared state could be a `:snooze` target. "Snoozed" is a derived
      condition - `status in [:pending, :escalated] and snooze_until > now()` -
      which keeps snooze-expiry resumption a pure timestamp comparison and
      avoids auditing every existing `status` filter for a new value.
      """
    end

    attribute :acknowledged_by_user_id, :uuid do
      public? true

      description """
      Platform user who acknowledged, when one can be identified.

      The free-text `acknowledged_by` is retained alongside this for external
      principals (a chat or paging identity with no platform user).
      """
    end

    attribute :metadata, :map do
      default %{}
      public? true
      description "Additional metadata"
    end

    attribute :tags, {:array, :string} do
      default []
      public? true
      description "Alert tags for filtering"
    end

    create_timestamp :created_at
    update_timestamp :updated_at
  end

  relationships do
    has_many :notification_deliveries,
             ServiceRadar.Notifications.NotificationDelivery do
      destination_attribute :alert_id
    end

    belongs_to :acknowledged_by_user, ServiceRadar.Identity.User do
      source_attribute :acknowledged_by_user_id
      destination_attribute :id
      define_attribute? false
      attribute_writable? true
      allow_nil? true
      public? true
    end

    belongs_to :service_check, ServiceRadar.Monitoring.ServiceCheck do
      source_attribute :service_check_id
      destination_attribute :id
      allow_nil? true
      public? true
    end

    belongs_to :device, ServiceRadar.Inventory.Device do
      source_attribute :device_uid
      destination_attribute :uid
      allow_nil? true
      public? true
    end

    belongs_to :agent, ServiceRadar.Infrastructure.Agent do
      source_attribute :agent_uid
      destination_attribute :uid
      allow_nil? true
      public? true
    end
  end

  calculations do
    calculate :severity_color,
              :string,
              expr(
                cond do
                  severity == :emergency -> "red"
                  severity == :critical -> "red"
                  severity == :warning -> "yellow"
                  severity == :info -> "blue"
                  true -> "gray"
                end
              )

    calculate :status_label,
              :string,
              expr(
                cond do
                  status == :pending -> "Pending"
                  status == :acknowledged -> "Acknowledged"
                  status == :resolved -> "Resolved"
                  status == :escalated -> "Escalated"
                  status == :suppressed -> "Suppressed"
                  true -> "Unknown"
                end
              )

    calculate :is_actionable, :boolean, expr(status in [:pending, :acknowledged, :escalated])

    calculate :duration_seconds,
              :integer,
              expr(
                if is_nil(resolved_at) do
                  fragment("EXTRACT(EPOCH FROM now() - ?)", triggered_at)
                else
                  fragment("EXTRACT(EPOCH FROM ? - ?)", resolved_at, triggered_at)
                end
              )

    calculate :needs_escalation,
              :boolean,
              expr(
                status == :pending and
                  triggered_at < ago(30, :minute)
              )
  end
end
