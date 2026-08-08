defmodule ServiceRadarAgentGateway.SafeGrpcLoggerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ServiceRadarAgentGateway.SafeGrpcLogger

  @moduletag :requires_app

  test "logs gRPC method and status without request or response bodies" do
    stream = %GRPC.Server.Stream{
      server: ServiceRadarAgentGateway.AgentGatewayServer,
      rpc: {:hello, nil},
      request_id: "request-1"
    }

    req = %{agent_id: "agent-1", password: "request-secret"}

    log =
      capture_log(fn ->
        assert {:ok, ^stream, %{token: "response-secret"}} =
                 SafeGrpcLogger.call(
                   req,
                   stream,
                   fn _req, stream ->
                     {:ok, stream, %{token: "response-secret"}}
                   end,
                   level: :warning
                 )
      end)

    assert log =~ "gRPC request completed"
    assert log =~ "method=hello"
    assert log =~ "status=ok"
    assert log =~ "actor=unknown"
    refute log =~ "request-secret"
    refute log =~ "response-secret"
    refute log =~ "agent-1"
  end
end
