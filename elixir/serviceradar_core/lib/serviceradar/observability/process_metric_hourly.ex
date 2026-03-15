defmodule ServiceRadar.Observability.ProcessMetricHourly do
  @moduledoc """
  Hourly process metric rollups from `process_metrics_hourly`.
  """

  use ServiceRadar.Observability.HourlyMetricResource,
    table: "process_metrics_hourly",
    type: "process_metric_hourly",
    route: "/process_metrics_hourly"

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

    attribute :name, :string do
      public? true
    end

    attribute :avg_cpu_usage, :float do
      public? true
    end

    attribute :max_cpu_usage, :float do
      public? true
    end

    attribute :avg_memory_usage, :float do
      public? true
    end

    attribute :max_memory_usage, :float do
      public? true
    end

    attribute :sample_count, :integer do
      public? true
    end
  end
end
