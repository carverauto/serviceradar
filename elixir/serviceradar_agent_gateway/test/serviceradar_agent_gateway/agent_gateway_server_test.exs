defmodule ServiceRadarAgentGateway.AgentGatewayServerTest do
  use ExUnit.Case, async: false

  alias ServiceRadarAgentGateway.AgentGatewayServer
  alias ServiceRadarAgentGateway.Config

  setup do
    previous_config =
      try do
        Config.get()
      rescue
        # credo:disable-for-next-line ExSlop.Check.Warning.BlanketRescue
        ArgumentError -> nil
      end

    on_exit(fn ->
      if previous_config do
        Config.setup(
          gateway_id: previous_config.gateway_id,
          domain: previous_config.domain,
          capabilities: previous_config.capabilities
        )
      end
    end)

    :ok
  end

  test "uses configured logical gateway id for external attribution" do
    Config.setup(gateway_id: "gateway-platform", domain: "demo")

    assert AgentGatewayServer.gateway_id() == "gateway-platform"
    refute AgentGatewayServer.gateway_id() == Atom.to_string(node())
  end

  describe "device_attrs_from_request/3 — gateway bridge for identity evidence" do
    # These tests guard the bridge that carries host_macs from the protobuf
    # request to AgentGatewaySync.ensure_device_for_agent/2. If host_macs is
    # accidentally removed from device_attrs_from_request the evidence silently
    # stops reaching core identity reconciliation, so each request type that
    # calls ensure_device_for_agent is covered here.

    test "unary enrollment hello (AgentHelloRequest) forwards host_macs to device attrs" do
      request = %Monitoring.AgentHelloRequest{
        agent_id: "agent-test-01",
        hostname: "node-a",
        os: "linux",
        arch: "amd64",
        host_ip: "192.0.2.10",
        host_macs: ["00:00:5e:00:53:01"]
      }

      attrs = AgentGatewayServer.device_attrs_from_request("partition-1", request, "192.0.2.10")

      assert attrs.host_macs == ["00:00:5e:00:53:01"]
      assert attrs.source_ip == "192.0.2.10"
      assert attrs.partition == "partition-1"
    end

    test "control-stream hello (ControlStreamHello) forwards host_macs to device attrs" do
      hello = %Monitoring.ControlStreamHello{
        agent_id: "agent-test-02",
        hostname: "node-b",
        os: "linux",
        arch: "amd64",
        host_ip: "192.0.2.11",
        host_macs: ["00:00:5e:00:53:02", "00:00:5e:00:53:03"]
      }

      attrs = AgentGatewayServer.device_attrs_from_request("partition-2", hello, "192.0.2.11")

      assert attrs.host_macs == ["00:00:5e:00:53:02", "00:00:5e:00:53:03"]
      assert attrs.source_ip == "192.0.2.11"
      assert attrs.partition == "partition-2"
    end

    test "unary enrollment hello without host_macs is backward compatible" do
      request = %Monitoring.AgentHelloRequest{
        agent_id: "agent-test-03",
        hostname: "node-c",
        host_ip: "192.0.2.12"
      }

      attrs = AgentGatewayServer.device_attrs_from_request("partition-1", request, "192.0.2.12")

      assert attrs.host_macs == []
    end

    test "control-stream hello without host_macs is backward compatible" do
      hello = %Monitoring.ControlStreamHello{
        agent_id: "agent-test-04",
        hostname: "node-d",
        host_ip: "192.0.2.13"
      }

      attrs = AgentGatewayServer.device_attrs_from_request("partition-2", hello, "192.0.2.13")

      assert attrs.host_macs == []
    end

    test "prefers reported host_ip over TCP peer address for source_ip" do
      request = %Monitoring.AgentHelloRequest{
        agent_id: "agent-test-05",
        host_ip: "192.0.2.20",
        host_macs: ["00:00:5e:00:53:04"]
      }

      attrs = AgentGatewayServer.device_attrs_from_request("partition-1", request, "198.51.100.5")

      assert attrs.source_ip == "192.0.2.20"
    end
  end
end
