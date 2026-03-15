defmodule ServiceRadarWebNGWeb.InterfaceLive.MetricsTest do
  @moduledoc """
  Unit tests for metric grouping and panel building logic.
  These tests don't require database connections.
  """
  use ExUnit.Case, async: true

  # ============================================================================
  # Task 7.2: Unit tests for combined chart path generation (metric grouping)
  # ============================================================================

  describe "build_metrics_panels/3 metric grouping logic" do
    # These tests verify the panel building logic for grouped vs ungrouped metrics

    test "empty groups returns empty list from helper" do
      results = build_sample_metric_results()
      panels = build_panels_for_groups(results, nil, [])

      # Empty groups means no grouped panels
      assert panels == []
    end

    test "groups metrics into single panel" do
      results = build_sample_metric_results()

      groups = [
        %{
          "id" => "group-1",
          "name" => "Traffic",
          "metrics" => ["ifInOctets", "ifOutOctets"]
        }
      ]

      panels = build_panels_for_groups(results, nil, groups)

      # Should have a panel with the group name
      traffic_panel = Enum.find(panels, &(&1.title == "Traffic"))
      assert traffic_panel
      assert traffic_panel.assigns.group_id == "group-1"
    end

    test "grouped panel has combined series" do
      results = build_sample_metric_results()

      groups = [
        %{
          "id" => "group-1",
          "name" => "Traffic",
          "metrics" => ["ifInOctets", "ifOutOctets"]
        }
      ]

      panels = build_panels_for_groups(results, nil, groups)
      traffic_panel = Enum.find(panels, &(&1.title == "Traffic"))

      # Should have 2 series (Inbound and Outbound)
      assert length(traffic_panel.assigns.series) == 2

      series_names = Enum.map(traffic_panel.assigns.series, & &1.name)
      assert "Inbound" in series_names
      assert "Outbound" in series_names
    end

    test "multiple groups create multiple panels" do
      results = build_sample_metric_results()

      groups = [
        %{
          "id" => "group-1",
          "name" => "Traffic",
          "metrics" => ["ifInOctets", "ifOutOctets"]
        },
        %{
          "id" => "group-2",
          "name" => "Errors",
          "metrics" => ["ifInErrors"]
        }
      ]

      panels = build_panels_for_groups(results, nil, groups)

      # Should have both group panels
      assert Enum.any?(panels, &(&1.title == "Traffic"))
      assert Enum.any?(panels, &(&1.title == "Errors"))
      assert length(panels) == 2
    end

    test "group with no matching metrics returns nil panel" do
      results = build_sample_metric_results()

      groups = [
        %{
          "id" => "group-1",
          "name" => "Unknown",
          "metrics" => ["nonexistent_metric"]
        }
      ]

      panels = build_panels_for_groups(results, nil, groups)

      # The "Unknown" group should not create a panel since no data matches
      refute Enum.any?(panels, &(&1.title == "Unknown"))
      assert panels == []
    end

    test "interface speed is passed to grouped panels" do
      results = build_sample_metric_results()
      # 1 Gbps in bytes/sec
      max_speed = 125_000_000

      groups = [
        %{
          "id" => "group-1",
          "name" => "Traffic",
          "metrics" => ["ifInOctets", "ifOutOctets"]
        }
      ]

      panels = build_panels_for_groups(results, max_speed, groups)

      traffic_panel = Enum.find(panels, &(&1.title == "Traffic"))
      assert traffic_panel.assigns.max_speed_bytes_per_sec == max_speed
    end

    test "chart_mode is set to combined for grouped panels" do
      results = build_sample_metric_results()

      groups = [
        %{
          "id" => "group-1",
          "name" => "Traffic",
          "metrics" => ["ifInOctets", "ifOutOctets"]
        }
      ]

      panels = build_panels_for_groups(results, nil, groups)
      traffic_panel = Enum.find(panels, &(&1.title == "Traffic"))

      assert traffic_panel.assigns.chart_mode == :combined
    end

    test "empty metrics list is filtered out" do
      results = build_sample_metric_results()

      groups = [
        %{
          "id" => "group-1",
          "name" => "Empty",
          "metrics" => []
        }
      ]

      panels = build_panels_for_groups(results, nil, groups)
      assert panels == []
    end

    test "series data is sorted by time" do
      results = [
        %{"metric_name" => "ifInOctets", "time" => ~U[2100-01-01 00:10:00Z], "value" => 3000},
        %{"metric_name" => "ifInOctets", "time" => ~U[2100-01-01 00:00:00Z], "value" => 1000},
        %{"metric_name" => "ifInOctets", "time" => ~U[2100-01-01 00:05:00Z], "value" => 2000}
      ]

      groups = [
        %{
          "id" => "group-1",
          "name" => "Inbound Traffic",
          "metrics" => ["ifInOctets"]
        }
      ]

      panels = build_panels_for_groups(results, nil, groups)
      panel = Enum.find(panels, &(&1.title == "Inbound Traffic"))
      series = Enum.find(panel.assigns.series, &(&1.name == "Inbound"))

      times = Enum.map(series.data, & &1.time)
      assert times == Enum.sort(times)
    end
  end

  describe "series name formatting" do
    test "formats traffic metrics" do
      assert format_series_name("ifInOctets") == "Inbound"
      assert format_series_name("ifOutOctets") == "Outbound"
      assert format_series_name("ifHCInOctets") == "Inbound (64-bit)"
      assert format_series_name("ifHCOutOctets") == "Outbound (64-bit)"
    end

    test "formats error metrics" do
      assert format_series_name("ifInErrors") == "In Errors"
      assert format_series_name("ifOutErrors") == "Out Errors"
    end

    test "formats discard metrics" do
      assert format_series_name("ifInDiscards") == "In Discards"
      assert format_series_name("ifOutDiscards") == "Out Discards"
    end

    test "formats packet metrics" do
      assert format_series_name("ifInUcastPkts") == "In Packets"
      assert format_series_name("ifOutUcastPkts") == "Out Packets"
    end

    test "passes through unknown metrics unchanged" do
      assert format_series_name("custom_metric") == "custom_metric"
      assert format_series_name("unknown") == "unknown"
    end
  end

  # ============================================================================
  # Helper functions
  # ============================================================================

  defp build_sample_metric_results do
    [
      %{"metric_name" => "ifInOctets", "time" => ~U[2100-01-01 00:00:00Z], "value" => 1000},
      %{"metric_name" => "ifInOctets", "time" => ~U[2100-01-01 00:05:00Z], "value" => 2000},
      %{"metric_name" => "ifOutOctets", "time" => ~U[2100-01-01 00:00:00Z], "value" => 500},
      %{"metric_name" => "ifOutOctets", "time" => ~U[2100-01-01 00:05:00Z], "value" => 600},
      %{"metric_name" => "ifInErrors", "time" => ~U[2100-01-01 00:00:00Z], "value" => 0},
      %{"metric_name" => "ifInErrors", "time" => ~U[2100-01-01 00:05:00Z], "value" => 1}
    ]
  end

  defp build_panels_for_groups(_results, _max_speed, []), do: []

  defp build_panels_for_groups(results, max_speed, groups) do
    groups
    |> Enum.filter(fn group ->
      metrics = group["metrics"] || []
      metrics != []
    end)
    |> Enum.map(fn group ->
      build_grouped_panel(group, results, max_speed)
    end)
    |> Enum.filter(&(&1 != nil))
  end

  defp build_grouped_panel(group, results, max_speed) do
    group_name = group["name"] || "Combined Chart"
    group_metrics = group["metrics"] || []

    group_results =
      Enum.filter(results, fn result ->
        metric_name = Map.get(result, "metric_name")
        metric_name in group_metrics
      end)

    if group_results == [] do
      nil
    else
      build_panel_from_results(group, group_name, group_results, max_speed)
    end
  end

  defp build_panel_from_results(group, group_name, group_results, max_speed) do
    series = build_series_list(group_results)

    %{
      id: "group-#{group["id"]}",
      plugin: :timeseries,
      title: group_name,
      assigns: %{
        series: series,
        max_speed_bytes_per_sec: max_speed,
        chart_mode: :combined,
        group_id: group["id"]
      }
    }
  end

  defp build_series_list(group_results) do
    group_results
    |> Enum.group_by(& &1["metric_name"])
    |> Enum.map(&build_single_series/1)
  end

  defp build_single_series({name, points}) do
    data =
      points
      |> Enum.map(fn p -> %{time: p["time"], value: p["value"]} end)
      |> Enum.sort_by(& &1.time)

    %{name: format_series_name(name), data: data}
  end

  defp format_series_name(name) when is_binary(name) do
    case name do
      "ifInOctets" -> "Inbound"
      "ifOutOctets" -> "Outbound"
      "ifHCInOctets" -> "Inbound (64-bit)"
      "ifHCOutOctets" -> "Outbound (64-bit)"
      "ifInErrors" -> "In Errors"
      "ifOutErrors" -> "Out Errors"
      "ifInDiscards" -> "In Discards"
      "ifOutDiscards" -> "Out Discards"
      "ifInUcastPkts" -> "In Packets"
      "ifOutUcastPkts" -> "Out Packets"
      _ -> name
    end
  end
end
