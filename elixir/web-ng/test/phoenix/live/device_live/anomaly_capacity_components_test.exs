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
      "anomaly_disposition" => %{
        "action" => "escalate",
        "seasonal_disposition" => "seasonal_breach",
        "seasonal_status" => "breach",
        "seasonal_score" => 4.8,
        "seasonal_window_started_at" => "2026-06-19T00:00:00Z",
        "seasonal_window_ended_at" => "2026-06-19T01:00:00Z",
        "seasonal_evaluated_at" => "2026-06-19T01:05:00Z",
        "reason" => "central_seasonal_breach"
      },
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
    assert html =~ "CPU / cpu.usage_percent"
    assert html =~ "value 97.50"
    assert html =~ "score 4.20"
    assert html =~ "disk.used_percent"
    assert html =~ "percent"
    assert html =~ "current remaining 22.50%"
    assert html =~ "Finding UID"
    assert html =~ "partition:agent:cpu0"
    assert html =~ "Alert disposition"
    assert html =~ "escalated"
    assert html =~ "Central seasonal context also found this series off baseline"
    assert html =~ "seasonal_breach"
    assert html =~ "central seasonal breach"

    capacity_html =
      render_component(&AnomalyCapacityComponents.anomaly_capacity_section/1,
        overview: overview,
        detail: %{kind: "capacity", row: capacity}
      )

    assert capacity_html =~ "Projection"
    assert capacity_html =~ "projected 91.20%"
    assert capacity_html =~ "current remaining 22.50%"
  end

  test "renders edge episode evidence with distinct peak and confirmation labels" do
    episode_started = ~U[2026-06-19 00:00:00Z]
    episode_peak = ~U[2026-06-19 00:04:00Z]
    finding_emitted = ~U[2026-06-19 00:06:00Z]
    episode_cleared = ~U[2026-06-19 00:10:00Z]

    anomaly = %{
      "id" => "event-1",
      "finding_uid" => "finding-1",
      "finding_title" => "CPU saturation",
      "message" => "breach confirmed after 8/5 consecutive anomalous slots",
      "metric_class" => "cpu",
      "metric_name" => "cpu.usage_percent",
      "metric_value" => 97.5,
      "score" => 4.2,
      "severity" => "High",
      "status" => "anomaly_open",
      "time" => DateTime.to_iso8601(finding_emitted),
      "metadata" => %{
        "finding_info" => %{
          "dimensions" => %{
            "consecutive_anomalous" => 8,
            "episode_started_at_unix_nano" => DateTime.to_unix(episode_started, :nanosecond),
            "episode_peak_at_unix_nano" => DateTime.to_unix(episode_peak, :nanosecond),
            "episode_peak_value" => 97.5,
            "observed_at_unix_nano" => DateTime.to_unix(finding_emitted, :nanosecond),
            "episode_ended_at_unix_nano" => DateTime.to_unix(episode_cleared, :nanosecond),
            "signals" => [
              %{
                "name" => "rolling_baseline",
                "enabled" => true,
                "ready" => true,
                "breached" => true,
                "score" => 4.2,
                "threshold" => 3.0,
                "sample_count" => 300,
                "mean" => 12.0,
                "stddev" => 2.0,
                "reason" => "rolling_baseline z-score 4.200 breached 3.000"
              }
            ]
          }
        }
      }
    }

    overview = %{
      status: :ok,
      anomaly_rows: [anomaly],
      capacity_rows: [],
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

    assert html =~ "Edge detector evidence"
    assert html =~ "edge spike detector"
    assert html =~ "Chart markers use the episode"
    assert html =~ "shaded chart window"
    assert html =~ "Seasonal or causal disposition"
    assert html =~ "CPU raw samples are max-aggregated into 30-second evaluation slots"
    assert html =~ "short high-CPU spike can be visible on the chart"
    assert html =~ "Opened because 8 of 5 consecutive evaluation slots breached the detector."
    assert html =~ "8 consecutive slots"
    assert html =~ "Episode start"
    assert html =~ "Peak sample"
    assert html =~ "Finding emitted"
    assert html =~ "Episode clear"
    assert html =~ "rolling_baseline"
    assert html =~ "breached"
    assert html =~ "4.20 / 3.00"
    assert html =~ "mean 12.00"
  end

  test "does not treat opaque series keys as anomaly values" do
    anomaly = %{
      "id" => "event-opaque",
      "finding_uid" => "finding-opaque",
      "finding_title" => "Opaque key anomaly",
      "message" => "breach confirmed after 5/5 consecutive anomalous slots",
      "metric_class" => "cpu",
      "metric_name" => "cpu.usage_percent",
      "series_key" => "partition:agent:cpu0",
      "severity" => "High",
      "status" => "anomaly_open",
      "time" => "2026-06-19T00:06:00Z"
    }

    overview = %{
      status: :ok,
      anomaly_rows: [anomaly],
      capacity_rows: [],
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

    assert html =~ "partition:agent:cpu0"
    refute html =~ "value partition:agent:cpu0"
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
      "projected_value" => 163.46,
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

    assert html =~ "crosses 100.00%"
    assert html =~ "current remaining 92.96%"
    refute html =~ "163.46%"
    refute html =~ "over threshold 63.46%"
  end
end
