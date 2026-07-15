defmodule ServiceRadarAgentGateway.DesktopMediaServer do
  @moduledoc """
  gRPC service that accepts desktop media session traffic from edge agents.

  Screen payload forwarding is intentionally kept separate from the generic
  agent control stream. The initial service slice admits and tracks sessions;
  the production media stream is opened only after the gateway/browser forwarder
  is connected.
  """

  use GRPC.Server, service: Desktopmedia.DesktopMediaService.Service

  import ServiceRadarAgentGateway.MediaIdentity,
    only: [
      enforce_component_identity!: 3,
      gateway_id: 0,
      required_agent_id: 1,
      required_string: 2,
      resolve_partition: 1
    ]

  alias ServiceRadarAgentGateway.ComponentIdentityResolver
  alias ServiceRadarAgentGateway.DesktopMediaForwarder
  alias ServiceRadarAgentGateway.DesktopMediaSessionTracker
  alias ServiceRadarAgentGateway.MediaIdentity

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
    :ok =
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
          {agent_id, session} = validate_desktop_media_frame!(frame, stream)
          ack = forward_desktop_media_frame!(frame, session, agent_id)

          send_stream_reply(stream, %Desktopmedia.DesktopMediaServerMessage{
            message: {:ack, ack}
          })

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
           media_ingest_id: request.media_ingest_id,
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

      {:error, :media_ingest_mismatch} ->
        raise GRPC.RPCError, status: :permission_denied, message: "media_ingest_id mismatch"

      {:error, :session_closing} ->
        raise GRPC.RPCError, status: :failed_precondition, message: "desktop media session is closing"

      {:error, :session_expired} ->
        raise GRPC.RPCError, status: :failed_precondition, message: "desktop media session expired"

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

    case close_desktop_media_route(desktop_session_id, media_session_id, agent_id, %{
           media_ingest_id: request.media_ingest_id,
           reason: request.reason
         }) do
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

      {:error, :media_ingest_mismatch} ->
        raise GRPC.RPCError, status: :permission_denied, message: "media_ingest_id mismatch"

      {:error, :agent_id_mismatch} ->
        raise GRPC.RPCError, status: :permission_denied, message: "desktop media session owner mismatch"

      {:error, :core_ingress_cleanup_failed} ->
        raise GRPC.RPCError,
          status: :unavailable,
          message: "desktop media core cleanup is temporarily unavailable"
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

    case close_desktop_media_route(desktop_session_id, media_session_id, agent_id, %{
           media_ingest_id: request.media_ingest_id,
           reason: request.reason
         }) do
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

      {:error, :media_ingest_mismatch} ->
        raise GRPC.RPCError, status: :permission_denied, message: "media_ingest_id mismatch"

      {:error, :agent_id_mismatch} ->
        raise GRPC.RPCError, status: :permission_denied, message: "desktop media session owner mismatch"

      {:error, :core_ingress_cleanup_failed} ->
        raise GRPC.RPCError,
          status: :unavailable,
          message: "desktop media core cleanup is temporarily unavailable"
    end
  end

  defp close_desktop_media_route(desktop_session_id, media_session_id, agent_id, attrs) do
    closing_attrs = Map.put(attrs, :pending_core_cleanup, true)

    with {:ok, _closing_session} <-
           session_tracker().mark_closing(
             desktop_session_id,
             media_session_id,
             agent_id,
             closing_attrs
           ),
         :ok <- close_core_ingress(desktop_session_id) do
      session_tracker().close_session(
        desktop_session_id,
        media_session_id,
        agent_id,
        attrs
      )
    end
  end

  defp validate_desktop_media_frame!(%Desktopmedia.DesktopMediaFrameChunk{} = frame, stream) do
    agent_id = required_agent_id(frame.agent_id)
    identity = extract_identity_from_stream(stream)
    enforce_component_identity!(identity, agent_id, @agent_gateway_component_types)
    partition_id = resolve_partition(identity)

    desktop_session_id = required_string(frame.desktop_session_id, "desktop_session_id")
    media_session_id = required_string(frame.media_session_id, "media_session_id")

    case session_tracker().fetch_session(desktop_session_id, agent_id) do
      {:ok, %{media_session_id: ^media_session_id} = session} ->
        enforce_frame_owner!(frame, session, agent_id, partition_id)
        enforce_frame_media_ingest!(frame, session)
        enforce_active_media_session!(session)
        enforce_frame_size!(frame, session)
        {agent_id, session}

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

  defp enforce_frame_owner!(frame, session, agent_id, partition_id) do
    cond do
      session.agent_id != agent_id ->
        reject_frame_owner!(
          frame,
          session,
          :agent_id_mismatch,
          agent_id: agent_id,
          certificate_partition_id: partition_id
        )

      session.partition_id != partition_id ->
        reject_frame_owner!(
          frame,
          session,
          :partition_id_mismatch,
          agent_id: agent_id,
          certificate_partition_id: partition_id
        )

      true ->
        :ok
    end
  end

  defp reject_frame_owner!(frame, session, reason, metadata) do
    metadata =
      Keyword.merge(metadata,
        reason: reason,
        desktop_session_id: frame.desktop_session_id,
        media_session_id: frame.media_session_id,
        media_ingest_id: frame.media_ingest_id,
        session_agent_id: session.agent_id,
        session_partition_id: session.partition_id
      )

    :telemetry.execute(
      [:serviceradar, :desktop_media, :frame, :rejected],
      %{
        sequence: frame.sequence,
        payload_bytes: frame_byte_count(frame)
      },
      Map.new(metadata)
    )

    Logger.warning(
      "Rejected desktop media frame owner binding",
      Keyword.update(metadata, :desktop_session_id, "invalid", &safe_log_identifier/1)
    )

    raise GRPC.RPCError, status: :permission_denied, message: frame_owner_error_message(reason)
  end

  defp frame_owner_error_message(:agent_id_mismatch), do: "desktop media session owner mismatch"
  defp frame_owner_error_message(:partition_id_mismatch), do: "desktop media session partition mismatch"

  defp enforce_frame_media_ingest!(frame, session) do
    if default_ack_id(frame.media_ingest_id, session.media_ingest_id) != session.media_ingest_id do
      raise GRPC.RPCError, status: :permission_denied, message: "media_ingest_id mismatch"
    end
  end

  defp enforce_active_media_session!(%{status: "active", lease_expires_at_unix: lease_expires_at_unix}) do
    if is_integer(lease_expires_at_unix) and lease_expires_at_unix <= System.os_time(:second) do
      raise GRPC.RPCError, status: :failed_precondition, message: "desktop media session expired"
    end
  end

  defp enforce_active_media_session!(_session) do
    raise GRPC.RPCError, status: :failed_precondition, message: "desktop media session is closing"
  end

  defp enforce_frame_size!(frame, session) do
    byte_count = frame_byte_count(frame)

    if byte_count > session.max_chunk_bytes do
      raise GRPC.RPCError,
        status: :resource_exhausted,
        message: "desktop media frame exceeded max size #{session.max_chunk_bytes}"
    end
  end

  defp forward_desktop_media_frame!(frame, session, agent_id) do
    forwarder = frame_forwarder()

    if is_nil(forwarder) do
      raise GRPC.RPCError,
        status: :failed_precondition,
        message: "desktop media frame forwarding is not enabled"
    end

    frame_cost = frame_byte_count(frame)

    case forwarder.forward_frame(frame, session) do
      {:ok, %Desktopmedia.DesktopMediaAck{} = ack} ->
        ack = normalize_forwarded_ack!(ack, frame, session)

        with {:ok, _session} <-
               session_tracker().record_frame(session.desktop_session_id, session.media_session_id, agent_id, %{
                 media_ingest_id: frame.media_ingest_id,
                 sequence: frame.sequence,
                 credit_cost: frame_cost
               }),
             {:ok, _session} <-
               session_tracker().apply_ack(session.desktop_session_id, session.media_session_id, %{
                 media_ingest_id: ack.media_ingest_id,
                 last_accepted_sequence: ack.last_accepted_sequence,
                 credit_bytes: ack.credit_bytes,
                 quality_level: ack.quality_level,
                 pause: ack.pause,
                 resume: ack.resume,
                 close_reason: ack.close_reason
               }) do
          ack
        else
          {:error, :not_found} ->
            raise GRPC.RPCError, status: :not_found, message: "desktop media session not found"

          {:error, :media_session_mismatch} ->
            raise GRPC.RPCError, status: :permission_denied, message: "media_session_id mismatch"

          {:error, :session_closing} ->
            raise GRPC.RPCError, status: :failed_precondition, message: "desktop media session is closing"

          {:error, :session_expired} ->
            raise GRPC.RPCError, status: :failed_precondition, message: "desktop media session expired"

          {:error, :agent_id_mismatch} ->
            raise GRPC.RPCError, status: :permission_denied, message: "desktop media session owner mismatch"
        end

      {:error, %GRPC.RPCError{} = error} ->
        raise error

      {:error, reason} ->
        raise GRPC.RPCError,
          status: :unavailable,
          message: "desktop media frame forward failed: #{inspect(reason)}"
    end
  end

  defp normalize_forwarded_ack!(ack, frame, session) do
    desktop_session_id = default_ack_id(ack.desktop_session_id, frame.desktop_session_id)
    media_session_id = default_ack_id(ack.media_session_id, frame.media_session_id)
    media_ingest_id = default_ack_id(ack.media_ingest_id, session.media_ingest_id)

    cond do
      desktop_session_id != frame.desktop_session_id ->
        raise GRPC.RPCError,
          status: :permission_denied,
          message: "desktop_session_id mismatch"

      media_session_id != frame.media_session_id ->
        raise GRPC.RPCError,
          status: :permission_denied,
          message: "media_session_id mismatch"

      media_ingest_id != session.media_ingest_id ->
        raise GRPC.RPCError,
          status: :permission_denied,
          message: "media_ingest_id mismatch"

      true ->
        %{
          ack
          | desktop_session_id: desktop_session_id,
            media_session_id: media_session_id,
            media_ingest_id: media_ingest_id,
            gateway_id: default_ack_id(ack.gateway_id, gateway_id())
        }
    end
  end

  defp default_ack_id(nil, default), do: default

  defp default_ack_id(value, default) do
    case value |> to_string() |> String.trim() do
      "" -> default
      normalized -> normalized
    end
  end

  defp frame_byte_count(frame), do: byte_size(frame.metadata || <<>>) + byte_size(frame.payload || <<>>)

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

  defp frame_forwarder do
    Application.get_env(:serviceradar_agent_gateway, :desktop_media_frame_forwarder, DesktopMediaForwarder)
  end

  defp close_core_ingress(desktop_session_id) do
    forwarder = frame_forwarder()

    result =
      if is_atom(forwarder) and Code.ensure_loaded?(forwarder) and
           function_exported?(forwarder, :close_session, 1) do
        forwarder.close_session(desktop_session_id)
      else
        {:error, :core_ingress_cleanup_unavailable}
      end

    case result do
      :ok ->
        :ok

      other ->
        Logger.warning("Desktop media core ingress cleanup failed; close remains pending",
          desktop_session_id: safe_log_identifier(desktop_session_id),
          reason: inspect(other)
        )

        {:error, :core_ingress_cleanup_failed}
    end
  rescue
    error ->
      Logger.warning("Desktop media core ingress cleanup raised; close remains pending",
        desktop_session_id: safe_log_identifier(desktop_session_id),
        reason: Exception.message(error)
      )

      {:error, :core_ingress_cleanup_failed}
  catch
    :exit, reason ->
      Logger.warning("Desktop media core ingress cleanup exited; close remains pending",
        desktop_session_id: safe_log_identifier(desktop_session_id),
        reason: inspect(reason)
      )

      {:error, :core_ingress_cleanup_failed}
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

  defp safe_log_identifier(value) when is_binary(value) do
    if byte_size(value) <= 128 and Regex.match?(~r/\A[A-Za-z0-9_.:-]+\z/, value),
      do: value,
      else: "invalid"
  end

  defp safe_log_identifier(_value), do: "invalid"

  defp extract_identity_from_stream(stream) do
    MediaIdentity.extract_identity_from_stream(stream, identity_resolver(), "Desktop media")
  end
end
