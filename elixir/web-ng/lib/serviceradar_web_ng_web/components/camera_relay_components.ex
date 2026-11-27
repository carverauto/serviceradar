defmodule ServiceRadarWebNGWeb.CameraRelayComponents do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  alias ServiceRadar.Camera.RelayPlayback
  alias ServiceRadar.Camera.RelaySourceFailure

  attr(:session, :map, required: true)
  attr(:id_prefix, :string, default: "camera-relay")
  attr(:class, :string, default: "")
  attr(:compact, :boolean, default: false)
  attr(:poster_url, :string, default: nil)

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
      class={["sr-camera-relay-player", @compact && "sr-camera-relay-player-compact", @class]}
    >
      <div class="sr-camera-relay-frame">
        <img
          :if={is_binary(@poster_url) and @poster_url != ""}
          src={@poster_url}
          alt=""
          data-role="video-poster"
          class="sr-camera-relay-poster pointer-events-none absolute inset-0 z-10 h-full w-full object-contain transition-opacity duration-300"
        />
        <canvas data-role="video-canvas" class="sr-camera-relay-canvas" />
        <video
          data-role="video-element"
          class="sr-camera-relay-video hidden"
          poster={@poster_url}
          muted
          playsinline
          autoplay
        />
      </div>
      <div
        :if={@compact}
        data-role="relay-compact-bar"
        class="flex flex-wrap items-center justify-between gap-2 bg-zinc-950/95 px-3 py-1.5 text-[11px] text-zinc-300"
      >
        <div class="flex min-w-0 flex-wrap items-center gap-2">
          <span class="inline-flex items-center gap-1.5 rounded-full border border-emerald-500/30 bg-emerald-500/10 px-2 py-0.5 text-[10px] font-medium text-emerald-300">
            <span class="size-1.5 rounded-full bg-emerald-400"></span>
            <span data-role="transport-status">Connecting stream...</span>
          </span>
          <span data-role="viewer-count" class="font-mono text-[10px] text-zinc-400">
            Viewers: {Map.get(@session, :viewer_count, 0)}
          </span>
          <span data-role="failure-reason" class="sr-camera-relay-muted text-[10px] text-rose-400">
            {relay_failure_reason_text(@session)}
          </span>
        </div>
        <details data-role="relay-diagnostics-details" class="text-[10px] text-zinc-400">
          <summary class="cursor-pointer select-none rounded border border-zinc-700/80 bg-zinc-900 px-2 py-0.5 font-medium text-zinc-300 hover:border-zinc-500">
            Stream info
          </summary>
          <div class="mt-1.5 flex flex-wrap items-center gap-x-3 gap-y-1 rounded-md border border-zinc-800 bg-zinc-900/90 px-2.5 py-1.5 font-mono text-[10px] text-zinc-400">
            <span data-role="player-status">Waiting for decoder...</span>
            <span data-role="compatibility-status">
              Preferred: {relay_preferred_playback_transport(@session)}
            </span>
            <span data-role="relay-status">Relay: {relay_status_label(@session.status)}</span>
            <span data-role="playback-state" data-state={relay_playback_state(@session)}>
              Playback: {relay_playback_state(@session)}
            </span>
            <span data-role="termination-kind" class="sr-camera-relay-muted">
              {relay_termination_text(@session)}
            </span>
            <span data-role="close-reason" class="sr-camera-relay-muted">
              {relay_close_reason_text(@session)}
            </span>
          </div>
        </details>
      </div>
      <div :if={!@compact} class="sr-camera-relay-meta">
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

  @doc """
  An agent-reported camera source failure as the sentence an operator acts on;
  other failure text is shown as-is.
  """
  def relay_failure_reason_text(session) do
    case Map.get(session || %{}, :failure_reason) do
      value when is_binary(value) and value != "" ->
        RelaySourceFailure.describe(value) || "Failure reason: #{value}"

      _ ->
        ""
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
