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

  describe "window controls" do
    alias ServiceRadarWebNGWeb.MetricWindowComponents

    defp render_sections(sections, time_range) do
      render_component(&MetricSectionComponents.metric_sections_content/1, %{
        device_uid: "sr:test",
        timezone: "Etc/UTC",
        chart_focus: nil,
        time_range: time_range,
        sections: sections
      })
    end

    defp present?(html, id), do: html |> LazyHTML.from_fragment() |> LazyHTML.query("[id='#{id}']") |> Enum.any?()

    @controls "device-sr:test-metric-window"
    @bounds "device-sr:test-metric-window-bounds"
    @empty "device-sr:test-metric-window-empty"
    @error_section %{
      key: "cpu",
      title: "CPU",
      subtitle: "last 24h",
      panels: [],
      error: "Metrics are unavailable.",
      header_stats: nil,
      header_value: nil
    }

    test "a device with no sections on the default window shows no controls" do
      html = render_sections([], MetricWindowComponents.default_range())

      refute present?(html, @controls)
      refute present?(html, @bounds)
      refute present?(html, @empty)
    end

    test "an empty relative window keeps the controls and says it is empty" do
      html = render_sections([], "last_90d")

      assert present?(html, @controls)
      assert present?(html, "#{@controls}-#{MetricWindowComponents.default_range()}")
      refute present?(html, @bounds)
      assert present?(html, @empty)
      assert html =~ "No metrics in this window."
    end

    test "an empty custom window keeps the controls, its bounds and says it is empty" do
      html = render_sections([], "[2025-01-01T00:00:00Z,2025-01-08T00:00:00Z]")

      assert present?(html, @controls)
      assert present?(html, @bounds)
      assert present?(html, @empty)

      datetimes = html |> LazyHTML.from_fragment() |> LazyHTML.query("time") |> LazyHTML.attribute("datetime")
      assert datetimes == ["2025-01-01T00:00:00Z", "2025-01-08T00:00:00Z"]
    end

    test "an empty window does not claim to be empty while its load is in flight" do
      render = fn loading? ->
        render_component(&MetricSectionComponents.metric_sections_content/1, %{
          device_uid: "sr:test",
          timezone: "Etc/UTC",
          chart_focus: nil,
          time_range: "last_90d",
          metrics_loading: loading?,
          sections: []
        })
      end

      loading = render.(true)
      assert present?(loading, @controls)
      refute present?(loading, @empty)

      assert present?(render.(false), @empty)
    end

    test "sections on any window show the controls and no empty state" do
      for range <- [MetricWindowComponents.default_range(), "last_30d"] do
        html = render_sections([@error_section], range)

        assert present?(html, @controls)
        refute present?(html, @empty)
        assert html =~ "Metrics are unavailable."
      end
    end
  end
end
