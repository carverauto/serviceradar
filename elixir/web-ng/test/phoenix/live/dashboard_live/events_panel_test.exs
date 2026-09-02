defmodule ServiceRadarWebNGWeb.DashboardLive.EventsPanelTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNGWeb.DashboardLive.Index.EventsPanel

  @moduletag :db_free

  test "renders a selectable event chart with canonical gapped bucket metadata" do
    document =
      render_events([
        point(~U[2026-08-27 10:00:00Z], "10:00", 2),
        point(~N[2026-08-27 12:00:00], "12:00", 5),
        point(~U[2026-08-27 13:00:00Z], "13:00", 10)
      ])

    selector = LazyHTML.query(document, "#dashboard-events-range-selector")
    instructions = LazyHTML.query(selector, "#dashboard-events-range-instructions")
    status = LazyHTML.query(selector, "[data-range-status]")

    assert Enum.count(LazyHTML.query(document, "#dashboard-events-range-selector")) == 1
    assert Enum.empty?(LazyHTML.query(document, "[data-testid='security-events-empty']"))
    assert Enum.count(LazyHTML.query(document, "#dashboard-events-range-instructions")) == 1
    assert Enum.count(LazyHTML.query(document, "#dashboard-events-view-all")) == 1
    assert LazyHTML.attribute(selector, "phx-hook") == ["ChartRangeSelection"]
    assert LazyHTML.attribute(selector, "tabindex") == ["0"]
    assert LazyHTML.attribute(selector, "role") == ["group"]
    assert LazyHTML.attribute(selector, "aria-label") == ["Select an Events Over Time range"]
    assert LazyHTML.attribute(selector, "aria-describedby") == ["dashboard-events-range-instructions"]
    assert Enum.count(instructions) == 1
    assert Enum.count(status) == 1
    assert LazyHTML.attribute(status, "aria-live") == ["polite"]
    assert LazyHTML.attribute(selector, "data-range-event") == ["select_events_range"]
    assert LazyHTML.attribute(selector, "data-timezone") == ["America/Chicago"]
    assert LazyHTML.attribute(selector, "data-testid") == ["security-events-chart"]
    assert LazyHTML.attribute(selector, "data-chart-width") == ["640"]
    assert LazyHTML.attribute(selector, "data-chart-left-pad") == ["36"]
    assert LazyHTML.attribute(selector, "data-chart-right-pad") == ["24"]

    assert selector
           |> LazyHTML.attribute("data-range-buckets")
           |> List.first()
           |> Jason.decode!() == [
             %{
               "x" => 36,
               "start" => "2026-08-27T10:00:00Z",
               "end" => "2026-08-27T10:59:59.999999Z"
             },
             %{
               "x" => 326,
               "start" => "2026-08-27T12:00:00Z",
               "end" => "2026-08-27T12:59:59.999999Z"
             },
             %{
               "x" => 616,
               "start" => "2026-08-27T13:00:00Z",
               "end" => "2026-08-27T13:59:59.999999Z"
             }
           ]

    assert_present(selector, "[data-range-svg]")
    assert_present(selector, "[data-range-overlay]")
    assert_present(selector, "[data-range-status][aria-live='polite']")
    assert_present(selector, "#dashboard-events-range-instructions")
    assert_present(selector, ".sr-ops-events-area-low")
    assert_present(selector, ".sr-ops-events-area-medium")
    assert_present(selector, ".sr-ops-events-area-high")
    assert_present(selector, ".sr-ops-events-area-critical")
    assert_present(selector, ".sr-ops-events-axis + [data-range-overlay]")
    assert_present(selector, ".sr-ops-events-legend")

    axis_times = LazyHTML.query(selector, ".sr-ops-events-axis text[phx-hook='UserTime']")

    assert LazyHTML.attribute(axis_times, "data-user-time-iso") == [
             "2026-08-27T10:00:00Z",
             "2026-08-27T12:00:00Z",
             "2026-08-27T13:00:00Z"
           ]

    assert LazyHTML.attribute(axis_times, "data-user-time-zone") ==
             List.duplicate("America/Chicago", 3)

    assert axis_times |> LazyHTML.attribute("id") |> Enum.uniq() |> length() == 3

    assert selector
           |> LazyHTML.query(".sr-ops-events-line")
           |> LazyHTML.attribute("points") == ["36,149 326,103 616,26"]

    assert LazyHTML.attribute(LazyHTML.query(document, "a#dashboard-events-range-selector"), "id") == []
    assert LazyHTML.attribute(LazyHTML.query(selector, "#dashboard-events-view-all"), "id") == []

    assert LazyHTML.attribute(
             LazyHTML.query(document, "#dashboard-events-view-all"),
             "href"
           ) == ["/observability/events"]
  end

  test "keeps a true one-bucket chart selectable at the plot origin" do
    document = render_events([point(~U[2026-08-27 10:00:00Z], "10:00", 4)])
    selector = LazyHTML.query(document, "#dashboard-events-range-selector")

    assert selector
           |> LazyHTML.attribute("data-range-buckets")
           |> List.first()
           |> Jason.decode!() == [
             %{
               "x" => 36,
               "start" => "2026-08-27T10:00:00Z",
               "end" => "2026-08-27T10:59:59.999999Z"
             }
           ]

    assert selector
           |> LazyHTML.query(".sr-ops-events-line")
           |> LazyHTML.attribute("points") == ["36,118"]
  end

  test "renders malformed nonempty trend input as an inert fallback with a separate action" do
    document = render_events([%{bucket: "2026-08-27T10:00:00Z"}])

    assert_inert_fallback(document)
  end

  test "renders a timestamp-valid point missing required plot fields as an inert fallback" do
    document = render_events([%{bucket: ~U[2026-08-27 10:00:00Z]}])

    assert_inert_fallback(document)
  end

  test "renders nonnumeric plot values and maxima as inert fallbacks" do
    valid = point(~U[2026-08-27 10:00:00Z], "10:00", 4)

    for {trend, max_total} <- [
          {[Map.put(valid, :total, "4")], 10},
          {[Map.put(valid, :low, "4")], 10},
          {[valid], "10"}
        ] do
      trend
      |> render_events(max_total)
      |> assert_inert_fallback()
    end
  end

  test "keeps omitted severity counts on an otherwise plottable point safe" do
    document =
      render_events([
        %{bucket: ~U[2026-08-27 10:00:00Z], label: "10:00", total: 4}
      ])

    assert Enum.count(LazyHTML.query(document, "#dashboard-events-range-selector")) == 1
  end

  test "keeps the View all action in the empty state without a hooked surface" do
    document = render_events([])

    assert_inert_fallback(document)
  end

  defp assert_inert_fallback(document) do
    assert LazyHTML.attribute(
             LazyHTML.query(document, "[data-testid='security-events-empty']"),
             "data-testid"
           ) == ["security-events-empty"]

    assert LazyHTML.attribute(LazyHTML.query(document, "#dashboard-events-range-selector"), "id") == []

    assert LazyHTML.attribute(
             LazyHTML.query(document, "#dashboard-events-view-all"),
             "href"
           ) == ["/observability/events"]
  end

  defp render_events(security_trend, security_trend_max \\ 10) do
    (&EventsPanel.render/1)
    |> render_component(
      dashboard: %{
        security_trend: security_trend,
        security_trend_max: security_trend_max,
        time_window_label: "24h"
      },
      embedded: true,
      timezone: "America/Chicago"
    )
    |> LazyHTML.from_fragment()
  end

  defp point(bucket, label, total) do
    %{bucket: bucket, label: label, total: total, low: total, medium: 0, high: 0, critical: 0}
  end

  defp assert_present(document, selector) do
    assert [_ | _] =
             document
             |> LazyHTML.query(selector)
             |> LazyHTML.attribute("class"),
           "expected rendered selector #{selector}"
  end
end
