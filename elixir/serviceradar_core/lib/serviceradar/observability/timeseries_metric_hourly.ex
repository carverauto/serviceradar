defmodule ServiceRadar.Observability.TimeseriesMetricHourly do
  @moduledoc """
  Hourly timeseries metric rollups from `timeseries_metrics_hourly`.
  """

  use ServiceRadar.Observability.HourlyMetricResource,
    table: "timeseries_metrics_hourly",
    type: "timeseries_metric_hourly",
    route: "/timeseries_metrics_hourly"

  attributes do
    attribute :bucket, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :device_id, :string do
      public? true
    end

    attribute :metric_type, :string do
      public? true
    end

    attribute :metric_name, :string do
      public? true
    end

    attribute :avg_value, :float do
      public? true
    end

    attribute :min_value, :float do
      public? true
    end

    attribute :max_value, :float do
      public? true
    end

    attribute :sample_count, :integer do
      public? true
    end
  end
end
