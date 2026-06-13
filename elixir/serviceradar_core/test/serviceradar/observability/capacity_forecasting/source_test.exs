defmodule ServiceRadar.Observability.CapacityForecasting.SourceTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Observability.CapacityForecasting.Source

  test "default SRQL sources read newest buckets with a bounded page size" do
    queries =
      [time_range: "last_30d", limit: 123]
      |> Source.defaults()
      |> Enum.map(& &1.query)

    assert Enum.all?(queries, &String.contains?(&1, "time:last_30d"))
    assert Enum.all?(queries, &String.contains?(&1, "sort:bucket:desc"))
    assert Enum.all?(queries, &String.contains?(&1, "limit:123"))
    refute Enum.any?(queries, &String.contains?(&1, "sort:bucket:asc"))
  end

  test "defaults avoid raw generic timeseries values because counters are stored as cumulative ramps" do
    sources = Source.defaults()

    refute Enum.any?(sources, &(&1.name == "timeseries_value"))
    refute Enum.any?(sources, &String.contains?(&1.query, "in:timeseries_metrics"))

    assert Enum.any?(
             sources,
             &String.contains?(&1.query, "in:timeseries_metric_interface_hourly")
           )
  end
end
