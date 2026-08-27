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

    assert LazyHTML.attribute(selector, "phx-hook") == ["ChartRangeSelection"]
    assert LazyHTML.attribute(selector, "tabindex") == ["0"]
    assert LazyHTML.attribute(selector, "role") == ["group"]
    assert LazyHTML.attribute(selector, "aria-describedby") == ["dashboard-events-range-instructions"]
    assert LazyHTML.attribute(selector, "data-range-event") == ["select_events_range"]
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

  test "keeps the View all action in the empty state without a hooked surface" do
    document = render_events([])

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

  defp render_events(security_trend) do
    (&EventsPanel.render/1)
    |> render_component(
      dashboard: %{
        security_trend: security_trend,
        security_trend_max: 10,
        time_window_label: "24h"
      },
      embedded: true
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
