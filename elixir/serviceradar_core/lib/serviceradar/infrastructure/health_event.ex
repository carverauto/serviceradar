defmodule ServiceRadar.Infrastructure.HealthEvent do
  @moduledoc """
  Records health state changes for all infrastructure entities.

  HealthEvents provide a historical record of health status changes for:
  - Pollers (job orchestrators)
  - Agents (check executors)
  - Checkers (service check definitions)
  - Collectors (data aggregation points)
  - Core services (serviceradar_core nodes)
  - Web services (serviceradar_web nodes)

  ## Use Cases

  - **Health Timeline**: Show when an entity was healthy/degraded/offline
  - **Uptime Calculation**: Calculate availability percentages
  - **Incident Analysis**: Correlate failures across entities
  - **Alerting**: Trigger alerts based on state changes

  ## Entity Types

  - `:poller` - Polling orchestrators
  - `:agent` - Check executors
  - `:checker` - Service check definitions
  - `:collector` - Data aggregators
  - `:core` - Core service nodes
  - `:web` - Web service nodes
  - `:custom` - Custom/external services

  ## Recording Events

  Events are automatically recorded by:
  1. State machine transitions (via PublishStateChange)
  2. Service heartbeat registration
  3. Manual recording for external services

      # Record a health event
      HealthEvent.record(:agent, "agent-uid", tenant_id, :healthy, :degraded,
        reason: "high_latency",
        metadata: %{latency_ms: 500}
      )

  ## Querying History

      # Get health timeline for an entity
      HealthEvent.timeline(:poller, "poller-001", tenant_id, last: 24, unit: :hour)

      # Get current health status
      HealthEvent.current_status(:agent, "agent-uid", tenant_id)
  """

  use Ash.Resource,
    domain: ServiceRadar.Infrastructure,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "health_events"
    repo ServiceRadar.Repo

    custom_indexes do
      index [:entity_type, :entity_id, :recorded_at]
      index [:tenant_id, :recorded_at]
      index [:entity_type, :new_state, :recorded_at]
    end
  end

  multitenancy do
    strategy :attribute
    attribute :tenant_id
    global? true
  end

  code_interface do
    define :record, action: :record
    define :timeline, action: :timeline, args: [:entity_type, :entity_id]
    define :current_status, action: :current_status, args: [:entity_type, :entity_id]
    define :recent_events, action: :recent
  end

  actions do
    defaults [:read]

    create :record do
      description "Record a health state change"

      accept [
        :entity_type,
        :entity_id,
        :tenant_id,
        :old_state,
        :new_state,
        :reason,
        :node,
        :metadata
      ]

      change set_attribute(:recorded_at, &DateTime.utc_now/0)

      change fn changeset, _context ->
        # Calculate duration since last event for this entity
        entity_type = Ash.Changeset.get_attribute(changeset, :entity_type)
        entity_id = Ash.Changeset.get_attribute(changeset, :entity_id)
        tenant_id = Ash.Changeset.get_attribute(changeset, :tenant_id)

        case get_last_event(entity_type, entity_id, tenant_id) do
          {:ok, %{recorded_at: last_recorded_at}} ->
            duration = DateTime.diff(DateTime.utc_now(), last_recorded_at, :second)
            Ash.Changeset.change_attribute(changeset, :duration_seconds, duration)

          _ ->
            changeset
        end
      end
    end

    read :timeline do
      description "Get health timeline for an entity"

      argument :entity_type, :atom do
        allow_nil? false
        constraints one_of: [:poller, :agent, :checker, :collector, :core, :web, :custom]
      end

      argument :entity_id, :string, allow_nil?: false
      argument :since, :utc_datetime
      argument :limit, :integer, default: 100

      filter expr(
               entity_type == ^arg(:entity_type) and
                 entity_id == ^arg(:entity_id)
             )

      filter expr(is_nil(^arg(:since)) or recorded_at >= ^arg(:since))

      prepare build(sort: [recorded_at: :desc], limit: arg(:limit))
    end

    read :current_status do
      description "Get the most recent health event for an entity"

      argument :entity_type, :atom do
        allow_nil? false
        constraints one_of: [:poller, :agent, :checker, :collector, :core, :web, :custom]
      end

      argument :entity_id, :string, allow_nil?: false

      filter expr(
               entity_type == ^arg(:entity_type) and
                 entity_id == ^arg(:entity_id)
             )

      prepare build(sort: [recorded_at: :desc], limit: 1)
    end

    read :recent do
      description "Get recent health events across all entities"

      argument :limit, :integer, default: 50
      argument :entity_type, :atom
      argument :state, :atom

      filter expr(is_nil(^arg(:entity_type)) or entity_type == ^arg(:entity_type))
      filter expr(is_nil(^arg(:state)) or new_state == ^arg(:state))

      prepare build(sort: [recorded_at: :desc], limit: arg(:limit))
    end

    read :by_state do
      description "Get entities currently in a specific state"

      argument :state, :atom, allow_nil?: false
      argument :entity_type, :atom

      # This is a bit complex - we need the latest event per entity
      # For now, just filter by new_state and let caller dedupe
      filter expr(new_state == ^arg(:state))
      filter expr(is_nil(^arg(:entity_type)) or entity_type == ^arg(:entity_type))

      prepare build(sort: [recorded_at: :desc])
    end
  end

  policies do
    bypass always() do
      authorize_if actor_attribute_equals(:role, :super_admin)
    end

    # Read access: Must be in same tenant
    policy action_type(:read) do
      authorize_if expr(tenant_id == ^actor(:tenant_id))
    end

    # Create: System/operator can record events
    policy action(:record) do
      authorize_if expr(
                     ^actor(:role) in [:operator, :admin] and
                       tenant_id == ^actor(:tenant_id)
                   )
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :entity_type, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:poller, :agent, :checker, :collector, :core, :web, :custom]
      description "Type of entity this event is for"
    end

    attribute :entity_id, :string do
      allow_nil? false
      public? true
      description "Unique identifier of the entity"
    end

    attribute :old_state, :atom do
      public? true
      description "Previous health state (nil for first event)"
    end

    attribute :new_state, :atom do
      allow_nil? false
      public? true
      description "New health state"
    end

    attribute :reason, :atom do
      public? true
      description "Reason for state change (heartbeat_timeout, recovery, manual, etc.)"
    end

    attribute :node, :string do
      public? true
      description "Cluster node that recorded this event"
    end

    attribute :duration_seconds, :integer do
      public? true
      description "Seconds spent in the previous state"
    end

    attribute :recorded_at, :utc_datetime do
      allow_nil? false
      public? true
      description "When this event was recorded"
    end

    attribute :metadata, :map do
      default %{}
      public? true
      description "Additional context (latency, error details, etc.)"
    end

    # Multi-tenancy
    attribute :tenant_id, :uuid do
      allow_nil? false
      public? false
      description "Tenant this event belongs to"
    end
  end

  calculations do
    calculate :state_label,
              :string,
              expr(
                cond do
                  new_state == :healthy -> "Healthy"
                  new_state == :degraded -> "Degraded"
                  new_state == :offline -> "Offline"
                  new_state == :connected -> "Connected"
                  new_state == :disconnected -> "Disconnected"
                  new_state == :active -> "Active"
                  new_state == :failing -> "Failing"
                  new_state == :recovering -> "Recovering"
                  new_state == :maintenance -> "Maintenance"
                  true -> "Unknown"
                end
              )

    calculate :state_color,
              :string,
              expr(
                cond do
                  new_state in [:healthy, :connected, :active] -> "green"
                  new_state in [:degraded, :recovering] -> "yellow"
                  new_state in [:offline, :disconnected, :failing] -> "red"
                  new_state == :maintenance -> "purple"
                  true -> "gray"
                end
              )

    calculate :duration_human,
              :string,
              expr(
                cond do
                  is_nil(duration_seconds) -> nil
                  duration_seconds < 60 -> "#{duration_seconds}s"
                  duration_seconds < 3600 -> "#{div(duration_seconds, 60)}m"
                  duration_seconds < 86400 -> "#{div(duration_seconds, 3600)}h"
                  true -> "#{div(duration_seconds, 86400)}d"
                end
              )
  end

  identities do
    identity :unique_event, [:id]
  end

  # Helper function for duration calculation
  defp get_last_event(entity_type, entity_id, tenant_id) do
    require Ash.Query

    __MODULE__
    |> Ash.Query.filter(
      entity_type == ^entity_type and
        entity_id == ^entity_id and
        tenant_id == ^tenant_id
    )
    |> Ash.Query.sort(recorded_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read_one(authorize?: false)
  end
end
