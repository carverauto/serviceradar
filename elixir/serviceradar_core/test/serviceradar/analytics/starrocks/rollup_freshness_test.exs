defmodule ServiceRadar.Analytics.StarRocks.RollupFreshnessTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Analytics.StarRocks.Env
  alias ServiceRadar.Analytics.StarRocks.RollupFreshness

  @moduletag :db_free

  @now ~N[1999-06-15 13:00:00]

  defp mysql(rows) do
    fn sql ->
      assert sql ==
               "SELECT MAX(`bucket`) FROM #{Env.table("ocsf_network_activity_hourly")}"

      {:ok,
       %Postgrex.Result{
         command: :select,
         columns: ["MAX(`bucket`)"],
         rows: rows,
         num_rows: length(rows),
         connection_id: nil
       }}
    end
  end

  test "a recently refreshed view reads as fresh" do
    opts = [mysql: mysql([[~N[1999-06-15 12:30:00]]]), now: @now]
    assert RollupFreshness.fresh?(:flows, opts)
  end

  test "a view lagging past the threshold reads as stale" do
    opts = [mysql: mysql([[~N[1999-06-15 10:00:00]]]), now: @now]
    refute RollupFreshness.fresh?(:flows, opts)
  end

  test "an empty view reads as stale, never as fresh" do
    opts = [mysql: mysql([]), now: @now]
    refute RollupFreshness.fresh?(:flows, opts)
  end

  test "a NULL high-water mark reads as stale" do
    opts = [mysql: mysql([[nil]]), now: @now]
    refute RollupFreshness.fresh?(:flows, opts)
  end

  test "a failed freshness probe fails closed to stale" do
    mysql = fn _sql -> {:error, :connect_failed} end
    refute RollupFreshness.fresh?(:flows, mysql: mysql, now: @now)
  end

  test "an unknown dataset reads as stale" do
    opts = [mysql: mysql([[~N[1999-06-15 12:30:00]]]), now: @now]
    refute RollupFreshness.fresh?(:unknown_dataset, opts)
  end

  test "the staleness threshold is configurable per call" do
    rows = [[~N[1999-06-15 10:00:00]]]
    assert RollupFreshness.fresh?(:flows,
             mysql: mysql(rows),
             now: @now,
             stale_after_seconds: 11_000
           )

    refute RollupFreshness.fresh?(:flows,
             mysql: mysql(rows),
             now: @now,
             stale_after_seconds: 3_000
           )
  end
end
