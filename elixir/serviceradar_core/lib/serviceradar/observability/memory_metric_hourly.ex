defmodule ServiceRadar.Observability.MemoryMetricHourly do
  @moduledoc """
  Hourly memory metric rollups from `memory_metrics_hourly`.
  """

  use ServiceRadar.Observability.HourlyMetricResource,
    table: "memory_metrics_hourly",
    type: "memory_metric_hourly",
    route: "/memory_metrics_hourly"

  attributes do
    attribute :bucket, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :device_id, :string do
      public? true
    end

    attribute :host_id, :string do
      public? true
    end

    attribute :avg_usage_percent, :float do
      public? true
    end

    attribute :max_usage_percent, :float do
      public? true
    end

    attribute :avg_used_bytes, :float do
      public? true
    end

    attribute :avg_available_bytes, :float do
      public? true
    end

    attribute :sample_count, :integer do
      public? true
    end
  end
end
