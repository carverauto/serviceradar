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
    refute Enum.any?(sources, &String.contains?(&1.query, ~s|metric_type:"sysmon.process"|))
    refute Enum.any?(sources, &String.contains?(&1.query, ~s|metric_name:"process.count"|))

    assert Enum.all?(
             Enum.filter(sources, &String.contains?(&1.query, "in:timeseries_metrics")),
             &(&1.value_field == "value" and &1.bucket_field == "timestamp")
           )

    assert Enum.any?(
             sources,
             &String.contains?(&1.query, "in:timeseries_metric_interface_hourly")
           )

    interface_source = Enum.find(sources, &(&1.name == "interface_rate"))
    assert "partition" in interface_source.key_fields
    assert interface_source.value_unit == "percent"

    assert sources
           |> Enum.filter(&(&1.resource_type in ["cpu", "memory", "disk"]))
           |> Enum.all?(&(&1.value_unit == "percent"))

    flow_source = Enum.find(sources, &(&1.resource_type == "flow"))
    assert flow_source.name == "flow_bytes_per_hour"
    assert flow_source.metric_name == "bytes_per_hour"
    assert flow_source.value_field == "bytes_total"
    assert flow_source.threshold == 1_000_000_000_000.0
    assert flow_source.value_unit == "bytes"
    refute flow_source.metric_name == "bps"
  end

  test "configured sources preserve value units" do
    source =
      Source.from_config(%{
        "name" => "custom_percent",
        "resource_type" => "custom",
        "metric_class" => "custom",
        "metric_name" => "utilization_percent",
        "query" => "in:custom",
        "value_unit" => "percent"
      })

    assert source.value_unit == "percent"
  end
end
