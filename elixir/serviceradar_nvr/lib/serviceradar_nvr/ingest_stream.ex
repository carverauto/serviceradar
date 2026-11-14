defmodule ServiceRadarNVR.IngestStream do
  @moduledoc false

  import Plug.Conn, only: [read_body: 2]

  @max_request_bytes 67_108_864
  @max_unit_bytes 1_048_576

  def new(conn), do: %{conn: conn, buffer: <<>>, eof?: false, bytes: 0}

  def header(stream, config) do
    with {:ok, <<length::32>>, stream} <- take(stream, 4),
         true <- length in 1..1024,
         {:ok, bytes, stream} <- take(stream, length),
         {:ok, header} when is_map(header) and map_size(header) == 5 <- Jason.decode(bytes),
         {:ok, ^bytes} <- ServiceRadarRecordingMetadata.CanonicalJSON.encode(header),
         %{
           "version" => 1,
           "storage_id" => storage,
           "recovery_generation" => generation,
           "identity" => identity,
           "clock_epoch" => clock_epoch
         } <- header,
         true <- storage == config.storage_id and generation == config.recovery_gate.generation,
         %{"source_id" => source, "profile" => profile, "recorder_epoch" => epoch, "block_sequence" => sequence} <-
           identity,
         true <- map_size(identity) == 4,
         true <- is_binary(clock_epoch) and byte_size(clock_epoch) in 1..128 do
      identity = %{source_id: source, profile: profile, recorder_epoch: epoch, block_sequence: sequence}
      clock = %{clock_epoch: clock_epoch, timebase: 90_000, dts_source: :pts_no_reordering, utc_mapping: :unknown}
      {:ok, identity, clock, stream}
    else
      _ -> {:error, :invalid_ingest_header}
    end
  end

  def next(stream) do
    with {:ok, <<length::32>>, stream} <- take(stream, 4) do
      unit(length, stream)
    end
  end

  defp unit(0, stream) do
    case take(stream, 1) do
      {:error, :end_of_body, %{buffer: <<>>} = stream} -> {:done, stream}
      _ -> {:error, :invalid_ingest_end}
    end
  end

  defp unit(length, stream) when length in 1..@max_unit_bytes do
    with {:ok, <<sequence::64, pts::64, dts::64>>, stream} <- take(stream, 24),
         {:ok, payload, stream} <- take(stream, length) do
      {:ok, %{sequence: sequence, pts: pts, dts: dts, payload: payload, codec: "h264", payload_format: "annexb"}, stream}
    end
  end

  defp unit(_, _), do: {:error, :invalid_ingest_unit}

  defp take(%{buffer: bytes} = stream, count) when byte_size(bytes) >= count do
    <<result::binary-size(count), rest::binary>> = bytes
    {:ok, result, %{stream | buffer: rest}}
  end

  defp take(%{eof?: true} = stream, _count), do: {:error, :end_of_body, stream}

  defp take(stream, count) do
    case read_body(stream.conn, length: count - byte_size(stream.buffer), read_length: 65_536, read_timeout: 1000) do
      {status, bytes, conn} when status in [:ok, :more] and stream.bytes + byte_size(bytes) <= @max_request_bytes ->
        take(
          %{
            stream
            | conn: conn,
              buffer: stream.buffer <> bytes,
              bytes: stream.bytes + byte_size(bytes),
              eof?: status == :ok
          },
          count
        )

      _ ->
        {:error, :ingest_read_failed}
    end
  end
end
