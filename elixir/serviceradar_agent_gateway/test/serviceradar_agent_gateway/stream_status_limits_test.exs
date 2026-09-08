defmodule ServiceRadarAgentGateway.StreamStatusLimitsTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

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

  test "pins normalized delivery capabilities for the entire stream" do
    pinned =
      AgentGatewayServer.pin_stream_capabilities(nil, [
        " plugin-result-retained:v1 ",
        "other:v1",
        "other:v1"
      ])

    assert pinned == ["other:v1", "plugin-result-retained:v1"]

    assert AgentGatewayServer.pin_stream_capabilities(pinned, [
             "other:v1",
             "plugin-result-retained:v1"
           ]) == pinned

    assert_raise GRPC.RPCError, ~r/capabilities changed mid-stream/, fn ->
      AgentGatewayServer.pin_stream_capabilities(pinned, ["other:v1"])
    end
  end

  test "protobuf metric status sources are rejected instead of truncated when oversized" do
    oversized_payload = :binary.copy("x", 15 * 1024 * 1024 + 1)

    for source <- ["rperf-metrics", "mtr-metrics", "sweep-metrics", "addon:native", "plugin:wasm"] do
      service = %Monitoring.GatewayServiceStatus{
        service_name: "metric-source",
        service_type: "metrics",
        source: source,
        message: oversized_payload
      }

      log =
        capture_log(fn ->
          assert AgentGatewayServer.process_chunk_services([service], metadata()) == []
        end)

      assert log =~ "payload exceeds max size"
      assert log =~ ~s(source: "#{source}")
    end
  end

  defp metadata do
    %{
      agent_id: "agent-1",
      gateway_id: "gateway-1",
      partition: "default",
      kv_store_id: "kv-1",
      timestamp: 1_700_000_000,
      agent_timestamp: 1_700_000_000,
      chunk_index: 0,
      total_chunks: 1,
      is_final: true
    }
  end
end
