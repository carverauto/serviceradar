defmodule ServiceRadar.AnalyticsStore.SRQLPickerTest do
  use ExUnit.Case, async: true

  @forecast "lib/serviceradar/observability/capacity_forecasting"
  @seasonal "lib/serviceradar/observability/seasonal_disposition"
  @retrohunt "lib/serviceradar/observability/threat_intel_retrohunt_worker.ex"
  @runner "lib/serviceradar/observability/srql_runner.ex"
  @silence "lib/serviceradar/observability/anomaly_ingest_silence_worker.ex"
  @correlation "lib/serviceradar/event_writer/device_correlation.ex"
  @topology_metrics "lib/serviceradar/network_discovery/topology_graph/telemetry/metrics.ex"
  @threshold "lib/serviceradar/inventory/interface_threshold_worker.ex"

  test "capacity forecasting and seasonal disposition query through SRQLRunner" do
    forecast = read_tree!(@forecast)
    seasonal = read_tree!(@seasonal)
    assert forecast =~ "SRQLRunner"
    assert seasonal =~ "SRQLRunner"
    refute forecast =~ ~r/Repo\.query(?:!)?\(/
    refute seasonal =~ ~r/Repo\.query(?:!)?\(/
  end

  test "SRQLRunner picks AnalyticsRepo from the translation dialect" do
    runner = File.read!(Path.join(root(), @runner))
    assert runner =~ "AnalyticsStore.SQL.repo_for_translation"
    assert runner =~ "drivers_json"
  end

  test "retrohunt NetFlow match goes through the analytics-store SQL picker" do
    source = File.read!(Path.join(root(), @retrohunt))
    assert source =~ ~s[AnalyticsStore.SQL.query(]
    assert source =~ ~s["ocsf_network_activity"]
  end

  test "remaining timeseries_metrics readers go through the analytics-store SQL picker" do
    silence = File.read!(Path.join(root(), @silence))
    correlation = File.read!(Path.join(root(), @correlation))
    topology = File.read!(Path.join(root(), @topology_metrics))

    assert silence =~ ~s[AnalyticsStore.SQL.query(]
    assert silence =~ ~s["timeseries_metrics"]

    assert correlation =~ ~s[AnalyticsStore.SQL.query(]
    assert correlation =~ ~s["timeseries_metrics"]
    assert correlation =~ "timeseries_cagg_available?"

    assert topology =~ ~s[AnalyticsStore.SQL.query("timeseries_metrics"]
    assert topology =~ "ROW_NUMBER()"
    refute topology =~ "DISTINCT ON"
    refute topology =~ ~s[from(m in "timeseries_metrics"]

    threshold = File.read!(Path.join(root(), @threshold))
    assert threshold =~ "AnalyticsStore.SQL.query"
    assert threshold =~ "TimeseriesQueries.latest_interface_value_sql"
    refute threshold =~ ~s[from(m in "timeseries_metrics"]
  end

  defp root, do: Path.expand("../../..", __DIR__)

  defp read_tree!(relative) do
    path = Path.join(root(), relative)

    if File.dir?(path) do
      path
      |> Path.join("**/*.ex")
      |> Path.wildcard()
      |> Enum.map_join("\n", &File.read!/1)
    else
      File.read!(path)
    end
  end
end
