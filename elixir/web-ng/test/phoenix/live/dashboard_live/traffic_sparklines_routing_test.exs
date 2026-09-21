defmodule ServiceRadarWebNGWeb.DashboardLive.Data.TrafficSparklinesRoutingTest do
  # Not async: the cutover list is global application env.
  use ExUnit.Case, async: false

  alias ServiceRadar.Analytics.StarRocks
  alias ServiceRadarWebNGWeb.DashboardLive.Data.TrafficSparklines

  @moduletag :db_free

  @cutoff ~U[2025-01-01 00:00:00Z]

  setup do
    prev = Application.get_env(:serviceradar_core, StarRocks, [])
    on_exit(fn -> Application.put_env(:serviceradar_core, StarRocks, prev) end)
    %{prev: prev}
  end

  test "the throughput sparkline keeps its CNPG relations while flows are not cut over", %{prev: prev} do
    Application.put_env(:serviceradar_core, StarRocks, Keyword.put(prev, :cutover_datasets, [:metrics]))

    assert TrafficSparklines.warehouse_traffic_rows(@cutoff, 900) == :cnpg
  end

  test "with flows cut over it asks the warehouse and never falls back to CNPG", %{prev: prev} do
    Application.put_env(:serviceradar_core, StarRocks, Keyword.put(prev, :cutover_datasets, [:flows]))

    # No warehouse is running under this test, so the read fails; what matters
    # is that the answer is the warehouse's error and not `:cnpg`.
    assert {:error, _reason} = TrafficSparklines.warehouse_traffic_rows(@cutoff, 900)
  end
end
