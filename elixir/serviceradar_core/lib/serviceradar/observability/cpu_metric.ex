defmodule ServiceRadar.Observability.CpuMetric do
  @moduledoc """
  CPU utilization metric resource.

  Maps to the `cpu_metrics` TimescaleDB hypertable. This table is managed by raw SQL
  migrations that match the Go schema exactly.
  """

  use ServiceRadar.Observability.RawMetricResource,
    table: "cpu_metrics",
    type: "cpu_metric",
    route: "/cpu_metrics"

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
        :gateway_id,
        :agent_id,
        :host_id,
        :core_id,
        :usage_percent,
        :frequency_hz,
        :label,
        :cluster,
        :device_id,
        :partition,
        :created_at
      ]
    end
  end

  attributes do
    # TimescaleDB hypertable - no traditional PK, timestamp is the time column
    # We use a generated ID for Ash compatibility but it's not in the DB
    attribute :timestamp, :utc_datetime_usec do
      allow_nil? false
      public? true
      description "When the metric was recorded"
    end

    attribute :gateway_id, :string do
      allow_nil? false
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

    attribute :core_id, :integer do
      public? true
      description "CPU core number"
    end

    attribute :usage_percent, :float do
      public? true
      description "CPU usage percentage"
    end

    attribute :frequency_hz, :float do
      public? true
      description "CPU frequency in Hz"
    end

    attribute :label, :string do
      public? true
      description "CPU label"
    end

    attribute :cluster, :string do
      public? true
      description "Cluster name"
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
