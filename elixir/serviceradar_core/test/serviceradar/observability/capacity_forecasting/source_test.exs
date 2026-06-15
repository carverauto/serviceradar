defmodule ServiceRadar.Observability.CapacityForecasting.SourceTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Observability.CapacityForecasting.Source

  test "default SRQL sources read newest buckets with a bounded page size" do
    queries =
      [time_range: "last_30d", limit: 123]
      |> Source.defaults()
      |> Enum.map(& &1.query)

    assert Enum.all?(queries, &String.contains?(&1, "time:last_30d"))

    assert Enum.all?(
             queries,
             &(String.contains?(&1, "sort:bucket:desc") or
                 String.contains?(&1, "sort:timestamp:desc"))
           )

    assert Enum.all?(queries, &String.contains?(&1, "limit:123"))
    refute Enum.any?(queries, &String.contains?(&1, "sort:bucket:asc"))
  end

  test "defaults use normalized sysmon timeseries and interface counter rollups" do
    sources = Source.defaults()

    refute Enum.any?(sources, &(&1.name == "timeseries_value"))

    assert Enum.any?(sources, &String.contains?(&1.query, ~s|metric_type:"sysmon.cpu"|))
    assert Enum.any?(sources, &String.contains?(&1.query, ~s|metric_name:"memory.used_percent"|))
    assert Enum.any?(sources, &String.contains?(&1.query, ~s|metric_name:"disk.used_percent"|))
    assert Enum.any?(sources, &String.contains?(&1.query, ~s|metric_name:"process.count"|))

    assert Enum.all?(
             Enum.filter(sources, &String.contains?(&1.query, "in:timeseries_metrics")),
             &(&1.value_field == "value" and &1.bucket_field == "timestamp")
           )

    assert Enum.any?(
             sources,
             &String.contains?(&1.query, "in:timeseries_metric_interface_hourly")
           )
  end
end
