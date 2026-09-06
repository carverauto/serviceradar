defmodule ServiceRadar.Notifications.NotificationChannel do
  @moduledoc """
  A configured instance of a notification provider - "Slack #noc".

  A `ServiceRadar.Notifications.NotificationProvider` is a *kind* of
  destination. A channel is one destination an operator configured, and it is
  the unit an escalation step fans out to: a step holds a SET of channels
  (design D4).

  Four fields carry design decisions rather than mere configuration:

    * `execution_route` (D3) is a field, not an architecture. `:control_plane`
      egresses from the platform and is the default and the documented
      recommendation; `:edge_agent` egresses from a named site agent over the
      bidirectional gRPC tunnel, which R1 makes the first-class answer for
      "notifications must leave from my network". An `:edge_agent` channel MUST
      name the agent it egresses from, mirroring the
      `notification_channels_edge_agent` check constraint.
    * `partition_id` follows the route and is force-bound server-side by
      `ServiceRadar.Notifications.Changes.BindChannelPartition` from the agent's
      authenticated mTLS control session. It is never operator-supplied and is
      therefore absent from every action's accept list.
    * `fallback_channel_id` (D4) is TRANSPORT failover: one hop, taken when
      retries are exhausted or the agent is offline. It is deliberately
      distinct from escalation, which is a HUMAN mechanism gated on
      acknowledgement; conflating the two is the most common design error in
      homegrown notification systems. `fail_closed` opts a channel out of
      failover entirely - the correct setting for a destination whose whole
      purpose is that it must not be silently substituted.
    * `max_attempts` (D4) is the retry bound, and it lives on the channel
      rather than the provider or the route because patience is a property of
      the destination an operator configured: a paging channel and a chat
      channel backed by the same provider deserve different bounds. It defaults
      from the provider's `default_max_attempts` so a channel is usable without
      tuning.

  `config` is validated against the provider's `config_schema` through
  `ServiceRadar.Plugins.ConfigSchema`, and `secret_refs` holds only
  `ServiceRadar.Plugins.SecretRefs` references plus their linked material. Raw
  secret values never reach either column, `secret_refs` is `sensitive?`, and
  the paper trail redacts it rather than versioning its contents.

  See `openspec/changes/add-notification-platform/design.md`.
  """

  use Ash.Resource,
    domain: ServiceRadar.Notifications,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshPaperTrail.Resource, AshJsonApi.Resource],
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Notifications.Changes.ApplyProviderContract
  alias ServiceRadar.Notifications.Changes.BindChannelPartition
  alias ServiceRadar.Notifications.Validations.ChannelFallbackChain
  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @view_check {ActorHasPermission, permission: "notifications.channels.view"}
  @manage_check {ActorHasPermission, permission: "notifications.channels.manage"}

  @fields [
    :name,
    :description,
    :provider_id,
    :enabled,
    :config,
    :secret_refs,
    :execution_route,
    :agent_uid,
    :partition_id,
    :fallback_channel_id,
    :fail_closed,
    :rate_limit_per_minute,
    :max_attempts,
    :health,
    :last_success_at,
    :last_failure_at,
    :last_error,
    :metadata
  ]

  # `partition_id` is absent by construction: it is mTLS-derived and bound
  # server-side. `health` and the `last_*` telemetry are written only by the
  # dispatcher through :record_success / :record_failure.
  @writable [
    :name,
    :description,
    :provider_id,
    :enabled,
    :config,
    :secret_refs,
    :execution_route,
    :agent_uid,
    :fallback_channel_id,
    :fail_closed,
    :rate_limit_per_minute,
    :max_attempts,
    :metadata
  ]

  postgres do
    table "notification_channels"
    repo ServiceRadar.Repo
    schema "platform"

    identity_index_names unique_name: "notification_channels_name_uidx"

    references do
      reference :provider, on_delete: :restrict
      reference :fallback_channel, on_delete: :nilify
    end
  end

  paper_trail do
    primary_key_type :uuid_v7
    table_name "notification_channel_versions"
    mixin {ServiceRadar.Credentials.PaperTrailMixin, :mixin, []}
    change_tracking_mode :changes_only
    store_action_name? true
    store_action_inputs? true
    create_version_on_destroy? false

    # A configuration audit must show that credentials changed without
    # carrying the material, so `secret_refs` is redacted rather than ignored.
    sensitive_attributes :redact

    # The health writers run once per delivery outcome. Versioning them would
    # bury the configuration changes this trail exists to record under
    # thousands of telemetry rows, so they are excluded outright rather than
    # producing empty-diff versions.
    ignore_actions [:record_success, :record_failure]

    ignore_attributes [
      :inserted_at,
      :updated_at,
      :health,
      :last_success_at,
      :last_failure_at,
      :last_error
    ]
  end

  json_api do
    type "notification_channel"

    hide_fields [:secret_refs]

    routes do
      base "/notification-channels"

      index :read
    end
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
    define :get_by_name, action: :by_name, args: [:name]
    define :list_enabled, action: :enabled
    define :list_by_provider, action: :by_provider, args: [:provider_id]
    define :list_for_agent, action: :for_agent, args: [:agent_uid]
    define :create_channel, action: :create
    define :update_channel, action: :update
    define :enable_channel, action: :enable
    define :disable_channel, action: :disable
    define :record_success, action: :record_success
    define :record_failure, action: :record_failure
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

    read :by_provider do
      argument :provider_id, :uuid, allow_nil?: false
      filter expr(provider_id == ^arg(:provider_id))
      prepare build(select: [:id, :inserted_at, :updated_at | @fields], sort: [name: :asc])
    end

    # Edge dispatch selects by the agent it egresses from. The route is part of
    # the filter so a control-plane channel can never be handed to an agent.
    read :for_agent do
      argument :agent_uid, :string, allow_nil?: false

      filter expr(execution_route == :edge_agent and agent_uid == ^arg(:agent_uid))
      prepare build(select: [:id, :inserted_at, :updated_at | @fields], sort: [name: :asc])
    end

    create :create do
      accept @writable

      validate present(:agent_uid) do
        where attribute_equals(:execution_route, :edge_agent)
        message "is required when execution_route is edge_agent"
      end

      validate ChannelFallbackChain

      change ApplyProviderContract
      change BindChannelPartition
    end

    # `provider_id` is deliberately not updatable: `config` and `secret_refs`
    # are shaped by the provider's schema, so swapping the provider underneath
    # them would leave a channel whose stored configuration validates against
    # nothing. Rebinding a destination is a new channel.
    update :update do
      accept List.delete(@writable, :provider_id)

      validate present(:agent_uid) do
        where attribute_equals(:execution_route, :edge_agent)
        message "is required when execution_route is edge_agent"
      end

      validate ChannelFallbackChain

      change ApplyProviderContract
      change BindChannelPartition
    end

    update :enable do
      accept []
      change set_attribute(:enabled, true)
    end

    update :disable do
      accept []
      change set_attribute(:enabled, false)
    end

    update :record_success do
      accept []
      change set_attribute(:health, :healthy)
      change set_attribute(:last_success_at, &DateTime.utc_now/0)
      change set_attribute(:last_error, nil)
    end

    update :record_failure do
      accept [:last_error]

      argument :health, :atom do
        allow_nil? false
        default :failing
        constraints one_of: [:degraded, :failing]
      end

      change set_attribute(:health, arg(:health))
      change set_attribute(:last_failure_at, &DateTime.utc_now/0)
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()

    action_with_permission(
      [:read, :by_id, :by_name, :enabled, :by_provider, :for_agent],
      @view_check
    )

    action_type_with_permission([:create, :update, :destroy], @manage_check)

    action_with_permission(
      [:enable, :disable, :record_success, :record_failure],
      @manage_check
    )
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :name, :string, allow_nil?: false, public?: true
    attribute :description, :string, allow_nil?: true, public?: true
    attribute :provider_id, :uuid, allow_nil?: false, public?: true

    attribute :enabled, :boolean do
      allow_nil? false
      public? true
      default true
    end

    attribute :config, :map do
      allow_nil? false
      public? true
      default %{}
      description "Provider configuration, validated against the provider config_schema"
    end

    attribute :secret_refs, :map do
      allow_nil? false
      public? true
      sensitive? true
      default %{}
      description "Plugins.SecretRefs references and their linked material; never raw secrets"
    end

    attribute :execution_route, :atom do
      allow_nil? false
      public? true
      default :control_plane
      constraints one_of: [:control_plane, :edge_agent]
    end

    attribute :agent_uid, :string do
      allow_nil? true
      public? true

      description "Site agent this channel egresses from; required when execution_route is edge_agent"
    end

    attribute :partition_id, :string do
      allow_nil? true
      public? true

      description "Immutable mTLS-derived partition bound server-side from the agent control session"
    end

    attribute :fallback_channel_id, :uuid do
      allow_nil? true
      public? true
      description "Transport failover target; one hop, never taken when fail_closed is set"
    end

    attribute :fail_closed, :boolean do
      allow_nil? false
      public? true
      default false
    end

    attribute :rate_limit_per_minute, :integer do
      allow_nil? true
      public? true
      constraints min: 1
      description "Shared, restart-surviving send budget for this destination"
    end

    attribute :max_attempts, :integer do
      allow_nil? false
      public? true
      default 3
      constraints min: 1
      description "Retry bound for deliveries on this channel; defaults from the provider"
    end

    attribute :health, :atom do
      allow_nil? false
      public? true
      default :unknown
      constraints one_of: [:unknown, :healthy, :degraded, :failing]
    end

    attribute :last_success_at, :utc_datetime_usec, allow_nil?: true, public?: true
    attribute :last_failure_at, :utc_datetime_usec, allow_nil?: true, public?: true
    attribute :last_error, :string, allow_nil?: true, public?: true

    attribute :metadata, :map do
      allow_nil? false
      public? true
      default %{}
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :provider, ServiceRadar.Notifications.NotificationProvider do
      attribute_writable? true
      public? true
      define_attribute? false
      source_attribute :provider_id
    end

    belongs_to :fallback_channel, __MODULE__ do
      attribute_writable? true
      public? true
      define_attribute? false
      source_attribute :fallback_channel_id
    end

    has_many :fallback_for, __MODULE__ do
      public? true
      destination_attribute :fallback_channel_id
    end

    has_many :escalation_step_channels,
             ServiceRadar.Notifications.NotificationEscalationStepChannel do
      destination_attribute :channel_id
    end

    has_many :deliveries, ServiceRadar.Notifications.NotificationDelivery do
      destination_attribute :channel_id
    end
  end

  identities do
    identity :unique_name, [:name]
  end
end
