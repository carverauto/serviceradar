defmodule ServiceRadar.Monitoring.Alert do
  @moduledoc """
  Alert resource with state machine lifecycle.

  Manages the lifecycle of monitoring alerts through states:
  - `pending` -> `acknowledged` -> `resolved`
  - `pending` -> `escalated` (via timeout)
  - `acknowledged` -> `resolved`
  - `acknowledged` -> `escalated`

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
    extensions: [AshStateMachine, AshOban, AshJsonApi.Resource]

  json_api do
    type "alert"

    routes do
      base "/alerts"

      get :by_id
      index :read
      index :active, route: "/active"
      index :pending, route: "/pending"
      post :trigger
      patch :acknowledge, route: "/:id/acknowledge"
      patch :resolve, route: "/:id/resolve"
    end
  end

  postgres do
    table "alerts"
    repo ServiceRadar.Repo
  end

  multitenancy do
    strategy :attribute
    attribute :tenant_id
    global? true
  end

  oban do
    triggers do
      # Scheduled trigger for auto-escalation of pending alerts
      trigger :auto_escalate do
        queue :alerts
        read_action :pending
        scheduler_cron "*/5 * * * *"
        action :escalate

        scheduler_module_name ServiceRadar.Monitoring.Alert.AutoEscalateScheduler
        worker_module_name ServiceRadar.Monitoring.Alert.AutoEscalateWorker

        # Only escalate alerts that have been pending for 30+ minutes
        where expr(
          status == :pending and
          triggered_at < ago(30, :minute) and
          severity in [:critical, :emergency]
        )
      end

      # Scheduled trigger for sending notifications on new/escalated alerts
      trigger :send_notifications do
        queue :notifications
        read_action :needs_notification
        scheduler_cron "* * * * *"
        action :send_notification

        scheduler_module_name ServiceRadar.Monitoring.Alert.SendNotificationsScheduler
        worker_module_name ServiceRadar.Monitoring.Alert.SendNotificationsWorker
      end
    end
  end

  state_machine do
    initial_states [:pending]
    default_initial_state :pending
    state_attribute :status
    deprecated_states []

    transitions do
      # Normal lifecycle
      transition :acknowledge, from: :pending, to: :acknowledged
      transition :resolve, from: [:pending, :acknowledged, :escalated], to: :resolved
      transition :escalate, from: [:pending, :acknowledged], to: :escalated
      transition :suppress, from: [:pending, :acknowledged, :escalated], to: :suppressed
      transition :reopen, from: [:resolved, :suppressed], to: :pending
    end
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
      constraints one_of: [:service_check, :device, :poller, :agent, :system, :external]
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

    # Multi-tenancy
    attribute :tenant_id, :uuid do
      allow_nil? false
      public? false
      description "Tenant this alert belongs to"
    end

    create_timestamp :created_at
    update_timestamp :updated_at
  end

  relationships do
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
      description "Alerts that need notification"
      # Find alerts that are active and either:
      # - Never notified (notification_count == 0)
      # - Not suppressed (suppressed_until is nil or in the past)
      filter expr(
        status in [:pending, :escalated] and
        notification_count == 0 and
        (is_nil(suppressed_until) or suppressed_until < now())
      )
      pagination keyset?: true, default_limit: 100
    end

    create :trigger do
      description "Trigger a new alert"
      accept [
        :title, :description, :severity, :source_type, :source_id,
        :service_check_id, :device_uid, :agent_uid, :metric_name,
        :metric_value, :threshold_value, :comparison, :metadata, :tags
      ]

      change set_attribute(:triggered_at, &DateTime.utc_now/0)
    end

    update :acknowledge do
      description "Acknowledge an alert"
      argument :acknowledged_by, :string, allow_nil?: false
      argument :note, :string

      change transition_state(:acknowledged)
      change set_attribute(:acknowledged_at, &DateTime.utc_now/0)
      change set_attribute(:acknowledged_by, arg(:acknowledged_by))
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
      argument :reason, :string
      require_atomic? false

      change transition_state(:escalated)
      change set_attribute(:escalated_at, &DateTime.utc_now/0)
      change set_attribute(:escalation_reason, arg(:reason))
      change fn changeset, _context ->
        current_level = Ash.Changeset.get_data(changeset, :escalation_level) || 0
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
      require_atomic? false

      change fn changeset, _context ->
        current_count = Ash.Changeset.get_data(changeset, :notification_count) || 0

        changeset
        |> Ash.Changeset.change_attribute(:notification_count, current_count + 1)
        |> Ash.Changeset.change_attribute(:last_notification_at, DateTime.utc_now())
      end
    end

    update :send_notification do
      description "Send notification for an alert (called by AshOban scheduler)"
      require_atomic? false

      change fn changeset, _context ->
        alert = Ash.Changeset.get_data(changeset)
        current_count = alert.notification_count || 0

        # Log the notification being sent
        require Logger
        Logger.info("Sending notification for alert: #{alert.title} (#{alert.id}) - severity: #{alert.severity}")

        # TODO: Implement actual notification dispatch (email, webhook, PubSub, etc.)
        # For now, just record that a notification was sent

        changeset
        |> Ash.Changeset.change_attribute(:notification_count, current_count + 1)
        |> Ash.Changeset.change_attribute(:last_notification_at, DateTime.utc_now())
      end
    end

    update :update_metadata do
      accept [:metadata, :tags]
    end
  end

  calculations do
    calculate :severity_color, :string, expr(
      cond do
        severity == :emergency -> "red"
        severity == :critical -> "red"
        severity == :warning -> "yellow"
        severity == :info -> "blue"
        true -> "gray"
      end
    )

    calculate :status_label, :string, expr(
      cond do
        status == :pending -> "Pending"
        status == :acknowledged -> "Acknowledged"
        status == :resolved -> "Resolved"
        status == :escalated -> "Escalated"
        status == :suppressed -> "Suppressed"
        true -> "Unknown"
      end
    )

    calculate :is_actionable, :boolean, expr(
      status in [:pending, :acknowledged, :escalated]
    )

    calculate :duration_seconds, :integer, expr(
      if not is_nil(resolved_at) do
        fragment("EXTRACT(EPOCH FROM ? - ?)", resolved_at, triggered_at)
      else
        fragment("EXTRACT(EPOCH FROM now() - ?)", triggered_at)
      end
    )

    calculate :needs_escalation, :boolean, expr(
      status == :pending and
      triggered_at < ago(30, :minute)
    )
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
    define :list_active, action: :active
    define :list_pending, action: :pending
    define :list_by_device, action: :by_device, args: [:device_uid]
  end

  policies do
    # Super admins bypass all policies
    bypass always() do
      authorize_if actor_attribute_equals(:role, :super_admin)
    end

    # All authenticated users can read alerts
    policy action_type(:read) do
      authorize_if actor_attribute_equals(:role, :viewer)
      authorize_if actor_attribute_equals(:role, :operator)
      authorize_if actor_attribute_equals(:role, :admin)
    end

    # Operators and admins can trigger alerts
    policy action(:trigger) do
      authorize_if actor_attribute_equals(:role, :operator)
      authorize_if actor_attribute_equals(:role, :admin)
    end

    # Operators and admins can acknowledge and resolve
    policy action([:acknowledge, :resolve, :record_notification, :update_metadata]) do
      authorize_if actor_attribute_equals(:role, :operator)
      authorize_if actor_attribute_equals(:role, :admin)
    end

    # Only admins can escalate, suppress, or reopen
    policy action([:escalate, :suppress, :reopen]) do
      authorize_if actor_attribute_equals(:role, :admin)
    end

    # Send notification action - can be run by operators, admins, or system (AshOban)
    policy action(:send_notification) do
      authorize_if actor_attribute_equals(:role, :operator)
      authorize_if actor_attribute_equals(:role, :admin)
      # Allow AshOban scheduler (no actor) to send notifications
      authorize_if always()
    end
  end
end
