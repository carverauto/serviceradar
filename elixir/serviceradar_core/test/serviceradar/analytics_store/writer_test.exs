defmodule ServiceRadar.AnalyticsStore.WriterTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.AnalyticsStore
  alias ServiceRadar.AnalyticsStore.Config
  alias ServiceRadar.AnalyticsStore.Layout
  alias ServiceRadar.AnalyticsStore.Storage
  alias ServiceRadar.AnalyticsStore.Writer

  @cfg_opts [
    driver: :pg_duckdb,
    storage: :filesystem,
    filesystem_path: "/var/lib/serviceradar/analytics",
    head_host: "analytics-head",
    tables: "timeseries_metrics"
  ]

  defp cfg, do: Config.validate!(Config.load(@cfg_opts))

  defp row(extra \\ %{}) do
    Map.merge(
      %{
        timestamp: ~U[2026-09-14 12:00:00Z],
        gateway_id: "gw-1",
        metric_name: "cpu",
        metric_type: "sysmon",
        value: 1.0
      },
      extra
    )
  end

  test "storage URLs keep staging out of the date= prefix" do
    keys = Layout.keys("timeseries_metrics", ~D[2026-09-14], "core-elx", "b1")
    {:ok, staging} = Storage.copy_target(cfg(), keys.staging_key)
    {:ok, published} = Storage.copy_target(cfg(), keys.published_key)
    assert staging =~ "_staging"
    refute published =~ "_staging"
    assert published =~ "date=2026-09-14"
    assert Storage.publish_sql(staging, published) =~ "read_parquet"
  end

  test "write publishes a verified batch and records the manifest" do
    parent = self()

    session = fn _cfg, fun -> {:ok, fun.(:conn)} end

    query = fn :conn, sql, _params ->
      send(parent, {:sql, sql})
      :ok
    end

    verify = fn :conn, _entry, url ->
      send(parent, {:verify, url})
      {:ok, 1}
    end

    record = fn attrs ->
      send(parent, {:manifest, attrs})
      :ok
    end

    assert {:ok, 1} =
             AnalyticsStore.write("timeseries_metrics", [row()],
               config: cfg(),
               session: session,
               query: query,
               verify: verify,
               record_manifest: record,
               batch_id: "b1",
               writer_id: "test"
             )

    assert_received {:verify, url}
    assert url =~ "_staging"

    assert_received {:manifest,
                     %{
                       table_name: "timeseries_metrics",
                       object_key: object_key,
                       row_count: 1,
                       status: :published
                     }}

    assert object_key =~ "date=2026-09-14"
    refute object_key =~ "_staging"

    sqls =
      for _ <- 1..4 do
        assert_received {:sql, sql}
        sql
      end

    assert Enum.any?(sqls, &(&1 =~ "CREATE TEMP TABLE"))
    assert Enum.any?(sqls, &(&1 =~ "INSERT INTO analytics_batch"))
    assert Enum.any?(sqls, &(&1 =~ "FORMAT parquet"))
    assert Enum.any?(sqls, &(&1 =~ "read_parquet"))
  end

  test "verify mismatch does not record a manifest" do
    record = fn _attrs ->
      send(self(), :manifest)
      :ok
    end

    assert {:error, %RuntimeError{}} =
             AnalyticsStore.write("timeseries_metrics", [row()],
               config: cfg(),
               session: fn _cfg, fun -> {:ok, fun.(:conn)} end,
               query: fn :conn, _sql, _params -> :ok end,
               verify: fn :conn, _entry, _url -> {:ok, 99} end,
               record_manifest: record,
               batch_id: "b2"
             )

    refute_received :manifest
  end

  test "rows without a timestamp are rejected" do
    assert {:error, {:rows_missing_timestamp, 1}} =
             AnalyticsStore.write("timeseries_metrics", [%{value: 1}],
               config: cfg(),
               session: fn _, _ -> flunk("session must not run") end
             )
  end

  test "unknown table is rejected" do
    assert {:error, {:unknown_analytics_table, "not_a_registry_table"}} =
             Writer.write("not_a_registry_table", [row()], config: cfg())
  end
end
