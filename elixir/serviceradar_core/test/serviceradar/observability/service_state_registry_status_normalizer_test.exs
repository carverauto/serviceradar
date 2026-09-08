defmodule ServiceRadar.Observability.ServiceStateRegistry.StatusNormalizerTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Observability.ServiceStateRegistry.StatusNormalizer
  alias ServiceRadar.Plugins.PluginAssignment
  alias ServiceRadar.Plugins.PluginPackage

  test "assignment placeholders use the immutable assignment partition over mutable agent metadata" do
    assignment = %PluginAssignment{
      id: "11ba9c1c-4934-4863-a1bc-677b20adba0f",
      agent_uid: "shared-pve-name",
      partition_id: "farm01",
      enabled: true
    }

    package = %PluginPackage{
      id: "ff0a3144-1f05-4aca-bb05-aeeb882f3e2c",
      plugin_id: "proxmox-inventory",
      name: "Proxmox inventory",
      version: "1.0.0",
      status: :approved,
      outputs: "serviceradar.plugin_result.v1"
    }

    agent = %{
      gateway_id: "farm01-gateway",
      metadata: %{"partition_id" => "tonka01"}
    }

    attrs = StatusNormalizer.build_attrs_from_assignment(assignment, agent, package)

    assert attrs.agent_id == "shared-pve-name"
    assert attrs.gateway_id == "farm01-gateway"
    assert attrs.partition == "farm01"
  end
end
