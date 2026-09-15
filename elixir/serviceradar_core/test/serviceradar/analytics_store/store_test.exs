defmodule ServiceRadar.AnalyticsStore.StoreTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.AnalyticsStore
  alias ServiceRadar.AnalyticsStore.Config
  alias ServiceRadar.AnalyticsStore.TimescaleDriver

  defmodule FakeRepo do
    def insert_all(table, rows, opts) do
      send(self(), {:insert_all, table, rows, opts})
      {length(rows), nil}
    end
  end

  test "timescale write uses on_conflict: :nothing and does not hit the default repo" do
    rows = [%{metric_name: "cpu", value: 1.0}]

    assert {:ok, 1} =
             TimescaleDriver.write("timeseries_metrics", rows,
               repo: FakeRepo,
               on_conflict: :nothing,
               returning: false
             )

    assert_received {:insert_all, "timeseries_metrics", ^rows, opts}
    assert opts[:on_conflict] == :nothing
    assert opts[:returning] == false
  end

  test "empty timescale write is a no-op" do
    assert {:ok, 0} = TimescaleDriver.write("timeseries_metrics", [], repo: FakeRepo)
    refute_received {:insert_all, _, _, _}
  end

  test "facade routes timescale tables to postgres dialect" do
    cfg = Config.load([])
    assert AnalyticsStore.dialect("timeseries_metrics", config: cfg) == :postgres
    assert AnalyticsStore.driver_map(config: cfg) == %{}
  end

  test "driver_map lists only flipped tables" do
    cfg =
      Config.validate!(
        Config.load(
          driver: :pg_duckdb,
          storage: :filesystem,
          filesystem_path: "/var/lib/serviceradar/analytics",
          head_host: "analytics-head",
          tables: ["timeseries_metrics"]
        )
      )

    assert AnalyticsStore.driver_map(config: cfg) == %{"timeseries_metrics" => "pg_duckdb"}
    assert AnalyticsStore.dialect("ocsf_network_activity", config: cfg) == :postgres
  end

  test "pg_duckdb table does not fall back to timescale" do
    cfg =
      Config.validate!(
        Config.load(
          driver: :pg_duckdb,
          storage: :s3,
          s3_bucket_url: "s3://analytics",
          s3_access_key_id: "id",
          s3_secret_access_key: "secret",
          head_host: "analytics-head",
          tables: ["timeseries_metrics"]
        )
      )

    assert AnalyticsStore.dialect("timeseries_metrics", config: cfg) == :duckdb

    assert {:error, :head_down} =
             AnalyticsStore.write(
               "timeseries_metrics",
               [%{timestamp: ~U[2026-09-14 12:00:00Z], value: 1}],
               config: cfg,
               repo: FakeRepo,
               session: fn _cfg, _fun -> {:error, :head_down} end
             )

    refute_received {:insert_all, _, _, _}
  end

  test "dual-write sends timescale then parquet and fails closed on parquet error" do
    cfg =
      Config.validate!(
        Config.load(
          driver: :timescale,
          dual_write: "timeseries_metrics",
          storage: :s3,
          s3_bucket_url: "s3://analytics",
          s3_access_key_id: "id",
          s3_secret_access_key: "secret",
          head_host: "analytics-head"
        )
      )

    rows = [%{timestamp: ~U[2026-09-14 12:00:00Z], metric_name: "cpu", value: 1.0}]

    assert {:error, {:dual_write_failed, :head_down}} =
             AnalyticsStore.write("timeseries_metrics", rows,
               config: cfg,
               repo: FakeRepo,
               on_conflict: :nothing,
               returning: false,
               session: fn _cfg, _fun -> {:error, :head_down} end
             )

    assert_received {:insert_all, "timeseries_metrics", ^rows, _}
  end

  test "unlisted table stays on timescale while another is flipped" do
    cfg =
      Config.validate!(
        Config.load(
          driver: :pg_duckdb,
          storage: :s3,
          s3_bucket_url: "s3://analytics",
          s3_access_key_id: "id",
          s3_secret_access_key: "secret",
          head_host: "analytics-head",
          tables: "timeseries_metrics"
        )
      )

    rows = [%{bytes_total: 1}]

    assert {:ok, 1} =
             AnalyticsStore.write("ocsf_network_activity", rows,
               config: cfg,
               repo: FakeRepo,
               on_conflict: :nothing,
               returning: false
             )

    assert_received {:insert_all, "ocsf_network_activity", ^rows, opts}
    assert opts[:on_conflict] == :nothing
    assert AnalyticsStore.dialect("ocsf_network_activity", config: cfg) == :postgres
  end
end
