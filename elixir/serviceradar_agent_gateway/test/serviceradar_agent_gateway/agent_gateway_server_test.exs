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
end
