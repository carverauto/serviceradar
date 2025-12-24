defmodule ServiceRadar.Infrastructure.Poller do
  @moduledoc """
  Poller resource for managing polling nodes.

  Pollers are distributed nodes that execute service checks and
  collect data from agents. They register with Horde.Registry
  on startup and receive job assignments via ERTS distribution.

  ## Status Values

  - `active` - Poller is healthy and receiving jobs
  - `degraded` - Poller has issues but is still operating
  - `inactive` - Poller is offline or unresponsive
  - `draining` - Poller is shutting down gracefully
  """

  use Ash.Resource,
    domain: ServiceRadar.Infrastructure,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshJsonApi.Resource]

  json_api do
    type "poller"

    routes do
      base "/pollers"

      get :by_id
      index :read
      index :active, route: "/active"
    end
  end

  postgres do
    table "pollers"
    repo ServiceRadar.Repo
  end

  multitenancy do
    strategy :attribute
    attribute :tenant_id
    global? true
  end

  attributes do
    attribute :id, :string do
      source :poller_id
      allow_nil? false
      primary_key? true
      public? true
      description "Unique poller identifier"
    end

    attribute :component_id, :string do
      public? true
      description "Component identifier for hierarchical organization"
    end

    attribute :registration_source, :string do
      public? true
      description "How the poller was registered (auto, manual, kubernetes)"
    end

    attribute :status, :string do
      default "active"
      public? true
      description "Current operational status"
    end

    attribute :spiffe_identity, :string do
      public? true
      description "SPIFFE ID for mTLS authentication"
    end

    attribute :first_registered, :utc_datetime do
      public? true
      description "When poller first registered"
    end

    attribute :first_seen, :utc_datetime do
      public? true
      description "When poller was first seen online"
    end

    attribute :last_seen, :utc_datetime do
      public? true
      description "When poller was last seen online"
    end

    attribute :metadata, :map do
      default %{}
      public? true
      description "Additional metadata"
    end

    attribute :created_by, :string do
      public? true
      description "User or system that created this poller"
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
      description "Tenant this poller belongs to"
    end

    # Partition assignment
    attribute :partition_id, :uuid do
      public? true
      description "Partition this poller is assigned to"
    end
  end

  identities do
    identity :unique_poller_id, [:id]
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

  actions do
    defaults [:read]

    read :by_id do
      argument :id, :string, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end

    read :active do
      description "All active pollers"
      filter expr(status == "active" and is_healthy == true)
    end

    read :by_status do
      argument :status, :string, allow_nil?: false
      filter expr(status == ^arg(:status))
    end

    read :recently_seen do
      description "Pollers seen in the last 5 minutes"
      filter expr(last_seen > ago(5, :minute))
    end

    create :register do
      description "Register a new poller"
      accept [
        :id, :component_id, :registration_source, :spiffe_identity,
        :metadata, :created_by
      ]

      change fn changeset, _context ->
        now = DateTime.utc_now()

        changeset
        |> Ash.Changeset.change_attribute(:first_registered, now)
        |> Ash.Changeset.change_attribute(:first_seen, now)
        |> Ash.Changeset.change_attribute(:last_seen, now)
        |> Ash.Changeset.change_attribute(:status, "active")
        |> Ash.Changeset.change_attribute(:is_healthy, true)
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

    update :set_status do
      accept [:status]
      change set_attribute(:updated_at, &DateTime.utc_now/0)
    end

    update :mark_unhealthy do
      description "Mark poller as unhealthy"
      change set_attribute(:is_healthy, false)
      change set_attribute(:status, "degraded")
      change set_attribute(:updated_at, &DateTime.utc_now/0)
    end

    update :deactivate do
      description "Deactivate a poller"
      change set_attribute(:status, "inactive")
      change set_attribute(:is_healthy, false)
      change set_attribute(:updated_at, &DateTime.utc_now/0)
    end
  end

  calculations do
    calculate :is_online, :boolean, expr(
      last_seen > ago(5, :minute) and is_healthy == true
    )

    calculate :status_color, :string, expr(
      cond do
        status == "active" and is_healthy == true -> "green"
        status == "degraded" -> "yellow"
        status == "draining" -> "yellow"
        true -> "red"
      end
    )

    calculate :display_name, :string, expr(
      if not is_nil(component_id) do
        component_id
      else
        id
      end
    )
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
    define :list_active, action: :active
  end

  policies do
    # Import common policy checks

    # Super admins bypass all policies (cross-tenant access)
    bypass always() do
      authorize_if actor_attribute_equals(:role, :super_admin)
    end

    # TENANT ISOLATION: All non-super-admin access requires tenant match
    # This is the primary security boundary for multi-tenant SaaS

    # Read access: Must be authenticated AND in same tenant
    policy action_type(:read) do
      # First check: user has a valid role
      authorize_if expr(
        ^actor(:role) in [:viewer, :operator, :admin] and
        tenant_id == ^actor(:tenant_id)
      )
    end

    # Register new pollers: Admin only, enforces tenant from context
    policy action(:register) do
      authorize_if expr(
        ^actor(:role) == :admin and
        tenant_id == ^actor(:tenant_id)
      )
    end

    # Update operations: Operators/admins in same tenant
    policy action([:update, :heartbeat, :set_status]) do
      authorize_if expr(
        ^actor(:role) in [:operator, :admin] and
        tenant_id == ^actor(:tenant_id)
      )
    end

    # Administrative actions: Admins only, same tenant
    policy action([:mark_unhealthy, :deactivate]) do
      authorize_if expr(
        ^actor(:role) == :admin and
        tenant_id == ^actor(:tenant_id)
      )
    end
  end
end
