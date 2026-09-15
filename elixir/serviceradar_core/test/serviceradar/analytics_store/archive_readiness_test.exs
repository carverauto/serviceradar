defmodule ServiceRadar.AnalyticsStore.ArchiveReadinessTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.AnalyticsStore.ArchiveReadiness
  alias ServiceRadar.AnalyticsStore.Config
  alias ServiceRadar.AnalyticsStore.Query

  @window {~U[2025-01-01 00:00:00Z], ~U[2025-02-01 00:00:00Z]}

  defp config, do: Config.load(driver: :hybrid, tables: ["timeseries_metrics"])

  test "does not acquire a catalog dependency for legacy or Timescale-only queries" do
    for driver <- [:timescale, :pg_duckdb] do
      assert :ok =
               ArchiveReadiness.await("timeseries_metrics", @window,
                 config: Config.load(driver: driver),
                 archive_pending_fn: fn _, _, _ ->
                   flunk("legacy queries must not inspect the outbox")
                 end
               )
    end
  end

  test "queries with no overlapping pending work proceed immediately" do
    assert :ok =
             ArchiveReadiness.await("timeseries_metrics", @window,
               config: config(),
               archive_pending_fn: fn "timeseries_metrics", @window, _ -> {:ok, []} end,
               archive_published_fn: fn _, _ -> flunk("empty snapshot needs no poll") end
             )
  end

  test "waits for the fixed snapshot without adding future ingress" do
    owner = self()
    send(owner, {:published, false})
    send(owner, {:published, true})

    assert :ok =
             ArchiveReadiness.await("timeseries_metrics", @window,
               config: config(),
               archive_wait_timeout: 1_000,
               archive_pending_fn: fn _, _, _ ->
                 send(owner, :snapshot)
                 {:ok, ["synthetic-batch"]}
               end,
               archive_published_fn: fn ["synthetic-batch"], opts ->
                 assert opts[:timeout] > 0
                 receive do: ({:published, ready} -> {:ok, ready})
               end,
               archive_sleep_fn: fn _ -> send(owner, :waited) end
             )

    assert_received :snapshot
    refute_received :snapshot
    assert_received :waited
  end

  test "an unpublished snapshot times out before any manifest selection" do
    assert {:error, :analytics_archive_not_ready} =
             Query.prepare("timeseries_metrics", "SELECT * FROM timeseries_metrics", @window,
               config: config(),
               archive_wait_timeout: 0,
               archive_pending_fn: fn _, _, _ -> {:ok, ["synthetic-batch"]} end,
               manifest_list_fn: fn _, _, _ -> flunk("must not query incomplete archive") end
             )
  end

  test "catalog failures are explicit and never treated as ready" do
    assert {:error, :catalog_unavailable} =
             ArchiveReadiness.await("timeseries_metrics", @window,
               config: config(),
               archive_pending_fn: fn _, _, _ -> {:error, :catalog_unavailable} end
             )

    assert {:error, :catalog_unavailable} =
             ArchiveReadiness.await("timeseries_metrics", @window,
               config: config(),
               archive_pending_fn: fn _, _, _ -> {:ok, ["synthetic-batch"]} end,
               archive_published_fn: fn _, _ -> {:error, :catalog_unavailable} end
             )
  end
end
