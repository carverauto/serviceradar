defmodule ServiceRadar.EventWriter.ArchiveCompactionCleanupTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.AnalyticsStore.Config
  alias ServiceRadar.EventWriter.ArchiveCompactionCleanup

  @key "analytics/v1/timeseries_metrics/_candidates/date=2001-01-02/example.parquet"
  @retired_file %{id: 1, object_key: @key, staging_key: @key}
  @now ~U[2001-01-04 00:00:00Z]

  test "cleanup waits a day, deduplicates physical keys and verifies absence before marking" do
    parent = self()

    assert {:ok, 1} =
             ArchiveCompactionCleanup.run(config(),
               now: @now,
               prune: fn [config: _, now: @now] -> {:ok, 0} end,
               list: fn "timeseries_metrics", ~U[2001-01-03 00:00:00Z], 32 ->
                 {:ok, [@retired_file]}
               end,
               delete: fn [@key] ->
                 send(parent, :deleted)
                 {:ok, 1}
               end,
               absent?: fn @key ->
                 assert_receive :deleted
                 send(parent, :verified_absent)
                 {:ok, true}
               end,
               mark: fn 1 ->
                 assert_receive :verified_absent
                 :ok
               end
             )
  end

  test "successful delete with an object still present never marks cleanup complete" do
    assert {:error, :retired_object_still_present} =
             ArchiveCompactionCleanup.run(config(),
               now: @now,
               prune: fn [config: _, now: @now] -> {:ok, 0} end,
               list: fn _, _, _ -> {:ok, [@retired_file]} end,
               delete: fn _ -> {:ok, 1} end,
               absent?: fn _ -> {:ok, false} end,
               mark: fn _ -> flunk("object still exists") end
             )
  end

  test "partial deletion and failed verification remain retryable" do
    for failure <- [:delete, :head] do
      assert {:error, :synthetic_unavailable} =
               ArchiveCompactionCleanup.run(config(),
                 now: @now,
                 prune: fn [config: _, now: @now] -> {:ok, 0} end,
                 list: fn _, _, _ -> {:ok, [@retired_file]} end,
                 delete: fn _ ->
                   if failure == :delete, do: {:error, :synthetic_unavailable}, else: {:ok, 1}
                 end,
                 absent?: fn _ -> {:error, :synthetic_unavailable} end,
                 mark: fn _ -> flunk("unverified deletion") end
               )
    end
  end

  test "retention failure prevents deletion and remains retryable" do
    assert {:error, :catalog_unavailable} =
             ArchiveCompactionCleanup.run(config(),
               prune: fn _ -> {:error, :catalog_unavailable} end,
               list: fn _, _, _ -> flunk("retirement failed") end
             )
  end

  test "Timescale-only and head-local filesystem deployments do not delete local paths" do
    for cfg <- [Config.load([]), %{config() | storage: :filesystem}] do
      assert {:ok, 0} =
               ArchiveCompactionCleanup.run(cfg, list: fn _, _, _ -> flunk("not eligible") end)
    end
  end

  defp config do
    Config.load(
      driver: :hybrid,
      tables: ["timeseries_metrics"],
      storage: :s3,
      s3_bucket_url: "s3://synthetic-archive",
      s3_endpoint: "objects.example.com",
      s3_region: "example-region",
      s3_access_key_id: "synthetic-access-key",
      s3_secret_access_key: "synthetic-secret"
    )
  end
end
