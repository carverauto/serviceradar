defmodule ServiceRadarWebNGWeb.DeviceLive.InterfaceDataMetricsTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.DeviceLive.InterfaceData

  @moduletag :db_free

  def query(query, opts) do
    send(self(), {:batch_srql, query, opts})
    Process.get({__MODULE__, :response}) || raise "missing synthetic SRQL response"
  end

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

  test "one batch keeps each interface's rates, selected metrics, labels and thresholds" do
    interfaces = batch_interfaces()

    rows =
      Enum.map(
        [
          {"7:ifInOctets", 10.0},
          {"8:ifInOctets", 90.0},
          {"7:ifOutOctets", 999.0},
          {"8:ifOutOctets", 20.0},
          {"7:metric:packets", 3.0},
          {"8:metric:packets", 777.0},
          {"99:ifInOctets", 888.0}
        ],
        fn {series, value} ->
          %{"series" => series, "interface_metric" => series, "value" => value, "timestamp" => "2026-02-01T00:00:00Z"}
        end
      )

    put_batch_response(
      rows ++
        [
          %{"series" => "7:ifInOctets", "value" => 11.0, "timestamp" => "2026-02-01T00:01:00Z"},
          %{"series" => "8:ifInOctets", "value" => 91.0, "timestamp" => "2026-02-01T00:01:00Z"},
          %{"series" => "invalid", "value" => 1},
          %{"series" => "7:", "value" => 2},
          nil
        ]
    )

    metrics = load_batch(interfaces)
    assert_received {:batch_srql, query, %{scope: :synthetic_scope}}
    assert query =~ "series:interface_metric"
    refute_received {:batch_srql, _query, _opts}

    [first, second] = metrics.panels
    assert first.assigns.interface_label == "synthetic-port-a (ifIndex: 7)"
    assert second.assigns.interface_label == "synthetic-port-b (ifIndex: 8)"
    assert series_values(first) == %{"ifInOctets" => [10.0, 11.0], "metric:packets" => [3.0]}
    assert series_values(second) == %{"ifInOctets" => [90.0, 91.0], "ifOutOctets" => [20.0]}

    assert [%{value: 12.0, series: "ifInOctets"}] =
             Enum.map(first.assigns.reference_lines, &Map.take(&1, [:value, :series]))

    assert second.assigns.reference_lines == []
    assert is_nil(metrics.error)
  end

  test "HC preference applies within each interface without suppressing another interface's legacy counter" do
    rows =
      Enum.map([{"7:ifInOctets", 1.0}, {"7:ifHCInOctets", 12.0}, {"8:ifInOctets", 34.0}], fn {series, value} ->
        %{"series" => series, "interface_metric" => series, "value" => value, "timestamp" => "2026-02-01T00:00:00Z"}
      end)

    put_batch_response(rows)
    [first, second] = load_batch(batch_interfaces()).panels
    assert series_values(first) == %{"ifHCInOctets" => [12.0]}
    assert series_values(second) == %{"ifInOctets" => [34.0]}
  end

  test "batch errors stay visible and an empty batch keeps collection guidance" do
    Process.put({__MODULE__, :response}, {:error, "synthetic query failure"})
    assert load_batch(batch_interfaces()).error == "Failed to load metrics: synthetic query failure"

    Process.put({__MODULE__, :response}, {:ok, %{"results" => []}})
    empty = load_batch(batch_interfaces())
    assert empty.panels == []
    assert empty.action == :enable_favorited_metrics
    assert is_nil(empty.error)
  end

  defp load_batch(interfaces) do
    InterfaceData.load_interface_metrics(
      __MODULE__,
      "sr:synthetic-device",
      MapSet.new(["ifindex:7", "ifindex:8"]),
      MapSet.new(),
      interfaces,
      :synthetic_scope
    )
  end

  defp put_batch_response(rows) do
    Process.put(
      {__MODULE__, :response},
      {:ok,
       %{
         "results" => rows,
         "viz" => %{
           "suggestions" => [
             %{"kind" => "timeseries", "x" => "timestamp", "y" => "value", "series" => "interface_metric"}
           ]
         }
       }}
    )
  end

  defp batch_interfaces do
    [
      %{
        "interface_uid" => "ifindex:7",
        "if_index" => 7,
        "if_name" => "synthetic-port-a",
        "metrics_selected" => ["ifInOctets", "metric:packets"],
        "metric_thresholds" => %{
          "ifInOctets" => %{"enabled" => true, "comparison" => "gt", "threshold_type" => "absolute", "value" => 12}
        }
      },
      %{
        "interface_uid" => "ifindex:8",
        "if_index" => 8,
        "if_name" => "synthetic-port-b",
        "metrics_selected" => ["ifInOctets", "ifOutOctets"]
      }
    ]
  end

  defp series_values(panel) do
    Map.new(panel.assigns.series_points, fn {name, points} -> {name, Enum.map(points, &elem(&1, 1))} end)
  end
end
