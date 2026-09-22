defmodule ServiceRadar.Observability.TimeseriesMetricDiskHourlyTest do
  use ExUnit.Case, async: true

  alias Ash.Resource.Info
  alias AshPostgres.DataLayer.Info, as: PostgresInfo
  alias ServiceRadar.Observability
  alias ServiceRadar.Observability.TimeseriesMetricDiskHourly

  @migration_path "priv/repo/migrations/20260912120000_create_timeseries_metrics_disk_hourly.exs"

  test "resource is raw-managed in the platform schema" do
    assert PostgresInfo.table(TimeseriesMetricDiskHourly) == "timeseries_metrics_disk_hourly"
    assert PostgresInfo.schema(TimeseriesMetricDiskHourly) == "platform"
    refute PostgresInfo.migrate?(TimeseriesMetricDiskHourly)

    assert TimeseriesMetricDiskHourly in Ash.Domain.Info.resources(Observability)
  end

  test "resource exposes mount-keyed hourly aggregate fields" do
    attributes = TimeseriesMetricDiskHourly |> Info.attributes() |> Map.new(&{&1.name, &1})

    for field <- [
          :bucket,
          :device_id,
          :metric_type,
          :metric_name,
          :series_key,
          :mount_point,
          :avg_value,
          :min_value,
          :max_value,
          :sample_count
        ] do
      assert Map.has_key?(attributes, field)
    end
  end

  test "migration creates a mount-keyed hourly CAGG over sysmon disk gauges" do
    migration = File.read!(@migration_path)

    assert migration =~ ~s(@view "platform.timeseries_metrics_disk_hourly")
    assert migration =~ "CREATE MATERIALIZED VIEW IF NOT EXISTS \#{@view}"
    assert migration =~ "WITH (timescaledb.continuous)"
    assert migration =~ "tags->>'mount_point' AS mount_point"
    assert migration =~ "metric_type = 'sysmon.disk'"
    assert migration =~ "device_id IS NOT NULL"
    assert migration =~ "tags->>'mount_point' IS NOT NULL"
    assert migration =~ "GROUP BY 1, 2, 3, 4, 5, 6"
    assert migration =~ "FROM platform.timeseries_metrics"
    assert migration =~ "add_continuous_aggregate_policy"
    assert migration =~ "add_retention_policy"
    assert migration =~ ~s(@retention_interval "395 days")
    assert migration =~ ~s(@refresh_start_offset "5 days")
    assert migration =~ "serviceradar:allow-startup-maintenance"
    refute migration =~ "refresh_continuous_aggregate"
    refute migration =~ "public.timeseries_metrics_disk_hourly"
  end
end
