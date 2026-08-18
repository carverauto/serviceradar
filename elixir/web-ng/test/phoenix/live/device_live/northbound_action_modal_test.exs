defmodule ServiceRadarWebNGWeb.DeviceLive.NorthboundActionModalTest do
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [to_form: 2]
  import Phoenix.LiveViewTest

  alias ServiceRadarWebNG.Northbound.ActionForm
  alias ServiceRadarWebNGWeb.NorthboundActionComponents

  @moduletag :db_free

  defp action(overrides \\ %{}) do
    Map.merge(
      %{
        id: "northbound:device:sample",
        descriptor_id: "018f0000-0000-7000-8000-000000000001",
        label: "Sample Device Action",
        description: "Runs a provider-neutral action against selected devices.",
        provider_type: "wasm_plugin",
        provider_name: "Network Automation",
        scope: "device",
        destination: nil,
        input_schema: %{
          "type" => "object",
          "required" => ["reason"],
          "properties" => %{
            "reason" => %{"type" => "string", "title" => "Reason"},
            "mode" => %{
              "type" => "string",
              "title" => "Mode",
              "enum" => ["audit", "enforce"],
              "default" => "audit"
            }
          }
        },
        safety_classification: "standard",
        requires_confirmation: true,
        timeout_seconds: 120,
        metadata: %{}
      },
      overrides
    )
  end

  defp render_modal(action) do
    render_component(&NorthboundActionComponents.northbound_action_modal/1,
      id: "northbound_action_modal",
      title: "Run Action",
      subtitle: "2 selected device(s)",
      form: to_form(ActionForm.default_params(action), as: :action),
      actions: [action],
      action: action,
      error: nil,
      close_event: "close_northbound_action_modal",
      change_event: "northbound_action_change",
      submit_event: "launch_northbound_action"
    )
  end

  test "renders only provider-neutral schema inputs" do
    html = render_modal(action())

    assert html =~ "Sample Device Action"
    assert html =~ ~s(name="action[input][reason]")
    assert html =~ ~s(name="action[input][mode]")
    assert html =~ ~s(<option value="audit" selected)

    refute html =~ "AWX"
    refute html =~ "Ansible"
    refute html =~ "raw extra_vars"
    refute html =~ ~s(name="action[raw_extra_vars]")
    refute html =~ ~s(name="action[vars])
  end

  test "renders a generic empty-input state" do
    html = render_modal(action(%{input_schema: %{"type" => "object", "properties" => %{}}}))

    assert html =~ "This action does not require additional input."
  end
end
