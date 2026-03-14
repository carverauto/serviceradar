defmodule ServiceRadar.Observability.CpuMetricHourly do
  @moduledoc """
  Hourly CPU metric rollups from `cpu_metrics_hourly`.
  """

  use ServiceRadar.Observability.HourlyMetricResource,
    table: "cpu_metrics_hourly",
    type: "cpu_metric_hourly",
    route: "/cpu_metrics_hourly"

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

    attribute :sample_count, :integer do
      public? true
    end
  end
end
