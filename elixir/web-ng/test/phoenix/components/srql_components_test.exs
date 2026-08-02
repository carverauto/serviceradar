defmodule ServiceRadarWebNGWeb.Components.SRQLComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNGWeb.SRQLComponents

  @moduletag :db_free

  test "compact editor keeps the SRQLInput hook and datalist fallback" do
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
    # restyle while saying nothing about the hook or the datalist it is named for.
    assert html =~ "--srql-font-size:"
    assert html =~ ~s(data-srql-input-overlay)
    assert html =~ ~s(<datalist id="query-completions">)
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

  test "results table preserves explicit column order and formats numeric cells" do
    html =
      render_component(&SRQLComponents.srql_results_table/1,
        id: "results",
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
        rows: [%{"zeta" => 1}, %{"alpha" => 2}]
      )

    assert html =~ "zeta"
    assert html =~ "alpha"
    assert :binary.match(html, "zeta") < :binary.match(html, "alpha")
  end
end
