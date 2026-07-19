defmodule ServiceRadarWebNGWeb.DeviceLive.AnsiblePanelRuntimeTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.DeviceLive.AnsiblePanelRuntime

  test "launch_error_message distinguishes hold and preflight failures from the approval catch-all" do
    assert AnsiblePanelRuntime.launch_error_message({:target_held, "sr:device-1"}) =~
             "automation hold"

    assert AnsiblePanelRuntime.launch_error_message({:target_hold_lookup_failed, :db}) =~
             "target-hold"

    assert AnsiblePanelRuntime.launch_error_message(:authenticated_edge_principal_unavailable) =~
             "edge principal"

    assert AnsiblePanelRuntime.launch_error_message(:awx_preflight_unavailable) =~
             "preflight"

    assert AnsiblePanelRuntime.launch_error_message(:unknown_reason) =~
             "approval or authorization"
  end
end
