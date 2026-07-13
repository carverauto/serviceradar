defmodule ServiceRadarWebNGWeb.DeviceLive.AnsiblePanelComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadar.Automation.Ansible.VariableSchema.Var
  alias ServiceRadarWebNGWeb.DeviceLive.AnsiblePanelComponents

  @moduletag :db_free

  # Verified routes (`~p`) in the panel need the endpoint's config in
  # :persistent_term. In db-free mode the app isn't booted, so start the
  # endpoint here (idempotent across the suite).
  setup_all do
    if !Process.whereis(ServiceRadarWebNGWeb.Endpoint) do
      {:ok, _} = ServiceRadarWebNGWeb.Endpoint.start_link([])
    end

    :ok
  end

  defp target(overrides \\ %{}) do
    Map.merge(
      %{
        status: :ok,
        ok_count: 5,
        changed_count: 2,
        failed_count: 0,
        unreachable_count: 0,
        skipped_count: 0,
        started_at: ~U[2026-07-06 12:00:00Z],
        inserted_at: ~U[2026-07-06 11:59:00Z],
        awx_host_name: "web01",
        run: %{id: "run-123", state: :succeeded, playbook: %{name: "Deploy nginx"}}
      },
      overrides
    )
  end

  defp base_assigns(overrides) do
    Keyword.merge(
      [
        device_uid: "sr:abc",
        device_awx_managed: true,
        can_view_ansible_runs: true,
        can_run_ansible: true,
        device_deleted: false,
        ansible_controller_id: "ctrl-1",
        runs: [],
        playbooks: [%{id: "pb-1", name: "Deploy nginx", source_type: :awx}],
        launch_open: false,
        selected_playbook_id: nil,
        vars: [],
        var_values: %{},
        launch_notice: nil,
        launch_ready: false,
        launch_resolution: nil,
        launch_readiness: "Select a reviewed playbook.",
        launch_form: Phoenix.Component.to_form(%{})
      ],
      overrides
    )
  end

  test "renders run history for an AWX-managed device" do
    html =
      render_component(&AnsiblePanelComponents.ansible_runs_section/1, base_assigns(runs: [target()]))

    assert html =~ "device-ansible-panel"
    assert html =~ "Deploy nginx"
    # per-device host status + run state badges
    assert html =~ "succeeded"
    assert html =~ "5 ok"
    assert html =~ "2 chg"
    # link to the run detail page
    assert html =~ "/ansible/runs/run-123"
    # launch affordance present for a launcher
    assert html =~ "Run Task"
    assert html =~ ~s(phx-click="ansible_launch_open")
  end

  test "renders an empty state when the device has no runs" do
    html = render_component(&AnsiblePanelComponents.ansible_runs_section/1, base_assigns([]))

    assert html =~ "device-ansible-panel"
    assert html =~ "No playbook runs have targeted this device yet."
  end

  test "hides the whole panel for a non-AWX device" do
    html =
      render_component(
        &AnsiblePanelComponents.ansible_runs_section/1,
        base_assigns(device_awx_managed: false)
      )

    refute html =~ "device-ansible-panel"
    refute html =~ "Run Task"
  end

  test "hides the panel when the operator cannot view runs" do
    html =
      render_component(
        &AnsiblePanelComponents.ansible_runs_section/1,
        base_assigns(can_view_ansible_runs: false)
      )

    refute html =~ "device-ansible-panel"
  end

  test "launch modal renders the playbook picker and a declared-vars form" do
    var = %Var{
      name: "app_version",
      label: "app_version",
      type: :text,
      default: "1.4.0",
      required: false,
      private: false,
      choices: [],
      min: nil,
      max: nil,
      help: nil
    }

    html =
      render_component(
        &AnsiblePanelComponents.ansible_runs_section/1,
        base_assigns(
          launch_open: true,
          selected_playbook_id: "pb-1",
          vars: [var],
          var_values: %{"app_version" => "1.4.0"},
          launch_ready: true,
          launch_resolution: %{inventory_id: 34, binding_version: 2},
          launch_readiness: "Reviewed binding and exact target membership are ready."
        )
      )

    assert html =~ "Launch a reviewed playbook"
    assert html =~ ~s(phx-submit="ansible_launch")
    assert html =~ ~s(phx-change="ansible_launch_change")
    # the playbook picker lists the launchable template
    assert html =~ "Deploy nginx"
    # the declared-variable input is rendered, pre-filled with its default
    assert html =~ ~s(name="inputs[app_version]")
    assert html =~ ~s(value="1.4.0")
    assert html =~ "Binding approved"
    assert html =~ "Inventory 34"
    refute html =~ ~s(type="password")
  end

  test "launch button is disabled with a reason when no playbooks are launchable" do
    html =
      render_component(
        &AnsiblePanelComponents.ansible_runs_section/1,
        base_assigns(playbooks: [])
      )

    assert html =~ "Run Task"
    assert html =~ "disabled"
    assert html =~ "No launchable playbooks"
  end

  test "secret variables render a credential-binding warning instead of an input" do
    secret = %Var{name: "admin_password", label: "Admin password", type: :password, private: true}

    html =
      render_component(&AnsiblePanelComponents.var_input/1,
        var: secret,
        value: nil,
        name: "inputs[admin_password]"
      )

    assert html =~ "cannot be collected"
    refute html =~ "inputs[admin_password]"
    refute html =~ ~s(type="password")
  end
end
