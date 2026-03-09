defmodule ServiceRadarWebNG.Edge.GatewayCertificateIssuerTest do
  use ServiceRadarWebNG.DataCase, async: false

  alias ServiceRadarWebNG.Edge.GatewayCertificateIssuer

  test "falls back to GatewayTracker when GatewayRegistry lookup is empty" do
    gateway_id = "tracker-gateway-#{System.unique_integer([:positive])}"

    ServiceRadar.GatewayTracker.register(gateway_id, %{
      node: Node.self(),
      partition: "default",
      domain: "default",
      status: :available
    })

    on_exit(fn ->
      ServiceRadar.GatewayTracker.unregister(gateway_id)
    end)

    assert {:error, :ca_not_available} =
             GatewayCertificateIssuer.issue_agent_bundle(
               gateway_id,
               "test-agent",
               "default",
               []
             )
  end
end
