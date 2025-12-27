defmodule ServiceRadar.Observability.MemoryMetric do
  @moduledoc """
  Memory utilization metric resource.

  Maps to the `memory_metrics` table for storing memory usage data.
  Uses TimescaleDB hypertable for efficient time-series storage.
  """

  use Ash.Resource,
    domain: ServiceRadar.Observability,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshJsonApi.Resource]

  json_api do
    type "memory_metric"

    routes do
      base "/memory_metrics"

      index :read
    end
  end

  postgres do
    table "memory_metrics"
    repo ServiceRadar.Repo
  end

  multitenancy do
    strategy :attribute
    attribute :tenant_id
    global? true
  end

  attributes do
    uuid_primary_key :id

    attribute :timestamp, :utc_datetime do
      allow_nil? false
      public? true
    end

    # Memory metrics (in bytes)
    attribute :total_bytes, :integer do
      public? true
      description "Total memory in bytes"
    end

    attribute :used_bytes, :integer do
      public? true
      description "Used memory in bytes"
    end

    attribute :free_bytes, :integer do
      public? true
      description "Free memory in bytes"
    end

    attribute :available_bytes, :integer do
      public? true
      description "Available memory in bytes"
    end

    attribute :buffers_bytes, :integer do
      public? true
      description "Buffer memory in bytes"
    end

    attribute :cached_bytes, :integer do
      public? true
      description "Cached memory in bytes"
    end

    attribute :swap_total_bytes, :integer do
      public? true
      description "Total swap in bytes"
    end

    attribute :swap_used_bytes, :integer do
      public? true
      description "Used swap in bytes"
    end

    # Percentage convenience
    attribute :used_pct, :float do
      public? true
      description "Memory usage percentage"
    end

    # Device references
    attribute :uid, :string do
      public? true
    end

    attribute :host_id, :string do
      public? true
    end

    attribute :poller_id, :string do
      public? true
    end

    attribute :agent_id, :string do
      public? true
    end

    attribute :partition, :string do
      public? true
    end

    attribute :tenant_id, :uuid do
      allow_nil? false
      public? false
    end
  end

  actions do
    defaults [:read]

    read :by_device do
      argument :uid, :string, allow_nil?: false
      filter expr(uid == ^arg(:uid))
    end

    read :recent do
      filter expr(timestamp > ago(24, :hour))
    end

    create :create do
      accept [
        :timestamp, :total_bytes, :used_bytes, :free_bytes, :available_bytes,
        :buffers_bytes, :cached_bytes, :swap_total_bytes, :swap_used_bytes, :used_pct,
        :uid, :host_id, :poller_id, :agent_id, :partition
      ]
    end
  end

  policies do
    bypass always() do
      authorize_if actor_attribute_equals(:role, :super_admin)
    end

    policy action_type(:read) do
      authorize_if expr(
        ^actor(:role) in [:viewer, :operator, :admin] and
        tenant_id == ^actor(:tenant_id)
      )
    end

    policy action(:create) do
      authorize_if expr(
        ^actor(:role) in [:operator, :admin] and
        tenant_id == ^actor(:tenant_id)
      )
    end
  end
end
