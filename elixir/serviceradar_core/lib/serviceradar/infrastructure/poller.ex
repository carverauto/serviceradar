defmodule ServiceRadar.Infrastructure.Poller do
  @moduledoc """
  Poller resource for managing poller nodes.

  Pollers orchestrate checks for agents and report health/status.
  """

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
    type "poller"

    routes do
      base "/pollers"
      get :by_id
      index :read
      index :active
      post :register
      patch :heartbeat, route: "/:id/heartbeat"
      patch :update, route: "/:id"
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
      transition :activate, from: :inactive, to: :healthy
      transition :degrade, from: :healthy, to: :degraded
      transition :heartbeat_timeout, from: [:healthy, :degraded], to: :degraded
      transition :go_offline, from: [:healthy, :degraded, :draining], to: :offline
      transition :recover, from: [:degraded, :offline, :recovering], to: :recovering
      transition :restore_health, from: [:degraded, :recovering], to: :healthy
      transition :start_maintenance, from: [:healthy, :degraded], to: :maintenance
      transition :end_maintenance, from: :maintenance, to: :healthy
      transition :start_draining, from: [:healthy, :degraded], to: :draining
      transition :finish_draining, from: :draining, to: :offline
      transition :deactivate, from: [:healthy, :degraded, :offline, :recovering, :maintenance, :draining], to: :inactive
    end
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
    define :list_active, action: :active
    define :list_by_status, action: :by_status, args: [:status]
    define :list_recent, action: :recently_seen
  end

  actions do
    defaults [:read]

    read :by_id do
      argument :id, :string, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end

    read :active do
      description "All healthy pollers"
      filter expr(status == :healthy and is_healthy == true)
    end

    read :by_status do
      argument :status, :atom,
        allow_nil?: false,
        constraints: [
          one_of: [:healthy, :degraded, :offline, :recovering, :maintenance, :draining, :inactive]
        ]

      filter expr(status == ^arg(:status))
    end

    read :recently_seen do
      description "Pollers seen in the last 5 minutes"
      filter expr(last_seen > ago(5, :minute))
    end

    create :register do
      description "Register a new poller (starts in healthy state)"

      accept [
        :id,
        :component_id,
        :registration_source,
        :spiffe_identity,
        :metadata,
        :created_by,
        :partition_id
      ]

      change fn changeset, _context ->
        now = DateTime.utc_now()

        changeset
        |> Ash.Changeset.change_attribute(:first_registered, now)
        |> Ash.Changeset.change_attribute(:first_seen, now)
        |> Ash.Changeset.change_attribute(:last_seen, now)
        |> Ash.Changeset.change_attribute(:status, :healthy)
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
      description "Set poller status explicitly"
      argument :status, :atom,
        allow_nil?: false,
        constraints: [
          one_of: [:healthy, :degraded, :offline, :recovering, :maintenance, :draining, :inactive]
        ]

      change set_attribute(:status, arg(:status))
      change set_attribute(:updated_at, &DateTime.utc_now/0)
    end

    update :activate do
      description "Activate an inactive poller"
      require_atomic? false

      change transition_state(:healthy)
      change set_attribute(:is_healthy, true)
      change set_attribute(:last_seen, &DateTime.utc_now/0)
      change set_attribute(:updated_at, &DateTime.utc_now/0)
      change {ServiceRadar.Infrastructure.Changes.PublishStateChange, entity_type: :poller, new_state: :healthy}
    end

    update :degrade do
      description "Mark poller as degraded"
      argument :reason, :string
      require_atomic? false

      change transition_state(:degraded)
      change set_attribute(:is_healthy, false)
      change set_attribute(:updated_at, &DateTime.utc_now/0)
      change {ServiceRadar.Infrastructure.Changes.PublishStateChange, entity_type: :poller, new_state: :degraded}
    end

    update :go_offline do
      description "Mark poller as offline"
      argument :reason, :string
      require_atomic? false

      change transition_state(:offline)
      change set_attribute(:is_healthy, false)
      change set_attribute(:updated_at, &DateTime.utc_now/0)
      change {ServiceRadar.Infrastructure.Changes.PublishStateChange, entity_type: :poller, new_state: :offline}
    end

    update :recover do
      description "Start recovery from degraded/offline"
      require_atomic? false

      change transition_state(:recovering)
      change set_attribute(:updated_at, &DateTime.utc_now/0)
      change {ServiceRadar.Infrastructure.Changes.PublishStateChange, entity_type: :poller, new_state: :recovering}
    end

    update :restore_health do
      description "Restore poller to healthy state"
      require_atomic? false

      change transition_state(:healthy)
      change set_attribute(:is_healthy, true)
      change set_attribute(:last_seen, &DateTime.utc_now/0)
      change set_attribute(:updated_at, &DateTime.utc_now/0)
      change {ServiceRadar.Infrastructure.Changes.PublishStateChange, entity_type: :poller, new_state: :healthy}
    end

    update :start_maintenance do
      description "Put poller into maintenance"
      require_atomic? false

      change transition_state(:maintenance)
      change set_attribute(:updated_at, &DateTime.utc_now/0)
      change {ServiceRadar.Infrastructure.Changes.PublishStateChange, entity_type: :poller, new_state: :maintenance}
    end

    update :end_maintenance do
      description "End maintenance mode"
      require_atomic? false

      change transition_state(:healthy)
      change set_attribute(:is_healthy, true)
      change set_attribute(:updated_at, &DateTime.utc_now/0)
      change {ServiceRadar.Infrastructure.Changes.PublishStateChange, entity_type: :poller, new_state: :healthy}
    end

    update :start_draining do
      description "Start draining poller"
      require_atomic? false

      change transition_state(:draining)
      change set_attribute(:updated_at, &DateTime.utc_now/0)
      change {ServiceRadar.Infrastructure.Changes.PublishStateChange, entity_type: :poller, new_state: :draining}
    end

    update :finish_draining do
      description "Finish draining and go offline"
      require_atomic? false

      change transition_state(:offline)
      change set_attribute(:is_healthy, false)
      change set_attribute(:updated_at, &DateTime.utc_now/0)
      change {ServiceRadar.Infrastructure.Changes.PublishStateChange, entity_type: :poller, new_state: :offline}
    end

    update :deactivate do
      description "Deactivate poller"
      require_atomic? false

      change transition_state(:inactive)
      change set_attribute(:is_healthy, false)
      change set_attribute(:updated_at, &DateTime.utc_now/0)
      change {ServiceRadar.Infrastructure.Changes.PublishStateChange, entity_type: :poller, new_state: :inactive}
    end

    update :mark_unhealthy do
      description "Legacy: mark poller as unhealthy"
      require_atomic? false

      change transition_state(:degraded)
      change set_attribute(:is_healthy, false)
      change set_attribute(:updated_at, &DateTime.utc_now/0)
      change {ServiceRadar.Infrastructure.Changes.PublishStateChange, entity_type: :poller, new_state: :degraded}
    end
  end

  policies do
    bypass always() do
      authorize_if actor_attribute_equals(:role, :super_admin)
    end

    policy action_type(:read) do
      authorize_if expr(tenant_id == ^actor(:tenant_id))
    end

    policy action(:register) do
      authorize_if expr(^actor(:role) in [:admin, :operator])
    end

    policy action([:update, :heartbeat]) do
      authorize_if expr(^actor(:role) in [:admin, :operator] and tenant_id == ^actor(:tenant_id))
    end

    policy action([:set_status, :mark_unhealthy, :deactivate]) do
      authorize_if expr(^actor(:role) == :admin and tenant_id == ^actor(:tenant_id))
    end
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
      description "Component identifier"
    end

    attribute :registration_source, :string do
      public? true
      description "How the poller was registered"
    end

    attribute :status, :atom do
      allow_nil? false
      default :inactive
      public? true
      constraints one_of: [:healthy, :degraded, :offline, :recovering, :maintenance, :draining, :inactive]
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
      description "When poller first seen online"
    end

    attribute :last_seen, :utc_datetime do
      public? true
      description "When poller last seen online"
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

    attribute :tenant_id, :uuid do
      allow_nil? false
      public? false
      description "Tenant this poller belongs to"
    end

    attribute :partition_id, :uuid do
      public? true
      description "Partition this poller is assigned to"
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
                  true -> "gray"
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
    identity :unique_poller_id, [:id]
  end
end
