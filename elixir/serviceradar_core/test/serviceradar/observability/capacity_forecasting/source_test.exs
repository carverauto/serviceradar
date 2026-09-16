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

  test "defaults include only monotone consumable sources" do
    sources = Source.defaults()
    queries = Enum.map(sources, & &1.query)

    refute Enum.any?(sources, &(&1.name == "timeseries_value"))
    refute Enum.any?(sources, &(&1.name == "cpu_usage"))
    refute Enum.any?(sources, &(&1.name == "interface_rate"))
    refute Enum.any?(sources, &(&1.name == "flow_bytes_per_hour"))

    refute Enum.any?(queries, &String.contains?(&1, ~s|metric_type:"sysmon.cpu"|))
    assert Enum.any?(queries, &String.contains?(&1, ~s|metric_name:"memory.used_percent"|))
    assert Enum.any?(queries, &String.contains?(&1, ~s|metric_name:"disk.used_percent"|))
    refute Enum.any?(queries, &String.contains?(&1, "in:timeseries_metric_interface_hourly"))
    refute Enum.any?(queries, &String.contains?(&1, "in:flows"))
    refute Enum.any?(queries, &String.contains?(&1, ~s|metric_type:"sysmon.process"|))
    refute Enum.any?(queries, &String.contains?(&1, ~s|metric_name:"process.count"|))

    assert Enum.all?(
             Enum.filter(sources, &String.contains?(&1.query, "in:timeseries_metrics")),
             &(&1.value_field == "value" and &1.bucket_field == "timestamp")
           )

    assert sources
           |> Enum.filter(&(&1.resource_type in ["memory", "disk"]))
           |> Enum.all?(&(&1.value_unit == "percent"))
  end

  test "bursty and non-consumable sources are explicit opt-ins" do
    sources =
      Source.defaults(include_sources: ["cpu_usage", "interface_rate", "flow_bytes_per_hour"])

    queries = Enum.map(sources, & &1.query)

    assert Enum.any?(queries, &String.contains?(&1, ~s|metric_type:"sysmon.cpu"|))

    cpu_source = Enum.find(sources, &(&1.name == "cpu_usage"))
    assert cpu_source.threshold == 90.0
    assert cpu_source.sustained_statistic == "daily_p95"

    assert Enum.any?(
             sources,
             &String.contains?(&1.query, "in:timeseries_metric_interface_hourly")
           )

    interface_source = Enum.find(sources, &(&1.name == "interface_rate"))
    assert "partition" in interface_source.key_fields
    assert interface_source.value_unit == "percent"
    assert interface_source.threshold == 90.0
    assert interface_source.sustained_statistic == "daily_p95"

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

  test "opt_in_names lists exactly the non-default sources in definition order" do
    # Literal guard: the resource validation, seeder filter, worker validation,
    # and Settings UI all derive from this list, so a bad edit to the source
    # definitions must fail loudly here.
    assert Source.opt_in_names() == ["cpu_usage", "interface_rate", "flow_bytes_per_hour"]

    default_names = Enum.map(Source.defaults(), & &1.name)
    all_names = Enum.map(Source.defaults(include_sources: :all), & &1.name)

    assert Enum.sort(Source.opt_in_names() ++ default_names) == Enum.sort(all_names)
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

  test "disk usage reads the per-mount hourly aggregate keyed by device and mount" do
    disk = Enum.find(Source.defaults(), &(&1.name == "disk_usage"))

    assert String.starts_with?(
             disk.query,
             ~s|in:timeseries_metric_disk_hourly metric_type:"sysmon.disk" metric_name:"disk.used_percent"|
           )

    assert String.contains?(disk.query, "sort:bucket:desc")
    assert disk.value_field == "avg_value"
    assert disk.bucket_field == "bucket"
    assert disk.key_fields == ["device_id", "mount_point"]
    assert disk.label_fields == ["device_id", "mount_point"]
    assert disk.threshold == 100.0
    assert disk.value_unit == "percent"
  end
end
