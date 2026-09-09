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
      "forecasted_at" => "2026-06-19T00:00:00Z",
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
        detail: %{kind: "anomaly", row: anomaly},
        timezone: "Etc/UTC"
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
    assert html =~ "headroom 22.50%"
    assert html =~ "Finding UID"
    assert html =~ "partition:agent:cpu0"

    capacity_html =
      render_component(&AnomalyCapacityComponents.anomaly_capacity_section/1,
        overview: overview,
        detail: %{kind: "capacity", row: capacity},
        timezone: "Etc/UTC"
      )

    assert capacity_html =~ "Capacity forecast"
    assert capacity_html =~ "projected 91.20%"
    assert capacity_html =~ "headroom 22.50%"
    assert capacity_html =~ "Forecasted"
    assert capacity_html =~ "Projected crossing"
    assert capacity_html =~ "Confidence"
    refute capacity_html =~ "PI coverage"
  end

  test "decodes v2 series identity and uses source identity tags in finding details" do
    series_key =
      Enum.join(
        [
          "v2",
          series_component("partition", "demo"),
          series_component("class", "sysmon"),
          series_component("family", "cpu"),
          series_component("identity", "sr:ns03"),
          series_component("if_index", "20"),
          series_tag_component("core_id", "20"),
          series_tag_component("label", "CPU20")
        ],
        ":"
      )

    anomaly = %{
      "id" => "event-1",
      "finding_uid" => "finding-1",
      "finding_title" => "CPU saturation",
      "metric_class" => "sysmon.cpu",
      "metric_name" => "cpu.usage_percent",
      "metric_value" => 97.5,
      "score" => 8.2,
      "series_key" => series_key,
      "severity" => "High",
      "status" => "anomaly_open",
      "state" => "confirmed",
      "time" => "2026-06-19T00:00:00Z",
      "metadata" => %{
        "source_identity" => %{
          "tags" => %{"core_id" => "20", "label" => "CPU20"}
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
        detail: %{kind: "anomaly", row: anomaly},
        timezone: "Etc/UTC"
      )

    assert html =~ "demo | sysmon/cpu | sr:ns03 | ifIndex 20 | core_id=20 | label=CPU20"
    assert html =~ "CPU20 / ifIndex 20"
    assert html =~ "CPU20 (core 20)"
    assert html =~ ~s(title="#{series_key}")
  end

  test "renders selected edge findings with distinct value and observed-time labels" do
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
        detail: %{kind: "anomaly", row: anomaly},
        timezone: "Etc/UTC"
      )

    assert html =~ "CPU saturation"
    assert html =~ "Finding UID"
    assert html =~ "finding-1"
    assert html =~ "cpu.usage_percent"
    assert html =~ "High"
    assert html =~ "value 97.50"
    assert html =~ "score 4.20"
    assert html =~ "Observed"

    document = LazyHTML.from_fragment(html)
    observed_time = LazyHTML.query(document, "#anomaly-capacity-detail-observed-time")

    assert LazyHTML.attribute(observed_time, "datetime") == ["2026-06-19T00:06:00Z"]
    assert LazyHTML.attribute(observed_time, "data-user-time-zone") == ["Etc/UTC"]
    assert html =~ "breach confirmed after 8/5 consecutive anomalous slots"
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
        detail: %{kind: "anomaly", row: anomaly},
        timezone: "Etc/UTC"
      )

    assert html =~ "partition:agent:cpu0"
    refute html =~ "value partition:agent:cpu0"
  end

  test "explains a cleared flap-merged episode without presenting the opening breach as active" do
    anomaly = %{
      "id" => "episode-cleared-1",
      "finding_uid" => "finding-cleared-1",
      "finding_title" => "breach confirmed after 5/5 consecutive anomalous slots",
      "metric_class" => "interface",
      "metric_name" => "ifOutUcastPkts",
      "severity" => "High",
      "status" => "cleared",
      "state" => "cleared",
      "opening_reason" => "breach confirmed after 5/5 consecutive anomalous slots",
      "resolution_reason" => "anomaly cleared: flap merged",
      "reason" => "anomaly cleared: flap merged",
      "message" => "anomaly cleared: flap merged",
      "time" => "2026-07-18T08:36:00Z",
      "window_ended_at" => "2026-07-18T08:36:00Z"
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
        detail: %{kind: "anomaly", row: anomaly},
        timezone: "Etc/UTC"
      )

    assert html =~ "Resolved: ifOutUcastPkts"
    assert html =~ "This episode is now resolved."
    assert html =~ "briefly cleared and reopened inside the flap window"
    assert html =~ "Original detection trigger"
    assert html =~ "breach confirmed after 5/5 consecutive anomalous slots"
    assert html =~ "How anomaly episode lifecycle works"
    assert html =~ "anomaly-detection#episode-lifecycle"
  end

  test "renders bounded percent forecast values with current headroom" do
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
        detail: %{kind: "capacity", row: capacity},
        timezone: "Etc/UTC"
      )

    assert html =~ "projected 163.46%"
    assert html =~ "headroom 92.96%"
    refute html =~ "current remaining"
    refute html =~ "over threshold 63.46%"
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
              series_points: [{"usage_percent memory_usage", points}]
            }
          }
        ]
      }
    ]

    html =
      render_component(&AnomalyCapacityComponents.anomaly_capacity_section/1,
        overview: overview,
        detail: %{kind: "capacity", row: capacity},
        metric_sections: metric_sections,
        timezone: "Etc/UTC"
      )

    document = LazyHTML.from_fragment(html)

    assert html =~ "Metric context"

    panel_selector = "#panel-anomaly-capacity-detail-memory-memory-context-0"

    assert LazyHTML.attribute(
             LazyHTML.query(document, panel_selector),
             "data-timezone"
           ) == ["Etc/UTC"]

    assert LazyHTML.attribute(
             LazyHTML.query(document, "#{panel_selector} [data-time-axis-iso]"),
             "data-time-axis-iso"
           ) == [
             "2026-06-22T14:00:00Z",
             "2026-06-22T16:00:00Z",
             "2026-06-22T18:00:00Z"
           ]
  end

  test "renders an explicit note when the detail marker is outside the metric context window" do
    capacity = %{
      "finding_title" => "Capacity forecast: memory",
      "metric_class" => "memory",
      "metric_name" => "usage_percent memory_usage",
      "severity" => "Low",
      "status" => "projected",
      "forecasted_at" => "2026-06-22T20:00:00Z",
      "projected_exhaustion_at" => "2026-06-29T20:00:00Z"
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

    points =
      for hour <- 14..18 do
        {DateTime.add(~U[2026-06-22 00:00:00Z], hour * 60 * 60, :second), hour * 1.0}
      end

    metric_sections = [
      %{
        key: "memory",
        title: "Memory",
        subtitle: "around Jun 22 20:00 UTC",
        error: nil,
        panels: [
          %{
            plugin: Timeseries,
            id: "memory-context",
            assigns: %{
              chart_mode: :single,
              rate_mode: :none,
              series_points: [{"usage_percent memory_usage", points}]
            }
          }
        ]
      }
    ]

    html =
      render_component(&AnomalyCapacityComponents.anomaly_capacity_section/1,
        overview: overview,
        detail: %{kind: "capacity", row: capacity},
        metric_sections: metric_sections,
        timezone: "Etc/UTC"
      )

    assert html =~ "data-annotation-window-position=\"after_window\""
    assert html =~ "data-testid=\"timeseries-marker-window-note\""
    assert html =~ "Capacity forecast is after this chart window"
  end

  test "sorts recent anomaly findings newest-first regardless of finding state" do
    rows = [
      confirmed_finding("Confirmed medium finding", "Medium", "2026-09-09T00:21:00Z"),
      cleared_finding("Older cleared low finding", "Low", "2026-09-09T00:19:00Z"),
      cleared_finding("Newest cleared low finding", "Low", "2026-09-09T00:24:00Z")
    ]

    html = render_findings(rows, %{"severity" => "all", "status" => "all", "sort" => "newest"})

    assert_finding_order(html, [
      "Newest cleared low finding",
      "Confirmed medium finding",
      "Older cleared low finding"
    ])
  end

  test "sorts recent anomaly findings oldest-first regardless of finding state" do
    rows = [
      confirmed_finding("Confirmed medium finding", "Medium", "2026-09-09T00:21:00Z"),
      cleared_finding("Older cleared low finding", "Low", "2026-09-09T00:19:00Z"),
      cleared_finding("Newest cleared low finding", "Low", "2026-09-09T00:24:00Z")
    ]

    html = render_findings(rows, %{"severity" => "all", "status" => "all", "sort" => "oldest"})

    assert_finding_order(html, [
      "Older cleared low finding",
      "Confirmed medium finding",
      "Newest cleared low finding"
    ])
  end

  test "sorts recent anomaly findings by severity before recency" do
    rows = [
      cleared_finding("Older cleared low finding", "Low", "2026-09-09T00:19:00Z"),
      cleared_finding("Newest cleared low finding", "Low", "2026-09-09T00:24:00Z"),
      confirmed_finding("Confirmed medium finding", "Medium", "2026-09-09T00:21:00Z"),
      cleared_finding("Old cleared high finding", "High", "2026-09-08T23:58:00Z")
    ]

    html = render_findings(rows, %{"severity" => "all", "status" => "all", "sort" => "severity"})

    assert_finding_order(html, [
      "Old cleared high finding",
      "Confirmed medium finding",
      "Newest cleared low finding",
      "Older cleared low finding"
    ])
  end

  defp render_findings(rows, filters) do
    overview = %{
      status: :ok,
      anomaly_rows: rows,
      capacity_rows: [],
      anomaly_query: "in:events limit:20",
      capacity_query: "in:capacity_forecasts limit:12",
      anomaly_filter: %{field: "service_radar_device_uid", label: "device", value: "router-1"},
      capacity_filter: %{field: "resource_id", label: "device", value: "router-1"},
      anomaly_error: nil,
      capacity_error: nil,
      metric_statuses: []
    }

    render_component(&AnomalyCapacityComponents.anomaly_capacity_section/1,
      overview: overview,
      anomaly_filters: filters,
      timezone: "Etc/UTC"
    )
  end

  defp confirmed_finding(title, severity, time) do
    %{
      "finding_title" => title,
      "metric_name" => "ifInUcastPkts",
      "if_index" => 30,
      "score" => 4.98,
      "severity" => severity,
      "status" => "anomaly_open",
      "state" => "confirmed",
      "time" => time
    }
  end

  defp cleared_finding(title, severity, time) do
    %{
      "finding_title" => title,
      "episode_uid" => "episode-#{Base.encode16(title, case: :lower)}",
      "metric_name" => "ifOutUcastPkts",
      "if_index" => 3,
      "score" => 3.22,
      "severity" => severity,
      "status" => "cleared",
      "state" => "cleared",
      "time" => time
    }
  end

  defp assert_finding_order(html, titles) do
    positions =
      Enum.map(titles, fn title ->
        case :binary.match(html, title) do
          {position, _} -> position
          :nomatch -> flunk("expected finding #{inspect(title)} in rendered findings")
        end
      end)

    assert positions == Enum.sort(positions),
           "expected findings in order #{inspect(titles)}"
  end

  defp series_component(name, value), do: "#{name}=#{series_hex(value)}"
  defp series_tag_component(name, value), do: "tag_#{series_hex(name)}=#{series_hex(value)}"
  defp series_hex(value), do: value |> to_string() |> Base.encode16(case: :lower)
end
