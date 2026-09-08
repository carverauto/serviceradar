defmodule ServiceRadar.Observability.TimeseriesMetricInterfaceHourlyTest do
  use ExUnit.Case, async: true

  alias Ash.Resource.Info
  alias AshPostgres.DataLayer.Info, as: PostgresInfo
  alias ServiceRadar.Observability
  alias ServiceRadar.Observability.TimeseriesMetricInterfaceHourly

  @migration_path "priv/repo/migrations/20260612090000_create_timeseries_metrics_interface_hourly.exs"

  test "resource is raw-managed in the platform schema" do
    assert PostgresInfo.table(TimeseriesMetricInterfaceHourly) ==
             "timeseries_metrics_interface_hourly"

    assert PostgresInfo.schema(TimeseriesMetricInterfaceHourly) == "platform"
    refute PostgresInfo.migrate?(TimeseriesMetricInterfaceHourly)

    assert TimeseriesMetricInterfaceHourly in Ash.Domain.Info.resources(Observability)
  end

  test "resource exposes interface-keyed hourly aggregate fields" do
    attributes = TimeseriesMetricInterfaceHourly |> Info.attributes() |> Map.new(&{&1.name, &1})

    for field <- [
          :bucket,
          :device_id,
          :target_device_ip,
          :if_index,
          :metric_type,
          :metric_name,
          :series_key,
          :avg_value,
          :min_value,
          :max_value,
          :delta_value,
          :duration_seconds,
          :avg_rate_per_second,
          :sample_count
        ] do
      assert Map.has_key?(attributes, field)
    end
  end

  test "migration creates an interface-keyed hourly CAGG with retention policy" do
    migration = File.read!(@migration_path)

    assert migration =~ ~s(@view "platform.timeseries_metrics_interface_hourly")
    assert migration =~ "CREATE MATERIALIZED VIEW IF NOT EXISTS \#{@view}"
    assert migration =~ "WITH (timescaledb.continuous)"
    assert migration =~ "target_device_ip"
    assert migration =~ "if_index"
    assert migration =~ "series_key"

    assert migration =~
             "COALESCE(metadata->>'kind', metadata->>'metric_type') IN ('sum', 'counter')"

    assert migration =~ "metadata->>'temporality' = 'cumulative'"
    assert migration =~ "LOWER(COALESCE(metadata->>'is_monotonic', 'false')) IN ('true', '1')"
    assert migration =~ "metadata ? 'raw_value'"
    assert migration =~ "GROUP BY 1, 2, 3, 4, 5, 6, 7"
    assert migration =~ "avg_rate_per_second"
    assert migration =~ "add_continuous_aggregate_policy"
    assert migration =~ "add_retention_policy"
    refute migration =~ "public.timeseries_metrics_interface_hourly"
  end
end
