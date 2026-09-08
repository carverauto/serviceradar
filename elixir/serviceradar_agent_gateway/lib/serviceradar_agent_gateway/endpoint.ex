defmodule ServiceRadarAgentGateway.Endpoint do
  @moduledoc """
  gRPC endpoint for the agent gateway.

  This endpoint exposes the AgentGatewayService for receiving
  status pushes from Go agents.
  """

  use GRPC.Endpoint

  intercept(ServiceRadarAgentGateway.GRPCSafeLoggerInterceptor)

  run(ServiceRadarAgentGateway.AgentGatewayServer)
  run(ServiceRadarAgentGateway.CameraMediaServer)
  run(ServiceRadarAgentGateway.DesktopMediaServer)
  run(ServiceRadarAgentGateway.RemoteCaptureServer)
end
