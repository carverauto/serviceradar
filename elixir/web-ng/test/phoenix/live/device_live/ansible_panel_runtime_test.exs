defmodule ServiceRadarWebNGWeb.DeviceLive.AnsiblePanelRuntimeTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.DeviceLive.AnsiblePanelRuntime

  @moduletag :db_free

  test "defaults expose canonical operation history without legacy run assigns" do
    socket =
      AnsiblePanelRuntime.assign_defaults(%Phoenix.LiveView.Socket{
        assigns: %{__changed__: %{}}
      })

    assert socket.assigns.ansible_operation_history == []
    refute Map.has_key?(socket.assigns, :ansible_secure_history)
    refute Map.has_key?(socket.assigns, :ansible_runs)
  end

  test "AWX-managed detection retains existing device-data fallbacks" do
    assert AnsiblePanelRuntime.awx_managed?(%{
             "metadata" => %{"awx" => %{"host_id" => 42}}
           })

    assert AnsiblePanelRuntime.awx_managed?(%{"ansible_managed" => true})
    assert AnsiblePanelRuntime.awx_managed?(%{"discovery_sources" => ["awx"]})
    assert AnsiblePanelRuntime.awx_managed?(%{"discovery_sources" => "{snmp,ansible}"})
    refute AnsiblePanelRuntime.awx_managed?(%{"discovery_sources" => ["snmp"]})
  end

  test "launch_error_message distinguishes hold and preflight failures from the approval catch-all" do
    assert AnsiblePanelRuntime.launch_error_message({:target_held, "sr:device-1"}) =~
             "automation hold"

    assert AnsiblePanelRuntime.launch_error_message({:target_hold_lookup_failed, :db}) =~
             "target-hold"

    assert AnsiblePanelRuntime.launch_error_message(:authenticated_edge_principal_unavailable) =~
             "edge principal"

    assert AnsiblePanelRuntime.launch_error_message(:awx_preflight_unavailable) =~
             "preflight"

    for {reason, category} <- [
          {:awx_preflight_controller_drift, "controller"},
          {:awx_preflight_template_project_drift, "template or project"},
          {:awx_preflight_inventory_drift, "inventory"},
          {:awx_preflight_credential_set_drift, "credential set"},
          {:awx_preflight_execution_environment_drift, "execution environment"},
          {:awx_preflight_survey_contract_drift, "survey contract"},
          {:awx_preflight_prompt_policy_drift, "launch-prompt policy"},
          {:awx_preflight_target_drift, "target"}
        ] do
      message = AnsiblePanelRuntime.launch_error_message(reason)
      assert message =~ category
      assert message =~ "authorized reviewer" or message =~ "request binding review"
      refute message =~ "token"
    end

    assert AnsiblePanelRuntime.launch_error_message(:unknown_reason) =~
             "approval or authorization"
  end
end
