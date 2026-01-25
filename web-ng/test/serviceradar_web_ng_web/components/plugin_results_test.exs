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
end
