defmodule ServiceRadar.Infrastructure.Gateway do
  @moduledoc """
  Gateway resource for managing agent gateway nodes.

  Gateways are job orchestrators - they do NOT perform checks directly.
  They receive scheduled jobs (via AshOban), find available agents via
  Horde registry, and dispatch work to agents via RPC.

  ## Role

  Gateways have a single, well-defined role in the monitoring architecture:
  1. **Receive** - Accept scheduled monitoring jobs from AshOban scheduler
  2. **Select** - Find available agents via Horde.Registry lookup
  3. **Dispatch** - Execute RPC calls to agents to perform actual checks

  Agents have capabilities (ICMP, TCP, process checks, gRPC to external checkers).
  Gateways do not have capabilities - they only orchestrate work.

  ## Status Values

  - `active` - Gateway is healthy and receiving jobs
  - `degraded` - Gateway has issues but is still operating
  - `inactive` - Gateway is offline or unresponsive
  - `draining` - Gateway is shutting down gracefully
  """

  @role_description "Gateways orchestrate monitoring jobs but do not perform checks directly. They receive scheduled jobs and dispatch work to available agents."

  @role_steps [
    %{key: "receive", label: "JOB", description: "Receive scheduled jobs"},
    %{key: "select", label: "SELECT", description: "Find available agents"},
    %{key: "dispatch", label: "DISPATCH", description: "RPC work to agents"}
  ]

  @doc "Returns the role description for gateways"
  def role_description, do: @role_description

  @doc "Returns the role steps that gateways perform"
  def role_steps, do: @role_steps

  use Ash.Resource,
    domain: ServiceRadar.Infrastructure,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshStateMachine, AshJsonApi.Resource]

  postgres do
    table "pollers"
    repo ServiceRadar.Repo
  end

  json_api do
    type "gateway"

    routes do
      base "/gateways"

      # Read operations
      get :by_id
      index :read
      index :active, route: "/active"

      # Registration
      post :register

      # State machine transitions
      patch :activate, route: "/:id/activate"
      patch :degrade, route: "/:id/degrade"
      patch :go_offline, route: "/:id/offline"
      patch :recover, route: "/:id/recover"
      patch :restore_health, route: "/:id/restore"
      patch :start_maintenance, route: "/:id/maintenance/start"
      patch :end_maintenance, route: "/:id/maintenance/end"
      patch :start_draining, route: "/:id/drain/start"
      patch :finish_draining, route: "/:id/drain/finish"
      patch :deactivate, route: "/:id/deactivate"
      patch :heartbeat, route: "/:id/heartbeat"
    end
  end

  multitenancy do
    strategy :attribute
    attribute :tenant_id
    global? true
  end

  state_machine do
    initial_states [:healthy, :inactive]
    default_initial_state :inactive
    state_attribute :status
    deprecated_states []

    transitions do
      # Activation transitions
      transition :activate, from: :inactive, to: :healthy

      # Health degradation
      transition :degrade, from: :healthy, to: :degraded
      transition :heartbeat_timeout, from: [:healthy, :degraded], to: :degraded

      # Going offline
      transition :go_offline, from: [:healthy, :degraded, :draining], to: :offline
      transition :lose_connection, from: [:healthy, :degraded], to: :offline

      # Recovery
      transition :recover, from: [:degraded, :offline, :recovering], to: :recovering
      transition :restore_health, from: [:degraded, :recovering], to: :healthy

      # Maintenance mode
      transition :start_maintenance, from: [:healthy, :degraded], to: :maintenance
      transition :end_maintenance, from: :maintenance, to: :healthy

      # Graceful shutdown
      transition :start_draining, from: [:healthy, :degraded], to: :draining
      transition :finish_draining, from: :draining, to: :offline

      # Deactivation
      transition :deactivate, from: [:healthy, :degraded, :offline, :recovering, :maintenance, :draining], to: :inactive
    end
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
    define :list_active, action: :active
    define :list_by_partition, action: :by_partition, args: [:partition_slug]
    define :list_by_partition_id, action: :by_partition_id, args: [:partition_id]
  end

  actions do
    defaults [:read]

    read :by_id do
      argument :id, :string, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end

    read :active do
      description "All active gateways"
      filter expr(status == :healthy and is_healthy == true)
    end

    read :by_status do
      argument :status, :atom,
        allow_nil?: false,
        constraints: [one_of: [:inactive, :healthy, :degraded, :offline, :recovering, :maintenance, :draining]]

      filter expr(status == ^arg(:status))
    end

    read :recently_seen do
      description "Gateways seen in the last 5 minutes"
      filter expr(last_seen > ago(5, :minute))
    end

    read :by_partition do
      description "Find active gateways in a specific partition"
      argument :partition_slug, :string, allow_nil?: false

      filter expr(
               status == :healthy and
                 is_healthy == true and
                 partition.slug == ^arg(:partition_slug)
             )

      prepare build(load: [:partition])
    end

    read :by_partition_id do
      description "Find active gateways by partition UUID"
      argument :partition_id, :uuid, allow_nil?: false

      filter expr(
               status == :healthy and
                 is_healthy == true and
                 partition_id == ^arg(:partition_id)
             )
    end

    create :register do
      description "Register a new gateway (starts in healthy state)"

      accept [
        :id,
        :component_id,
        :registration_source,
        :spiffe_identity,
        :metadata,
        :created_by,
        :partition_id
      ]

      change fn changeset, context ->
        now = DateTime.utc_now()
        actor = context.actor
        tenant_id = if is_map(actor), do: Map.get(actor, :tenant_id)

        if is_nil(tenant_id) do
          changeset
          |> Ash.Changeset.add_error(field: :tenant_id, message: "tenant_id is required")
        else
          partition_id = Ash.Changeset.get_attribute(changeset, :partition_id)

          changeset
          |> Ash.Changeset.change_attribute(:tenant_id, tenant_id)
          |> Ash.Changeset.change_attribute(:partition_id, partition_id)
          |> Ash.Changeset.change_attribute(:first_registered, now)
          |> Ash.Changeset.change_attribute(:first_seen, now)
          |> Ash.Changeset.change_attribute(:last_seen, now)
          |> Ash.Changeset.change_attribute(:status, :healthy)
          |> Ash.Changeset.change_attribute(:is_healthy, true)
        end
      end
    end

    update :update do
      accept [:metadata, :agent_count, :checker_count]
      change set_attribute(:updated_at, &DateTime.utc_now/0)
    end

    update :heartbeat do
      description "Update last_seen and health status"
      accept [:is_healthy, :agent_count, :checker_count]

      change set_attribute(:last_seen, &DateTime.utc_now/0)
      change set_attribute(:updated_at, &DateTime.utc_now/0)
    end

    # State machine transition actions
    # Each action includes PublishStateChange to emit NATS events

    update :activate do
      description "Activate an inactive gateway"
      require_atomic? false

      change transition_state(:healthy)
      change set_attribute(:is_healthy, true)
      change set_attribute(:last_seen, &DateTime.utc_now/0)
      change set_attribute(:updated_at, &DateTime.utc_now/0)
      change {ServiceRadar.Infrastructure.Changes.PublishStateChange, entity_type: :gateway, new_state: :healthy}
    end

    update :degrade do
      description "Mark gateway as degraded (having issues)"
      argument :reason, :string
      require_atomic? false

      change transition_state(:degraded)
      change set_attribute(:is_healthy, false)
      change set_attribute(:updated_at, &DateTime.utc_now/0)
      change {ServiceRadar.Infrastructure.Changes.PublishStateChange, entity_type: :gateway, new_state: :degraded}
    end

    update :heartbeat_timeout do
      description "Mark gateway as degraded due to heartbeat timeout"
      require_atomic? false

      change transition_state(:degraded)
      change set_attribute(:is_healthy, false)
      change set_attribute(:updated_at, &DateTime.utc_now/0)
      change {ServiceRadar.Infrastructure.Changes.PublishStateChange, entity_type: :gateway, new_state: :degraded}
    end

    update :go_offline do
      description "Mark gateway as offline"
      argument :reason, :string
      require_atomic? false

      change transition_state(:offline)
      change set_attribute(:is_healthy, false)
      change set_attribute(:updated_at, &DateTime.utc_now/0)
      change {ServiceRadar.Infrastructure.Changes.PublishStateChange, entity_type: :gateway, new_state: :offline}
    end

    update :lose_connection do
      description "Mark gateway as offline due to lost connection"
      require_atomic? false

      change transition_state(:offline)
      change set_attribute(:is_healthy, false)
      change set_attribute(:updated_at, &DateTime.utc_now/0)
      change {ServiceRadar.Infrastructure.Changes.PublishStateChange, entity_type: :gateway, new_state: :offline}
    end

    update :recover do
      description "Start recovery process for degraded/offline gateway"
      require_atomic? false

      change transition_state(:recovering)
      change set_attribute(:updated_at, &DateTime.utc_now/0)
      change {ServiceRadar.Infrastructure.Changes.PublishStateChange, entity_type: :gateway, new_state: :recovering}
    end

    update :restore_health do
      description "Restore gateway to healthy state"
      require_atomic? false

      change transition_state(:healthy)
      change set_attribute(:is_healthy, true)
      change set_attribute(:last_seen, &DateTime.utc_now/0)
      change set_attribute(:updated_at, &DateTime.utc_now/0)
      change {ServiceRadar.Infrastructure.Changes.PublishStateChange, entity_type: :gateway, new_state: :healthy}
    end

    update :start_maintenance do
      description "Put gateway into maintenance mode"
      require_atomic? false

      change transition_state(:maintenance)
      change set_attribute(:updated_at, &DateTime.utc_now/0)
      change {ServiceRadar.Infrastructure.Changes.PublishStateChange, entity_type: :gateway, new_state: :maintenance}
    end

    update :end_maintenance do
      description "End maintenance mode, return to healthy"
      require_atomic? false

      change transition_state(:healthy)
      change set_attribute(:is_healthy, true)
      change set_attribute(:updated_at, &DateTime.utc_now/0)
      change {ServiceRadar.Infrastructure.Changes.PublishStateChange, entity_type: :gateway, new_state: :healthy}
    end

    update :start_draining do
      description "Start graceful shutdown (draining)"
      require_atomic? false

      change transition_state(:draining)
      change set_attribute(:updated_at, &DateTime.utc_now/0)
      change {ServiceRadar.Infrastructure.Changes.PublishStateChange, entity_type: :gateway, new_state: :draining}
    end

    update :finish_draining do
      description "Finish draining, go offline"
      require_atomic? false

      change transition_state(:offline)
      change set_attribute(:is_healthy, false)
      change set_attribute(:updated_at, &DateTime.utc_now/0)
      change {ServiceRadar.Infrastructure.Changes.PublishStateChange, entity_type: :gateway, new_state: :offline}
    end

    update :deactivate do
      description "Deactivate a gateway (admin action)"
      require_atomic? false

      change transition_state(:inactive)
      change set_attribute(:is_healthy, false)
      change set_attribute(:updated_at, &DateTime.utc_now/0)
      change {ServiceRadar.Infrastructure.Changes.PublishStateChange, entity_type: :gateway, new_state: :inactive}
    end

    # Legacy compatibility aliases
    update :mark_unhealthy do
      description "Mark gateway as unhealthy (legacy - use degrade)"
      require_atomic? false

      change transition_state(:degraded)
      change set_attribute(:is_healthy, false)
      change set_attribute(:updated_at, &DateTime.utc_now/0)
      change {ServiceRadar.Infrastructure.Changes.PublishStateChange, entity_type: :gateway, new_state: :degraded}
    end
  end

  policies do
    # Super admins can see all gateways across tenants
    bypass always() do
      authorize_if actor_attribute_equals(:role, :super_admin)
    end

    # Tenant isolation: users can only see gateways in their tenant
    policy action_type(:read) do
      authorize_if expr(tenant_id == ^actor(:tenant_id))
    end

    # Registration: tenant_id is injected by the action change, so authorize via actor context.
    policy action(:register) do
      authorize_if expr(not is_nil(^actor(:tenant_id)))
    end

    # Allow updates for gateways in user's tenant
    policy action_type(:update) do
      authorize_if expr(tenant_id == ^actor(:tenant_id))
    end
  end

  attributes do
    attribute :id, :string do
      source :poller_id
      allow_nil? false
      primary_key? true
      public? true
      description "Unique gateway identifier"
    end

    attribute :component_id, :string do
      public? true
      description "Component identifier for hierarchical organization"
    end

    attribute :registration_source, :string do
      public? true
      description "How the gateway was registered (auto, manual, kubernetes)"
    end

    attribute :status, :atom do
      allow_nil? false
      default :inactive
      public? true
      constraints one_of: [:inactive, :healthy, :degraded, :offline, :recovering, :maintenance, :draining]
      description "Current operational status (state machine managed)"
    end

    attribute :spiffe_identity, :string do
      public? true
      description "SPIFFE ID for mTLS authentication"
    end

    attribute :first_registered, :utc_datetime do
      public? true
      description "When gateway first registered"
    end

    attribute :first_seen, :utc_datetime do
      public? true
      description "When gateway was first seen online"
    end

    attribute :last_seen, :utc_datetime do
      public? true
      description "When gateway was last seen online"
    end

    attribute :metadata, :map do
      default %{}
      public? true
      description "Additional metadata"
    end

    attribute :created_by, :string do
      public? true
      description "User or system that created this gateway"
    end

    attribute :is_healthy, :boolean do
      default true
      public? true
      description "Current health status"
    end

    attribute :agent_count, :integer do
      default 0
      public? true
      description "Number of connected agents"
    end

    attribute :checker_count, :integer do
      default 0
      public? true
      description "Number of active checkers"
    end

    attribute :updated_at, :utc_datetime do
      public? true
      description "Last update time"
    end

    # Multi-tenancy
    attribute :tenant_id, :uuid do
      allow_nil? false
      public? false
      description "Tenant this gateway belongs to"
    end

    # Partition assignment
    attribute :partition_id, :uuid do
      public? true
      description "Partition this gateway is assigned to"
    end
  end

  relationships do
    has_many :agents, ServiceRadar.Infrastructure.Agent do
      source_attribute :id
      destination_attribute :poller_id
      public? true
    end

    belongs_to :partition, ServiceRadar.Infrastructure.Partition do
      source_attribute :partition_id
      destination_attribute :id
      allow_nil? true
      public? true
    end
  end

  calculations do
    calculate :is_online, :boolean, expr(last_seen > ago(5, :minute) and is_healthy == true)

    calculate :status_color,
              :string,
              expr(
                cond do
                  status == :healthy and is_healthy == true -> "green"
                  status == :degraded -> "yellow"
                  status == :draining -> "yellow"
                  status == :recovering -> "blue"
                  status == :maintenance -> "purple"
                  status == :inactive -> "gray"
                  status == :offline -> "red"
                  true -> "red"
                end
              )

    calculate :status_label,
              :string,
              expr(
                cond do
                  status == :healthy -> "Healthy"
                  status == :degraded -> "Degraded"
                  status == :offline -> "Offline"
                  status == :recovering -> "Recovering"
                  status == :maintenance -> "Maintenance"
                  status == :draining -> "Draining"
                  status == :inactive -> "Inactive"
                  true -> "Unknown"
                end
              )

    calculate :display_name,
              :string,
              expr(
                if not is_nil(component_id) do
                  component_id
                else
                  id
                end
              )
  end

  identities do
    identity :unique_gateway_id, [:id]
  end
end
