defmodule ServiceRadar.AnalyticsStore.CaggRefreshTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.AnalyticsStore.CaggRefresh
  alias ServiceRadar.AnalyticsStore.Config

  defp pg_duckdb_cfg(tables) do
    Config.validate!(
      Config.load(
        driver: :pg_duckdb,
        storage: :filesystem,
        filesystem_path: "/var/lib/serviceradar/analytics",
        head_host: "analytics-head",
        tables: tables
      )
    )
  end

  test "timeseries_metrics CAGGs are the SRQL hourly family" do
    assert CaggRefresh.views_for("timeseries_metrics") == [
             "timeseries_metrics_hourly",
             "timeseries_metrics_interface_hourly",
             "timeseries_metrics_disk_hourly"
           ]
  end

  test "flow CAGGs refresh from ocsf_network_activity" do
    assert "ocsf_network_activity_5m_traffic" in CaggRefresh.views_for("ocsf_network_activity")

    assert "ocsf_network_activity_hourly_talkers" in CaggRefresh.views_for(
             "ocsf_network_activity"
           )
  end

  test "unknown tables have no CAGGs to stop" do
    assert CaggRefresh.views_for("unified_devices") == []
  end

  test "remove_policy_sql is idempotent and qualified" do
    sql = CaggRefresh.remove_policy_sql("timeseries_metrics_hourly")
    assert sql =~ "remove_continuous_aggregate_policy"
    assert sql =~ "if_exists => true"
    assert sql =~ "platform"
    assert sql =~ "timeseries_metrics_hourly"
    refute sql =~ "_staging"
  end

  test "remove_policy_sql rejects non-identifiers" do
    assert_raise ArgumentError, ~r/invalid CAGG view name/, fn ->
      CaggRefresh.remove_policy_sql("timeseries_metrics_hourly; drop table x")
    end
  end

  test "reconcile is a no-op while the driver is still timescale" do
    cfg = Config.load([])

    CaggRefresh.reconcile(
      config: cfg,
      exec: fn _sql -> flunk("must not touch CAGG policies before a table flips") end
    )
  end

  test "reconcile is a no-op during dual-write (driver still timescale)" do
    cfg =
      Config.validate!(
        Config.load(
          driver: :timescale,
          dual_write: "timeseries_metrics",
          storage: :filesystem,
          filesystem_path: "/var/lib/serviceradar/analytics",
          head_host: "analytics-head"
        )
      )

    assert Config.dual_write?(cfg, "timeseries_metrics")
    assert Config.driver_for(cfg, "timeseries_metrics") == :timescale

    CaggRefresh.reconcile(
      config: cfg,
      exec: fn _sql -> flunk("dual-write still feeds Timescale CAGGs") end
    )
  end

  test "reconcile removes policies only for flipped tables" do
    cfg = pg_duckdb_cfg("timeseries_metrics")
    parent = self()

    CaggRefresh.reconcile(
      config: cfg,
      exec: fn sql -> send(parent, {:exec, sql}) end
    )

    sqls = for {:exec, sql} <- receive_all(), do: sql
    assert length(sqls) == 3
    assert Enum.all?(sqls, &(&1 =~ "remove_continuous_aggregate_policy"))
    assert Enum.any?(sqls, &(&1 =~ "timeseries_metrics_hourly"))
    assert Enum.any?(sqls, &(&1 =~ "timeseries_metrics_interface_hourly"))
    assert Enum.any?(sqls, &(&1 =~ "timeseries_metrics_disk_hourly"))
    refute Enum.any?(sqls, &(&1 =~ "ocsf_network_activity"))
    refute Enum.any?(sqls, &(&1 =~ "cpu_metrics_hourly"))
  end

  test "hybrid restores missing timeseries policies without removing any refresh policy" do
    cfg =
      Config.validate!(
        Config.load(
          driver: :hybrid,
          tables: ["timeseries_metrics"],
          storage: :filesystem,
          filesystem_path: "/tmp/example-hybrid-archive",
          head_host: "archive.example.com"
        )
      )

    parent = self()
    assert :ok = CaggRefresh.reconcile(config: cfg, exec: &send(parent, {:exec, &1}))
    sqls = for {:exec, sql} <- receive_all(), do: sql

    assert length(sqls) == 3
    assert Enum.all?(sqls, &(&1 =~ "add_continuous_aggregate_policy"))
    assert Enum.all?(sqls, &(&1 =~ "if_not_exists => true"))
    refute Enum.any?(sqls, &(&1 =~ "remove_continuous_aggregate_policy"))
    refute Enum.any?(sqls, &(&1 =~ "ocsf_network_activity"))

    for view <- CaggRefresh.views_for("timeseries_metrics") do
      assert Enum.any?(sqls, &(&1 =~ "view_name = '#{view}'"))
    end
  end

  test "hybrid restore respects a short hot window and skips absent extensions or CAGGs" do
    sql = CaggRefresh.restore_policy_sql("timeseries_metrics_hourly", 1)
    assert sql =~ "start_offset => INTERVAL ''1 hours''"
    assert sql =~ "end_offset => INTERVAL ''10 minutes''"
    assert sql =~ "IF ts_schema IS NULL THEN"
    assert sql =~ "IF NOT EXISTS"
    assert sql =~ "view_schema = 'platform'"

    for hot_days <- [7, 30, 90] do
      sql = CaggRefresh.restore_policy_sql("timeseries_metrics_hourly", hot_days)
      assert sql =~ "start_offset => INTERVAL ''120 hours''"
    end

    assert_raise ArgumentError, fn ->
      CaggRefresh.restore_policy_sql("ocsf_network_activity_5m_traffic", 7)
    end
  end

  defp receive_all(acc \\ []) do
    receive do
      msg -> receive_all([msg | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
