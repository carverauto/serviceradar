defmodule ServiceRadarAgentGateway.StreamStatusLimitsTest do
  use ExUnit.Case, async: true

  alias ServiceRadarAgentGateway.AgentGatewayServer

  @chunk_max 16 * 1024 * 1024
  @window_max 64 * 1024 * 1024

  test "computes encoded chunk size from protobuf wire bytes" do
    chunk = %Monitoring.GatewayStatusChunk{
      agent_id: "agent-1",
      chunk_index: 0,
      total_chunks: 1,
      is_final: true,
      services: [
        %Monitoring.GatewayServiceStatus{
          service_name: "svc-1",
          service_type: "test",
          message: "ok"
        }
      ]
    }

    assert AgentGatewayServer.stream_status_chunk_size(chunk) ==
             chunk
             |> Protobuf.Encoder.encode_to_iodata()
             |> IO.iodata_length()
  end

  test "enforces per-chunk and per-stream byte budgets" do
    assert AgentGatewayServer.validate_stream_status_byte_window!(0, @chunk_max) == @chunk_max

    assert_raise GRPC.RPCError, ~r/chunk exceeds byte budget/, fn ->
      AgentGatewayServer.validate_stream_status_byte_window!(0, @chunk_max + 1)
    end

    assert_raise GRPC.RPCError, ~r/stream exceeds byte budget/, fn ->
      AgentGatewayServer.validate_stream_status_byte_window!(@window_max - 1, 2)
    end
  end
end
