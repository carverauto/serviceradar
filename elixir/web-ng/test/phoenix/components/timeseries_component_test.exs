defmodule ServiceRadarWebNGWeb.Components.TimeseriesComponentTest do
  @moduledoc """
  Unit tests for the timeseries chart component rendering.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries

  @moduletag :unit

  test "renders gridlines and axis labels" do
    points = [
      {~U[2025-01-01 00:00:00Z], 0.0},
      {~U[2025-01-01 00:05:00Z], 1024.0},
      {~U[2025-01-01 00:10:00Z], 2048.0},
      {~U[2025-01-01 00:15:00Z], 4096.0}
    ]

    series_points = [{"ifInOctets", points}]

    html =
      render_component(Timeseries, %{
        id: "ts-axes",
        title: "Traffic",
        panel_assigns: %{chart_mode: :single, rate_mode: :none},
        series_points: series_points
      })

    assert html =~ "stroke-dasharray=\"3 4\""
    assert html =~ "12:00 AM"
  end

  test "renders timestamp annotations as SVG markers" do
    points = [
      {~U[2025-01-01 00:00:00Z], 10.0},
      {~U[2025-01-01 00:10:00Z], 20.0},
      {~U[2025-01-01 00:20:00Z], 30.0}
    ]

    html =
      render_component(Timeseries, %{
        id: "ts-annotations",
        title: "Annotated",
        panel_assigns: %{
          chart_mode: :single,
          rate_mode: :none,
          annotations: [
            %{
              dt: ~U[2025-01-01 00:05:00Z],
              label: "Anomaly finding",
              severity: "critical"
            }
          ]
        },
        series_points: [{"cpu", points}]
      })

    assert html =~ "data-testid=\"timeseries-annotations\""
    assert html =~ "data-testid=\"timeseries-annotation\""
    assert html =~ "data-annotation-label=\"Anomaly finding\""
    assert html =~ "data-annotation-severity=\"critical\""
    assert html =~ "x1=\"204.0\""
    assert html =~ "#EF4444"
  end

  test "formats percent axis labels for usage percent metrics" do
    points = [
      {~U[2025-01-01 00:00:00Z], 10.0},
      {~U[2025-01-01 00:05:00Z], 55.5},
      {~U[2025-01-01 00:10:00Z], 90.0}
    ]

    series_points = [{"cpu", points}]

    html =
      render_component(Timeseries, %{
        id: "ts-percent",
        title: "CPU",
        panel_assigns: %{chart_mode: :single, rate_mode: :none},
        spec: %{x: "timestamp", y: "usage_percent", series: "label"},
        series_points: series_points
      })

    assert html =~ "%"
  end

  test "renders non-color stroke patterns for multi-series charts" do
    points = [
      {~U[2025-01-01 00:00:00Z], 10.0},
      {~U[2025-01-01 00:05:00Z], 20.0},
      {~U[2025-01-01 00:10:00Z], 30.0}
    ]

    html =
      render_component(Timeseries, %{
        id: "ts-patterns",
        title: "Patterns",
        panel_assigns: %{chart_mode: :single, rate_mode: :none, combine_all_series: true},
        spec: %{x: "timestamp", y: "value", series: "label"},
        series_points: [{"cpu0", points}, {"cpu1", points}]
      })

    assert html =~ "cpu0"
    assert html =~ "cpu1"
    assert html =~ "stroke-dasharray=\"6 4\""
  end

  test "prefers SRQL metric unit metadata over value field-name inference" do
    points = [
      {~U[2025-01-01 00:00:00Z], 1024.0},
      {~U[2025-01-01 00:05:00Z], 2048.0},
      {~U[2025-01-01 00:10:00Z], 4096.0}
    ]

    html =
      render_component(Timeseries, %{
        id: "ts-row-unit",
        title: "Row Unit",
        panel_assigns: %{chart_mode: :single, rate_mode: :none},
        spec: %{x: "timestamp", y: "value", series: "label", series_units: %{"disk" => :bytes}},
        series_points: [{"disk", points}]
      })

    assert html =~ "4.1 KB"
  end

  test "preserves measured bytes per second spikes without interpolation or smoothing" do
    points = [
      {~U[2025-01-01 00:00:00Z], 0.0},
      {~U[2025-01-01 00:05:00Z], 1000.0},
      {~U[2025-01-01 00:10:00Z], 0.0}
    ]

    html =
      render_component(Timeseries, %{
        id: "ts-measured-rate",
        title: "Measured rate",
        panel_assigns: %{chart_mode: :single, rate_mode: :none},
        spec: %{x: "timestamp", y: "value", series: "label", series_units: %{"traffic" => :bytes_per_sec}},
        series_points: [{"traffic", points}]
      })

    chart_points = decode_chart_points(html)

    assert Enum.map(chart_points, & &1["v"]) == [0.0, 1000.0, 0.0]
    assert length(chart_points) == 3
    assert html =~ "1.0 KB/s"
  end

  test "keeps bit and byte rate row units distinct" do
    assert {:ok, bit_assigns} =
             Timeseries.build(%{
               "viz" => %{
                 "suggestions" => [
                   %{"kind" => "timeseries", "x" => "timestamp", "y" => "value", "series" => "label"}
                 ]
               },
               "results" => [
                 %{
                   "timestamp" => "2025-01-01T00:00:00Z",
                   "value" => 1_000.0,
                   "label" => "bits",
                   "metric.unit" => "b/s"
                 }
               ]
             })

    bit_html =
      render_component(Timeseries, %{
        id: "ts-bits-row-unit",
        title: "Bits",
        panel_assigns: Map.put(bit_assigns, :rate_mode, :none)
      })

    assert bit_html =~ "data-unit=\"bits_per_sec\""
    assert bit_html =~ "1.0 Kbit/s"
    refute bit_html =~ "1.0 KB/s"

    assert {:ok, byte_assigns} =
             Timeseries.build(%{
               "viz" => %{
                 "suggestions" => [
                   %{"kind" => "timeseries", "x" => "timestamp", "y" => "value", "series" => "label"}
                 ]
               },
               "results" => [
                 %{
                   "timestamp" => "2025-01-01T00:00:00Z",
                   "value" => 1_000.0,
                   "label" => "bytes",
                   "metric.unit" => "By/s"
                 }
               ]
             })

    byte_html =
      render_component(Timeseries, %{
        id: "ts-bytes-row-unit",
        title: "Bytes",
        panel_assigns: Map.put(byte_assigns, :rate_mode, :none)
      })

    assert byte_html =~ "data-unit=\"bytes_per_sec\""
    assert byte_html =~ "1.0 KB/s"
    refute byte_html =~ "1.0 Kbit/s"
  end

  test "downsamples with a min max envelope so narrow spikes survive" do
    points =
      Enum.map(0..1000, fn idx ->
        value = if idx == 501, do: 10_000.0, else: 10.0
        {DateTime.add(~U[2025-01-01 00:00:00Z], idx * 60, :second), value}
      end)

    html =
      render_component(Timeseries, %{
        id: "ts-envelope-downsample",
        title: "Envelope",
        panel_assigns: %{chart_mode: :single, rate_mode: :none},
        spec: %{x: "timestamp", y: "value", series: "label"},
        series_points: [{"samples", points}]
      })

    chart_points = decode_chart_points(html)
    values = Enum.map(chart_points, & &1["v"])

    assert length(chart_points) <= 800
    assert List.first(values) == 10.0
    assert List.last(values) == 10.0
    assert 10_000.0 in values
  end

  test "scales numeric y axis to the data band instead of forcing zero" do
    points = [
      {~U[2025-01-01 00:00:00Z], 80.0},
      {~U[2025-01-01 00:05:00Z], 85.0},
      {~U[2025-01-01 00:10:00Z], 90.0}
    ]

    html =
      render_component(Timeseries, %{
        id: "ts-band",
        title: "Narrow band",
        panel_assigns: %{chart_mode: :single, rate_mode: :none},
        spec: %{x: "timestamp", y: "gauge_value", series: "label"},
        series_points: [{"gauge", points}]
      })

    assert html =~ "79.5"
    assert html =~ "90.5"
  end

  test "supports opt-in log scale for timeseries panels" do
    points = [
      {~U[2025-01-01 00:00:00Z], 1.0},
      {~U[2025-01-01 00:05:00Z], 10.0},
      {~U[2025-01-01 00:10:00Z], 100.0}
    ]

    html =
      render_component(Timeseries, %{
        id: "ts-log",
        title: "Log scale",
        panel_assigns: %{chart_mode: :single, rate_mode: :none, scale_mode: :log},
        spec: %{x: "timestamp", y: "gauge_value", series: "label"},
        series_points: [{"gauge", points}]
      })

    assert html =~ "2.51"
    assert html =~ "39.81"
  end

  test "counter rates drop the synthetic first zero and render resets as gaps" do
    points = [
      {~U[2025-01-01 00:00:00Z], 1_000.0},
      {~U[2025-01-01 00:05:00Z], 7_000.0},
      {~U[2025-01-01 00:10:00Z], 100.0},
      {~U[2025-01-01 00:15:00Z], 3_100.0}
    ]

    html =
      render_component(Timeseries, %{
        id: "ts-counter-gap",
        title: "Traffic",
        panel_assigns: %{chart_mode: :single, rate_mode: :counter},
        series_points: [{"ifInOctets", points}]
      })

    assert html =~ "&quot;v&quot;:null"
    refute html =~ "&quot;v&quot;:0.0"
    assert html =~ ~r/d="M [^"]+ M /
  end

  test "precomputed rate mode preserves backend rates without counter differencing" do
    points = [
      {~U[2025-01-01 00:00:00Z], 125.0},
      {~U[2025-01-01 00:05:00Z], 250.0}
    ]

    html =
      render_component(Timeseries, %{
        id: "ts-precomputed-rate",
        title: "Traffic",
        panel_assigns: %{chart_mode: :single, rate_mode: :rate},
        series_points: [{"ifInOctets", points}]
      })

    chart_points = decode_chart_points(html)

    assert Enum.map(chart_points, & &1["v"]) == [125.0, 250.0]
    assert html =~ "250.0 B/s"
  end

  test "counter speed clamp applies only to octet traffic series" do
    points = [
      {~U[2025-01-01 00:00:00Z], 0.0},
      {~U[2025-01-01 00:05:00Z], 300_000.0}
    ]

    html =
      render_component(Timeseries, %{
        id: "ts-counter-errors",
        title: "Errors",
        panel_assigns: %{chart_mode: :single, rate_mode: :counter, max_speed_bytes_per_sec: 100},
        series_points: [{"ifInErrors", points}]
      })

    assert html =~ "1.0 K/s"
    refute html =~ "100.0 /s"
  end

  test "renders an explicit no-data state instead of an empty chart" do
    html =
      render_component(Timeseries, %{
        id: "ts-empty",
        title: "Empty",
        panel_assigns: %{chart_mode: :single, rate_mode: :none},
        series_points: []
      })

    assert html =~ "No chart data"
    assert html =~ "No samples matched this chart"
    refute html =~ "phx-hook=\"TimeseriesChart\""
  end

  test "renders query-error and disabled states distinctly" do
    error_html =
      render_component(Timeseries, %{
        id: "ts-query-error",
        title: "Query error",
        panel_assigns: %{
          chart_mode: :single,
          rate_mode: :none,
          empty_state: :query_error,
          error_message: "SRQL timeout while loading samples"
        },
        series_points: []
      })

    assert error_html =~ "Chart query failed"
    assert error_html =~ "The chart query failed before returning usable data."
    refute error_html =~ "SRQL timeout while loading samples"
    assert error_html =~ "border-error"

    safe_detail_html =
      render_component(Timeseries, %{
        id: "ts-query-error-safe-detail",
        title: "Query error",
        panel_assigns: %{
          chart_mode: :single,
          rate_mode: :none,
          empty_state: :query_error,
          empty_detail: "Could not load metric samples for this chart.",
          error_message: "SRQL timeout while loading samples"
        },
        series_points: []
      })

    assert safe_detail_html =~ "Could not load metric samples for this chart."
    refute safe_detail_html =~ "SRQL timeout while loading samples"

    disabled_html =
      render_component(Timeseries, %{
        id: "ts-disabled",
        title: "Disabled",
        panel_assigns: %{
          chart_mode: :single,
          rate_mode: :none,
          empty_state: :disabled,
          empty_config_href: "/settings/snmp",
          empty_config_label: "SNMP settings"
        },
        series_points: []
      })

    assert disabled_html =~ "Metrics collection disabled"
    assert disabled_html =~ "Enable the relevant SNMP or polling configuration"
    assert disabled_html =~ "href=\"/settings/snmp\""
    assert disabled_html =~ "SNMP settings"
    assert disabled_html =~ "border-warning"
  end

  defp decode_chart_points(html) do
    [_, encoded] = Regex.run(~r/data-points="([^"]+)"/, html)

    encoded
    |> String.replace("&quot;", "\"")
    |> Jason.decode!()
  end
end
