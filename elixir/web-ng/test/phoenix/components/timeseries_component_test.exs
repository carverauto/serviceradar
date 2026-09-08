defmodule ServiceRadarWebNGWeb.Components.TimeseriesComponentTest do
  @moduledoc """
  Unit tests for the timeseries chart component rendering.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries
  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries.Points

  @moduletag :unit
  @moduletag :db_free

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
    assert html =~ ~s(data-timezone="Etc/UTC")
    assert html =~ ~s(data-time-axis-iso="2025-01-01T00:00:00Z")
    assert html =~ "<text x=\"62\""
    refute html =~ "<text x=\"4\""
  end

  test "carries explicit panel timezone and canonical instants to chart labels" do
    html =
      render_component(Timeseries, %{
        id: "ts-timezone",
        title: "Traffic",
        panel_assigns: %{
          chart_mode: :single,
          rate_mode: :none,
          timezone: "America/Chicago"
        },
        series_points: [
          {"ifInOctets",
           [
             {~U[2026-08-30 18:00:00Z], 1.0},
             {~U[2026-08-30 18:05:00Z], 2.0}
           ]}
        ]
      })

    document = LazyHTML.from_fragment(html)

    assert LazyHTML.attribute(LazyHTML.query(document, "#panel-ts-timezone"), "data-timezone") == [
             "America/Chicago"
           ]

    assert LazyHTML.attribute(LazyHTML.query(document, "[data-time-axis-iso]"), "data-time-axis-iso") ==
             ["2026-08-30T18:00:00Z", "2026-08-30T18:05:00Z"]

    assert LazyHTML.attribute(LazyHTML.query(document, "time"), "data-user-time-zone") ==
             ["America/Chicago", "America/Chicago", "America/Chicago", "America/Chicago"]
  end

  test "series endpoint time IDs remain attached to series identity after reordering" do
    render_ids = fn series_points ->
      Timeseries
      |> render_component(%{
        id: "ts-stable-series-time-ids",
        title: "Traffic",
        panel_assigns: %{chart_mode: :single, rate_mode: :none},
        series_points: series_points
      })
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("time[id^='timeseries-ts-stable-series-time-ids-series-']")
      |> LazyHTML.attribute("id")
      |> Enum.sort()
    end

    points = [
      {~U[2026-08-30 18:00:00Z], 1.0},
      {~U[2026-08-30 18:05:00Z], 2.0}
    ]

    series = [{"cpu.user", points}, {"cpu-user", points}]

    assert render_ids.(series) == render_ids.(Enum.reverse(series))
    assert series |> render_ids.() |> Enum.uniq() |> length() == 4

    assert render_ids.(series) == [
             "timeseries-ts-stable-series-time-ids-series-e-Y3B1LnVzZXI-first-time",
             "timeseries-ts-stable-series-time-ids-series-e-Y3B1LnVzZXI-last-time",
             "timeseries-ts-stable-series-time-ids-series-s-cpu-user-first-time",
             "timeseries-ts-stable-series-time-ids-series-s-cpu-user-last-time"
           ]
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
    assert html =~ "x1=\"246.0\""
    assert html =~ "#EF4444"
  end

  test "renders anomaly chart overlays with windows and peak glyphs" do
    points = [
      {~U[2025-01-01 00:00:00Z], 10.0},
      {~U[2025-01-01 00:10:00Z], 20.0},
      {~U[2025-01-01 00:20:00Z], 30.0}
    ]

    html =
      render_component(Timeseries, %{
        id: "ts-anomaly-overlays",
        title: "Anomaly overlays",
        panel_assigns: %{
          chart_mode: :single,
          rate_mode: :none,
          chart_overlays: [
            %{
              kind: :anomaly,
              dt: ~U[2025-01-01 00:10:00Z],
              window_started_at: ~U[2025-01-01 00:05:00Z],
              window_ended_at: ~U[2025-01-01 00:15:00Z],
              value: 20.0,
              score: 4.7,
              label: "CPU spike",
              severity: "critical",
              disposition: "active",
              reason: "Burst above baseline"
            }
          ]
        },
        series_points: [{"cpu", points}]
      })

    assert html =~ "data-testid=\"timeseries-chart-overlays\""
    assert html =~ "data-testid=\"timeseries-anomaly-window\""
    assert html =~ "data-testid=\"timeseries-overlay-marker\""
    assert html =~ "data-testid=\"timeseries-overlay-value\""
    assert html =~ "data-overlay-label=\"CPU spike\""
    assert html =~ "score 4.7"
    assert html =~ "Burst above baseline"
  end

  test "renders in-window capacity runway and omits out-of-window forecast marks" do
    points = [
      {~U[2025-01-01 00:00:00Z], 50.0},
      {~U[2025-01-01 00:10:00Z], 60.0},
      {~U[2025-01-01 00:20:00Z], 70.0}
    ]

    html =
      render_component(Timeseries, %{
        id: "ts-capacity-overlays",
        title: "Capacity overlays",
        panel_assigns: %{
          chart_mode: :single,
          rate_mode: :none,
          reference_lines: [
            %{value: 90.0, label: "Capacity threshold", severity: "critical"}
          ],
          chart_overlays: [
            %{
              kind: :capacity,
              forecasted_at: ~U[2025-01-01 00:00:00Z],
              projected_exhaustion_at: ~U[2025-01-01 00:20:00Z],
              current_value: 55.0,
              projected_value: 80.0,
              threshold_value: 90.0,
              lower_bound: 75.0,
              upper_bound: 85.0,
              label: "Capacity forecast",
              severity: "critical"
            },
            %{
              kind: :capacity,
              forecasted_at: ~U[2025-01-01 00:00:00Z],
              projected_exhaustion_at: ~U[2025-01-02 00:00:00Z],
              current_value: 55.0,
              projected_value: 80.0,
              lower_bound: 75.0,
              upper_bound: 85.0,
              label: "Out-of-window forecast",
              severity: "warning"
            }
          ]
        },
        spec: %{x: "timestamp", y: "used_percent", series: "label"},
        series_points: [{"disk", points}]
      })

    assert html =~ "data-testid=\"timeseries-capacity-runway\""
    assert html =~ "data-testid=\"timeseries-capacity-confidence\""
    assert html =~ "data-overlay-label=\"Capacity forecast\""
    refute html =~ "data-overlay-label=\"Out-of-window forecast\""
  end

  test "focuses a finding on its matching series and time window" do
    points =
      for minute <- 0..20 do
        {DateTime.add(~U[2025-01-01 00:00:00Z], minute, :minute), minute * 1.0}
      end

    html =
      render_component(Timeseries, %{
        id: "ts-focused-finding",
        title: "Focused finding",
        panel_assigns: %{
          chart_mode: :single,
          rate_mode: :none,
          chart_focus: %{
            timestamp: ~U[2025-01-01 00:10:00Z],
            label: "CPU saturation",
            severity: "critical",
            series: "cpu1",
            window_seconds: 60
          }
        },
        series_points: [
          {"cpu0", points},
          {"cpu1", points}
        ]
      })

    assert html =~ "CPU saturation"
    assert html =~ "data-annotation-label=\"CPU saturation\""
    assert html =~ "x1=\"420.0\""
    assert html =~ "cpu1"
    refute html =~ "cpu0"
    assert html =~ ~s(data-time-axis-iso="2025-01-01T00:09:00Z")
    assert html =~ ~s(data-time-axis-iso="2025-01-01T00:11:00Z")
    refute html =~ ~s(data-time-axis-iso="2025-01-01T00:00:00Z")
    refute html =~ ~s(data-time-axis-iso="2025-01-01T00:20:00Z")
  end

  test "clamps out-of-window finding focus markers to the chart edge" do
    points = [
      {~U[2025-01-01 00:00:00Z], 10.0},
      {~U[2025-01-01 00:10:00Z], 20.0},
      {~U[2025-01-01 00:20:00Z], 30.0}
    ]

    html =
      render_component(Timeseries, %{
        id: "ts-focused-outside-window",
        title: "Focused finding",
        panel_assigns: %{
          chart_mode: :single,
          rate_mode: :none,
          chart_focus: %{
            timestamp: ~U[2025-01-01 01:00:00Z],
            label: "Capacity forecast",
            severity: "warning",
            series: "disk",
            window_seconds: 60
          }
        },
        series_points: [{"disk", points}]
      })

    assert html =~ "data-testid=\"timeseries-annotation\""
    assert html =~ "data-annotation-window-position=\"after_window\""
    assert html =~ "x1=\"768\""
    assert html =~ "data-testid=\"timeseries-marker-window-note\""
    assert html =~ "Capacity forecast is after this chart window"
  end

  test "renders threshold reference lines and includes them in the y domain" do
    points = [
      {~U[2025-01-01 00:00:00Z], 10.0},
      {~U[2025-01-01 00:10:00Z], 20.0},
      {~U[2025-01-01 00:20:00Z], 30.0}
    ]

    html =
      render_component(Timeseries, %{
        id: "ts-threshold",
        title: "Threshold",
        panel_assigns: %{
          chart_mode: :single,
          rate_mode: :none,
          reference_lines: [
            %{
              value: 80.0,
              label: "Warning threshold",
              severity: "warning",
              series: "cpu"
            }
          ]
        },
        spec: %{x: "timestamp", y: "usage_percent", series: "label"},
        series_points: [{"cpu", points}]
      })

    assert html =~ "data-testid=\"timeseries-reference-lines\""
    assert html =~ "data-testid=\"timeseries-reference-line\""
    assert html =~ "data-reference-label=\"Warning threshold\""
    assert html =~ "data-reference-severity=\"warning\""
    assert html =~ "data-reference-series=\"cpu\""
    assert html =~ "Warning threshold - 80.0%"
  end

  test "renders threshold reference lines and includes them in chart scale" do
    points = [
      {~U[2025-01-01 00:00:00Z], 10.0},
      {~U[2025-01-01 00:10:00Z], 20.0},
      {~U[2025-01-01 00:20:00Z], 30.0}
    ]

    html =
      render_component(Timeseries, %{
        id: "ts-reference-lines",
        title: "Thresholds",
        panel_assigns: %{
          chart_mode: :single,
          rate_mode: :none,
          reference_lines: [
            %{
              value: 80.0,
              label: "CPU >= 80%",
              severity: "warning",
              series: "cpu"
            }
          ]
        },
        series_points: [{"cpu", points}]
      })

    assert html =~ "data-testid=\"timeseries-reference-lines\""
    assert html =~ "data-testid=\"timeseries-reference-line\""
    assert html =~ "data-reference-label=\"CPU &gt;= 80%\""
    assert html =~ "data-reference-severity=\"warning\""
    assert html =~ "data-reference-series=\"cpu\""
    assert html =~ "#EAB308"
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

  test "renders non-color markers with solid strokes for multi-series charts" do
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
    assert html =~ ~s(data-series-shape="circle")
    assert html =~ ~s(data-series-shape="square")
    refute html =~ ~s(stroke-dasharray="6 4")
    refute html =~ ~s(stroke-dasharray="2 3")
  end

  test "renders compact combined charts full width instead of inside the series card grid" do
    points = [
      {~U[2025-01-01 00:00:00Z], 10.0},
      {~U[2025-01-01 00:05:00Z], 20.0},
      {~U[2025-01-01 00:10:00Z], 30.0}
    ]

    html =
      render_component(Timeseries, %{
        id: "ts-compact-combined",
        title: "CPU",
        panel_assigns: %{
          compact: true,
          chart_mode: :single,
          rate_mode: :none,
          combine_all_series: true,
          combined_title: "CPU cores"
        },
        spec: %{x: "timestamp", y: "usage_percent", series: "label"},
        series_points: [{"0", points}, {"1", points}, {"2", points}]
      })

    assert html =~ ~s(id="combined-chart-ts-compact-combined")
    assert html =~ "CPU cores"
    refute html =~ "lg:grid-cols-2 xl:grid-cols-3"
  end

  test "renders a compact title above individual series grids" do
    points = [
      {~U[2025-01-01 00:00:00Z], 10.0},
      {~U[2025-01-01 00:05:00Z], 20.0}
    ]

    html =
      render_component(Timeseries, %{
        id: "ts-compact-title",
        title: "CPU",
        panel_assigns: %{
          compact: true,
          chart_mode: :single,
          rate_mode: :none,
          compact_title: "Top cores"
        },
        spec: %{x: "timestamp", y: "usage_percent", series: "core_id"},
        series_points: [{"15", points}, {"16", points}]
      })

    assert html =~ "Top cores"
    assert html =~ "lg:grid-cols-2 xl:grid-cols-3"
    refute html =~ ~s(id="combined-chart-ts-compact-title")
  end

  test "prefers SRQL metric unit metadata over field-name inference" do
    points = [
      {~U[2025-01-01 00:00:00Z], 1024.0},
      {~U[2025-01-01 00:05:00Z], 4096.0}
    ]

    html =
      render_component(Timeseries, %{
        id: "ts-unit-metadata",
        title: "Disk",
        panel_assigns: %{chart_mode: :single, rate_mode: :none},
        spec: %{x: "timestamp", y: "value", series: "label", series_units: %{"disk" => :bytes}},
        series_points: [{"disk", points}]
      })

    assert html =~ ~s(data-unit="bytes")
    assert html =~ "4.1 KB"
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

  test "downsampling preserves bucket minima and maxima" do
    start_dt = ~U[2025-01-01 00:00:00Z]
    spike_dt = DateTime.add(start_dt, 457, :second)
    dip_dt = DateTime.add(start_dt, 612, :second)

    points =
      for idx <- 0..999 do
        dt = DateTime.add(start_dt, idx, :second)

        value =
          cond do
            dt == spike_dt -> 999.0
            dt == dip_dt -> -50.0
            true -> 10.0
          end

        {dt, value}
      end

    limited = Points.limit_points(points, 80)

    assert length(limited) <= 80
    assert List.first(limited) == List.first(points)
    assert List.last(limited) == List.last(points)
    assert {spike_dt, 999.0} in limited
    assert {dip_dt, -50.0} in limited

    assert limited ==
             Enum.sort_by(limited, fn {dt, _value} -> DateTime.to_unix(dt, :microsecond) end)
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

    assert html =~ "2.19"
    assert html =~ "45.7"
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
