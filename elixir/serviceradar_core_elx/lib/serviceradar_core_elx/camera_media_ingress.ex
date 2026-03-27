defmodule ServiceRadarCoreElx.CameraMediaIngress do
  @moduledoc """
  ERTS-native ingress boundary for gateway-forwarded camera relay sessions.

  The gateway uses a single RPC on session open to allocate a relay ingress
  process on a core-elx node. Subsequent media and lifecycle operations target
  that process directly over ERTS.
  """

  alias ServiceRadarCoreElx.CameraMediaIngressSupervisor
  alias ServiceRadarCoreElx.CameraMediaSessionTracker

  @max_chunk_bytes 1_048_576

  def open_relay_session(%Camera.OpenRelaySessionRequest{} = request, opts \\ []) do
    tracker = tracker(opts)

    case tracker.open_session(request_attrs(request)) do
      {:ok, session} ->
        case CameraMediaIngressSupervisor.start_session(session, session_opts(opts)) do
          {:ok, ingress_pid} ->
            {:ok,
             %Camera.OpenRelaySessionResponse{
               accepted: true,
               message: "core relay session accepted",
               media_ingest_id: session.media_ingest_id,
               max_chunk_bytes: @max_chunk_bytes,
               lease_expires_at_unix: session.lease_expires_at_unix
             }, %{ingress_pid: ingress_pid, core_node: node(ingress_pid)}}

          {:error, reason} = error ->
            maybe_cleanup_failed_open(session, tracker, reason)
            error
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp maybe_cleanup_failed_open(session, tracker, _reason) do
    _ =
      tracker.close_session(session.relay_session_id, session.media_ingest_id, %{
        reason: "failed to start ingress session"
      })

    :ok
  end

  defp request_attrs(request) do
    %{
      relay_session_id: request.relay_session_id,
      agent_id: request.agent_id,
      gateway_id: request.gateway_id,
      camera_source_id: request.camera_source_id,
      stream_profile_id: request.stream_profile_id,
      codec_hint: request.codec_hint,
      container_hint: request.container_hint
    }
  end

  defp tracker(opts) do
    Keyword.get(
      opts,
      :tracker,
      Application.get_env(
        :serviceradar_core_elx,
        :camera_media_session_tracker_module,
        CameraMediaSessionTracker
      )
    )
  end

  defp session_opts(opts) do
    tracker =
      Keyword.get(
        opts,
        :tracker,
        Application.get_env(
          :serviceradar_core_elx,
          :camera_media_session_tracker_module,
          CameraMediaSessionTracker
        )
      )

    [tracker: tracker]
  end
end
