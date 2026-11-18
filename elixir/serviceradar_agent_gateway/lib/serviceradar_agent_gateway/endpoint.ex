defmodule ServiceRadarAgentGateway.Endpoint do
  @moduledoc """
  gRPC endpoint for the agent gateway.

  This endpoint exposes the AgentGatewayService for receiving
  status pushes from Go agents.
  """

  use GRPC.Endpoint

  # Declared first so it is the outermost interceptor: the request log line and everything after
  # it run inside the SERVER span.
  intercept(ServiceRadarAgentGateway.GRPCTraceInterceptor)
  intercept(ServiceRadarAgentGateway.GRPCSafeLoggerInterceptor)

  run(ServiceRadarAgentGateway.AgentGatewayServer)
  run(ServiceRadarAgentGateway.CameraMediaServer)
  run(ServiceRadarAgentGateway.DesktopMediaServer)
  run(ServiceRadarAgentGateway.RemoteCaptureServer)
  run(ServiceRadarAgentGateway.EdgeRecordIngestServer)
end
