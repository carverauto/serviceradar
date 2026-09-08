defmodule ServiceRadarWebNGWeb.DeviceLive.AnsiblePanelComponentsTest do
  # The verified-route component needs the singleton endpoint persistent term.
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest

  alias ServiceRadar.Automation.Ansible.VariableSchema.Var
  alias ServiceRadarWebNGWeb.DeviceLive.AnsiblePanelComponents

  @moduletag :db_free

  # Verified routes (`~p`) in the panel need the endpoint's config in
  # :persistent_term. In db-free mode the app isn't booted, so start the
  # endpoint here (idempotent across the suite).
  setup_all do
    if !Process.whereis(ServiceRadarWebNGWeb.Endpoint) do
      case ServiceRadarWebNGWeb.Endpoint.start_link([]) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end

    :ok
  end

  defp base_assigns(overrides) do
    Keyword.merge(
      [
        device_uid: "sr:abc",
        device_awx_managed: true,
        can_view_ansible_operations: true,
        can_run_ansible: true,
        device_deleted: false,
        ansible_controller_id: "ctrl-1",
        playbooks: [%{id: "pb-1", name: "Deploy nginx", source_type: :awx}],
        launch_open: false,
        selected_playbook_id: nil,
        vars: [],
        var_values: %{},
        launch_notice: nil,
        launch_ready: false,
        launch_resolution: nil,
        launch_readiness: "Select a reviewed playbook.",
        launch_form: Phoenix.Component.to_form(%{}),
        timezone: "America/Chicago"
      ],
      overrides
    )
  end

  test "renders canonical automation links for an AWX-managed device" do
    html = render_component(&AnsiblePanelComponents.ansible_operations_section/1, base_assigns([]))

    assert html =~ "device-ansible-panel"
    assert html =~ "/images/integrations/ansible.svg"
    assert html =~ "/images/integrations/ansible-dark.svg"
    refute html =~ "hero-command-line"
    assert html =~ "/ansible/operations"
    assert html =~ "All operations"
    assert html =~ "Launch Playbook"
    assert html =~ ~s(phx-click="ansible_launch_open")
    refute html =~ "/ansible/runs"
    refute String.downcase(html) =~ "legacy"
  end

  test "renders canonical automation operation history" do
    operation_record = %{
      operation: %{
        id: "operation-12345678",
        state: :running,
        started_at: ~U[2026-07-13 12:00:00Z]
      },
      execution: %{
        state: :scope_verified,
        scope_verified_at: ~U[2026-07-13 12:00:30Z],
        awx_job_id: 77,
        started_at: ~U[2026-07-13 12:00:05Z],
        controller: %{id: "controller-1", name: "farm01-awx"}
      },
      target: %{
        status: :ok,
        awx_host_id: 7,
        membership_generation: 2,
        host_name: "web01",
        ansible_host: "192.0.2.10",
        controller_id: "controller-1",
        inventory_id: 34,
        active_hold: nil
      }
    }

    document =
      (&AnsiblePanelComponents.ansible_operations_section/1)
      |> render_component(base_assigns(operation_history: [operation_record]))
      |> LazyHTML.from_fragment()

    assert Enum.count(LazyHTML.query(document, "[data-testid=device-ansible-operation-history]")) == 1

    operation_text =
      document
      |> LazyHTML.query("[data-testid=device-ansible-operation-history]")
      |> LazyHTML.text()

    assert operation_text =~ "farm01-awx"
    assert operation_text =~ "controller-1 / inventory 34"
    assert operation_text =~ "host 7 · gen 2"
    assert operation_text =~ "controller-local"

    time =
      LazyHTML.query(
        document,
        "#device-ansible-operation-operation-12345678-started-at[data-user-time-zone='America/Chicago']"
      )

    assert LazyHTML.attribute(time, "datetime") == ["2026-07-13T12:00:05Z"]

    assert LazyHTML.attribute(
             LazyHTML.query(document, "a[href='/ansible/operations/operation-12345678']"),
             "href"
           ) == ["/ansible/operations/operation-12345678"]

    panel_text = LazyHTML.text(document)
    assert panel_text =~ "Recent operations"
    refute String.downcase(panel_text) =~ "legacy"
  end

  test "renders an empty state when the device has no operations" do
    html = render_component(&AnsiblePanelComponents.ansible_operations_section/1, base_assigns([]))

    assert html =~ "device-ansible-panel"
    assert html =~ "No Ansible operations have targeted this device yet."
  end

  test "hides the whole panel for a non-AWX device" do
    html =
      render_component(
        &AnsiblePanelComponents.ansible_operations_section/1,
        base_assigns(device_awx_managed: false)
      )

    refute html =~ "device-ansible-panel"
    refute html =~ "Launch Playbook"
  end

  test "launch-only operator sees launch without operation history affordances" do
    html =
      render_component(
        &AnsiblePanelComponents.ansible_operations_section/1,
        base_assigns(can_view_ansible_operations: false)
      )

    assert html =~ "device-ansible-panel"
    assert html =~ "Launch Playbook"
    refute html =~ "All operations"
    refute html =~ "No Ansible operations have targeted this device yet."
    refute html =~ "Recent operations"
  end

  test "hides the panel without operation-view or launch permission" do
    html =
      render_component(
        &AnsiblePanelComponents.ansible_operations_section/1,
        base_assigns(can_view_ansible_operations: false, can_run_ansible: false)
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
        &AnsiblePanelComponents.ansible_operations_section/1,
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
        &AnsiblePanelComponents.ansible_operations_section/1,
        base_assigns(playbooks: [])
      )

    assert html =~ "Launch Playbook"
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
