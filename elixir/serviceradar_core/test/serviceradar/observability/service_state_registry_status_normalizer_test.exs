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

  describe "attrs_from_status/3 message" do
    defp attrs(message) do
      StatusNormalizer.attrs_from_status(
        %{
          agent_id: "agent-1",
          gateway_id: "gateway-1",
          partition: "default",
          service_type: "sweep",
          service_name: "network_sweep",
          available: true,
          message: message
        },
        nil,
        preserve_gateway?: true
      )
    end

    test "a message longer than 2048 characters is kept whole, never cut" do
      text = String.duplicate("probe timed out on 192.0.2.10; ", 200)
      assert String.length(text) > 2048

      assert attrs(text).message == text

      summary = String.duplicate("é", 3_000)
      assert attrs(Jason.encode!(%{"summary" => summary, "hosts" => []})).message == summary
    end

    test "a structured payload with no summary of its own is kept whole in details, not copied into message" do
      document = %{
        "total_hosts" => 600,
        "hosts" =>
          Enum.map(1..600, &%{"host" => "198.51.100.#{rem(&1, 250)}", "available" => false})
      }

      encoded = Jason.encode!(document)
      assert byte_size(encoded) > 2048

      result = attrs(encoded)

      assert result.message == nil
      assert Jason.decode!(result.details) == document
    end
  end
end
