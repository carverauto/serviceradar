defmodule ServiceRadar.Observability.ProcessMetric do
  @moduledoc """
  Process metrics resource.

  Maps to the `process_metrics` TimescaleDB hypertable. This table is managed by raw SQL
  migrations that match the Go schema exactly.
  """

  use Ash.Resource,
    domain: ServiceRadar.Observability,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshJsonApi.Resource]

  postgres do
    table "process_metrics"
    repo ServiceRadar.Repo
    # Don't generate migrations - table is managed by raw SQL migration
    # that creates TimescaleDB hypertable matching Go schema
    migrate? false
  end

  json_api do
    type "process_metric"

    routes do
      base "/process_metrics"

      index :read
    end
  end

  multitenancy do
    strategy :context
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

    read :by_host do
      argument :host_id, :string, allow_nil?: false
      filter expr(host_id == ^arg(:host_id))
    end

    read :recent do
      description "Metrics from the last 24 hours"
      filter expr(timestamp > ago(24, :hour))
    end

    create :create do
      accept [
        :timestamp,
        :gateway_id,
        :agent_id,
        :host_id,
        :pid,
        :name,
        :cpu_usage,
        :memory_usage,
        :status,
        :start_time,
        :device_id,
        :partition
      ]
    end
  end

  policies do
    # Reads are tenant-scoped by schema isolation
    policy action_type(:read) do
      authorize_if always()
    end

    policy action(:create) do
      authorize_if always()
    end
  end

  # Note: This hypertable does not include tenant_id; schema isolation handles tenancy.

  attributes do
    # TimescaleDB hypertable - no traditional PK
    attribute :timestamp, :utc_datetime_usec do
      allow_nil? false
      public? true
      description "When the metric was recorded"
    end

    attribute :gateway_id, :string do
      public? true
      description "Gateway that collected this metric"
    end

    attribute :agent_id, :string do
      public? true
      description "Agent ID"
    end

    attribute :host_id, :string do
      public? true
      description "Host identifier"
    end

    attribute :pid, :integer do
      public? true
      description "Process ID"
    end

    attribute :name, :string do
      public? true
      description "Process name"
    end

    attribute :cpu_usage, :float do
      public? true
      description "CPU usage (REAL in Go schema)"
    end

    attribute :memory_usage, :integer do
      public? true
      description "Memory usage in bytes"
    end

    attribute :status, :string do
      public? true
      description "Process status"
    end

    attribute :start_time, :string do
      public? true
      description "Process start time"
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
