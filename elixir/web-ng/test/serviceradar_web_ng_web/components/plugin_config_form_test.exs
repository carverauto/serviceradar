defmodule ServiceRadarWebNGWeb.PluginConfigFormTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNGWeb.PluginConfigForm

  @moduletag :db_free

  @camera_schema %{
    "type" => "object",
    "properties" => %{
      "host" => %{
        "type" => "string",
        "x-serviceradar-ui-hidden" => true,
        "x-serviceradar-credential-materialized" => true,
        "description" => "Controller host, injected per target."
      },
      "scheme" => %{"type" => "string", "description" => "http or https"}
    }
  }

  defp render_fields(assigns) do
    render_component(&PluginConfigForm.plugin_config_fields/1, assigns)
  end

  test "credential-materialized fields render as informational rows, not inputs" do
    html = render_fields(%{schema: @camera_schema, params: %{}, base_name: "assignment[params]"})

    assert html =~ "Provided by credential rules"
    assert html =~ ~s(data-credential-materialized="host")
    # No input is rendered for the materialized field.
    refute html =~ ~s(name="assignment[params][host]")
    # Ordinary fields still render as inputs.
    assert html =~ ~s(name="assignment[params][scheme]")
  end

  test "without coverage info the row shows the neutral runtime explanation" do
    html = render_fields(%{schema: @camera_schema, params: %{}})

    assert html =~ "materialized per target by credential rules at runtime"
    refute html =~ "matches this agent"
    refute html =~ "No enabled"
  end

  test "covered agents show the matching rule in green" do
    coverage = %{
      state: :covered,
      provider: "unifi-protect",
      purpose: :camera_inventory,
      rules: ["Protect HQ"]
    }

    html = render_fields(%{schema: @camera_schema, params: %{}, credential_coverage: coverage})

    assert html =~ "text-success"
    assert html =~ "Protect HQ"
    assert html =~ "matches this agent"
  end

  test "uncovered agents show an amber warning naming provider and purpose" do
    coverage = %{
      state: :uncovered,
      provider: "unifi-protect",
      purpose: :camera_inventory,
      rules: []
    }

    html = render_fields(%{schema: @camera_schema, params: %{}, credential_coverage: coverage})

    assert html =~ "text-warning"
    assert html =~ "No enabled unifi-protect/camera_inventory credential rule matches this agent"
  end

  test "ui-hidden fields without the annotation stay hidden" do
    schema = %{
      "type" => "object",
      "properties" => %{
        "internal" => %{"type" => "string", "x-serviceradar-ui-hidden" => true}
      }
    }

    html = render_fields(%{schema: schema, params: %{}})

    refute html =~ "internal"
    refute html =~ "Provided by credential rules"
  end

  test "schema required arrays still mark fields as required" do
    schema = %{
      "type" => "object",
      "required" => ["base_url"],
      "properties" => %{"base_url" => %{"type" => "string"}}
    }

    html = render_fields(%{schema: schema, params: %{}})

    assert html =~ "base_url"
    assert html =~ ~s(<span class="text-error">*</span>)
  end
end
