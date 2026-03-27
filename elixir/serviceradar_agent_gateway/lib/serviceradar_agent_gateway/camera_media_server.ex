defmodule ServiceRadarAgentGateway.CameraMediaServer do
  @moduledoc """
  gRPC service that accepts camera media relay traffic from edge agents.

  This service is separate from monitoring status/results transport. The gateway
  authenticates the edge session, tracks relay lifecycle, and prepares media for
  forwarding to core-elx.
  """

  use GRPC.Server, service: Camera.CameraMediaService.Service

  alias ServiceRadarAgentGateway.CameraMediaForwarder
  alias ServiceRadarAgentGateway.CameraMediaSessionTracker
  alias ServiceRadarAgentGateway.ComponentIdentityResolver

  require Logger

  # UniFi Protect high-profile keyframes can exceed 256 KiB when relayed as a
  # single Annex B access unit. Keep the per-frame limit comfortably below the
  # default gRPC message ceiling while allowing intact frames through.
  @max_chunk_bytes 1_048_576
  @agent_gateway_component_types [:agent]

  @typep open_relay_session_request :: %Camera.OpenRelaySessionRequest{}
  @typep open_relay_session_response :: %Camera.OpenRelaySessionResponse{}
  @typep upload_media_response :: %Camera.UploadMediaResponse{}
  @typep relay_heartbeat :: %Camera.RelayHeartbeat{}
  @typep relay_heartbeat_ack :: %Camera.RelayHeartbeatAck{}
  @typep close_relay_session_request :: %Camera.CloseRelaySessionRequest{}
  @typep close_relay_session_response :: %Camera.CloseRelaySessionResponse{}

  @spec open_relay_session(open_relay_session_request(), GRPC.Server.Stream.t()) ::
          open_relay_session_response()
  def open_relay_session(%Camera.OpenRelaySessionRequest{} = request, stream) do
    agent_id = required_agent_id(request.agent_id)
    identity = extract_identity_from_stream(stream)
    enforce_component_identity!(identity, agent_id, @agent_gateway_component_types)
    partition_id = resolve_partition(identity)

    if String.trim(request.lease_token || "") == "" do
      raise GRPC.RPCError, status: :invalid_argument, message: "lease_token is required"
    end

    upstream_request = %{
      request
      | agent_id: agent_id,
        gateway_id: gateway_id()
    }

    relay_session_id = required_string(request.relay_session_id, "relay_session_id")
    camera_source_id = required_string(request.camera_source_id, "camera_source_id")
    stream_profile_id = required_string(request.stream_profile_id, "stream_profile_id")

    {:ok, upstream_response, forward_metadata} = forward_open_relay_session(upstream_request)

    session_attrs = %{
      relay_session_id: relay_session_id,
      media_ingest_id: upstream_response.media_ingest_id,
      ingress_pid: Map.get(forward_metadata, :ingress_pid),
      core_node: Map.get(forward_metadata, :core_node),
      agent_id: agent_id,
      gateway_id: gateway_id(),
      partition_id: partition_id,
      camera_source_id: camera_source_id,
      stream_profile_id: stream_profile_id,
      lease_token: request.lease_token,
      codec_hint: request.codec_hint,
      container_hint: request.container_hint,
      lease_expires_at_unix: upstream_response.lease_expires_at_unix
    }

    session =
      case session_tracker().open_session(session_attrs) do
        {:ok, session} ->
          session

        {:error, :already_exists} ->
          best_effort_close_upstream(
            relay_session_id,
            upstream_response.media_ingest_id,
            agent_id,
            "duplicate relay session",
            ingress_pid: Map.get(forward_metadata, :ingress_pid)
          )

          raise GRPC.RPCError, status: :already_exists, message: "relay session already exists"

        {:error, {:limit_exceeded, limit_kind, limit}} ->
          best_effort_close_upstream(
            relay_session_id,
            upstream_response.media_ingest_id,
            agent_id,
            "gateway relay capacity exceeded",
            ingress_pid: Map.get(forward_metadata, :ingress_pid)
          )

          raise GRPC.RPCError,
            status: :resource_exhausted,
            message: capacity_error_message(limit_kind, limit)
      end

    Logger.info(
      "Opened camera relay session #{session.relay_session_id} for agent #{agent_id} camera=#{session.camera_source_id} profile=#{session.stream_profile_id}"
    )

    %Camera.OpenRelaySessionResponse{
      accepted: true,
      message: upstream_response.message,
      media_ingest_id: session.media_ingest_id,
      max_chunk_bytes: upstream_response.max_chunk_bytes || @max_chunk_bytes,
      lease_expires_at_unix: session.lease_expires_at_unix
    }
  rescue
    error in ArgumentError ->
      reraise GRPC.RPCError.exception(status: :invalid_argument, message: Exception.message(error)),
              __STACKTRACE__
  end

  @spec upload_media(Enumerable.t(), GRPC.Server.Stream.t()) :: upload_media_response()
  def upload_media(request_stream, stream) do
    identity = extract_identity_from_stream(stream)
    {:ok, session_ref} = Agent.start_link(fn -> %{relay_session_id: nil, media_ingest_id: nil} end)

    try do
      request_stream
      |> Enum.map(fn
        %Camera.MediaChunk{} = chunk ->
          {chunk, ingress_pid} = handle_media_chunk(chunk, identity)

          Agent.update(session_ref, fn _state ->
            %{
              relay_session_id: chunk.relay_session_id,
              media_ingest_id: chunk.media_ingest_id,
              ingress_pid: ingress_pid
            }
          end)

          chunk

        other ->
          other
      end)
      |> forwarder().upload_media(ingress_pid: ingress_pid(session_ref))
      |> case do
        {:ok, %Camera.UploadMediaResponse{} = response} ->
          maybe_mark_upload_closing(session_ref, response.message)
          response

        {:error, reason} ->
          raise GRPC.RPCError,
            status: :unavailable,
            message: "failed to forward media stream: #{inspect(reason)}"
      end
    after
      Agent.stop(session_ref, :normal)
    end
  end

  @spec heartbeat(relay_heartbeat(), GRPC.Server.Stream.t()) :: relay_heartbeat_ack()
  def heartbeat(request, stream) do
    agent_id = required_agent_id(request.agent_id)
    identity = extract_identity_from_stream(stream)
    enforce_component_identity!(identity, agent_id, @agent_gateway_component_types)

    relay_session_id = required_string(request.relay_session_id, "relay_session_id")
    media_ingest_id = required_string(request.media_ingest_id, "media_ingest_id")

    with {:ok, forwarding_session} <- forwarding_session(relay_session_id, media_ingest_id),
         {:ok, upstream_ack} <-
           forwarder().heartbeat(request, ingress_pid: Map.get(forwarding_session, :ingress_pid)),
         {:ok, _session} <-
           maybe_mark_closing(relay_session_id, media_ingest_id, %{
             close_reason: gateway_drain_reason(upstream_ack.message)
           }),
         {:ok, session} <-
           session_tracker().heartbeat(relay_session_id, media_ingest_id, %{
             last_sequence: request.last_sequence,
             sent_bytes: request.sent_bytes,
             lease_expires_at_unix: upstream_ack.lease_expires_at_unix
           }) do
      %Camera.RelayHeartbeatAck{
        accepted: true,
        lease_expires_at_unix: session.lease_expires_at_unix || upstream_ack.lease_expires_at_unix,
        message: upstream_ack.message
      }
    else
      {:error, %GRPC.RPCError{} = error} ->
        raise error

      {:error, :not_found} ->
        raise GRPC.RPCError, status: :not_found, message: "relay session not found"

      {:error, :media_ingest_mismatch} ->
        raise GRPC.RPCError, status: :permission_denied, message: "media_ingest_id mismatch"
    end
  end

  @spec close_relay_session(close_relay_session_request(), GRPC.Server.Stream.t()) ::
          close_relay_session_response()
  def close_relay_session(request, stream) do
    agent_id = required_agent_id(request.agent_id)
    identity = extract_identity_from_stream(stream)
    enforce_component_identity!(identity, agent_id, @agent_gateway_component_types)

    relay_session_id = required_string(request.relay_session_id, "relay_session_id")
    media_ingest_id = required_string(request.media_ingest_id, "media_ingest_id")

    with {:ok, forwarding_session} <- forwarding_session(relay_session_id, media_ingest_id),
         {:ok, %Camera.CloseRelaySessionResponse{} = upstream_response} <-
           forwarder().close_relay_session(
             request,
             ingress_pid: Map.get(forwarding_session, :ingress_pid)
           ) do
      case session_tracker().close_session(relay_session_id, media_ingest_id, %{reason: request.reason}) do
        :ok ->
          %Camera.CloseRelaySessionResponse{closed: true, message: upstream_response.message}

        {:error, :not_found} ->
          raise GRPC.RPCError, status: :not_found, message: "relay session not found"

        {:error, :media_ingest_mismatch} ->
          raise GRPC.RPCError, status: :permission_denied, message: "media_ingest_id mismatch"
      end
    else
      {:error, %GRPC.RPCError{} = error} ->
        raise error

      {:error, :not_found} ->
        raise GRPC.RPCError, status: :not_found, message: "relay session not found"

      {:error, :media_ingest_mismatch} ->
        raise GRPC.RPCError, status: :permission_denied, message: "media_ingest_id mismatch"

      {:error, reason} ->
        raise GRPC.RPCError, status: :unavailable, message: "failed to close upstream relay session: #{inspect(reason)}"
    end
  end

  defp handle_media_chunk(chunk, identity) do
    agent_id = required_agent_id(chunk.agent_id)
    enforce_component_identity!(identity, agent_id, @agent_gateway_component_types)

    relay_session_id = required_string(chunk.relay_session_id, "relay_session_id")
    media_ingest_id = required_string(chunk.media_ingest_id, "media_ingest_id")

    if byte_size(chunk.payload || <<>>) > @max_chunk_bytes do
      raise GRPC.RPCError,
        status: :resource_exhausted,
        message: "media chunk exceeded max size #{@max_chunk_bytes}"
    end

    case session_tracker().record_chunk(relay_session_id, media_ingest_id, %{
           sequence: chunk.sequence,
           payload: chunk.payload || <<>>
         }) do
      {:ok, session} ->
        {chunk, Map.get(session, :ingress_pid)}

      {:error, :not_found} ->
        raise GRPC.RPCError, status: :not_found, message: "relay session not found"

      {:error, :media_ingest_mismatch} ->
        raise GRPC.RPCError, status: :permission_denied, message: "media_ingest_id mismatch"
    end
  end

  defp forwarder do
    Application.get_env(:serviceradar_agent_gateway, :camera_media_forwarder, CameraMediaForwarder)
  end

  defp forward_open_relay_session(request) do
    case forwarder().open_relay_session(request) do
      {:ok, %Camera.OpenRelaySessionResponse{} = response, metadata} ->
        {:ok, response, metadata}

      {:ok, %Camera.OpenRelaySessionResponse{} = response} ->
        {:ok, response, %{}}

      {:error, %GRPC.RPCError{} = error} ->
        raise error

      {:error, reason} ->
        raise GRPC.RPCError, status: :unavailable, message: "failed to open upstream relay session: #{inspect(reason)}"
    end
  end

  defp best_effort_close_upstream(relay_session_id, media_ingest_id, agent_id, reason, opts) do
    case forwarder().close_relay_session(
           %Camera.CloseRelaySessionRequest{
             relay_session_id: relay_session_id,
             media_ingest_id: media_ingest_id,
             agent_id: agent_id,
             reason: reason
           },
           opts
         ) do
      {:ok, _response} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to clean up upstream relay session after gateway admission denial: #{inspect(reason)}")

        :ok
    end
  end

  defp session_tracker do
    Application.get_env(
      :serviceradar_agent_gateway,
      :camera_media_session_tracker_module,
      CameraMediaSessionTracker
    )
  end

  defp identity_resolver do
    Application.get_env(
      :serviceradar_agent_gateway,
      :camera_media_identity_resolver,
      ComponentIdentityResolver
    )
  end

  defp maybe_mark_closing(relay_session_id, media_ingest_id, attrs) do
    if draining_message?(Map.get(attrs, :close_reason)) do
      session_tracker().mark_closing(relay_session_id, media_ingest_id, attrs)
    else
      relay_session_id
      |> session_tracker().fetch_session()
      |> case do
        nil -> {:error, :not_found}
        session -> {:ok, session}
      end
    end
  end

  defp maybe_mark_upload_closing(session_ref, message) do
    if draining_message?(message) do
      %{relay_session_id: relay_session_id, media_ingest_id: media_ingest_id} =
        Agent.get(session_ref, & &1)

      if is_binary(relay_session_id) and relay_session_id != "" and is_binary(media_ingest_id) and
           media_ingest_id != "" do
        _ =
          session_tracker().mark_closing(relay_session_id, media_ingest_id, %{
            close_reason: gateway_drain_reason(message)
          })

        :ok
      else
        :ok
      end
    else
      :ok
    end
  end

  defp draining_message?(message) when is_binary(message) do
    String.contains?(String.downcase(message), "drain")
  end

  defp draining_message?(_message), do: false

  defp gateway_drain_reason(message) when is_binary(message) do
    if draining_message?(message), do: "upstream relay drain"
  end

  defp gateway_drain_reason(_message), do: nil

  defp forwarding_session(relay_session_id, media_ingest_id) do
    case session_tracker().fetch_session(relay_session_id) do
      nil ->
        {:error, :not_found}

      %{media_ingest_id: ^media_ingest_id} = session ->
        {:ok, session}

      _other ->
        {:error, :media_ingest_mismatch}
    end
  end

  defp ingress_pid(session_ref) do
    session_ref
    |> Agent.get(&Map.get(&1, :ingress_pid))
    |> case do
      pid when is_pid(pid) -> pid
      _other -> nil
    end
  end

  defp capacity_error_message(:agent, limit) do
    "per-agent relay session limit exceeded (limit=#{limit})"
  end

  defp capacity_error_message(:gateway, limit) do
    "per-gateway relay session limit exceeded (limit=#{limit})"
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
        Logger.warning("Camera media certificate validation failed: #{inspect(reason)}")
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
