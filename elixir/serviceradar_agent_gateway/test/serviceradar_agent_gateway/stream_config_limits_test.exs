defmodule ServiceRadarAgentGateway.StreamConfigLimitsTest do
  use ExUnit.Case, async: true

  alias ServiceRadarAgentGateway.AgentGatewayServer

  @chunk_max 2 * 1024 * 1024

  test "chunks protobuf encoded config responses with device targets" do
    response = %Monitoring.AgentConfigResponse{
      config_version: "vlarge",
      config_timestamp: 1_779_225_600,
      heartbeat_interval_sec: 30,
      config_poll_interval_sec: 60,
      config_json: large_device_target_config()
    }

    chunks = AgentGatewayServer.config_response_chunks("agent-1", response)

    assert length(chunks) > 1
    assert Enum.all?(chunks, &(&1.agent_id == "agent-1"))
    assert Enum.all?(chunks, &(&1.config_version == response.config_version))
    assert Enum.all?(chunks, &(&1.total_chunks == length(chunks)))
    assert chunks |> Enum.with_index() |> Enum.all?(fn {chunk, index} -> chunk.chunk_index == index end)
    assert List.last(chunks).is_final

    assert Enum.all?(chunks, fn chunk ->
             encoded_bytes =
               chunk
               |> Protobuf.Encoder.encode_to_iodata()
               |> IO.iodata_length()

             encoded_bytes <= @chunk_max
           end)

    payload = chunks |> Enum.map(& &1.payload) |> IO.iodata_to_binary()
    checksum = :sha256 |> :crypto.hash(payload) |> Base.encode16(case: :lower)

    assert Enum.all?(chunks, &(&1.payload_sha256 == checksum))
    assert Monitoring.AgentConfigResponse.decode(payload) == response
  end

  test "preserves not modified responses as a single decodable chunk" do
    response = %Monitoring.AgentConfigResponse{
      not_modified: true,
      config_version: "vcurrent",
      config_timestamp: 1_779_225_600
    }

    assert [chunk] = AgentGatewayServer.config_response_chunks("agent-1", response)
    assert chunk.not_modified
    assert chunk.is_final
    assert chunk.chunk_index == 0
    assert chunk.total_chunks == 1
    assert Monitoring.AgentConfigResponse.decode(chunk.payload) == response
  end

  test "sends config chunks on the grpc stream" do
    test_pid = self()

    response = %Monitoring.AgentConfigResponse{
      config_version: "vstream",
      config_timestamp: 1_779_225_600,
      heartbeat_interval_sec: 30,
      config_poll_interval_sec: 60,
      config_json: large_device_target_config()
    }

    chunks = AgentGatewayServer.config_response_chunks("agent-1", response)

    stream = %GRPC.Server.Stream{
      __interface__: %{
        send_reply: fn stream, chunk, _opts ->
          send(test_pid, {:config_chunk, chunk})
          stream
        end
      }
    }

    assert :ok = AgentGatewayServer.send_config_chunks(chunks, stream)

    for chunk <- chunks do
      assert_receive {:config_chunk, ^chunk}
    end

    refute_receive {:config_chunk, _}
  end

  defp large_device_target_config do
    device_target =
      ~s({"network":"10.46.0.10/32","query_label":"prod","source":"srql","metadata":{"sweep_group_id":"group-1","target_query":"devices where site = 'ual'","device_uid":"dev-1","hostname":"edge-1","discovery_sources":"srql"}})

    targets =
      device_target
      |> Kernel.<>(",")
      |> String.duplicate(25_000)
      |> String.trim_trailing(",")

    ~s({"sweep":{"groups":[{"name":"srql-production","interval":"5m","device_targets":[#{targets}]}]}})
  end
end
