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

  defp receive_all(acc \\ []) do
    receive do
      msg -> receive_all([msg | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
