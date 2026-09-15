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

  test "default writes use globally unique UUID identities in both object keys" do
    opts = [
      config: cfg(),
      session: fn _cfg, fun -> {:ok, fun.(:conn)} end,
      query: fn _, _, _ -> :ok end,
      verify: fn _, _, _ -> {:ok, 1} end,
      record_manifest: fn attrs ->
        send(self(), {:generated_batch, attrs})
        :ok
      end
    ]

    manifests =
      for _ <- 1..2 do
        assert {:ok, 1} = Writer.write("timeseries_metrics", [row()], opts)
        assert_received {:generated_batch, %{batch_id: batch_id} = manifest}
        assert {:ok, ^batch_id} = Ecto.UUID.cast(batch_id)
        assert manifest.staging_key =~ "/#{batch_id}.parquet"
        assert manifest.object_key =~ "/core-elx-#{batch_id}.parquet"
        manifest
      end

    assert [first, second] = manifests
    refute first.batch_id == second.batch_id
    refute first.staging_key == second.staging_key
    refute first.object_key == second.object_key
  end

  test "archive attempts publish outside the legacy hive prefix" do
    assert {:ok, 1} =
             Writer.write(
               "timeseries_metrics",
               [%{timestamp: ~U[2025-03-02 01:00:00Z], value: 3.5}],
               config: cfg(),
               candidate: true,
               batch_id: "synthetic-attempt",
               session: fn _cfg, fun -> {:ok, fun.(:conn)} end,
               query: fn _, _, _ -> :ok end,
               verify: fn _, _, _ -> {:ok, 1} end,
               record_manifest: fn attrs ->
                 assert attrs.object_key =~ "/_candidates/date=2025-03-02/"
                 refute attrs.object_key =~ "/timeseries_metrics/date="
                 :ok
               end
             )
  end

  test "manifest bounds follow actual unordered row times, including late arrivals" do
    rows = [
      %{timestamp: ~U[2034-08-09 13:07:19.987654Z], value: 4.0},
      %{"timestamp" => "2034-08-09T05:12:03.123456Z", "value" => 2.0},
      %{timestamp: ~N[2034-08-09 09:00:00.000001], value: 3.0}
    ]

    assert {:ok, 3} =
             Writer.write("timeseries_metrics", rows,
               config: cfg(),
               session: fn _cfg, fun -> {:ok, fun.(:conn)} end,
               query: fn _, _, _ -> :ok end,
               verify: fn _, _, _ -> {:ok, 3} end,
               record_manifest: fn attrs ->
                 send(self(), {:manifest_bounds, attrs})
                 :ok
               end
             )

    assert_received {:manifest_bounds,
                     %{
                       partition_date: ~D[2034-08-09],
                       row_count: 3,
                       min_timestamp: ~U[2034-08-09 05:12:03.123456Z],
                       max_timestamp: ~U[2034-08-09 13:07:19.987654Z],
                       status: :published
                     }}
  end

  test "late rows in another UTC day have independent manifest bounds" do
    times = [~U[2034-08-10 03:01:00.000000Z], ~U[2034-08-09 21:59:00.000000Z]]

    assert {:ok, 2} =
             Writer.write("timeseries_metrics", Enum.map(times, &%{timestamp: &1, value: 1.0}),
               config: cfg(),
               session: fn _cfg, fun -> {:ok, fun.(:conn)} end,
               query: fn _, _, _ -> :ok end,
               verify: fn _, _, _ -> {:ok, 1} end,
               record_manifest: fn attrs ->
                 send(self(), {:partition_bounds, attrs})
                 :ok
               end
             )

    for timestamp <- times do
      date = DateTime.to_date(timestamp)

      assert_received {:partition_bounds,
                       %{
                         partition_date: ^date,
                         min_timestamp: ^timestamp,
                         max_timestamp: ^timestamp
                       }}
    end
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
