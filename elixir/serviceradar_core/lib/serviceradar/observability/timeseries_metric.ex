defmodule ServiceRadar.Observability.TimeseriesMetric do
  @moduledoc """
  Generic time-series metric resource.

  Maps to the `timeseries_metrics` TimescaleDB hypertable. This table is managed by raw SQL
  migrations that match the Go schema exactly.
  """

  use ServiceRadar.Observability.RawMetricResource,
    table: "timeseries_metrics",
    type: "timeseries_metric",
    route: "/timeseries_metrics"

  actions do
    defaults [:read]

    read :by_device do
      argument :device_id, :string, allow_nil?: false
      filter expr(device_id == ^arg(:device_id))
    end

    read :by_metric_name do
      argument :metric_name, :string, allow_nil?: false
      filter expr(metric_name == ^arg(:metric_name))
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
        :series_key,
        :metric_name,
        :metric_type,
        :device_id,
        :value,
        :unit,
        :tags,
        :partition,
        :scale,
        :is_delta,
        :target_device_ip,
        :if_index,
        :metadata,
        :created_at
      ]
    end
  end

  attributes do
    # TimescaleDB hypertable - no traditional PK
    attribute :timestamp, :utc_datetime_usec do
      allow_nil? false
      public? true
      description "When the metric was collected"
    end

    attribute :gateway_id, :string do
      allow_nil? false
      public? true
      description "Gateway that collected this metric"
    end

    attribute :agent_id, :string do
      public? true
      description "Agent that collected this metric"
    end

    attribute :series_key, :string do
      allow_nil? false
      public? true
      description "Deterministic identity for one metric series"
    end

    attribute :metric_name, :string do
      allow_nil? false
      public? true
      description "Name of the metric"
    end

    attribute :metric_type, :string do
      allow_nil? false
      public? true
      description "Type of metric (gauge, counter, histogram)"
    end

    attribute :device_id, :string do
      public? true
      description "Device ID this metric belongs to"
    end

    attribute :value, :float do
      allow_nil? false
      public? true
      description "Metric value"
    end

    attribute :unit, :string do
      public? true
      description "Unit of measurement"
    end

    attribute :tags, :map do
      public? true
      description "Tags for dimensional querying (JSONB)"
    end

    attribute :partition, :string do
      public? true
      description "Partition/segment identifier"
    end

    attribute :scale, :float do
      public? true
      description "Scale factor"
    end

    attribute :is_delta, :boolean do
      default false
      public? true
      description "Whether this is a delta value"
    end

    attribute :target_device_ip, :string do
      public? true
      description "Target device IP for SNMP/network metrics"
    end

    attribute :if_index, :integer do
      public? true
      description "Interface index for network metrics"
    end

    attribute :metadata, :map do
      public? true
      description "Additional metadata (JSONB)"
    end

    attribute :created_at, :utc_datetime_usec do
      allow_nil? false
      public? true
      description "When the record was created"
    end
  end

  identities do
    identity :unique_timeseries_metric, [:timestamp, :gateway_id, :series_key]
  end
end
