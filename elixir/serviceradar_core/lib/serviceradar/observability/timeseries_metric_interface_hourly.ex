defmodule ServiceRadar.Observability.TimeseriesMetricInterfaceHourly do
  @moduledoc """
  Interface-keyed hourly timeseries metric rollups.

  This keeps SNMP/interface counters separated by `if_index` so capacity
  forecasting can compute per-link runway without collapsing all interfaces on
  a device into one series.
  """

  use ServiceRadar.Observability.HourlyMetricResource,
    table: "timeseries_metrics_interface_hourly",
    type: "timeseries_metric_interface_hourly",
    route: "/timeseries_metrics_interface_hourly"

  attributes do
    attribute :bucket, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :device_id, :string do
      public? true
    end

    attribute :target_device_ip, :string do
      public? true
    end

    attribute :if_index, :integer do
      allow_nil? false
      public? true
    end

    attribute :metric_type, :string do
      public? true
    end

    attribute :metric_name, :string do
      public? true
    end

    attribute :series_key, :string do
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

    attribute :delta_value, :float do
      public? true
    end

    attribute :duration_seconds, :float do
      public? true
    end

    attribute :avg_rate_per_second, :float do
      public? true
    end

    attribute :sample_count, :integer do
      public? true
    end
  end
end
