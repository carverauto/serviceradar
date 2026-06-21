defmodule ServiceRadarWebNGWeb.DeviceLive.AnomalyCapacityComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

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
      anomaly_filter: %{field: "device_uid_exact", label: "device", value: "router-1"},
      capacity_filter: %{field: "resource_id", label: "device", value: "router-1"},
      anomaly_error: nil,
      capacity_error: nil,
      metric_statuses: []
    }

    html =
      render_component(&AnomalyCapacityComponents.anomaly_capacity_section/1,
        overview: overview,
        selected_detail: %{kind: "anomaly", row: anomaly}
      )

    assert html =~ ~s(phx-click="open_anomaly_capacity_detail")
    assert html =~ ~s(phx-value-kind="anomaly")
    assert html =~ ~s(phx-value-kind="capacity")
    assert html =~ ~s(title="finding-1")
    assert html =~ "CPU saturation"
    assert html =~ "raw verdict reason should be secondary"
    assert html =~ "CPU / cpu.usage_percent"
    assert html =~ "value 97.50"
    assert html =~ "score 4.20"
    assert html =~ "disk.used_percent"
    assert html =~ "percent"
    assert html =~ "headroom 3.80%"
    assert html =~ "Finding UID"
    assert html =~ "partition:agent:cpu0"
  end
end
