defmodule ServiceRadarAgentGateway.DesktopMediaServer do
  @moduledoc """
  gRPC service that accepts desktop media session traffic from edge agents.

  Screen payload forwarding is intentionally kept separate from the generic
  agent control stream. The initial service slice admits and tracks sessions;
  the production media stream is opened only after the gateway/browser forwarder
  is connected.
  """

  use GRPC.Server, service: Desktopmedia.DesktopMediaService.Service

  alias ServiceRadarAgentGateway.ComponentIdentityResolver
  alias ServiceRadarAgentGateway.DesktopMediaSessionTracker

  require Logger

  @agent_gateway_component_types [:agent]

  def open_desktop_media_session(%Desktopmedia.OpenDesktopMediaSessionRequest{} = request, stream) do
    agent_id = required_agent_id(request.agent_id)
    identity = extract_identity_from_stream(stream)
    enforce_component_identity!(identity, agent_id, @agent_gateway_component_types)
    partition_id = resolve_partition(identity)

    if String.trim(request.lease_token || "") == "" do
      raise GRPC.RPCError, status: :invalid_argument, message: "lease_token is required"
    end

    session_attrs = %{
      desktop_session_id: required_string(request.desktop_session_id, "desktop_session_id"),
      media_session_id: request.media_session_id,
      media_ingest_id: nil,
      agent_id: agent_id,
      gateway_id: gateway_id(),
      partition_id: partition_id,
      target_id: required_string(request.target_id, "target_id"),
      route_id: required_string(request.route_id, "route_id"),
      lease_token: request.lease_token,
      encoding_hint: request.encoding_hint,
      initial_credit_bytes: request.requested_initial_credit_bytes,
      max_chunk_bytes: request.requested_max_chunk_bytes
    }

    case session_tracker().open_session(session_attrs) do
      {:ok, session} ->
        %Desktopmedia.OpenDesktopMediaSessionResponse{
          accepted: true,
          message: "desktop media session opened",
          media_ingest_id: session.media_ingest_id,
          media_session_id: session.media_session_id,
          initial_credit_bytes: session.initial_credit_bytes,
          max_chunk_bytes: session.max_chunk_bytes,
          max_ack_credit_bytes: session.max_ack_credit_bytes,
          lease_expires_at_unix: session.lease_expires_at_unix
        }

      {:error, :already_exists} ->
        raise GRPC.RPCError, status: :already_exists, message: "desktop media session already exists"

      {:error, {:limit_exceeded, limit_kind, limit}} ->
        raise GRPC.RPCError,
          status: :resource_exhausted,
          message: capacity_error_message(limit_kind, limit)
    end
  rescue
    error in ArgumentError ->
      reraise GRPC.RPCError.exception(status: :invalid_argument, message: Exception.message(error)),
              __STACKTRACE__
  end

  def stream_desktop_media(request_stream, stream) do
    Enum.reduce_while(request_stream, :ok, fn
      %Desktopmedia.DesktopMediaClientMessage{message: {:heartbeat, heartbeat}}, :ok ->
        ack = heartbeat(heartbeat, stream)

        send_stream_reply(stream, %Desktopmedia.DesktopMediaServerMessage{
          message: {:heartbeat, ack}
        })

      %Desktopmedia.DesktopMediaClientMessage{message: {:close, close}}, :ok ->
        response = close_desktop_media_stream(close, stream)

        send_stream_reply(stream, %Desktopmedia.DesktopMediaServerMessage{
          message: {:close, response}
        })

      %Desktopmedia.DesktopMediaClientMessage{message: {:frame, frame}}, :ok ->
        validate_desktop_media_frame!(frame, stream)

        raise GRPC.RPCError,
          status: :failed_precondition,
          message: "desktop media frame forwarding is not enabled"

      _other, :ok ->
        raise GRPC.RPCError, status: :invalid_argument, message: "unsupported desktop media stream message"
    end)

    :ok
  end

  def heartbeat(%Desktopmedia.DesktopMediaHeartbeat{} = request, stream) do
    agent_id = required_agent_id(request.agent_id)
    identity = extract_identity_from_stream(stream)
    enforce_component_identity!(identity, agent_id, @agent_gateway_component_types)

    desktop_session_id = required_string(request.desktop_session_id, "desktop_session_id")
    media_session_id = required_string(request.media_session_id, "media_session_id")

    case session_tracker().heartbeat(desktop_session_id, media_session_id, agent_id, %{
           last_sequence: request.last_sequence,
           sent_bytes: request.sent_bytes,
           received_credit_bytes: request.received_credit_bytes,
           viewer_count: request.viewer_count
         }) do
      {:ok, session} ->
        %Desktopmedia.DesktopMediaHeartbeatAck{
          accepted: true,
          lease_expires_at_unix: session.lease_expires_at_unix,
          message: "desktop media heartbeat accepted"
        }

      {:error, %GRPC.RPCError{} = error} ->
        raise error

      {:error, :not_found} ->
        raise GRPC.RPCError, status: :not_found, message: "desktop media session not found"

      {:error, :media_session_mismatch} ->
        raise GRPC.RPCError, status: :permission_denied, message: "media_session_id mismatch"

      {:error, :agent_id_mismatch} ->
        raise GRPC.RPCError, status: :permission_denied, message: "desktop media session owner mismatch"
    end
  rescue
    error in ArgumentError ->
      reraise GRPC.RPCError.exception(status: :invalid_argument, message: Exception.message(error)),
              __STACKTRACE__
  end

  def close_desktop_media_session(%Desktopmedia.CloseDesktopMediaSessionRequest{} = request, stream) do
    agent_id = required_agent_id(request.agent_id)
    identity = extract_identity_from_stream(stream)
    enforce_component_identity!(identity, agent_id, @agent_gateway_component_types)

    desktop_session_id = required_string(request.desktop_session_id, "desktop_session_id")
    media_session_id = required_string(request.media_session_id, "media_session_id")

    case session_tracker().close_session(desktop_session_id, media_session_id, agent_id, %{reason: request.reason}) do
      :ok ->
        %Desktopmedia.CloseDesktopMediaSessionResponse{
          closed: true,
          message: "desktop media session closed"
        }

      {:error, %GRPC.RPCError{} = error} ->
        raise error

      {:error, :not_found} ->
        raise GRPC.RPCError, status: :not_found, message: "desktop media session not found"

      {:error, :media_session_mismatch} ->
        raise GRPC.RPCError, status: :permission_denied, message: "media_session_id mismatch"

      {:error, :agent_id_mismatch} ->
        raise GRPC.RPCError, status: :permission_denied, message: "desktop media session owner mismatch"
    end
  rescue
    error in ArgumentError ->
      reraise GRPC.RPCError.exception(status: :invalid_argument, message: Exception.message(error)),
              __STACKTRACE__
  end

  defp close_desktop_media_stream(%Desktopmedia.DesktopMediaStreamClose{} = request, stream) do
    agent_id = required_agent_id(request.agent_id)
    identity = extract_identity_from_stream(stream)
    enforce_component_identity!(identity, agent_id, @agent_gateway_component_types)

    desktop_session_id = required_string(request.desktop_session_id, "desktop_session_id")
    media_session_id = required_string(request.media_session_id, "media_session_id")

    case session_tracker().close_session(desktop_session_id, media_session_id, agent_id, %{reason: request.reason}) do
      :ok ->
        %Desktopmedia.DesktopMediaStreamClose{
          desktop_session_id: desktop_session_id,
          media_session_id: media_session_id,
          media_ingest_id: request.media_ingest_id,
          agent_id: agent_id,
          gateway_id: gateway_id(),
          reason: request.reason,
          last_sequence: request.last_sequence
        }

      {:error, %GRPC.RPCError{} = error} ->
        raise error

      {:error, :not_found} ->
        raise GRPC.RPCError, status: :not_found, message: "desktop media session not found"

      {:error, :media_session_mismatch} ->
        raise GRPC.RPCError, status: :permission_denied, message: "media_session_id mismatch"

      {:error, :agent_id_mismatch} ->
        raise GRPC.RPCError, status: :permission_denied, message: "desktop media session owner mismatch"
    end
  end

  defp validate_desktop_media_frame!(%Desktopmedia.DesktopMediaFrameChunk{} = frame, stream) do
    agent_id = required_agent_id(frame.agent_id)
    identity = extract_identity_from_stream(stream)
    enforce_component_identity!(identity, agent_id, @agent_gateway_component_types)

    desktop_session_id = required_string(frame.desktop_session_id, "desktop_session_id")
    media_session_id = required_string(frame.media_session_id, "media_session_id")

    case session_tracker().fetch_session(desktop_session_id, agent_id) do
      {:ok, %{media_session_id: ^media_session_id} = session} ->
        enforce_frame_size!(frame, session)
        :ok

      {:ok, _session} ->
        raise GRPC.RPCError, status: :permission_denied, message: "media_session_id mismatch"

      {:error, :not_found} ->
        raise GRPC.RPCError, status: :not_found, message: "desktop media session not found"

      {:error, :agent_id_mismatch} ->
        raise GRPC.RPCError, status: :permission_denied, message: "desktop media session owner mismatch"
    end
  rescue
    error in ArgumentError ->
      reraise GRPC.RPCError.exception(status: :invalid_argument, message: Exception.message(error)),
              __STACKTRACE__
  end

  defp enforce_frame_size!(frame, session) do
    byte_count = byte_size(frame.metadata || <<>>) + byte_size(frame.payload || <<>>)

    if byte_count > session.max_chunk_bytes do
      raise GRPC.RPCError,
        status: :resource_exhausted,
        message: "desktop media frame exceeded max size #{session.max_chunk_bytes}"
    end
  end

  defp send_stream_reply(%{test_pid: test_pid}, response) when is_pid(test_pid) do
    send(test_pid, {:desktop_media_stream_reply, response})
    {:cont, :ok}
  end

  defp send_stream_reply(stream, response) do
    GRPC.Server.send_reply(stream, response)
    {:cont, :ok}
  end

  defp session_tracker do
    Application.get_env(
      :serviceradar_agent_gateway,
      :desktop_media_session_tracker_module,
      DesktopMediaSessionTracker
    )
  end

  defp identity_resolver do
    Application.get_env(
      :serviceradar_agent_gateway,
      :desktop_media_identity_resolver,
      ComponentIdentityResolver
    )
  end

  defp capacity_error_message(:agent, limit) do
    "per-agent desktop media session limit exceeded (limit=#{limit})"
  end

  defp capacity_error_message(:gateway, limit) do
    "per-gateway desktop media session limit exceeded (limit=#{limit})"
  end

  defp required_agent_id(value) do
    case value do
      nil ->
        raise GRPC.RPCError, status: :invalid_argument, message: "agent_id is required"

      value ->
        case value |> to_string() |> String.trim() do
          "" ->
            raise GRPC.RPCError, status: :invalid_argument, message: "agent_id is required"

          agent_id ->
            agent_id
        end
    end
  end

  defp required_string(value, field_name) do
    case value |> to_string() |> String.trim() do
      "" ->
        raise ArgumentError, "#{field_name} is required"

      normalized ->
        normalized
    end
  end

  defp gateway_id, do: Atom.to_string(node())

  defp resolve_partition(identity), do: Map.get(identity, :partition_id, "default")

  defp enforce_component_identity!(identity, component_id, allowed_types) do
    cert_component_id = Map.get(identity, :component_id)
    cert_component_type = Map.get(identity, :component_type)

    cond do
      cert_component_id != component_id ->
        raise GRPC.RPCError, status: :permission_denied, message: "component identity mismatch"

      cert_component_type not in allowed_types ->
        raise GRPC.RPCError, status: :permission_denied, message: "component type is not allowed"

      true ->
        :ok
    end
  end

  defp extract_identity_from_stream(stream) do
    with {:ok, cert_der} <- get_peer_cert(stream),
         {:ok, identity} <- identity_resolver().resolve_from_cert(cert_der) do
      identity
    else
      {:error, reason} ->
        Logger.warning("Desktop media certificate validation failed: #{inspect(reason)}")
        raise GRPC.RPCError, status: :unauthenticated, message: "invalid client certificate"
    end
  end

  defp get_peer_cert(stream) do
    adapter = stream.adapter
    payload = stream.payload

    if is_atom(adapter) and Code.ensure_loaded?(adapter) and function_exported?(adapter, :get_cert, 1) do
      case adapter.get_cert(payload) do
        :undefined -> {:error, :no_certificate}
        cert_der when is_binary(cert_der) -> {:ok, cert_der}
        other -> {:error, {:unexpected_cert_result, other}}
      end
    else
      {:error, {:cert_extraction_unsupported, adapter}}
    end
  rescue
    error -> {:error, {:extraction_failed, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:extraction_failed, kind, inspect(reason)}}
  end
end
