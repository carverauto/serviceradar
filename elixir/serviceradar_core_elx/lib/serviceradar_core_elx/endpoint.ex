defmodule ServiceRadarCoreElx.Endpoint do
  @moduledoc """
  gRPC endpoint for core-elx camera media ingress.
  """

  use GRPC.Endpoint

  intercept(GRPC.Server.Interceptors.Logger)

  run(ServiceRadarCoreElx.CameraMediaServer)
end
