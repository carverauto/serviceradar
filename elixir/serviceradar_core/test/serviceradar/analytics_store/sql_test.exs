defmodule ServiceRadar.AnalyticsStore.SQLTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.AnalyticsStore
  alias ServiceRadar.AnalyticsStore.Head
  alias ServiceRadar.AnalyticsStore.SQL
  alias ServiceRadar.Repo

  test "postgres translations stay on the primary repo" do
    assert SQL.repo_for_translation(%{"sql" => "select 1"}) == Repo
    assert SQL.repo_for_translation(%{"dialect" => "postgres"}) == Repo
  end

  test "duckdb translations fail closed without an analytics head" do
    assert SQL.repo_for_translation(%{"dialect" => "duckdb"}) ==
             {:error, :analytics_head_unavailable}
  end

  test "duckdb translations can inject a test query fn without a live head" do
    assert SQL.repo_for_translation(%{"dialect" => "duckdb"},
             analytics_query_fn: fn _, _ -> :ok end
           ) ==
             ServiceRadar.AnalyticsRepo
  end

  test "flipped table selects AnalyticsRepo only when the head is up" do
    cfg =
      AnalyticsStore.Config.validate!(
        AnalyticsStore.Config.load(
          driver: :pg_duckdb,
          storage: :filesystem,
          filesystem_path: "/var/lib/serviceradar/analytics",
          head_host: "analytics-head",
          tables: "timeseries_metrics"
        )
      )

    assert SQL.repo_for_table("timeseries_metrics", config: cfg) ==
             {:error, :analytics_head_unavailable}

    assert SQL.repo_for_table("ocsf_network_activity", config: cfg, repo: Repo) == Repo
  end

  test "drivers_json is empty on the timescale default" do
    assert SQL.drivers_json(config: AnalyticsStore.Config.load([])) == "{}"
  end

  test "only analytics SQL disables logging of rendered parameter values" do
    assert SQL.query_options("duckdb", 12_000) == [timeout: 12_000, log: false]
    assert SQL.query_options(:duckdb, 12_000) == [timeout: 12_000, log: false]
    assert SQL.query_options("postgres", 12_000) == [timeout: 12_000]
  end

  test "analytics repo child spec uses unnamed prepares and S3 after_connect" do
    cfg =
      AnalyticsStore.Config.load(
        head_host: "analytics-head",
        head_port: 5432,
        head_database: "serviceradar",
        head_username: "serviceradar",
        head_password: "secret",
        pool_size: 4
      )

    assert {ServiceRadar.AnalyticsRepo, opts} = SQL.child_spec_or_nil(cfg)
    assert opts[:prepare] == :unnamed
    assert opts[:after_connect] == {Head, :after_connect, []}
    assert opts[:parameters][:application_name] == "sr_analytics_repo"
  end

  test "hybrid recent SQL keeps PostgreSQL bindings without touching the manifest or head" do
    cfg = AnalyticsStore.Config.load(driver: :hybrid, tables: "timeseries_metrics")
    now = ~U[2025-02-01 12:00:00Z]
    start = DateTime.add(now, -1, :hour)
    sql = "SELECT value FROM platform.timeseries_metrics WHERE timestamp >= $1"

    opts = [
      config: cfg,
      now: now,
      time_range: {start, nil},
      manifest_list_fn: fn _, _, _ -> flunk("hot query consulted the archive") end
    ]

    assert SQL.prepare_query("timeseries_metrics", sql, [start], opts) == {:ok, sql, [start]}
    assert SQL.repo_for_table("timeseries_metrics", opts) == Repo
  end

  test "hybrid crossing and unbounded SQL uses the full archive window and fails closed" do
    cfg = AnalyticsStore.Config.load(driver: :hybrid, tables: "timeseries_metrics")
    now = ~U[2025-02-01 12:00:00Z]
    start = DateTime.add(now, -31, :day)
    sql = "SELECT value FROM platform.timeseries_metrics WHERE timestamp >= $1"

    opts = [
      config: cfg,
      now: now,
      time_range: {start, now},
      archive_pending_fn: fn _, _, _ -> {:ok, []} end,
      manifest_list_fn: fn "timeseries_metrics", ^start, ^now ->
        {:error, :archive_unavailable}
      end
    ]

    assert SQL.prepare_query("timeseries_metrics", sql, [start], opts) ==
             {:error, :archive_unavailable}

    assert SQL.repo_for_table("timeseries_metrics", opts) == {:error, :analytics_head_unavailable}

    assert SQL.repo_for_table("timeseries_metrics", config: cfg, now: now) ==
             {:error, :analytics_head_unavailable}
  end

  test "invalid direct bounds fail before checking out either backend" do
    cfg = AnalyticsStore.Config.load(driver: :hybrid, tables: "timeseries_metrics")

    assert {:error, :invalid_analytics_time_range} =
             SQL.query("timeseries_metrics", "SELECT 1", [], config: cfg, time_range: :invalid)
  end

  test "hybrid native map carries the configured hot window" do
    cfg =
      AnalyticsStore.Config.load(
        driver: :hybrid,
        tables: "timeseries_metrics",
        hot_window_days: 7
      )

    assert Jason.decode!(SQL.drivers_json(config: cfg)) == %{
             "timeseries_metrics" => %{"driver" => "hybrid", "hot_window_days" => 7}
           }
  end
end
