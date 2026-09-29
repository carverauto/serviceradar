defmodule ServiceRadarAgentGateway.ConfigChunks do
  @moduledoc """
  Splits an `AgentConfigResponse` into bounded `AgentConfigChunk`s.

  Shared by the `StreamConfig` fetch and the control-stream config push, so a
  config reaches the agent the same way whichever path delivers it. A compiled
  config can be several times larger than the agent's 4 MiB default gRPC
  receive limit; sent as one message it is rejected with `ResourceExhausted`
  and the whole stream carrying it is torn down.
  """

  @max_config_chunk_payload_bytes 1 * 1024 * 1024
  @max_stream_config_chunk_bytes 2 * 1024 * 1024
  @max_stream_config_window_bytes 64 * 1024 * 1024

  @doc """
  Encodes `response` and splits it into chunks carrying the full payload's
  SHA-256, in order, with the last one marked final.

  Raises `GRPC.RPCError` (`:resource_exhausted`) when the encoded config exceeds
  the stream byte budget.
  """
  @spec chunks(String.t(), Monitoring.AgentConfigResponse.t()) :: [Monitoring.AgentConfigChunk.t()]
  def chunks(agent_id, %Monitoring.AgentConfigResponse{} = response) do
    payload =
      response
      |> Protobuf.Encoder.encode_to_iodata()
      |> IO.iodata_to_binary()

    validate_window!(byte_size(payload))

    payload_sha256 = sha256_hex(payload)
    total_chunks = max(ceil_div(byte_size(payload), @max_config_chunk_payload_bytes), 1)

    Enum.map(0..(total_chunks - 1), fn chunk_index ->
      offset = chunk_index * @max_config_chunk_payload_bytes
      chunk_size = min(@max_config_chunk_payload_bytes, max(byte_size(payload) - offset, 0))

      chunk =
        %Monitoring.AgentConfigChunk{
          agent_id: agent_id,
          config_version: response.config_version,
          config_timestamp: response.config_timestamp,
          not_modified: response.not_modified,
          payload: binary_part(payload, offset, chunk_size),
          is_final: chunk_index == total_chunks - 1,
          chunk_index: chunk_index,
          total_chunks: total_chunks,
          payload_sha256: payload_sha256
        }

      validate_chunk!(chunk)
    end)
  end

  @doc "Encoded size of `response` in bytes."
  @spec size(Monitoring.AgentConfigResponse.t()) :: non_neg_integer()
  def size(%Monitoring.AgentConfigResponse{} = response) do
    response
    |> Protobuf.Encoder.encode_to_iodata()
    |> IO.iodata_length()
  end

  defp validate_window!(payload_bytes) do
    if payload_bytes > @max_stream_config_window_bytes do
      raise GRPC.RPCError,
        status: :resource_exhausted,
        message: "config stream exceeds byte budget"
    end
  end

  defp validate_chunk!(%Monitoring.AgentConfigChunk{} = chunk) do
    chunk_bytes =
      chunk
      |> Protobuf.Encoder.encode_to_iodata()
      |> IO.iodata_length()

    if chunk_bytes > @max_stream_config_chunk_bytes do
      raise GRPC.RPCError,
        status: :resource_exhausted,
        message: "config stream chunk exceeds byte budget"
    end

    chunk
  end

  defp ceil_div(0, _divisor), do: 0
  defp ceil_div(value, divisor), do: div(value + divisor - 1, divisor)

  defp sha256_hex(payload) do
    payload
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
