defmodule ServiceRadar.Observability.MemoryMetric do
  @moduledoc """
  Memory utilization metric resource.

  Maps to the `memory_metrics` TimescaleDB hypertable. This table is managed by raw SQL
  migrations that match the Go schema exactly.
  """

  use Ash.Resource,
    domain: ServiceRadar.Observability,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshJsonApi.Resource]

  postgres do
    table "memory_metrics"
    repo ServiceRadar.Repo
    # Don't generate migrations - table is managed by raw SQL migration
    # that creates TimescaleDB hypertable matching Go schema
    migrate? false
  end

  json_api do
    type "memory_metric"

    routes do
      base "/memory_metrics"

      index :read
    end
  end

  resource do
    # TimescaleDB hypertables don't have traditional primary keys
    require_primary_key? false
  end

  actions do
    defaults [:read]

    read :by_device do
      argument :device_id, :string, allow_nil?: false
      filter expr(device_id == ^arg(:device_id))
    end

    read :recent do
      description "Metrics from the last 24 hours"
      filter expr(timestamp > ago(24, :hour))
    end

    create :create do
      accept [
        :timestamp,
        :poller_id,
        :agent_id,
        :host_id,
        :total_bytes,
        :used_bytes,
        :available_bytes,
        :usage_percent,
        :device_id,
        :partition
      ]
    end
  end

  policies do
    # Allow all reads - this data isn't tenant-scoped in Go
    policy action_type(:read) do
      authorize_if always()
    end

    policy action(:create) do
      authorize_if always()
    end
  end

  # Note: No multitenancy - Go schema doesn't have tenant_id

  attributes do
    # TimescaleDB hypertable - no traditional PK
    attribute :timestamp, :utc_datetime_usec do
      allow_nil? false
      public? true
      description "When the metric was recorded"
    end

    attribute :poller_id, :string do
      public? true
      description "Poller that collected this metric"
    end

    attribute :agent_id, :string do
      public? true
      description "Agent ID"
    end

    attribute :host_id, :string do
      public? true
      description "Host identifier"
    end

    attribute :total_bytes, :integer do
      public? true
      description "Total memory in bytes"
    end

    attribute :used_bytes, :integer do
      public? true
      description "Used memory in bytes"
    end

    attribute :available_bytes, :integer do
      public? true
      description "Available memory in bytes"
    end

    attribute :usage_percent, :float do
      public? true
      description "Memory usage percentage"
    end

    attribute :device_id, :string do
      public? true
      description "Device identifier"
    end

    attribute :partition, :string do
      public? true
      description "Partition"
    end

    attribute :created_at, :utc_datetime_usec do
      allow_nil? false
      public? true
      description "When the record was created"
    end
  end
end
