defmodule ServiceRadar.Observability.TimeseriesMetricDiskHourly do
  @moduledoc """
  Mount-keyed hourly rollups of sysmon disk gauges.

  The device-level hourly aggregate averages every mount point on a host into
  one value, so a full data volume hides behind a flat root filesystem. This
  aggregate keeps `mount_point` (from the sample tags) so capacity forecasting
  can project each filesystem separately.
  """

  use ServiceRadar.Observability.HourlyMetricResource,
    table: "timeseries_metrics_disk_hourly",
    type: "timeseries_metric_disk_hourly",
    route: "/timeseries_metrics_disk_hourly",
    primary_key: [:bucket, :device_id, :metric_type, :metric_name, :series_key, :mount_point]

  attributes do
    attribute :bucket, :utc_datetime_usec do
      allow_nil?(false)
      public?(true)
    end

    attribute :device_id, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :metric_type, :string do
      public?(true)
    end

    attribute :metric_name, :string do
      public?(true)
    end

    attribute :series_key, :string do
      public?(true)
    end

    attribute :mount_point, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :avg_value, :float do
      public?(true)
    end

    attribute :min_value, :float do
      public?(true)
    end

    attribute :max_value, :float do
      public?(true)
    end

    attribute :sample_count, :integer do
      public?(true)
    end
  end
end
