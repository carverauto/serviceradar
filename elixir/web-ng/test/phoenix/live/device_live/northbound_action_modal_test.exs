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

  test "labels credential rule options by name and submits the rule id" do
    rule_id = "018f3f56-4444-7222-8333-123456789abc"

    html =
      render_modal(
        action(%{
          input_schema: %{
            "type" => "object",
            "properties" => %{
              "destination_rule_id" => %{
                "type" => "string",
                "enum" => [rule_id],
                "x-enum-labels" => %{rule_id => "Example destination account"}
              }
            }
          }
        })
      )

    assert html =~ ~s(<option value="#{rule_id}")
    assert html =~ "Example destination account"
  end

  test "renders a generic empty-input state" do
    html = render_modal(action(%{input_schema: %{"type" => "object", "properties" => %{}}}))

    assert html =~ "This action does not require additional input."
  end

  test "required credential rule options errors hide input and disable submit" do
    html =
      render_modal(
        action(%{
          input_schema: %{
            "type" => "object",
            "required" => ["destination_rule_id"],
            "properties" => %{
              "destination_rule_id" => %{
                "type" => "string",
                "x-credential-rule-options-error" => true
              }
            }
          }
        })
      )

    assert html =~ "Credential rule options are unavailable; try again later"
    refute html =~ ~s(name="action[input][destination_rule_id]")
    assert Regex.match?(~r/disabled[^:]/, html)
  end

  test "empty credential rule choices block free-text submission" do
    action =
      action(%{
        input_schema: %{
          "type" => "object",
          "required" => ["destination_rule_id"],
          "properties" => %{
            "destination_rule_id" => %{
              "type" => "string",
              "enum" => [],
              "x-credential-rule-options-empty" => true
            }
          }
        }
      })

    html = render_modal(action)
    assert html =~ "No credential rules are available for this action."
    refute html =~ ~s(name="action[input][destination_rule_id]")
    assert Regex.match?(~r/disabled[^:]/, html)

    assert {:error, {:credential_rule_options_empty, "destination_rule_id"}} =
             ActionForm.parse_input(action, %{
               "input" => %{"destination_rule_id" => "arbitrary-rule-id"}
             })

    assert {:error, {:missing_required_input, "destination_rule_id"}} =
             ActionForm.parse_input(action, %{"input" => %{}})
  end

  test "optional credential rule inputs remain omittable when options are unavailable" do
    action =
      action(%{
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "destination_rule_id" => %{
              "type" => "string",
              "x-credential-rule-options-error" => true
            },
            "source_rule_id" => %{
              "type" => "string",
              "enum" => [],
              "x-credential-rule-options-empty" => true
            }
          }
        }
      })

    html = render_modal(action)

    assert html =~ "Credential rule options are unavailable; try again later"
    assert html =~ "No credential rules are available for this action."
    refute Regex.match?(~r/disabled[^:]/, html)

    assert {:ok, %{}} = ActionForm.parse_input(action, %{"input" => %{}})
  end
end
