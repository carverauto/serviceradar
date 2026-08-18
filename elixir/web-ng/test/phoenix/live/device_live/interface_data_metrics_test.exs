defmodule ServiceRadarWebNGWeb.DeviceLive.InterfaceDataMetricsTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.DeviceLive.InterfaceData

  @moduletag :db_free

  defmodule RecordingSRQL do
    @moduledoc false
    @behaviour ServiceRadarWebNG.SRQLBehaviour

    @impl true
    def query(query, _opts) do
      send(self(), {:srql, query})
      {:ok, %{"results" => []}}
    end

    @impl true
    def query_request(%{"query" => query}), do: query(query, %{})
  end

  defmodule SampleSRQL do
    @moduledoc false
    @behaviour ServiceRadarWebNG.SRQLBehaviour

    @impl true
    def query(_query, _opts) do
      {:ok,
       %{
         "results" => [
           %{
             "metric_name" => "ifInOctets",
             "timestamp" => DateTime.to_iso8601(~U[2026-08-16 00:00:00Z]),
             "value" => 100.0
           }
         ],
         "viz" => %{
           "suggestions" => [
             %{"kind" => "timeseries", "x" => "timestamp", "y" => "value", "series" => "metric_name"}
           ]
         }
       }}
    end

    @impl true
    def query_request(%{"query" => query}), do: query(query, %{})
  end

  @iface %{
    "interface_uid" => "br0",
    "if_index" => 29,
    "if_name" => "br0",
    "metrics_selected" => []
  }

  test "favorited interfaces still query SNMP even when collection is off" do
    metrics =
      InterfaceData.load_interface_metrics(
        RecordingSRQL,
        "sr:udm",
        MapSet.new(["br0"]),
        MapSet.new(),
        [@iface],
        %{}
      )

    assert metrics.has_favorited
    assert metrics.favorited_count == 1
    assert metrics.action == :enable_favorited_metrics
    assert metrics.message =~ "collection is off"
    assert_received {:srql, query}
    assert query =~ "in:snmp_metrics"
    assert query =~ "if_index:29"
  end

  test "existing SNMP samples render for favorites without a settings flag" do
    metrics =
      InterfaceData.load_interface_metrics(
        SampleSRQL,
        "sr:udm",
        MapSet.new(["br0"]),
        MapSet.new(),
        [@iface],
        %{}
      )

    assert metrics.panels != []
    assert is_nil(metrics.action)
  end

  test "enabled favorites with no samples point at the polling agent" do
    metrics =
      InterfaceData.load_interface_metrics(
        RecordingSRQL,
        "sr:udm",
        MapSet.new(["br0"]),
        MapSet.new(["br0"]),
        [@iface],
        %{}
      )

    assert metrics.action == nil
    assert metrics.message =~ "No SNMP samples yet"
  end
end
