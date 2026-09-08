defmodule ServiceRadarWebNGWeb.Components.SRQLComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNGWeb.SRQL.Builder
  alias ServiceRadarWebNGWeb.SRQLComponents

  @moduletag :db_free

  test "compact editor keeps the SRQLInput hook and its own dropdown" do
    html =
      render_component(&SRQLComponents.srql_editor/1,
        id: "query",
        name: "q",
        value: "in:devices",
        compact: true
      )

    assert html =~ ~s(phx-hook="SRQLInput")
    assert html =~ ~s(class="relative srql-input-frame")
    # The compact frame drives its own type scale through custom properties, which is what
    # the overlay and the input have to agree on. The exact value is a design decision that
    # has already moved once (0.75rem -> 0.875rem); pinning it made this test fail on a
    # restyle while saying nothing about the hook it is named for.
    assert html =~ "--srql-font-size:"
    assert html =~ ~s(data-srql-input-overlay)
    # Completions render into the component's own dropdown, which the SRQLInput hook owns.
    assert html =~ ~s(data-srql-input-dropdown)
    # And explicitly NOT into a native <datalist>. The browser renders a datalist popup
    # above everything the page draws, so it covered the Recent-history list on an empty
    # focus; it was removed for that reason. Asserting its absence keeps it from coming
    # back as an innocent-looking "fallback".
    refute html =~ ~s(<datalist)
    refute html =~ ~s(phx-hook="SRQLEditor")
  end

  test "rich editor still renders the Monaco-backed SRQLEditor hook" do
    html =
      render_component(&SRQLComponents.srql_editor/1,
        id: "rich-query",
        name: "q",
        value: "in:devices",
        rich: true
      )

    assert html =~ ~s(id="rich-query-input")
    assert html =~ ~s(id="rich-query")
    assert html =~ ~s(phx-hook="SRQLEditor")
    assert html =~ ~s(data-input-id="rich-query-input")
    assert html =~ ~s(data-completions=)
    refute html =~ ~s(phx-hook="SRQLInput")
  end

  test "query builder renders row-only flow fields only when the bucket is cleared" do
    row_builder =
      "flows"
      |> Builder.default_state(100)
      |> Map.put("bucket", "")

    row_html =
      render_component(&SRQLComponents.srql_query_builder/1,
        builder: row_builder,
        supported: true,
        sync: true
      )

    chart_html =
      render_component(&SRQLComponents.srql_query_builder/1,
        builder: Map.put(row_builder, "bucket", "5m"),
        supported: true,
        sync: true
      )

    assert row_html =~ ~s(<option value="tag")
    assert row_html =~ ~s(<option value="cidr")
    refute chart_html =~ ~s(<option value="tag")
    assert chart_html =~ ~s(<option value="cidr")
  end

  test "results table preserves explicit column order and formats numeric cells" do
    html =
      render_component(&SRQLComponents.srql_results_table/1,
        id: "results",
        timezone: "Etc/UTC",
        rows: [
          %{
            "alpha" => "first",
            "beta" => 1234,
            "bytes_total" => 1_234_567.5,
            "gamma" => 1_234_567.5
          }
        ],
        columns: ["alpha", "beta", "bytes_total", "gamma"]
      )

    assert html =~ "first"
    assert html =~ "1,234"
    assert html =~ "1.18 MiB"
    assert html =~ "1,234,567.5"
    assert :binary.match(html, "alpha") < :binary.match(html, "beta")
    assert :binary.match(html, "beta") < :binary.match(html, "bytes_total")
    assert :binary.match(html, "bytes_total") < :binary.match(html, "gamma")
  end

  test "results table formats integer byte columns with binary units" do
    html =
      render_component(&SRQLComponents.srql_results_table/1,
        id: "results",
        timezone: "Etc/UTC",
        rows: [%{"count" => 1_234_567, "bytes_total" => 2048}],
        columns: ["bytes_total", "count"]
      )

    assert html =~ "2 KiB"
    assert html =~ "1,234,567"
    assert :binary.match(html, "bytes_total") < :binary.match(html, "count")
  end

  test "results table can render sortable headers for dashboard table plugin" do
    html =
      render_component(&SRQLComponents.srql_results_table/1,
        id: "results",
        timezone: "Etc/UTC",
        rows: [%{"count" => 2, "service" => "api"}],
        columns: ["service", "count"],
        sortable: true,
        sort_target: "table-plugin",
        sort_field: "count",
        sort_dir: "desc"
      )

    assert html =~ ~s(phx-click="table_sort")
    assert html =~ ~s(phx-target="table-plugin")
    assert html =~ ~s(phx-value-field="count")
    assert html =~ ~s(aria-sort="descending")
    assert html =~ ~s(hero-chevron-down)
  end

  test "results table infers columns across rows without sorting them alphabetically" do
    html =
      render_component(&SRQLComponents.srql_results_table/1,
        id: "results",
        timezone: "Etc/UTC",
        rows: [%{"zeta" => 1}, %{"alpha" => 2}]
      )

    assert html =~ "zeta"
    assert html =~ "alpha"
    assert :binary.match(html, "zeta") < :binary.match(html, "alpha")
  end

  test "results table renders canonical time cells in the selected timezone with unique ids" do
    html =
      render_component(&SRQLComponents.srql_results_table/1,
        id: "results",
        rows: [
          %{"timestamp" => "2026-08-30T18:00:00Z"},
          %{"timestamp" => "2026-08-30T18:01:00Z"}
        ],
        columns: ["timestamp"],
        timezone: "America/Chicago"
      )

    document = LazyHTML.from_fragment(html)
    times = LazyHTML.query(document, "time")
    ids = LazyHTML.attribute(times, "id")

    assert html =~ ~s(phx-hook="UserTime")
    assert ids == ["results-time-0-0", "results-time-1-0"]
    assert ids == Enum.uniq(ids)
    assert LazyHTML.attribute(times, "data-user-time-zone") == ["America/Chicago", "America/Chicago"]
    assert LazyHTML.attribute(times, "datetime") == ["2026-08-30T18:00:00Z", "2026-08-30T18:01:00Z"]
  end

  test "results table leaves offset-less time strings raw while accepting explicit instants" do
    html =
      render_component(&SRQLComponents.srql_results_table/1,
        id: "timestamp-boundary-results",
        rows: [
          %{"timestamp" => "2026-08-30T12:34:56"},
          %{"timestamp" => "2026-08-30T18:00:00Z"},
          %{"timestamp" => "2026-08-30T13:01:00-05:00"}
        ],
        columns: ["timestamp"],
        timezone: "America/Chicago"
      )

    document = LazyHTML.from_fragment(html)
    times = LazyHTML.query(document, "time")

    assert html =~ "2026-08-30T12:34:56"
    refute html =~ ~s(datetime="2026-08-30T12:34:56Z")

    assert LazyHTML.attribute(times, "id") == [
             "timestamp-boundary-results-time-1-0",
             "timestamp-boundary-results-time-2-0"
           ]

    assert LazyHTML.attribute(times, "datetime") == [
             "2026-08-30T18:00:00Z",
             "2026-08-30T18:01:00Z"
           ]
  end

  test "results table renders a composite timestamp semantically without rewriting its canonical instant" do
    html =
      render_component(&SRQLComponents.srql_results_table/1,
        id: "composite-results",
        rows: [%{"observed_at" => "2026-08-30T18:00:00Z, collector-a"}],
        columns: ["observed_at"],
        timezone: "America/Chicago"
      )

    document = LazyHTML.from_fragment(html)
    times = LazyHTML.query(document, "time")

    assert LazyHTML.attribute(times, "id") == ["composite-results-time-0-0"]
    assert LazyHTML.attribute(times, "datetime") == ["2026-08-30T18:00:00Z"]
    assert LazyHTML.attribute(times, "data-user-time-zone") == ["America/Chicago"]
    assert html =~ "collector-a"
    refute html =~ "2026-08-30 18:00:00 UTC"
  end

  test "category visualization renders ISO keys semantically in the explicit timezone" do
    html =
      render_component(&SRQLComponents.srql_auto_viz/1,
        id: "review-categories",
        timezone: "America/Chicago",
        viz:
          {:categories,
           %{
             label: "bucket",
             value: "count",
             items: [{"2026-08-30T18:00:00Z", 2}, {"ordinary", 1}]
           }}
      )

    document = LazyHTML.from_fragment(html)
    times = LazyHTML.query(document, "time")

    assert LazyHTML.attribute(times, "id") == ["review-categories-time-0"]
    assert LazyHTML.attribute(times, "datetime") == ["2026-08-30T18:00:00Z"]
    assert LazyHTML.attribute(times, "data-user-time-zone") == ["America/Chicago"]
    assert html =~ "ordinary"
    refute html =~ "2026-08-30 18:00:00 UTC"
  end

  test "category visualization leaves offset-less keys raw while accepting explicit instants" do
    html =
      render_component(&SRQLComponents.srql_auto_viz/1,
        id: "category-timestamp-boundary",
        timezone: "America/Chicago",
        viz:
          {:categories,
           %{
             label: "bucket",
             value: "count",
             items: [
               {"2026-08-30T12:34:56", 3},
               {"2026-08-30T18:00:00Z", 2},
               {"2026-08-30T13:01:00-05:00", 1}
             ]
           }}
      )

    document = LazyHTML.from_fragment(html)
    times = LazyHTML.query(document, "time")

    assert html =~ "2026-08-30T12:34:56"
    refute html =~ ~s(datetime="2026-08-30T12:34:56Z")

    assert LazyHTML.attribute(times, "id") == [
             "category-timestamp-boundary-time-1",
             "category-timestamp-boundary-time-2"
           ]

    assert LazyHTML.attribute(times, "datetime") == [
             "2026-08-30T18:00:00Z",
             "2026-08-30T18:01:00Z"
           ]
  end
end
