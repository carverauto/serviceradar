defmodule ServiceRadarWebNGWeb.DeviceLive.AnomalyCapacityComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries
  alias ServiceRadarWebNGWeb.DeviceLive.AnomalyCapacityComponents

  @moduletag :db_free

  test "renders actionable anomaly and capacity rows with operator detail" do
    anomaly = %{
      "id" => "event-1",
      "finding_uid" => "finding-1",
      "finding_title" => "CPU saturation",
      "message" => "raw verdict reason should be secondary",
      "metric_class" => "cpu",
      "metric_name" => "cpu.usage_percent",
      "metric_value" => 97.5,
      "threshold_value" => 90.0,
      "score" => 4.2,
      "series_key" => "partition:agent:cpu0",
      "interface_uid" => "if-router-1-1",
      "if_index" => 1,
      "device_label" => "router-1",
      "severity" => "High",
      "status" => "anomaly_open",
      "time" => "2026-06-19T00:00:00Z"
    }

    capacity = %{
      "resource_label" => "Filesystem /",
      "resource_key" => "disk:/",
      "resource_id" => "router-1",
      "metric_name" => "disk.used_percent",
      "metric_class" => "disk",
      "value_unit" => "percent",
      "status" => "projected",
      "model" => "holt_winters",
      "sample_count" => 168,
      "current_value" => 72.5,
      "projected_value" => 91.2,
      "projected_exhaustion_at" => "2026-06-20T00:00:00Z",
      "exhaustion_threshold" => 95.0,
      "confidence" => 0.82,
      "lower_bound" => 88.1,
      "upper_bound" => 93.4,
      "window_started_at" => "2026-06-12T00:00:00Z",
      "window_ended_at" => "2026-06-19T00:00:00Z"
    }

    overview = %{
      status: :ok,
      anomaly_rows: [anomaly],
      capacity_rows: [capacity],
      anomaly_query: "in:events limit:20",
      capacity_query: "in:capacity_forecasts limit:12",
      anomaly_filter: %{field: "service_radar_device_uid", label: "device", value: "router-1"},
      capacity_filter: %{field: "resource_id", label: "device", value: "router-1"},
      anomaly_error: nil,
      capacity_error: nil,
      metric_statuses: []
    }

    html =
      render_component(&AnomalyCapacityComponents.anomaly_capacity_section/1,
        overview: overview,
        detail: %{kind: "anomaly", row: anomaly}
      )

    assert html =~ ~s(phx-click="open_anomaly_capacity_detail")
    assert html =~ ~s(phx-value-kind="anomaly")
    assert html =~ ~s(phx-value-kind="capacity")
    assert html =~ ~s(title="finding-1")
    assert html =~ "CPU saturation"
    assert html =~ "raw verdict reason should be secondary"
    assert html =~ "cpu.usage_percent"
    assert html =~ "value 97.50"
    assert html =~ "score 4.20"
    assert html =~ "disk.used_percent"
    assert html =~ "percent"
    assert html =~ "Finding UID"
    assert html =~ "finding-1"
    assert html =~ "partition:agent:cpu0"

    capacity_html =
      render_component(&AnomalyCapacityComponents.anomaly_capacity_section/1,
        overview: overview,
        detail: %{kind: "capacity", row: capacity}
      )

    assert capacity_html =~ "Capacity forecast"
    assert capacity_html =~ "current 72.50%"
    assert capacity_html =~ "projected 91.20%"
  end

  test "renders bounded percent forecasts as threshold crossings when the horizon value is outside domain" do
    capacity = %{
      "resource_label" => "Filesystem /",
      "resource_key" => "disk:/",
      "resource_id" => "router-1",
      "metric_name" => "disk.used_percent",
      "metric_class" => "disk",
      "value_unit" => "percent",
      "status" => "projected",
      "current_value" => 7.04,
      "projected_value" => 91.2,
      "projected_exhaustion_at" => "2026-08-01T07:00:00Z",
      "exhaustion_threshold" => 100.0,
      "confidence" => 0.994
    }

    overview = %{
      status: :ok,
      anomaly_rows: [],
      capacity_rows: [capacity],
      anomaly_query: "in:events limit:20",
      capacity_query: "in:capacity_forecasts limit:12",
      anomaly_filter: %{field: "service_radar_device_uid", label: "device", value: "router-1"},
      capacity_filter: %{field: "resource_id", label: "device", value: "router-1"},
      anomaly_error: nil,
      capacity_error: nil,
      metric_statuses: []
    }

    html =
      render_component(&AnomalyCapacityComponents.anomaly_capacity_section/1,
        overview: overview,
        detail: %{kind: "capacity", row: capacity}
      )

    assert html =~ "91.20%"
    assert html =~ "headroom 92.96%"
    assert html =~ "confidence 99.4%"
  end

  test "renders selected finding metric context with the full detail focus window" do
    capacity = %{
      "finding_title" => "Capacity forecast: memory",
      "metric_class" => "memory",
      "metric_name" => "usage_percent memory_usage",
      "severity" => "Low",
      "status" => "inactive",
      "time" => "2026-06-22T16:00:00Z"
    }

    overview = %{
      status: :ok,
      anomaly_rows: [capacity],
      capacity_rows: [],
      anomaly_query: "in:events limit:20",
      capacity_query: "in:capacity_forecasts limit:12",
      anomaly_filter: %{field: "service_radar_device_uid", label: "device", value: "router-1"},
      capacity_filter: %{field: "resource_id", label: "device", value: "router-1"},
      anomaly_error: nil,
      capacity_error: nil,
      metric_statuses: []
    }

    points =
      for hour <- 14..18 do
        {DateTime.add(~U[2026-06-22 00:00:00Z], hour * 60 * 60, :second), hour * 1.0}
      end

    metric_sections = [
      %{
        key: "memory",
        title: "Memory",
        subtitle: "around Jun 22 16:00 UTC",
        error: nil,
        panels: [
          %{
            plugin: Timeseries,
            id: "memory-context",
            assigns: %{
              chart_mode: :single,
              rate_mode: :none,
              series_points: [{"series", points}]
            }
          }
        ]
      }
    ]

    html =
      render_component(&AnomalyCapacityComponents.anomaly_capacity_section/1,
        overview: overview,
        detail: %{kind: "capacity", row: capacity},
        metric_sections: metric_sections
      )

    assert html =~ "Metric context"
    assert html =~ "2:00 PM"
    assert html =~ "4:00 PM"
    assert html =~ "6:00 PM"
  end
end
