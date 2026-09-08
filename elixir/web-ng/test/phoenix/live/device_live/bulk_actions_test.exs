defmodule ServiceRadarWebNGWeb.DeviceLive.BulkActionsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNGWeb.DeviceLive.IndexView.BulkActions

  @moduletag :db_free

  defp render_actions(permissions) do
    render_component(&BulkActions.render/1,
      selected_count: 1,
      select_all_matching: false,
      total_matching_count: nil,
      srql: %{},
      current_scope: %Scope{user: %{id: "user-1"}, permissions: MapSet.new(permissions)},
      effective_count: 1,
      northbound_device_actions_loading: false,
      run_action_disabled?: false,
      run_action_title: "Run action for selected devices"
    )
  end

  test "Ansible launch permission exposes only the canonical playbook launch" do
    html = render_actions(["ansible.runs.launch"])

    assert html =~ "Launch Playbook"
    assert html =~ ~s(phx-click="launch_ansible_for_selection")
    refute html =~ "Run Action"
    refute html =~ ~s(phx-click="run_action_for_selection")
  end

  test "northbound launch permission exposes only the provider-neutral action" do
    html = render_actions(["northbound.actions.launch"])

    assert html =~ "Run Action"
    assert html =~ ~s(phx-click="run_action_for_selection")
    refute html =~ "Launch Playbook"
    refute html =~ ~s(phx-click="launch_ansible_for_selection")
  end
end
