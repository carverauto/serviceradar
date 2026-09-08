defmodule ServiceRadarAgentGateway.TestSupport.CameraMediaIdentityResolverStub do
  @moduledoc false

  def resolve_from_cert(_cert_der) do
    {:ok, %{component_id: "agent-1", component_type: :agent, partition_id: "default"}}
  end
end
