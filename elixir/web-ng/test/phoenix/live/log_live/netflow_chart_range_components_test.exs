defmodule ServiceRadarWebNGWeb.LogLive.NetflowChartRangeComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNGWeb.LogLive.Index
  alias ServiceRadarWebNGWeb.Netflow.RangeSelection

  @moduletag :db_free

  test "Lines exposes canonical selection geometry without replacing tooltip or bucket clicks" do
    document = render_timeseries(:lines, points())
    selector = LazyHTML.query(document, "#netflow-traffic-timeseries")
    svg = LazyHTML.query(selector, "svg[data-range-svg]")

    assert LazyHTML.attribute(selector, "phx-hook") == ["NetflowTrafficTooltip"]
    assert LazyHTML.attribute(selector, "data-timezone") == ["America/Chicago"]
    assert LazyHTML.attribute(selector, "data-range-event") == ["netflow_range_selected"]
    assert LazyHTML.attribute(selector, "role") == ["group"]
    assert LazyHTML.attribute(selector, "tabindex") == ["0"]
    assert LazyHTML.attribute(selector, "aria-describedby") == ["netflow-traffic-range-instructions"]
    assert selector |> LazyHTML.attribute("class") |> Enum.any?(&String.contains?(&1, "touch-pan-y"))
    assert one?(LazyHTML.query(selector, "#netflow-traffic-range-instructions"))
    assert one?(LazyHTML.query(selector, "[data-range-status][aria-live='polite']"))
    assert one?(LazyHTML.query(svg, "[data-range-surface]"))

    overlay = LazyHTML.query(svg, "[data-range-overlay]")
    assert overlay |> LazyHTML.attribute("class") |> Enum.any?(&String.contains?(&1, "hidden"))
    assert LazyHTML.attribute(overlay, "pointer-events") == ["none"]
    assert LazyHTML.attribute(overlay, "y") == ["10"]
    assert LazyHTML.attribute(overlay, "height") == ["140"]

    assert decode_attribute(selector, "data-range-buckets") == [
             %{
               "x" => 0.0,
               "start" => "2026-08-27T10:00:00Z",
               "end" => "2026-08-27T10:04:59.999999Z"
             },
             %{
               "x" => 500.0,
               "start" => "2026-08-27T10:05:00Z",
               "end" => "2026-08-27T10:09:59.999999Z"
             },
             %{
               "x" => 1000.0,
               "start" => "2026-08-27T10:10:00Z",
               "end" => "2026-08-27T10:14:59.999999Z"
             }
           ]

    assert LazyHTML.attribute(LazyHTML.query(svg, "polyline:not([stroke-dasharray])"), "points") == [
             "0.0,103.3 500.0,56.7 1.0e3,10.0"
           ]

    assert LazyHTML.attribute(LazyHTML.query(svg, "circle"), "cx") == ["0.0", "500.0", "1.0e3"]
    assert_bucket_clicks(svg)

    assert LazyHTML.text(LazyHTML.query(svg, "circle title")) =~
             "window: 2026-08-27T10:00:00Z → 2026-08-27T10:04:59.999999Z"

    axis_times = LazyHTML.query(svg, "text[data-netflow-time='axis']")

    assert LazyHTML.attribute(axis_times, "data-time-iso") == [
             "2026-08-27T10:00:00Z",
             "2026-08-27T10:05:00Z",
             "2026-08-27T10:15:00Z"
           ]

    assert LazyHTML.attribute(axis_times, "data-time-fallback") == [
             "2026-08-27T10:00:00Z",
             "2026-08-27T10:05:00Z",
             "2026-08-27T10:15:00Z"
           ]

    titles = LazyHTML.query(svg, "title[data-netflow-time='range-title']")

    assert LazyHTML.attribute(titles, "data-time-start") == [
             "2026-08-27T10:00:00Z",
             "2026-08-27T10:05:00Z",
             "2026-08-27T10:10:00Z"
           ]

    assert LazyHTML.attribute(titles, "data-time-end") == [
             "2026-08-27T10:04:59.999999Z",
             "2026-08-27T10:09:59.999999Z",
             "2026-08-27T10:14:59.999999Z"
           ]

    assert LazyHTML.attribute(titles, "data-time-fallback") == [
             "window: 2026-08-27T10:00:00Z → 2026-08-27T10:04:59.999999Z\nbytes: 100 B\navg rate: 3.0 bps",
             "window: 2026-08-27T10:05:00Z → 2026-08-27T10:09:59.999999Z\nbytes: 200 B\navg rate: 5.0 bps",
             "window: 2026-08-27T10:10:00Z → 2026-08-27T10:14:59.999999Z\nbytes: 300 B\navg rate: 8.0 bps"
           ]

    assert_semantic_window_endpoint(
      selector,
      "netflow-chart-window-start",
      "2026-08-27T10:00:00Z"
    )

    assert_semantic_window_endpoint(
      selector,
      "netflow-chart-window-end",
      "2026-08-27T10:15:00Z"
    )

    assert decode_attribute(selector, "data-points") == [
             %{
               "bucket_seconds" => 300,
               "bytes" => 100,
               "start" => "2026-08-27T10:00:00Z",
               "end" => "2026-08-27T10:04:59.999999Z"
             },
             %{
               "bucket_seconds" => 300,
               "bytes" => 200,
               "start" => "2026-08-27T10:05:00Z",
               "end" => "2026-08-27T10:09:59.999999Z"
             },
             %{
               "bucket_seconds" => 300,
               "bytes" => 300,
               "start" => "2026-08-27T10:10:00Z",
               "end" => "2026-08-27T10:14:59.999999Z"
             }
           ]
  end

  test "changing only the saved zone changes display metadata without changing canonical chart inputs" do
    chicago = render_timeseries(:lines, points(), "America/Chicago")
    utc = render_timeseries(:lines, points(), "Etc/UTC")
    chicago_root = LazyHTML.query(chicago, "#netflow-traffic-timeseries")
    utc_root = LazyHTML.query(utc, "#netflow-traffic-timeseries")

    assert LazyHTML.attribute(chicago_root, "data-timezone") == ["America/Chicago"]
    assert LazyHTML.attribute(utc_root, "data-timezone") == ["Etc/UTC"]

    for attribute <- ["data-points", "data-range-buckets", "data-range-event"] do
      assert LazyHTML.attribute(chicago_root, attribute) == LazyHTML.attribute(utc_root, attribute)
    end

    chicago_svg = LazyHTML.query(chicago_root, "svg")
    utc_svg = LazyHTML.query(utc_root, "svg")

    for attribute <- ["phx-value-start", "phx-value-end"] do
      assert LazyHTML.attribute(LazyHTML.query(chicago_svg, "circle"), attribute) ==
               LazyHTML.attribute(LazyHTML.query(utc_svg, "circle"), attribute)
    end

    assert LazyHTML.attribute(
             LazyHTML.query(chicago_root, "#netflow-chart-window-start"),
             "datetime"
           ) == ["2026-08-27T10:00:00Z"]

    assert LazyHTML.attribute(
             LazyHTML.query(utc_root, "#netflow-chart-window-start"),
             "datetime"
           ) == ["2026-08-27T10:00:00Z"]
  end

  test "Lines centers a singleton in both metadata and rendered geometry" do
    document = render_timeseries(:lines, [hd(points())])
    selector = LazyHTML.query(document, "#netflow-traffic-timeseries")

    assert [%{"x" => 500.0}] = decode_attribute(selector, "data-range-buckets")
    assert LazyHTML.attribute(LazyHTML.query(selector, "circle"), "cx") == ["500.0"]
    assert LazyHTML.attribute(LazyHTML.query(selector, "polyline"), "points") == ["500.0,10.0"]
  end

  test "Grid metadata and marks share fitted band centers" do
    document = render_timeseries(:grid, points())
    selector = LazyHTML.query(document, "#netflow-traffic-timeseries")
    svg = LazyHTML.query(selector, "svg")

    assert Enum.map(decode_attribute(selector, "data-range-buckets"), & &1["x"]) == [
             166.66666666666666,
             500.0,
             833.3333333333333
           ]

    assert LazyHTML.attribute(LazyHTML.query(svg, "circle"), "cx") == [
             "166.66666666666666",
             "500.0",
             "833.3333333333333"
           ]

    assert LazyHTML.attribute(LazyHTML.query(svg, "rect[phx-click='netflow_bucket']"), "x") == [
             "0.0",
             "333.33333333333337",
             "666.6666666666666"
           ]

    assert_bucket_clicks(svg)

    assert LazyHTML.text(LazyHTML.query(svg, "rect[phx-click='netflow_bucket'] title")) =~
             "window: 2026-08-27T10:00:00Z → 2026-08-27T10:04:59.999999Z"
  end

  test "empty and invalid Traffic Over Time input remains inert" do
    for input <- [[], [%{bucket_start: "bad", bucket_end: "bad", bytes: 1}]] do
      document = render_timeseries(:lines, input)

      assert Enum.empty?(LazyHTML.query(document, "#netflow-traffic-timeseries"))
      assert Enum.empty?(LazyHTML.query(document, "[phx-hook='NetflowTrafficTooltip']"))
      assert Enum.empty?(LazyHTML.query(document, "[data-range-buckets]"))
      assert Enum.empty?(LazyHTML.query(document, "[data-range-overlay]"))
      assert Enum.empty?(LazyHTML.query(document, "[data-range-status]"))
      assert Enum.empty?(LazyHTML.query(document, "[tabindex='0']"))
      assert one?(LazyHTML.query(document, "div.py-8"))
    end
  end

  test "Stacked Traffic carries exact canonical intervals and accessibility state" do
    intervals = RangeSelection.canonical_intervals(points())

    document =
      (&Index.netflow_timeseries_stacked_area_chart/1)
      |> render_component(%{
        id: "netflow-top-stacked",
        points: stacked_points(),
        keys: ["web", "db"],
        colors: %{},
        mode: "ports",
        series_field: nil,
        range_intervals: intervals,
        range_event: "netflow_range_selected",
        timezone: "America/Chicago"
      })
      |> LazyHTML.from_fragment()

    selector = LazyHTML.query(document, "#netflow-top-stacked")

    assert LazyHTML.attribute(selector, "phx-hook") == ["NetflowStackedAreaChart"]
    assert LazyHTML.attribute(selector, "data-timezone") == ["America/Chicago"]
    assert LazyHTML.attribute(selector, "phx-update") == ["ignore"]
    assert LazyHTML.attribute(selector, "data-range-event") == ["netflow_range_selected"]
    assert selector |> LazyHTML.attribute("class") |> Enum.any?(&String.contains?(&1, "touch-pan-y"))

    assert decode_attribute(selector, "data-range-intervals") == [
             %{
               "start" => "2026-08-27T10:00:00Z",
               "end" => "2026-08-27T10:04:59.999999Z"
             },
             %{
               "start" => "2026-08-27T10:05:00Z",
               "end" => "2026-08-27T10:09:59.999999Z"
             },
             %{
               "start" => "2026-08-27T10:10:00Z",
               "end" => "2026-08-27T10:14:59.999999Z"
             }
           ]

    assert LazyHTML.attribute(selector, "role") == ["group"]
    assert LazyHTML.attribute(selector, "tabindex") == ["0"]
    assert LazyHTML.attribute(selector, "aria-describedby") == ["netflow-top-stacked-range-instructions"]
    assert one?(LazyHTML.query(selector, "#netflow-top-stacked-range-instructions"))
    assert one?(LazyHTML.query(selector, "[data-range-status][aria-live='polite']"))
  end

  test "Stacked Traffic without a range opt-in retains the existing chart contract" do
    document =
      (&Index.netflow_timeseries_stacked_area_chart/1)
      |> render_component(%{
        id: "netflow-protocol-stacked",
        points: stacked_points(),
        keys: ["web", "db"],
        colors: %{},
        mode: "protocols",
        series_field: "protocol_group",
        timezone: "America/Chicago"
      })
      |> LazyHTML.from_fragment()

    selector = LazyHTML.query(document, "#netflow-protocol-stacked")

    assert LazyHTML.attribute(selector, "phx-hook") == ["NetflowStackedAreaChart"]
    assert LazyHTML.attribute(selector, "data-timezone") == ["America/Chicago"]
    assert LazyHTML.attribute(selector, "data-series-field") == ["protocol_group"]
    assert LazyHTML.attribute(selector, "data-range-event") == []
    assert LazyHTML.attribute(selector, "data-range-intervals") == []
    assert LazyHTML.attribute(selector, "tabindex") == []
    refute selector |> LazyHTML.attribute("class") |> Enum.any?(&String.contains?(&1, "touch-pan-y"))
    assert Enum.empty?(LazyHTML.query(selector, "[data-range-status]"))
  end

  test "Protocol activity uses canonical Traffic intervals without losing its series contract" do
    document =
      render_activity_cards(%{
        protocol_activity: protocol_activity(),
        app_activity: empty_activity()
      })

    assert_activity_range_card(document, %{
      id: "netflow-protocol-stacked",
      series_field: "protocol_group",
      accessible_name: "Select an Activity by Protocol time range",
      instructions: "protocol activity buckets",
      points: protocol_activity().points,
      keys: protocol_activity().keys,
      colors: protocol_activity().colors
    })

    assert one?(LazyHTML.query(document, "[phx-hook='NetflowStackedAreaChart']"))
    assert LazyHTML.text(document) =~ "No apps samples in this window."
  end

  test "Application activity uses canonical Traffic intervals without losing its series contract" do
    document =
      render_activity_cards(%{
        protocol_activity: empty_activity(),
        app_activity: app_activity()
      })

    assert_activity_range_card(document, %{
      id: "netflow-app-stacked",
      series_field: "app",
      accessible_name: "Select an Activity by Application time range",
      instructions: "application activity buckets",
      points: app_activity().points,
      keys: app_activity().keys,
      colors: app_activity().colors
    })

    assert one?(LazyHTML.query(document, "[phx-hook='NetflowStackedAreaChart']"))
    assert LazyHTML.text(document) =~ "No protocols samples in this window."
  end

  test "all temporal Traffic graph modes opt both activity cards into range selection" do
    for graph_mode <- ["lines", "grid", "stacked", "stacked100"] do
      document = render_activity_cards(%{graph_mode: graph_mode})

      for id <- ["netflow-protocol-stacked", "netflow-app-stacked"] do
        selector = LazyHTML.query(document, "##{id}")

        assert LazyHTML.attribute(selector, "data-range-event") == ["netflow_range_selected"]
        assert decode_attribute(selector, "data-range-intervals") == canonical_intervals_json()
        assert LazyHTML.attribute(selector, "role") == ["group"]
        assert LazyHTML.attribute(selector, "tabindex") == ["0"]
        assert one?(LazyHTML.query(selector, "[data-range-status][aria-live='polite']"))
      end
    end
  end

  test "Sankey Traffic keeps both activity series charts rendered but range-inert" do
    document = render_activity_cards(%{graph_mode: "sankey"})

    for {id, field, activity} <- [
          {"netflow-protocol-stacked", "protocol_group", protocol_activity()},
          {"netflow-app-stacked", "app", app_activity()}
        ] do
      selector = LazyHTML.query(document, "##{id}")

      assert LazyHTML.attribute(selector, "phx-hook") == ["NetflowStackedAreaChart"]
      assert LazyHTML.attribute(selector, "phx-update") == ["ignore"]
      assert LazyHTML.attribute(selector, "data-series-field") == [field]
      assert decode_attribute(selector, "data-points") == activity.points
      assert decode_attribute(selector, "data-keys") == activity.keys
      assert decode_attribute(selector, "data-colors") == activity.colors
      assert LazyHTML.attribute(selector, "data-range-event") == []
      assert LazyHTML.attribute(selector, "data-range-intervals") == []
      assert LazyHTML.attribute(selector, "role") == []
      assert LazyHTML.attribute(selector, "tabindex") == []
      assert LazyHTML.attribute(selector, "aria-describedby") == []
      refute selector |> LazyHTML.attribute("class") |> Enum.any?(&String.contains?(&1, "touch-pan-y"))
      assert Enum.empty?(LazyHTML.query(selector, "[id$='-range-instructions']"))
      assert Enum.empty?(LazyHTML.query(selector, "[data-range-status]"))
    end
  end

  test "empty activity cards retain mode-specific messages and expose no interaction surface" do
    document =
      render_activity_cards(%{
        protocol_activity: empty_activity(),
        app_activity: empty_activity()
      })

    assert LazyHTML.text(document) =~ "No protocols samples in this window."
    assert LazyHTML.text(document) =~ "No apps samples in this window."
    assert Enum.empty?(LazyHTML.query(document, "[phx-hook='NetflowStackedAreaChart']"))
    assert Enum.empty?(LazyHTML.query(document, "[data-range-event]"))
    assert Enum.empty?(LazyHTML.query(document, "[data-range-intervals]"))
    assert Enum.empty?(LazyHTML.query(document, "[tabindex='0']"))
    assert Enum.empty?(LazyHTML.query(document, "[data-range-status]"))
  end

  test "each activity card is inert when either points or keys are independently empty" do
    cases = [
      {:protocol_activity, "netflow-protocol-stacked", "netflow-app-stacked", "protocols"},
      {:app_activity, "netflow-app-stacked", "netflow-protocol-stacked", "apps"}
    ]

    for {activity_key, empty_id, populated_id, mode} <- cases,
        empty_activity <- [
          %{bucket_seconds: 300, points: [], keys: ["present"], colors: %{}},
          %{
            bucket_seconds: 300,
            points: [%{"t" => "2026-08-27T10:00:00Z", "present" => 1}],
            keys: [],
            colors: %{}
          }
        ] do
      document = render_activity_cards(%{activity_key => empty_activity})

      assert Enum.empty?(LazyHTML.query(document, "##{empty_id}"))
      assert one?(LazyHTML.query(document, "##{populated_id}"))
      assert LazyHTML.text(document) =~ "No #{mode} samples in this window."
      assert one?(LazyHTML.query(document, "[phx-hook='NetflowStackedAreaChart']"))
      assert one?(LazyHTML.query(document, "[data-range-event='netflow_range_selected']"))
      assert one?(LazyHTML.query(document, "[data-range-intervals]"))
      assert one?(LazyHTML.query(document, "[tabindex='0']"))
      assert one?(LazyHTML.query(document, "[role='group']"))
      assert one?(LazyHTML.query(document, "[data-range-status]"))
    end
  end

  defp render_timeseries(mode, chart_points, timezone \\ "America/Chicago") do
    (&Index.netflow_timeseries_chart/1)
    |> render_component(%{
      points: chart_points,
      compare_points: [],
      bucket_seconds: 300,
      compare_mode: "off",
      mode: Atom.to_string(mode),
      timezone: timezone
    })
    |> LazyHTML.from_fragment()
  end

  defp render_activity_cards(overrides) do
    (&Index.netflow_activity_cards/1)
    |> render_component(
      Map.merge(
        %{
          timeseries: %{bucket_seconds: 300, points: activity_base_points()},
          protocol_activity: protocol_activity(),
          app_activity: app_activity(),
          graph_mode: "stacked",
          timezone: "America/Chicago"
        },
        overrides
      )
    )
    |> LazyHTML.from_fragment()
  end

  defp assert_activity_range_card(document, expected) do
    selector = LazyHTML.query(document, "##{expected.id}")

    assert LazyHTML.attribute(selector, "phx-hook") == ["NetflowStackedAreaChart"]
    assert LazyHTML.attribute(selector, "data-timezone") == ["America/Chicago"]
    assert LazyHTML.attribute(selector, "phx-update") == ["ignore"]
    assert LazyHTML.attribute(selector, "data-range-event") == ["netflow_range_selected"]
    assert LazyHTML.attribute(selector, "data-series-field") == [expected.series_field]
    assert decode_attribute(selector, "data-range-intervals") == canonical_intervals_json()
    assert decode_attribute(selector, "data-points") == expected.points
    assert decode_attribute(selector, "data-keys") == expected.keys
    assert decode_attribute(selector, "data-colors") == expected.colors
    assert LazyHTML.attribute(selector, "role") == ["group"]
    assert LazyHTML.attribute(selector, "tabindex") == ["0"]
    assert LazyHTML.attribute(selector, "aria-label") == [expected.accessible_name]

    assert LazyHTML.attribute(selector, "aria-describedby") == [
             "#{expected.id}-range-instructions"
           ]

    assert selector |> LazyHTML.attribute("class") |> Enum.any?(&String.contains?(&1, "touch-pan-y"))

    instructions = LazyHTML.query(selector, "##{expected.id}-range-instructions")
    assert one?(instructions)
    assert instructions |> LazyHTML.text() |> String.downcase() =~ expected.instructions
    assert one?(LazyHTML.query(selector, "[data-range-status][aria-live='polite']"))
  end

  defp assert_bucket_clicks(svg) do
    circles = LazyHTML.query(svg, "circle[phx-click='netflow_bucket']")

    assert LazyHTML.attribute(circles, "phx-value-start") == [
             "2026-08-27T10:00:00Z",
             "2026-08-27T10:05:00Z",
             "2026-08-27T10:10:00Z"
           ]

    assert LazyHTML.attribute(circles, "phx-value-end") == [
             "2026-08-27T10:04:59.999999Z",
             "2026-08-27T10:09:59.999999Z",
             "2026-08-27T10:14:59.999999Z"
           ]
  end

  defp decode_attribute(selector, name) do
    selector
    |> LazyHTML.attribute(name)
    |> List.first()
    |> Jason.decode!()
  end

  defp assert_semantic_window_endpoint(root, id, instant) do
    time = LazyHTML.query(root, "##{id}")

    assert LazyHTML.tag(time) == ["time"]
    assert LazyHTML.attribute(time, "datetime") == [instant]
    assert LazyHTML.attribute(time, "data-user-time-iso") == [instant]
    assert LazyHTML.attribute(time, "data-user-time-zone") == ["America/Chicago"]
    assert LazyHTML.attribute(time, "data-user-time-style") == ["compact"]
  end

  defp one?(enumerable), do: match?([_], Enum.take(enumerable, 2))

  defp points do
    [
      point(~U[2026-08-27 10:00:00Z], ~U[2026-08-27 10:05:00Z], 100),
      point(~U[2026-08-27 10:05:00Z], ~U[2026-08-27 10:10:00Z], 200),
      point(~U[2026-08-27 10:10:00Z], ~U[2026-08-27 10:15:00Z], 300)
    ]
  end

  defp point(start_time, end_time, bytes) do
    %{bucket_start: start_time, bucket_end: end_time, bytes: bytes}
  end

  defp stacked_points do
    [
      %{"t" => "2026-08-27T10:00:00Z", "web" => 10, "db" => 20},
      %{"t" => "2026-08-27T10:05:00Z", "web" => 20, "db" => 10},
      %{"t" => "2026-08-27T10:10:00Z", "web" => 30, "db" => 15}
    ]
  end

  defp canonical_intervals_json do
    [
      %{
        "start" => "2026-08-27T10:00:00Z",
        "end" => "2026-08-27T10:04:59.999999Z"
      },
      %{
        "start" => "2026-08-27T10:10:00Z",
        "end" => "2026-08-27T10:14:59.999999Z"
      },
      %{
        "start" => "2026-08-27T10:20:00Z",
        "end" => "2026-08-27T10:29:59.999999Z"
      }
    ]
  end

  defp activity_base_points do
    [
      point(~U[2026-08-27 10:00:00Z], ~U[2026-08-27 10:05:00Z], 100),
      point(~U[2026-08-27 10:10:00Z], ~U[2026-08-27 10:15:00Z], 200),
      point(~U[2026-08-27 10:20:00Z], ~U[2026-08-27 10:30:00Z], 300)
    ]
  end

  defp protocol_activity do
    %{
      bucket_seconds: 300,
      points: [
        %{"t" => "2026-08-27T10:00:00Z", "tcp" => 70, "udp" => 30},
        %{"t" => "2026-08-27T10:10:00Z", "tcp" => 60, "udp" => 40},
        %{"t" => "2026-08-27T10:20:00Z", "tcp" => 80, "udp" => 20}
      ],
      keys: ["tcp", "udp"],
      colors: %{"tcp" => "#2563EB", "udp" => "#F97316"}
    }
  end

  defp app_activity do
    %{
      bucket_seconds: 300,
      points: [
        %{"t" => "2026-08-27T10:00:00Z", "dns" => 20, "https" => 80},
        %{"t" => "2026-08-27T10:10:00Z", "dns" => 25, "https" => 75},
        %{"t" => "2026-08-27T10:20:00Z", "dns" => 30, "https" => 70}
      ],
      keys: ["dns", "https"],
      colors: %{"dns" => "#7C3AED", "https" => "#059669"}
    }
  end

  defp empty_activity, do: %{bucket_seconds: 300, points: [], keys: [], colors: %{}}
end
