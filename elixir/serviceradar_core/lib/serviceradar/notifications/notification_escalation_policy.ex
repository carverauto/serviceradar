defmodule ServiceRadar.Notifications.NotificationEscalationPolicy do
  @moduledoc """
  An ordered escalation container: the human side of design D4.

  Retry, failover, and escalation are three distinct mechanisms. Retry and
  failover are transport concerns owned by
  `ServiceRadar.Notifications.NotificationChannel`. Escalation is a HUMAN
  mechanism: a step fires only when its delay has elapsed AND the alert is
  still unacknowledged. A policy is the ordered container for those steps, and
  fan-out is orthogonal to all three because a single
  `ServiceRadar.Notifications.NotificationEscalationStep` holds a SET of
  channels.

  `repeat_count` bounds how many times the policy replays after its last step;
  `repeat_interval_seconds` is the gap between replays and is required whenever
  `repeat_count` is greater than zero, mirroring the
  `notification_escalation_policies_repeat` check constraint.

  ## Cadence precedence: the rule is the floor (D6)

  `StatefulAlertRule.renotify_seconds` already owns how noisy an incident is
  allowed to be. A policy may therefore only make repeats LESS frequent:
  `repeat_interval_seconds` MUST be greater than or equal to the rule's
  `renotify_seconds`. A policy configured below the floor is rejected at save
  time with an actionable message rather than silently clamped, because a
  silent clamp means the policy no longer means what its author read.

  A policy is not bound to one rule, so the governing rule is unknown at save
  time. `ServiceRadar.Notifications.Validations.RepeatIntervalFloor` therefore
  checks the strictest floor the deployment presents - the maximum
  `renotify_seconds` across all ENABLED stateful alert rules - and the
  dispatcher re-checks per alert against the rule that actually fired. The
  save-time check catches the configuration error while the operator is looking
  at it; the dispatch-time check is what holds when a rule is enabled or
  lowered afterwards.

  `resolve_notifies` decides whether resolution closes the loop on the same
  channels that were paged. It defaults to true, because a page that is never
  followed by an all-clear trains an on-call team to ignore the channel.

  See `openspec/changes/add-notification-platform/design.md`.
  """

  use Ash.Resource,
    domain: ServiceRadar.Notifications,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshPaperTrail.Resource, AshJsonApi.Resource],
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Notifications.Validations.RepeatIntervalFloor
  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @view_check {ActorHasPermission, permission: "notifications.routes.view"}
  @manage_check {ActorHasPermission, permission: "notifications.routes.manage"}

  @fields [
    :name,
    :description,
    :enabled,
    :repeat_count,
    :repeat_interval_seconds,
    :resolve_notifies
  ]

  postgres do
    table "notification_escalation_policies"
    repo ServiceRadar.Repo
    schema "platform"

    identity_index_names unique_name: "notification_escalation_policies_name_uidx"
  end

  paper_trail do
    primary_key_type :uuid_v7
    table_name "notification_escalation_policy_versions"
    mixin {ServiceRadar.Credentials.PaperTrailMixin, :mixin, []}
    change_tracking_mode :changes_only
    store_action_name? true
    store_action_inputs? true
    create_version_on_destroy? false
    ignore_attributes [:inserted_at, :updated_at]
  end

  json_api do
    type "notification_escalation_policy"

    routes do
      base "/notification-escalation-policies"

      index :read
      post :create
    end
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
    define :get_by_name, action: :by_name, args: [:name]
    define :list_enabled, action: :enabled
    define :create_policy, action: :create
    define :update_policy, action: :update
    define :enable_policy, action: :enable
    define :disable_policy, action: :disable
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
      prepare build(select: [:id, :inserted_at, :updated_at | @fields])
    end

    read :by_name do
      argument :name, :string, allow_nil?: false
      get? true
      filter expr(name == ^arg(:name))
      prepare build(select: [:id, :inserted_at, :updated_at | @fields])
    end

    read :enabled do
      filter expr(enabled == true)
      prepare build(select: [:id, :inserted_at, :updated_at | @fields], sort: [name: :asc])
    end

    create :create do
      accept @fields

      validate compare(:repeat_count, greater_than_or_equal_to: 0)
      validate compare(:repeat_interval_seconds, greater_than: 0)

      validate present(:repeat_interval_seconds) do
        where compare(:repeat_count, greater_than: 0)
        message "is required when repeat_count is greater than zero"
      end

      validate RepeatIntervalFloor
    end

    update :update do
      accept @fields

      validate compare(:repeat_count, greater_than_or_equal_to: 0)
      validate compare(:repeat_interval_seconds, greater_than: 0)

      validate present(:repeat_interval_seconds) do
        where compare(:repeat_count, greater_than: 0)
        message "is required when repeat_count is greater than zero"
      end

      validate RepeatIntervalFloor
    end

    update :enable do
      accept []
      change set_attribute(:enabled, true)
    end

    update :disable do
      accept []
      change set_attribute(:enabled, false)
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    action_with_permission([:read, :by_id, :by_name, :enabled], @view_check)
    action_type_with_permission([:create, :update, :destroy], @manage_check)
    action_with_permission([:enable, :disable], @manage_check)
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :name, :string, allow_nil?: false, public?: true
    attribute :description, :string, allow_nil?: true, public?: true

    attribute :enabled, :boolean do
      allow_nil? false
      public? true
      default true
    end

    attribute :repeat_count, :integer do
      allow_nil? false
      public? true
      default 0
      constraints min: 0
      description "How many times the policy replays after its last step; 0 disables repeats"
    end

    attribute :repeat_interval_seconds, :integer do
      allow_nil? true
      public? true
      constraints min: 1
      description "Gap between repeats; required when repeat_count > 0, floored by the rule"
    end

    attribute :resolve_notifies, :boolean do
      allow_nil? false
      public? true
      default true
      description "Whether resolution closes the loop on the channels that were paged"
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    has_many :steps, ServiceRadar.Notifications.NotificationEscalationStep do
      public? true
      destination_attribute :policy_id
      sort step_number: :asc
    end

    has_many :routes, ServiceRadar.Notifications.NotificationRoute do
      destination_attribute :escalation_policy_id
    end

    has_many :deliveries, ServiceRadar.Notifications.NotificationDelivery do
      destination_attribute :policy_id
    end
  end

  identities do
    identity :unique_name, [:name]
  end
end
