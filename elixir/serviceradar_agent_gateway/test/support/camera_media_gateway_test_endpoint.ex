defmodule ServiceRadarAgentGateway.TestSupport.CameraMediaGatewayTestEndpoint do
  @moduledoc false

  use GRPC.Endpoint

  intercept(GRPC.Server.Interceptors.Logger)

  run(ServiceRadarAgentGateway.CameraMediaServer)
end
