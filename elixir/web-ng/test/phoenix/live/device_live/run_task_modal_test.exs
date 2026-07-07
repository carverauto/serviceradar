defmodule ServiceRadarWebNGWeb.DeviceLive.RunTaskModalTest do
  @moduledoc """
  Pure component tests for the bulk Devices "Run Task" modal: AWX applicability
  gating (summary + skipped-device callout + disabled launch) and the typed
  ansible variable form. No database — renders the component directly.
  """
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [to_form: 2]
  import Phoenix.LiveViewTest

  alias ServiceRadar.Automation.Ansible.VariableSchema.Var
  alias ServiceRadarWebNGWeb.NorthboundActionComponents

  @moduletag :db_free

  defp action do
    %{
      id: "northbound:device:sample",
      descriptor_id: "018f0000-0000-7000-8000-000000000001",
      label: "Sample Device Lookup",
      description: "Runs an AWX playbook against the selected devices.",
      provider_type: "ansible",
      provider_name: "AWX",
      scope: "device",
      destination: nil,
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "extra_vars" => %{"type" => "object", "title" => "Extra Vars", "default" => %{}}
        }
      },
      safety_classification: "standard",
      requires_confirmation: true,
      timeout_seconds: 300,
      metadata: %{"playbook_id" => "pb-1", "source_type" => "awx"}
    }
  end

  defp base_assigns do
    action = action()

    [
      id: "northbound_action_modal",
      title: "Run Task",
      subtitle: "3 selected device(s)",
      form: to_form(%{"action_id" => action.id, "input" => %{}}, as: :action),
      actions: [action],
      action: action,
      error: nil,
      close_event: "close_northbound_action_modal",
      change_event: "northbound_action_change",
      submit_event: "launch_northbound_action",
      toggle_raw_event: "toggle_northbound_raw_extra_vars"
    ]
  end

  defp render_modal(overrides) do
    render_component(
      &NorthboundActionComponents.northbound_action_modal/1,
      Keyword.merge(base_assigns(), overrides)
    )
  end

  describe "AWX applicability gating" do
    test "summarizes applicable count and names the skipped devices" do
      html =
        render_modal(
          applicability: %{
            applicable_count: 1,
            total_count: 3,
            non_applicable: [%{uid: "uid-a", label: "host-a"}, %{uid: "uid-b", label: "pve02"}]
          }
        )

      assert html =~ "1 of 3 selected device(s) are AWX-managed"
      assert html =~ "Not in an AWX inventory (will be skipped):"
      assert html =~ "host-a"
      assert html =~ "pve02"
      # Applicable devices exist -> Create Invocation stays enabled.
      refute html =~ ~s(<button type="submit" class="btn btn-primary" disabled)
    end

    test "truncates a long non-applicable list with +N more" do
      non_applicable = for i <- 1..14, do: %{uid: "uid-#{i}", label: "host-#{i}"}

      html =
        render_modal(applicability: %{applicable_count: 2, total_count: 16, non_applicable: non_applicable})

      assert html =~ "host-1"
      assert html =~ "+4 more"
      refute html =~ "host-14"
    end

    test "disables launch and explains when no selected device is AWX-managed" do
      html =
        render_modal(
          applicability: %{
            applicable_count: 0,
            total_count: 2,
            non_applicable: [%{uid: "uid-a", label: "host-a"}, %{uid: "uid-b", label: "host-b"}]
          }
        )

      assert html =~ "0 of 2 selected device(s) are AWX-managed"
      assert html =~ "Only AWX-managed devices can run Ansible tasks"
      assert html =~ ~s(<button type="submit" class="btn btn-primary" disabled)
    end

    test "renders no gating block when applicability is nil (non-bulk usage)" do
      html = render_modal(applicability: nil)

      refute html =~ "selected device(s) are AWX-managed"
      refute html =~ "Not in an AWX inventory"
    end
  end

  describe "typed ansible variable form" do
    test "renders a typed form for the selected task's declared variables" do
      vars = [
        %Var{name: "target_hostname", label: "Target hostname", type: :text, required: true},
        %Var{name: "mode", label: "Mode", type: :select, choices: ["audit", "enforce"]}
      ]

      html =
        render_modal(
          applicability: %{applicable_count: 2, total_count: 2, non_applicable: []},
          ansible_vars: vars,
          ansible_var_values: %{"mode" => "audit"},
          raw_extra_vars_open: false,
          raw_extra_vars: ""
        )

      assert html =~ ~s(name="action[vars][target_hostname]")
      assert html =~ ~s(name="action[vars][mode]")
      assert html =~ "Target hostname"
      assert html =~ "Variables"
      assert html =~ "Advanced: raw extra_vars JSON"
      # The freeform extra_vars JSON schema textarea is replaced by the typed form.
      refute html =~ ~s(name="action[input][extra_vars]")
    end

    test "shows a tidy no-variables state for a variable-free task" do
      html =
        render_modal(
          applicability: %{applicable_count: 1, total_count: 1, non_applicable: []},
          ansible_vars: [],
          ansible_var_values: %{},
          raw_extra_vars_open: false,
          raw_extra_vars: ""
        )

      assert html =~ "This task requires no variables"
      assert html =~ "Advanced: raw extra_vars JSON"
      refute html =~ "{}"
    end

    test "shows the raw extra_vars textarea only when the advanced section is open" do
      opened =
        render_modal(
          applicability: %{applicable_count: 1, total_count: 1, non_applicable: []},
          ansible_vars: [],
          ansible_var_values: %{},
          raw_extra_vars_open: true,
          raw_extra_vars: ~s({"foo": "bar"})
        )

      assert opened =~ ~s(name="action[raw_extra_vars]")
      assert opened =~ "foo"
    end

    test "falls back to the JSON-schema fields for a non-ansible action" do
      html =
        render_modal(
          applicability: %{applicable_count: 1, total_count: 1, non_applicable: []},
          ansible_vars: nil
        )

      # ansible_vars nil -> descriptor schema (extra_vars object) is rendered.
      assert html =~ ~s(name="action[input][extra_vars]")
      refute html =~ ~s(name="action[vars])
    end
  end
end
