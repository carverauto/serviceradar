defmodule ServiceRadarAgentGateway.TestSupport.EdgeRecordIdentityResolverStub do
  @moduledoc false

  def resolve_edge_identity(_cert_der, expected_type) do
    {:ok,
     %{
       component_id: "agent-1",
       component_type: expected_type,
       partition_id: "default",
       installation_trust_id: "test-installation",
       gateway_id: "test-gateway",
       spiffe_id: nil
     }}
  end
end
