defmodule ServiceRadarWebNGWeb.Components.PluginResultsTest do
  @moduledoc false

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNGWeb.PluginResults

  @moduletag :unit
  @moduletag :db_free

  test "renders stat card widget" do
    html =
      render_component(&PluginResults.plugin_results/1, %{
        display: [%{"widget" => "stat_card", "label" => "Latency", "value" => "42ms"}]
      })

    assert html =~ "Latency"
    assert html =~ "42ms"
  end

  test "ignores unsupported widgets" do
    html =
      render_component(&PluginResults.plugin_results/1, %{
        display: [%{"widget" => "nope", "label" => "Hidden"}]
      })

    refute html =~ "Hidden"
  end

  test "preserves Markdown structure and literal code text" do
    document =
      LazyHTML.from_fragment(
        render_component(&PluginResults.markdown/1, %{
          content: """
          # Release notes

          `a < b && c`

          ```
          a > b & d
          &lt; stays literal
          ```

              a < b && c

          > Warning

          [Details](https://example.com/notes?a=1&b=2)
          """
        })
      )

    assert document |> LazyHTML.query("h1") |> LazyHTML.text() == "Release notes"
    assert document |> LazyHTML.query("p > code") |> LazyHTML.text() == "a < b && c"

    assert document |> LazyHTML.query("pre > code") |> Enum.map(&LazyHTML.text/1) == [
             "a > b & d\n&lt; stays literal\n",
             "a < b && c\n"
           ]

    assert document |> LazyHTML.query("blockquote p") |> LazyHTML.text() == "Warning"

    assert document |> LazyHTML.query("a") |> LazyHTML.attribute("href") == [
             "https://example.com/notes?a=1&b=2"
           ]
  end

  test "escapes raw HTML in Markdown content" do
    content = """
    <script>alert(1)</script>

    <img src=x onerror=alert(1)>
    """

    document =
      LazyHTML.from_fragment(render_component(&PluginResults.markdown/1, %{content: content}))

    assert Enum.empty?(LazyHTML.query(document, "script, img, [onerror]"))
    assert LazyHTML.text(document) =~ "<script>alert(1)</script>"
    assert LazyHTML.text(document) =~ "<img src=x onerror=alert(1)>"
  end

  test "sanitizes javascript links in markdown widget content" do
    html =
      render_component(&PluginResults.plugin_results/1, %{
        display: [%{"widget" => "markdown", "content" => "[click](javascript:alert(1))"}]
      })

    refute html =~ "javascript:alert(1)"
    assert html =~ ~s(href="#")
  end

  test "sanitizes dangerous src protocols in markdown widget content" do
    html =
      render_component(&PluginResults.plugin_results/1, %{
        display: [%{"widget" => "markdown", "content" => "![x](javascript:alert(1))"}]
      })

    refute html =~ "javascript:alert(1)"
    assert html =~ ~s(src="")
  end
end
