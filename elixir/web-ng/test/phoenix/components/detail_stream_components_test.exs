defmodule ServiceRadarWebNGWeb.Components.DetailStreamComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNGWeb.Observability.DetailStreamComponents

  @moduletag :db_free

  test "renders repeated id-less entry instants semantically with unique stable caller ids" do
    entries = [
      %{
        id: "row-0",
        dom_id: "log-entry-0",
        href: "/logs/row-0",
        severity: "info",
        secondary: "collector-a",
        timestamp: "2026-08-30T18:00:00Z",
        preview: "identical"
      },
      %{
        id: "row-1",
        dom_id: "log-entry-1",
        href: "/logs/row-1",
        severity: "info",
        secondary: "collector-a",
        timestamp: "2026-08-30T18:00:00Z",
        preview: "identical"
      }
    ]

    assigns = %{
      id: "review-stream",
      title: "Related logs",
      entries: entries,
      page: 1,
      page_count: 2,
      selected_id: "none",
      stream_severity: "all",
      severity_filters: ["all"],
      timezone: "America/Chicago"
    }

    html = render_component(&DetailStreamComponents.detail_stream_pane/1, assigns)
    rerendered = render_component(&DetailStreamComponents.detail_stream_pane/1, assigns)

    document = LazyHTML.from_fragment(html)
    times = LazyHTML.query(document, "#review-stream time")
    ids = LazyHTML.attribute(times, "id")

    assert ids == ["review-stream-log-entry-0-time", "review-stream-log-entry-1-time"]
    assert ids == Enum.uniq(ids)
    assert LazyHTML.attribute(times, "datetime") == ["2026-08-30T18:00:00Z", "2026-08-30T18:00:00Z"]
    assert LazyHTML.attribute(times, "data-user-time-zone") == ["America/Chicago", "America/Chicago"]

    rerendered_ids =
      rerendered
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#review-stream time")
      |> LazyHTML.attribute("id")

    assert rerendered_ids == ids
    assert LazyHTML.attribute(LazyHTML.query(document, "#review-stream a"), "href") == ["/logs/row-0", "/logs/row-1"]
  end
end
