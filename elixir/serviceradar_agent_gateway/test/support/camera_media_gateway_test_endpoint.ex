defmodule ServiceRadarAgentGateway.TestSupport.CameraMediaGatewayTestEndpoint do
  @moduledoc false

  use GRPC.Endpoint

  intercept(ServiceRadarAgentGateway.GRPCSafeLoggerInterceptor)

  run(ServiceRadarAgentGateway.CameraMediaServer)
end
