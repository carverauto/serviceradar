defmodule ServiceRadarWebNGWeb.Components.MetricSectionComponentsTest do
  @moduledoc false

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Table
  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries
  alias ServiceRadarWebNGWeb.DeviceLive.MetricSectionComponents

  @moduletag :unit
  @moduletag :db_free

  test "indexes metric section panel component ids when panels share an engine id" do
    points = [
      {~U[2025-01-01 00:00:00Z], 10.0},
      {~U[2025-01-01 00:05:00Z], 20.0}
    ]

    panel = %{
      id: "timeseries",
      title: "Timeseries",
      plugin: Timeseries,
      assigns: %{
        chart_mode: :single,
        rate_mode: :none,
        series_points: [{"usage_percent", points}],
        spec: %{x: "timestamp", y: "usage_percent"}
      }
    }

    html =
      render_component(&MetricSectionComponents.metric_sections_content/1, %{
        device_uid: "sr:test",
        timezone: "Etc/UTC",
        chart_focus: nil,
        sections: [
          %{
            key: "cpu",
            title: "CPU",
            subtitle: "last 24h",
            panels: [panel, panel],
            error: nil,
            header_stats: nil,
            header_value: nil
          }
        ]
      })

    assert html =~ ~s(id="panel-device-sr:test-cpu-timeseries-0")
    assert html =~ ~s(id="panel-device-sr:test-cpu-timeseries-1")
  end

  test "threads the authenticated timezone into a dashboard table composite timestamp" do
    {:ok, table_assigns} =
      Table.build(%{
        "columns" => ["observed_at"],
        "results" => [%{"observed_at" => "2026-08-30T18:00:00Z, collector-a"}]
      })

    panel = %{id: "table", title: "Observations", plugin: Table, assigns: table_assigns}

    html =
      render_component(&MetricSectionComponents.metric_sections_content/1, %{
        device_uid: "sr:test",
        timezone: "America/Chicago",
        chart_focus: nil,
        sections: [
          %{
            key: "cpu",
            title: "CPU",
            subtitle: "last 24h",
            panels: [panel],
            error: nil,
            header_stats: nil,
            header_value: nil
          }
        ]
      })

    document = LazyHTML.from_fragment(html)
    times = LazyHTML.query(document, "time")

    assert LazyHTML.attribute(times, "datetime") == ["2026-08-30T18:00:00Z"]
    assert LazyHTML.attribute(times, "data-user-time-zone") == ["America/Chicago"]
    assert html =~ "collector-a"
  end
end
