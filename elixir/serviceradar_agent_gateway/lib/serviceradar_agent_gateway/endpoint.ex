defmodule ServiceRadarAgentGateway.Endpoint do
  @moduledoc """
  gRPC endpoint for the agent gateway.

  This endpoint exposes the AgentGatewayService for receiving
  status pushes from Go agents.
  """

  use GRPC.Endpoint

  intercept(GRPC.Server.Interceptors.Logger)

  run(ServiceRadarAgentGateway.AgentGatewayServer)
end
