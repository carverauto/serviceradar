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
        storage: :s3,
        s3_bucket_url: "s3://serviceradar-demo-analytics",
        s3_access_key_id: "id",
        s3_secret_access_key: "secret",
        s3_endpoint: "us-ord-10.linodeobjects.com",
        head_host: "analytics-head",
        tables: tables
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
               list_expired: fn _, _ -> [] end,
               delete_objects: fn [] -> {:ok, 0} end,
               forget: fn _ -> flunk("nothing to forget") end
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
