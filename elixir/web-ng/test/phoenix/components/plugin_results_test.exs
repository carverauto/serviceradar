defmodule ServiceRadarWebNGWeb.Components.PluginResultsTest do
  @moduledoc false

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNGWeb.PluginResults

  @moduletag :unit

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
