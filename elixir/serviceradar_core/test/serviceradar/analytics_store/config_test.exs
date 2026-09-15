defmodule ServiceRadar.AnalyticsStore.ConfigTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.AnalyticsStore.Config
  alias ServiceRadar.ColdTier.Registry

  test "defaults to timescale with no flipped tables" do
    cfg = Config.load([])
    assert %Config{driver: :timescale} = cfg
    assert Config.validate(cfg) == :ok
    assert Config.driver_for(cfg, "timeseries_metrics") == :timescale
    assert Config.driver_for(cfg, "ocsf_network_activity") == :timescale
  end

  test "pg_duckdb without storage is rejected" do
    cfg = Config.load(driver: :pg_duckdb)
    assert Config.validate(cfg) == {:error, :storage_required}

    assert_raise ArgumentError, ~r/analytics store config is invalid/, fn ->
      Config.validate!(cfg)
    end
  end

  test "pg_duckdb s3 without a bucket is rejected" do
    cfg = Config.load(driver: "pg_duckdb", storage: "s3")
    assert Config.validate(cfg) == {:error, {:incomplete_storage, :s3, :missing_bucket}}
  end

  test "pg_duckdb filesystem without a path is rejected" do
    cfg = Config.load(driver: :pg_duckdb, storage: :filesystem)
    assert {:error, {:incomplete_storage, :filesystem, :missing_path}} = Config.validate(cfg)
  end

  test "pg_duckdb s3 without credentials is rejected" do
    cfg =
      Config.load(
        driver: :pg_duckdb,
        storage: :s3,
        s3_bucket_url: "s3://analytics",
        head_host: "analytics-head"
      )

    assert Config.validate(cfg) == {:error, {:incomplete_storage, :s3, :missing_credentials}}
  end

  test "pg_duckdb s3 without a head is rejected" do
    cfg =
      Config.load(
        driver: :pg_duckdb,
        storage: :s3,
        s3_bucket_url: "s3://analytics",
        s3_access_key_id: "id",
        s3_secret_access_key: "secret"
      )

    assert Config.validate(cfg) == {:error, :head_required}
  end

  test "pg_duckdb s3 with a bucket and head is boot-safe" do
    cfg =
      Config.load(
        driver: :pg_duckdb,
        storage: :s3,
        s3_bucket_url: "s3://analytics",
        s3_access_key_id: "id",
        s3_secret_access_key: "secret",
        s3_endpoint: "us-ord-10.linodeobjects.com",
        head_host: "analytics-head",
        tables: "timeseries_metrics"
      )

    assert Config.validate!(cfg) == cfg
    assert Config.driver_for(cfg, "timeseries_metrics") == :pg_duckdb
    assert Config.driver_for(cfg, "ocsf_network_activity") == :timescale
    assert {:ok, opts} = Config.head_opts(cfg)
    assert opts[:hostname] == "analytics-head"
  end

  test "empty tables with pg_duckdb flips every registry table" do
    cfg =
      Config.load(
        driver: :pg_duckdb,
        storage: :filesystem,
        filesystem_path: "/var/lib/serviceradar/analytics",
        head_host: "analytics-head"
      )

    assert Config.validate(cfg) == :ok

    for %{table: table} <- Registry.tables() do
      assert Config.driver_for(cfg, table) == :pg_duckdb
    end

    assert Config.driver_for(cfg, "unified_devices") == :timescale
  end

  test "dual-write with timescale requires a complete pg_duckdb backend" do
    previous = Application.get_env(:serviceradar_core, :event_writer_enabled)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:serviceradar_core, :event_writer_enabled)
        value -> Application.put_env(:serviceradar_core, :event_writer_enabled, value)
      end
    end)

    Application.put_env(:serviceradar_core, :event_writer_enabled, true)
    cfg = Config.load(driver: :timescale, dual_write: "timeseries_metrics")
    assert Config.validate(cfg) == {:error, :storage_required}
    refute Config.dual_write?(Config.load([]), "timeseries_metrics")

    Application.put_env(:serviceradar_core, :event_writer_enabled, false)
    assert Config.validate(cfg) == :ok
  end

  test "dual-write flag is off by default" do
    cfg = Config.load([])
    refute Config.dual_write?(cfg, "timeseries_metrics")
  end

  test "unknown driver is rejected" do
    cfg = Config.load(driver: "clickhouse")
    assert {:error, {:unknown_driver, "clickhouse"}} = Config.validate(cfg)
  end
end
