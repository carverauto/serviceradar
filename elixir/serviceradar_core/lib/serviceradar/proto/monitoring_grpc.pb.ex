defmodule Monitoring.AgentService.Service do
  @moduledoc false

  use GRPC.Service, name: "monitoring.AgentService", protoc_gen_elixir_version: "0.13.0"

  rpc(:GetStatus, Monitoring.StatusRequest, Monitoring.StatusResponse)
  rpc(:GetResults, Monitoring.ResultsRequest, Monitoring.ResultsResponse)
  rpc(:StreamResults, Monitoring.ResultsRequest, stream(Monitoring.ResultsChunk))
end

defmodule Monitoring.AgentService.Stub do
  @moduledoc false

  use GRPC.Stub, service: Monitoring.AgentService.Service
end

defmodule Monitoring.AgentGatewayService.Service do
  @moduledoc false

  use GRPC.Service, name: "monitoring.AgentGatewayService", protoc_gen_elixir_version: "0.13.0"

  rpc(:Hello, Monitoring.AgentHelloRequest, Monitoring.AgentHelloResponse)
  rpc(:GetConfig, Monitoring.AgentConfigRequest, Monitoring.AgentConfigResponse)
  rpc(:PushStatus, Monitoring.GatewayStatusRequest, Monitoring.GatewayStatusResponse)
  rpc(:StreamStatus, stream(Monitoring.GatewayStatusChunk), Monitoring.GatewayStatusResponse)
end

defmodule Monitoring.AgentGatewayService.Stub do
  @moduledoc false

  use GRPC.Stub, service: Monitoring.AgentGatewayService.Service
end
