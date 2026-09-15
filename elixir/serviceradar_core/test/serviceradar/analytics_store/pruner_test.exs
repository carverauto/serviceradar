defmodule ServiceRadar.AnalyticsStore.PrunerTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.AnalyticsStore.Config
  alias ServiceRadar.AnalyticsStore.Pruner
  alias ServiceRadar.ColdTier.Registry
  alias ServiceRadar.Observability.DataRetentionWorker

  defp pg_duckdb_cfg(tables) do
    Config.validate!(
      Config.load(
        driver: :pg_duckdb,
        storage: :filesystem,
        filesystem_path: "/tmp/example-archive",
        head_host: "analytics.example.com",
        tables: tables
      )
    )
  end

  defp hybrid_cfg(opts \\ []) do
    Config.validate!(
      Config.load(
        Keyword.merge(
          [
            driver: :hybrid,
            tables: ["timeseries_metrics"],
            hot_window_days: 7,
            storage: :filesystem,
            filesystem_path: "/tmp/example-hybrid-archive",
            head_host: "archive.example.com"
          ],
          opts
        )
      )
    )
  end

  test "cutoff is exclusive of the retention window in UTC days" do
    {:ok, entry} = Registry.fetch("timeseries_metrics")
    now = ~U[2026-09-14 18:00:00Z]
    cutoff = Date.add(~D[2026-09-14], -Registry.hot_retention_days(entry))
    assert Pruner.cutoff_date(entry, now) == cutoff
  end

  test "timescale driver does not prune parquet" do
    assert {:ok, 0} =
             Pruner.prune_expired(
               config: Config.load([]),
               list_expired: fn _, _ -> flunk("no list") end,
               delete_objects: fn _ -> flunk("no delete") end,
               forget: fn _ -> flunk("no forget") end
             )
  end

  test "hybrid without an explicit archive lifetime never lists or deletes objects" do
    cfg = hybrid_cfg()
    {:ok, entry} = Registry.fetch("timeseries_metrics")
    assert Pruner.cutoff_date(entry, ~U[2001-06-20 12:00:00Z], cfg) == nil

    assert {:ok, 0} =
             Pruner.prune_expired(
               config: cfg,
               list_expired: fn _, _ ->
                 flunk("unset archive lifetime must not list expired keys")
               end,
               delete_objects: fn _ -> flunk("unset archive lifetime must not delete objects") end,
               forget: fn _ -> flunk("unset archive lifetime must not delete manifest rows") end
             )
  end

  test "hybrid archive expiry retires selected table entries without deleting objects or provenance" do
    cfg = hybrid_cfg(parquet_retention_days: 90)

    assert {:ok, 1} =
             Pruner.prune_expired(
               config: cfg,
               now: ~U[2001-06-20 12:00:00Z],
               retire_expired: fn table, cutoff, opts ->
                 assert table == "timeseries_metrics"
                 assert cutoff == Date.add(~D[2001-06-20], -90)
                 assert opts[:now] == ~U[2001-06-20 12:00:00Z]
                 {:ok, 1}
               end,
               list_expired: fn _, _ -> flunk("hybrid must retire a locked snapshot") end,
               delete_objects: fn _ -> flunk("reader grace must precede deletion") end,
               forget: fn _ -> flunk("publication provenance must survive expiry") end
             )
  end

  test "failed hybrid retirement propagates without deleting any objects" do
    assert {:error, :synthetic_retirement_failure} =
             Pruner.prune_expired(
               config: hybrid_cfg(parquet_retention_days: 90),
               retire_expired: fn _, _, _ -> {:error, :synthetic_retirement_failure} end,
               delete_objects: fn _ -> flunk("retirement failed") end,
               forget: fn _ -> flunk("retirement failed") end
             )
  end

  test "hybrid keeps the hot query window without shortening longer retention or changing other tables" do
    cfg = hybrid_cfg(hot_window_days: 30)

    assert DataRetentionWorker.effective_retention_days("timeseries_metrics", 7, cfg) == 30
    assert DataRetentionWorker.effective_retention_days("timeseries_metrics", 90, cfg) == 90
    assert DataRetentionWorker.effective_retention_days("ocsf_network_activity", 7, cfg) == 7
    refute DataRetentionWorker.skip_timescale_retention?("timeseries_metrics", cfg)

    assert DataRetentionWorker.effective_retention_days("timeseries_metrics", 7, hybrid_cfg()) ==
             7

    for pure <- [Config.load([]), pg_duckdb_cfg("timeseries_metrics")] do
      assert DataRetentionWorker.effective_retention_days("timeseries_metrics", 7, pure) == 7
    end
  end

  test "hybrid compression reinstalls only the metrics policy after schema migration" do
    cfg = hybrid_cfg()
    sql = DataRetentionWorker.hybrid_compression_policy_sql("timeseries_metrics", cfg)
    assert sql =~ "hypertable_schema = 'platform'"
    assert sql =~ "hypertable_name = 'timeseries_metrics'"
    assert sql =~ "AND compression_enabled"
    assert sql =~ "INTERVAL ''2 days''"
    assert sql =~ "if_not_exists => true"
    refute sql =~ "ALTER TABLE"
    refute sql =~ "compress_chunk"

    assert DataRetentionWorker.hybrid_compression_policy_sql("ocsf_network_activity", cfg) == nil

    for pure <- [Config.load([]), pg_duckdb_cfg("timeseries_metrics")] do
      assert DataRetentionWorker.hybrid_compression_policy_sql("timeseries_metrics", pure) == nil
    end
  end

  test "dual-write does not prune parquet (hypertables still own retention)" do
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

    assert {:ok, 0} =
             Pruner.prune_expired(
               config: cfg,
               list_expired: fn _, _ -> flunk("no list") end,
               delete_objects: fn _ -> flunk("no delete") end,
               forget: fn _ -> flunk("no forget") end
             )
  end

  test "flipped table deletes objects before forgetting the manifest" do
    cfg = pg_duckdb_cfg("timeseries_metrics")
    parent = self()
    keys = ["analytics/v1/timeseries_metrics/date=2026-09-01/core-elx-b1.parquet"]

    assert {:ok, 1} =
             Pruner.prune_expired(
               config: cfg,
               now: ~U[2026-09-14 18:00:00Z],
               legacy_prune_guard: fn "timeseries_metrics" -> :ok end,
               list_expired: fn table, cutoff ->
                 send(parent, {:list, table, cutoff})
                 keys
               end,
               delete_objects: fn deleted ->
                 send(parent, {:delete, deleted})
                 {:ok, length(deleted)}
               end,
               forget: fn key ->
                 send(parent, {:forget, key})
                 :ok
               end
             )

    published = "analytics/v1/timeseries_metrics/date=2026-09-01/core-elx-b1.parquet"
    assert_received {:list, "timeseries_metrics", %Date{}}
    assert_received {:delete, ^keys}
    assert_received {:forget, ^published}
  end

  test "failed object delete does not forget the manifest" do
    cfg = pg_duckdb_cfg("timeseries_metrics")

    assert {:error, :boom} =
             Pruner.prune_expired(
               config: cfg,
               now: ~U[2026-09-14 18:00:00Z],
               legacy_prune_guard: fn "timeseries_metrics" -> :ok end,
               list_expired: fn _, _ -> ["k"] end,
               delete_objects: fn _ -> {:error, :boom} end,
               forget: fn _ -> flunk("must not forget after a failed delete") end
             )
  end

  test "empty expired list is a successful no-op" do
    cfg = pg_duckdb_cfg("timeseries_metrics")

    assert {:ok, 0} =
             Pruner.prune_expired(
               config: cfg,
               now: ~U[2026-09-14 18:00:00Z],
               legacy_prune_guard: fn "timeseries_metrics" -> :ok end,
               list_expired: fn _, _ -> [] end,
               delete_objects: fn [] -> {:ok, 0} end,
               forget: fn _ -> flunk("nothing to forget") end
             )
  end

  test "switching to pure pg_duckdb cannot bypass durable hybrid retention" do
    assert {:error, :hybrid_archive_retention_required} =
             Pruner.prune_expired(
               config: pg_duckdb_cfg("timeseries_metrics"),
               legacy_prune_guard: fn "timeseries_metrics" ->
                 {:error, :hybrid_archive_retention_required}
               end,
               list_expired: fn _, _ -> flunk("hybrid history requires retirement") end,
               delete_objects: fn _ -> flunk("cannot bypass reader grace") end,
               forget: fn _ -> flunk("cannot delete durable provenance") end
             )
  end

  test "DataRetentionWorker skips Timescale drop_chunks only after a flip" do
    timescale = Config.load([])
    refute DataRetentionWorker.skip_timescale_retention?("timeseries_metrics", timescale)

    dual =
      Config.validate!(
        Config.load(
          driver: :timescale,
          dual_write: "timeseries_metrics",
          storage: :filesystem,
          filesystem_path: "/var/lib/serviceradar/analytics",
          head_host: "analytics-head"
        )
      )

    refute DataRetentionWorker.skip_timescale_retention?("timeseries_metrics", dual)

    flipped = pg_duckdb_cfg("timeseries_metrics")
    assert DataRetentionWorker.skip_timescale_retention?("timeseries_metrics", flipped)
    refute DataRetentionWorker.skip_timescale_retention?("ocsf_network_activity", flipped)
    refute DataRetentionWorker.skip_timescale_retention?("cpu_metrics", flipped)
  end
end
