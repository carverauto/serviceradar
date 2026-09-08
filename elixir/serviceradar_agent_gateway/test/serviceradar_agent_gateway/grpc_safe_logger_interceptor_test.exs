defmodule ServiceRadarAgentGateway.GRPCSafeLoggerInterceptorTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ServiceRadarAgentGateway.GRPCSafeLoggerInterceptor

  defmodule SecretRequest do
    @moduledoc false
    defstruct [:password]
  end

  test "logs method status duration and actor without request or response payloads" do
    request = %SecretRequest{password: "super-secret-request"}
    response = %{token: "super-secret-response"}

    stream = %GRPC.Server.Stream{
      server: __MODULE__,
      service_name: "serviceradar.gateway.AgentGateway",
      method_name: "PushStatus",
      rpc: {:PushStatus, nil},
      request_id: "req-1",
      local: %{actor_id: "agent-1"}
    }

    log =
      capture_log([level: :info], fn ->
        assert {:ok, ^stream, ^response} =
                 GRPCSafeLoggerInterceptor.call(
                   request,
                   stream,
                   fn next_request, next_stream ->
                     assert next_request == request

                     {:ok, next_stream, response}
                   end,
                   level: :warning
                 )
      end)

    assert log =~ "Handled gRPC request"
    assert log =~ "method=serviceradar.gateway.AgentGateway/PushStatus"
    assert log =~ "status=ok"
    assert log =~ "actor=agent-1"
    refute log =~ "super-secret-request"
    refute log =~ "super-secret-response"
  end

  test "does not log RPC error messages" do
    stream = %GRPC.Server.Stream{
      server: __MODULE__,
      service_name: "serviceradar.gateway.AgentGateway",
      method_name: "PushStatus",
      rpc: {:PushStatus, nil},
      request_id: "req-2",
      local: %{actor_id: "agent-2"}
    }

    error = GRPC.RPCError.exception(status: GRPC.Status.permission_denied(), message: "secret-error")

    log =
      capture_log([level: :info], fn ->
        assert {:error, ^error} =
                 GRPCSafeLoggerInterceptor.call(
                   %{password: "secret-request"},
                   stream,
                   fn _request, _stream -> {:error, error} end,
                   level: :warning
                 )
      end)

    assert log =~ "status=error:7"
    assert log =~ "actor=agent-2"
    refute log =~ "secret-error"
    refute log =~ "secret-request"
  end
end
