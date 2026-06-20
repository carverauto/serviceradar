defmodule ServiceRadarWebNGWeb.Components.SRQLComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNGWeb.SRQLComponents

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
    assert html =~ ~s(--srql-font-size: 0.75rem;)
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
        rows: [%{"count" => 1_234_567, "bytes_total" => 2048}],
        columns: ["bytes_total", "count"]
      )

    assert html =~ "2 KiB"
    assert html =~ "1,234,567"
    assert :binary.match(html, "bytes_total") < :binary.match(html, "count")
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
