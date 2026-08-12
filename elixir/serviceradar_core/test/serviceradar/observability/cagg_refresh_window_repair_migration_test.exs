defmodule ServiceRadar.Observability.CaggRefreshWindowRepairMigrationTest do
  use ExUnit.Case, async: true

  @migration_path Path.expand(
                    "../../../priv/repo/migrations/20260812020000_repair_cagg_refresh_windows.exs",
                    __DIR__
                  )
  @external_resource @migration_path

  @safe_clamps [
    ["cpu_metrics_hourly", "5 days", "10 minutes", "10 minutes"],
    ["memory_metrics_hourly", "5 days", "10 minutes", "10 minutes"],
    ["disk_metrics_hourly", "5 days", "10 minutes", "10 minutes"],
    ["process_metrics_hourly", "5 days", "10 minutes", "10 minutes"],
    ["timeseries_metrics_hourly", "5 days", "10 minutes", "10 minutes"],
    ["timeseries_metrics_interface_hourly", "5 days", "10 minutes", "10 minutes"],
    ["spans_red_1h", "1 day", "10 minutes", "10 minutes"],
    ["traces_stats_5m", "1 day", "5 minutes", "5 minutes"],
    ["otel_metrics_hourly_stats", "28 days", "10 minutes", "10 minutes"]
  ]

  test "reapplies exactly the nine safe refresh clamps" do
    migration = File.read!(@migration_path)

    clamps =
      Regex.scan(
        ~r/^\s+\{"([^"]+)", "([^"]+)", "([^"]+)", "([^"]+)"\},?$/m,
        migration,
        capture: :all_but_first
      )

    assert clamps == @safe_clamps
  end

  test "policy repair is guarded, idempotent, and startup-safe" do
    migration = File.read!(@migration_path)

    assert migration =~ "serviceradar:allow-startup-maintenance"
    assert migration =~ "IF ts_schema IS NULL THEN"
    assert migration =~ "to_regclass('timescaledb_information.continuous_aggregates') IS NULL"
    assert migration =~ "to_regclass('platform.\#{view}') IS NULL"
    assert migration =~ "IF NOT EXISTS ("
    assert migration =~ "FROM timescaledb_information.continuous_aggregates"
    assert migration =~ "remove_continuous_aggregate_policy(%L::regclass, if_exists => true)"
    assert migration =~ "add_continuous_aggregate_policy(%L::regclass, "
    assert migration =~ "if_not_exists => true)"

    refute migration =~ "refresh_continuous_aggregate("
    refute migration =~ "EXCEPTION"
    refute migration =~ "WHEN others"
  end

  test "rollback never restores the hazardous refresh windows" do
    migration = File.read!(@migration_path)

    assert migration =~ "def down, do: :ok"
    refute migration =~ ~r/\{"[^"]+", "32 days"/
    refute migration =~ ~r/\{"traces_stats_5m", "7 days"/
  end
end
