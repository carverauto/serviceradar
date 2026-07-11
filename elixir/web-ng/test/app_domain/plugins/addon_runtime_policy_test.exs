defmodule ServiceRadarWebNG.Plugins.AddonRuntimePolicyTest do
  use ExUnit.Case, async: false

  alias ServiceRadarWebNG.Plugins.AddonRuntimePolicy

  @moduletag :db_free

  setup do
    old_required_addons = Application.get_env(:serviceradar_core, :required_agent_addons)

    on_exit(fn ->
      if is_nil(old_required_addons) do
        Application.delete_env(:serviceradar_core, :required_agent_addons)
      else
        Application.put_env(:serviceradar_core, :required_agent_addons, old_required_addons)
      end
    end)

    :ok
  end

  test "recognizes string and map required-runtime configuration without treating retired add-ons as required" do
    Application.put_env(:serviceradar_core, :required_agent_addons, [
      "otel-collector",
      %{addon_id: "workload-identity"},
      %{"addon_id" => "advisory-producer"}
    ])

    assert AddonRuntimePolicy.required_addon_ids() == ["otel-collector", "workload-identity"]
    assert AddonRuntimePolicy.management_mode("otel-collector", false) == :required
    assert AddonRuntimePolicy.management_mode("custom-addon", false) == :observed
    assert AddonRuntimePolicy.management_mode("otel-collector", true) == :assignment
  end

  test "classifies the agent's cgroup fallback as an operational warning" do
    assert AddonRuntimePolicy.resource_limit_warning?(
             "resource limits not enforced: create addon cgroup root: permission denied"
           )

    refute AddonRuntimePolicy.resource_limit_warning?("health probe failed")
    refute AddonRuntimePolicy.resource_limit_warning?(nil)
  end
end
