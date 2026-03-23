defmodule ServiceRadarCoreElx.CameraMediaServer do
  @moduledoc """
  Authoritative camera media ingress for core-elx.

  This is the core-side landing point for media sessions forwarded by the
  agent-gateway before they are attached to Membrane pipelines.
  """

  use GRPC.Server, service: Camera.CameraMediaService.Service

  alias ServiceRadarCoreElx.CameraMediaSessionTracker

  @max_chunk_bytes 262_144

  def open_relay_session(request, _stream) do
    case CameraMediaSessionTracker.open_session(%{
           relay_session_id: required_string(request.relay_session_id, "relay_session_id"),
           agent_id: required_string(request.agent_id, "agent_id"),
           gateway_id: required_string(request.gateway_id, "gateway_id"),
           camera_source_id: required_string(request.camera_source_id, "camera_source_id"),
           stream_profile_id: required_string(request.stream_profile_id, "stream_profile_id"),
           codec_hint: request.codec_hint,
           container_hint: request.container_hint
         }) do
      {:ok, session} ->
        %Camera.OpenRelaySessionResponse{
          accepted: true,
          message: "core relay session accepted",
          media_ingest_id: session.media_ingest_id,
          max_chunk_bytes: @max_chunk_bytes,
          lease_expires_at_unix: session.lease_expires_at_unix
        }

      {:error, :already_exists} ->
        raise GRPC.RPCError, status: :already_exists, message: "relay session already exists"

      {:error, :not_found} ->
        raise GRPC.RPCError, status: :not_found, message: "relay session not found"

      {:error, {:invalid_status, status}} ->
        raise GRPC.RPCError,
          status: :failed_precondition,
          message: "relay session is in invalid state #{status}"

      {:error, reason} ->
        raise GRPC.RPCError, status: :internal, message: "failed to activate relay session: #{inspect(reason)}"
    end
  rescue
    error in ArgumentError ->
      raise GRPC.RPCError, status: :invalid_argument, message: Exception.message(error)
  end

  def upload_media(request_stream, _stream) do
    state =
      Enum.reduce_while(request_stream, %{last_sequence: 0, chunk_count: 0}, fn
        %Camera.MediaChunk{} = chunk, state ->
          next = handle_media_chunk(chunk, state)
          {:cont, next}

        _other, state ->
          {:cont, state}
      end)

    if state.chunk_count == 0 do
      raise GRPC.RPCError, status: :invalid_argument, message: "media stream contained no chunks"
    end

    %Camera.UploadMediaResponse{
      received: true,
      last_sequence: state.last_sequence,
      message: "media chunks accepted by core-elx"
    }
  end

  def heartbeat(request, _stream) do
    relay_session_id = required_string(request.relay_session_id, "relay_session_id")
    media_ingest_id = required_string(request.media_ingest_id, "media_ingest_id")

    case CameraMediaSessionTracker.heartbeat(relay_session_id, media_ingest_id, %{
           last_sequence: request.last_sequence,
           sent_bytes: request.sent_bytes
         }) do
      {:ok, session} ->
        %Camera.RelayHeartbeatAck{
          accepted: true,
          lease_expires_at_unix: session.lease_expires_at_unix,
          message: "core heartbeat accepted"
        }

      {:error, :not_found} ->
        raise GRPC.RPCError, status: :not_found, message: "relay session not found"

      {:error, :media_ingest_mismatch} ->
        raise GRPC.RPCError, status: :permission_denied, message: "media_ingest_id mismatch"

      {:error, {:invalid_status, status}} ->
        raise GRPC.RPCError,
          status: :failed_precondition,
          message: "relay session is in invalid state #{status}"
    end
  end

  def close_relay_session(request, _stream) do
    relay_session_id = required_string(request.relay_session_id, "relay_session_id")
    media_ingest_id = required_string(request.media_ingest_id, "media_ingest_id")

    case CameraMediaSessionTracker.close_session(relay_session_id, media_ingest_id, %{reason: request.reason}) do
      :ok ->
        %Camera.CloseRelaySessionResponse{closed: true, message: "core relay session closed"}

      {:error, :not_found} ->
        raise GRPC.RPCError, status: :not_found, message: "relay session not found"

      {:error, :media_ingest_mismatch} ->
        raise GRPC.RPCError, status: :permission_denied, message: "media_ingest_id mismatch"

      {:error, {:invalid_status, status}} ->
        raise GRPC.RPCError,
          status: :failed_precondition,
          message: "relay session is in invalid state #{status}"
    end
  end

  defp handle_media_chunk(chunk, state) do
    relay_session_id = required_string(chunk.relay_session_id, "relay_session_id")
    media_ingest_id = required_string(chunk.media_ingest_id, "media_ingest_id")

    if byte_size(chunk.payload || <<>>) > @max_chunk_bytes do
      raise GRPC.RPCError,
        status: :resource_exhausted,
        message: "media chunk exceeded max size #{@max_chunk_bytes}"
    end

    case CameraMediaSessionTracker.record_chunk(relay_session_id, media_ingest_id, %{
           sequence: chunk.sequence,
           payload: chunk.payload || <<>>,
           pts: chunk.pts,
           dts: chunk.dts,
           keyframe: chunk.keyframe,
           codec: chunk.codec,
           payload_format: chunk.payload_format,
           track_id: chunk.track_id
         }) do
      {:ok, _session} ->
        %{last_sequence: chunk.sequence, chunk_count: state.chunk_count + 1}

      {:error, :not_found} ->
        raise GRPC.RPCError, status: :not_found, message: "relay session not found"

      {:error, :media_ingest_mismatch} ->
        raise GRPC.RPCError, status: :permission_denied, message: "media_ingest_id mismatch"
    end
  end

  defp required_string(value, field_name) do
    case value |> to_string() |> String.trim() do
      "" -> raise ArgumentError, "#{field_name} is required"
      normalized -> normalized
    end
  end
end
