defmodule ServiceRadarWebNGWeb.CameraRelayComponents do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  alias ServiceRadar.Camera.RelayPlayback

  attr(:session, :map, required: true)
  attr(:id_prefix, :string, default: "camera-relay")
  attr(:class, :string, default: "")

  def relay_player(assigns) do
    ~H"""
    <div
      id={"#{@id_prefix}-#{@session.id}"}
      phx-hook="CameraRelayStatusStream"
      phx-update="ignore"
      data-stream-path={camera_relay_stream_path(@session)}
      data-preferred-playback-transport={relay_preferred_playback_transport(@session)}
      data-available-playback-transports={relay_available_playback_transports(@session)}
      data-playback-codec-hint={relay_playback_codec_hint(@session)}
      data-playback-container-hint={relay_playback_container_hint(@session)}
      data-webrtc-playback-transport={relay_webrtc_playback_transport(@session)}
      data-webrtc-signaling-path={relay_webrtc_signaling_path(@session)}
      data-webrtc-ice-servers={relay_webrtc_ice_servers_json(@session)}
      data-playback-state={relay_playback_state(@session)}
      class={["sr-camera-relay-player", @class]}
    >
      <div class="sr-camera-relay-frame">
        <canvas data-role="video-canvas" class="sr-camera-relay-canvas" />
        <video
          data-role="video-element"
          class="sr-camera-relay-video hidden"
          muted
          playsinline
          autoplay
        />
      </div>
      <div class="sr-camera-relay-meta">
        <span data-role="transport-status">Connecting stream...</span>
        <span data-role="player-status">Waiting for decoder...</span>
        <span data-role="compatibility-status">
          Preferred: {relay_preferred_playback_transport(@session)}
        </span>
        <span data-role="relay-status">Relay: {relay_status_label(@session.status)}</span>
        <span data-role="playback-state" data-state={relay_playback_state(@session)}>
          Playback: {relay_playback_state(@session)}
        </span>
        <span data-role="viewer-count">
          Viewers: {Map.get(@session, :viewer_count, 0)}
        </span>
        <span data-role="termination-kind" class="sr-camera-relay-muted">
          {relay_termination_text(@session)}
        </span>
        <span data-role="close-reason" class="sr-camera-relay-muted">
          {relay_close_reason_text(@session)}
        </span>
        <span data-role="failure-reason" class="sr-camera-relay-muted">
          {relay_failure_reason_text(@session)}
        </span>
      </div>
    </div>
    """
  end

  def relay_status_label(status) when is_atom(status), do: status |> Atom.to_string() |> String.capitalize()
  def relay_status_label(status) when is_binary(status), do: String.capitalize(status)
  def relay_status_label(_), do: "Requested"

  def relay_playback_state(%{status: status, media_ingest_id: media_ingest_id})
      when status in [:active, "active"] and is_binary(media_ingest_id) and media_ingest_id != "", do: "ready"

  def relay_playback_state(%{status: status}) when status in [:requested, :opening, "requested", "opening"], do: "pending"

  def relay_playback_state(%{status: status}) when status in [:closing, "closing"], do: "closing"
  def relay_playback_state(%{status: status}) when status in [:closed, "closed"], do: "closed"
  def relay_playback_state(%{status: status}) when status in [:failed, "failed"], do: "failed"
  def relay_playback_state(_session), do: "pending"

  def relay_preferred_playback_transport(session) do
    session
    |> relay_playback_contract()
    |> Map.get(:preferred_playback_transport, "")
  end

  def relay_available_playback_transports(session) do
    session
    |> relay_playback_contract()
    |> Map.get(:available_playback_transports, [])
    |> Enum.join(",")
  end

  def relay_playback_codec_hint(session) do
    session
    |> relay_playback_contract()
    |> Map.get(:playback_codec_hint, "h264")
  end

  def relay_playback_container_hint(session) do
    session
    |> relay_playback_contract()
    |> Map.get(:playback_container_hint, "annexb")
  end

  def relay_webrtc_playback_transport(session) do
    session
    |> relay_webrtc_metadata()
    |> Map.get(:webrtc_playback_transport)
  end

  def relay_webrtc_signaling_path(session) do
    session
    |> relay_webrtc_metadata()
    |> Map.get(:webrtc_signaling_path)
  end

  def relay_webrtc_ice_servers_json(session) do
    session
    |> relay_webrtc_metadata()
    |> Map.get(:webrtc_ice_servers, [])
    |> Jason.encode!()
  end

  def camera_relay_stream_path(%{id: relay_session_id}) when is_binary(relay_session_id) do
    ~p"/v1/camera-relay-sessions/#{relay_session_id}/stream"
  end

  def camera_relay_stream_path(_session), do: nil

  def relay_termination_text(session) do
    case Map.get(session, :termination_kind) do
      value when is_binary(value) and value != "" ->
        "Termination: #{value |> String.replace("_", " ") |> String.capitalize()}"

      _ ->
        ""
    end
  end

  def relay_close_reason_text(session) do
    case Map.get(session, :close_reason) do
      value when is_binary(value) and value != "" -> "Close reason: #{value}"
      _ -> ""
    end
  end

  def relay_failure_reason_text(session) do
    case Map.get(session, :failure_reason) do
      value when is_binary(value) and value != "" -> "Failure reason: #{value}"
      _ -> ""
    end
  end

  defp relay_playback_contract(session) when is_map(session) do
    session
    |> Map.merge(relay_webrtc_metadata(session))
    |> RelayPlayback.browser_metadata()
  end

  defp relay_playback_contract(_session), do: RelayPlayback.browser_metadata(%{})

  defp relay_webrtc_metadata(%{id: _relay_session_id} = session),
    do: ServiceRadarWebNG.CameraRelayWebRTC.metadata(session)

  defp relay_webrtc_metadata(_session), do: %{}
end
