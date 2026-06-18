defmodule ServiceRadar.Observability.SeasonalDisposition.SourceTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Observability.SeasonalDisposition.Source

  test "default sources cover the sysmon seasonal resource classes over the hourly CAGGs" do
    sources = Source.defaults()
    queries = Enum.map(sources, & &1.query)

    assert Enum.any?(queries, &String.contains?(&1, ~s|metric_type:"sysmon.cpu"|))
    assert Enum.any?(queries, &String.contains?(&1, ~s|metric_type:"sysmon.memory"|))
    assert Enum.any?(queries, &String.contains?(&1, ~s|metric_type:"sysmon.disk"|))

    # The 168-bucket hour-of-week aggregation STAYS in SQL (data gravity, D6): every
    # source profiles by dow/hod in the query, not in the kernel.
    assert Enum.all?(queries, &String.contains?(&1, "profile_hour_of_week"))

    cpu = Enum.find(sources, &(&1.name == "cpu_seasonal"))
    assert cpu.metric_class == "cpu"
    assert cpu.robust_statistic == :mean_stddev
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
        "label_fields" => ["series"]
      })

    assert source.name == "lat_seasonal"
    assert source.robust_statistic == :median_mad
    assert source.series_field == "series"
    assert source.sample_field == "sample_value"
    assert source.count_field == "bucket_count"
    assert source.center_field == "center"
    assert source.label_fields == ["series"]
  end

  test "from_config falls back to mean_stddev for an unknown robust statistic" do
    source = Source.from_config(%{robust_statistic: "nonsense"})
    assert source.robust_statistic == :mean_stddev
  end

  test "robust? is true only for statistics whose order stats SQL must pre-exclude" do
    assert Source.robust?(%Source{robust_statistic: :median_mad})
    assert Source.robust?(%Source{robust_statistic: :p05_p95})
    refute Source.robust?(%Source{robust_statistic: :mean_stddev})
  end

  test "from_config is idempotent on an existing struct" do
    source = %Source{name: "x", robust_statistic: :p05_p95}
    assert Source.from_config(source) == source
  end
end
