defmodule ServiceRadarWebNGWeb.Components.PluginConfigFormTest do
  @moduledoc false

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNGWeb.PluginConfigForm

  @moduletag :unit

  test "renders fields from schema" do
    schema = %{
      "type" => "object",
      "properties" => %{
        "url" => %{"type" => "string", "title" => "Target URL"},
        "timeout" => %{"type" => "integer", "title" => "Timeout"}
      },
      "required" => ["url"]
    }

    html =
      render_component(&PluginConfigForm.plugin_config_fields/1, %{
        schema: schema,
        params: %{"url" => "https://example.com", "timeout" => 10},
        base_name: "assignment[params]"
      })

    assert html =~ "Target URL"
    assert html =~ "Timeout"
    assert html =~ "assignment[params][url]"
    assert html =~ "assignment[params][timeout]"
  end
end
