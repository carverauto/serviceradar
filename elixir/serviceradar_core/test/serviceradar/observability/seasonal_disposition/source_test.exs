defmodule ServiceRadar.Observability.SeasonalDisposition.SourceTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Observability.SeasonalDisposition.Source

  test "default sources cover sustained sysmon host utilization over the hourly CAGGs" do
    sources = Source.defaults()
    queries = Enum.map(sources, & &1.query)

    assert Enum.map(sources, & &1.name) == [
             "cpu_seasonal",
             "memory_seasonal",
             "interface_if_in_octets_seasonal",
             "interface_if_out_octets_seasonal",
             "interface_if_in_ucast_pkts_seasonal",
             "interface_if_out_ucast_pkts_seasonal"
           ]

    assert Enum.any?(queries, &String.contains?(&1, ~s|metric_type:"sysmon.cpu"|))
    assert Enum.any?(queries, &String.contains?(&1, ~s|metric_type:"sysmon.memory"|))
    assert Enum.any?(queries, &String.contains?(&1, ~s|in:timeseries_metric_interface_hourly|))
    assert Enum.any?(queries, &String.contains?(&1, ~s|metric_name:"ifInOctets"|))
    assert Enum.any?(queries, &String.contains?(&1, ~s|metric_name:"ifOutUcastPkts"|))
    refute Enum.any?(queries, &String.contains?(&1, ~s|metric_type:"sysmon.disk"|))

    # The 168-bucket hour-of-week aggregation STAYS in SQL (data gravity, D6): every
    # source profiles by dow/hod in the query, not in the kernel.
    assert Enum.all?(queries, &String.contains?(&1, "profile_hour_of_week"))
    assert Enum.all?(queries, &String.contains?(&1, ~s|timezone:"Etc/UTC"|))
    assert Enum.all?(sources, &(&1.profile_timezone == "Etc/UTC"))
    assert Enum.all?(sources, &(&1.robust_statistic == :median_mad))

    cpu = Enum.find(sources, &(&1.name == "cpu_seasonal"))
    assert cpu.metric_class == "cpu"
    assert cpu.robust_statistic == :median_mad

    interface = Enum.find(sources, &(&1.name == "interface_if_in_octets_seasonal"))
    assert interface.resource_type == "interface"
    assert interface.metric_class == "interface"
    assert interface.metric_name == "ifInOctets"
    assert interface.wire_metric_name == "ifInOctets"
    assert interface.label_fields == ["series", "if_index", "metric_name"]
  end

  test "seasonal disposition support is limited to host cpu and memory utilization" do
    assert Source.seasonal_disposition_supported?(%Source{
             metric_class: "cpu",
             metric_name: "usage_percent"
           })

    assert Source.seasonal_disposition_supported?(%Source{
             metric_class: "memory",
             metric_name: "used_percent"
           })

    refute Source.seasonal_disposition_supported?(%Source{
             metric_class: "disk",
             metric_name: "usage_percent"
           })

    refute Source.seasonal_disposition_supported?(%Source{
             metric_class: "snmp",
             metric_name: "ifInOctets"
           })
  end

  test "baseline delivery support includes interface rate sources without central verdicts" do
    interface = Enum.find(Source.defaults(), &(&1.name == "interface_if_in_octets_seasonal"))

    refute Source.seasonal_disposition_supported?(interface)
    assert Source.baseline_delivery_supported?(interface)

    refute Source.baseline_delivery_supported?(%Source{
             resource_type: "interface",
             metric_class: "interface",
             metric_name: "ifOperStatus"
           })
  end

  test "default sources carry configured timezone into the profile query" do
    sources = Source.defaults(seasonal_profile_timezone: "America/Chicago")

    assert Enum.all?(sources, &(&1.profile_timezone == "America/Chicago"))
    assert Enum.all?(sources, &String.contains?(&1.query, ~s|timezone:"America/Chicago"|))
  end

  test "default sources normalize UTC alias and reject unsafe timezone strings" do
    [utc | _] = Source.defaults(profile_timezone: "UTC")
    assert utc.profile_timezone == "Etc/UTC"
    assert utc.query =~ ~s|timezone:"Etc/UTC"|

    [unknown | _] = Source.defaults(profile_timezone: "Foo/Bar")
    assert unknown.profile_timezone == "Etc/UTC"
    assert unknown.query =~ ~s|timezone:"Etc/UTC"|

    [unsafe | _] = Source.defaults(profile_timezone: ~s|Etc/UTC" sort:sample_value:desc|)
    assert unsafe.profile_timezone == "Etc/UTC"
    assert unsafe.query =~ ~s|timezone:"Etc/UTC"|
    refute unsafe.query =~ "sample_value"
  end

  test "from_config coerces a map into a source struct with field defaults" do
    source =
      Source.from_config(%{
        "name" => "lat_seasonal",
        "resource_type" => "service",
        "metric_class" => "latency",
        "metric_name" => "p95_ms",
        "query" => "in:timeseries_metrics stats:profile_hour_of_week(value)",
        "robust_statistic" => "median_mad",
        "profile_timezone" => "Europe/London",
        "label_fields" => ["series"]
      })

    assert source.name == "lat_seasonal"
    assert source.robust_statistic == :median_mad
    assert source.series_field == "series"
    assert source.sample_field == "sample_value"
    assert source.count_field == "bucket_count"
    assert source.center_field == "center"
    assert source.profile_timezone == "Europe/London"
    assert source.label_fields == ["series"]
  end

  test "from_config falls back to median_mad for an unknown robust statistic" do
    source = Source.from_config(%{robust_statistic: "nonsense"})
    assert source.robust_statistic == :median_mad
  end

  test "from_config normalizes the p05-p95 statistic to the :p05p95 NIF ABI atom" do
    # The NIF RobustStatistic NifUnitEnum decodes P05P95 ONLY as :p05p95 (no
    # underscore). The human-friendly underscore spelling must normalize to the exact
    # ABI atom or the worker crashes the whole dispose_batch call on a decode raise.
    for input <- [:p05p95, :p05_p95, "p05p95", "p05_p95"] do
      source = Source.from_config(%{robust_statistic: input})

      assert source.robust_statistic == :p05p95,
             "robust_statistic #{inspect(input)} must normalize to the :p05p95 ABI atom, " <>
               "got #{inspect(source.robust_statistic)}"
    end
  end

  test "robust? is true only for statistics whose order stats SQL must pre-exclude" do
    assert Source.robust?(%Source{robust_statistic: :median_mad})
    assert Source.robust?(%Source{robust_statistic: :p05p95})
    refute Source.robust?(%Source{robust_statistic: :mean_stddev})
  end

  test "from_config is idempotent on an existing struct" do
    source = %Source{name: "x", robust_statistic: :p05p95}
    assert Source.from_config(source) == source
  end
end
