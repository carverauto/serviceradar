defmodule ServiceRadarWebNGWeb.TopologyLive.GodViewCameraRelayComponents do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  alias ServiceRadar.Camera.RelayPlayback

  @default_camera_relay_tile_limit 4

  def camera_relay_panels(assigns) do
    ~H"""
    <.ui_panel :if={
      @selected_camera_context || @active_camera_relay_session || @last_camera_relay_session
    }>
      <:header>
        <div class="flex items-center justify-between gap-3">
          <div>
            <div class="text-sm font-semibold">Topology Camera Viewer</div>
            <div class="text-xs text-sr-muted">
              Opened from a God-View camera-capable node.
            </div>
          </div>
          <div class="flex items-center gap-2">
            <.ui_badge
              :if={@active_camera_relay_session}
              size="sm"
              variant={relay_status_badge_variant(@active_camera_relay_session.status)}
            >
              {relay_status_label(@active_camera_relay_session.status)}
            </.ui_badge>
            <.ui_badge
              :if={!@active_camera_relay_session && @last_camera_relay_session}
              size="sm"
              variant={relay_status_badge_variant(@last_camera_relay_session.status)}
            >
              {relay_status_label(@last_camera_relay_session.status)}
            </.ui_badge>
            <.ui_badge
              :if={@camera_relay_viewer_state}
              size="sm"
              variant={viewer_state_badge_variant(@camera_relay_viewer_state.kind)}
            >
              {@camera_relay_viewer_state.title}
            </.ui_badge>
            <.ui_button
              :if={@active_camera_relay_session}
              type="button"
              phx-click="close_camera_relay"
              size="xs"
              variant="outline"
            >
              Stop Relay
            </.ui_button>
          </div>
        </div>
      </:header>

      <div class="space-y-3">
        <div class="flex flex-wrap items-center gap-2 text-sm">
          <span class="font-medium text-sr-ink">
            {camera_context_label(@selected_camera_context)}
          </span>
          <.ui_badge
            :if={present?(camera_context_profile_label(@selected_camera_context))}
            size="sm"
            variant="outline"
          >
            {camera_context_profile_label(@selected_camera_context)}
          </.ui_badge>
          <.link
            :if={present?(camera_context_device_uid(@selected_camera_context))}
            navigate={~p"/devices/#{camera_context_device_uid(@selected_camera_context)}"}
            class="text-sr-brand hover:underline text-xs"
          >
            View device
          </.link>
        </div>

        <div
          :if={@camera_relay_viewer_state}
          class={[
            "rounded-lg border p-3",
            viewer_state_container_class(@camera_relay_viewer_state.kind)
          ]}
        >
          <div class="text-sm font-medium">{@camera_relay_viewer_state.title}</div>
          <div class="mt-1 text-xs leading-5 opacity-90">
            {@camera_relay_viewer_state.detail}
          </div>
          <div
            :if={present?(@camera_relay_viewer_state.hint)}
            class="mt-2 text-xs opacity-80"
          >
            {@camera_relay_viewer_state.hint}
          </div>
        </div>

        <div
          :if={@active_camera_relay_session}
          id={"topology-camera-relay-stream-#{@active_camera_relay_session.id}"}
          phx-hook="CameraRelayStatusStream"
          phx-update="ignore"
          data-stream-path={camera_relay_stream_path(@active_camera_relay_session)}
          data-preferred-playback-transport={
            relay_preferred_playback_transport(@active_camera_relay_session)
          }
          data-available-playback-transports={
            relay_available_playback_transports(@active_camera_relay_session)
          }
          data-playback-codec-hint={relay_playback_codec_hint(@active_camera_relay_session)}
          data-playback-container-hint={relay_playback_container_hint(@active_camera_relay_session)}
          data-webrtc-playback-transport={
            relay_webrtc_playback_transport(@active_camera_relay_session)
          }
          data-webrtc-signaling-path={relay_webrtc_signaling_path(@active_camera_relay_session)}
          data-webrtc-ice-servers={relay_webrtc_ice_servers_json(@active_camera_relay_session)}
          class="space-y-1"
        >
          <div class="overflow-hidden rounded-md border border-sr-line/70 bg-sr-control/20">
            <canvas
              data-role="video-canvas"
              class="block aspect-video w-full bg-neutral/80 object-contain"
            />
            <video
              data-role="video-element"
              class="hidden aspect-video w-full bg-neutral/80 object-contain"
              muted
              playsinline
              autoplay
            />
          </div>
          <div data-role="transport-status" class="text-xs text-sr-muted">
            Connecting browser stream...
          </div>
          <div data-role="player-status" class="text-xs text-sr-muted">
            Waiting for browser decoder...
          </div>
          <div data-role="compatibility-status" class="text-xs text-sr-muted">
            Preferred transport: {relay_preferred_playback_transport(@active_camera_relay_session)}
          </div>
          <div data-role="relay-status" class="text-xs font-medium text-sr-ink">
            Relay status: {relay_status_label(@active_camera_relay_session.status)}
          </div>
          <div
            data-role="playback-state"
            data-state={relay_playback_state(@active_camera_relay_session)}
            class="text-xs text-sr-muted"
          >
            Playback state: {relay_playback_state(@active_camera_relay_session)}
          </div>
          <div data-role="viewer-count" class="text-xs text-sr-muted">
            Viewer count: {Map.get(@active_camera_relay_session, :viewer_count, 0)}
          </div>
          <div data-role="termination-kind" class="text-xs text-info/80">
            {relay_termination_text(@active_camera_relay_session)}
          </div>
          <div data-role="failure-reason" class="text-xs text-error/80">
            {relay_failure_reason_text(@active_camera_relay_session)}
          </div>
          <div data-role="close-reason" class="text-xs text-warning/80">
            {relay_close_reason_text(@active_camera_relay_session)}
          </div>
          <div data-role="binary-stats" class="text-xs text-sr-muted">
            Chunks: 0  Bytes: 0
          </div>
          <div data-role="relay-detail" class="text-xs text-sr-muted">
            Browser viewer channel is attached to the persisted relay session.
          </div>
        </div>

        <div
          :if={!@active_camera_relay_session && @last_camera_relay_session}
          class="rounded-lg border border-sr-line/70 bg-sr-subtle/20 p-3 text-xs text-sr-muted"
        >
          <div class="font-medium text-sr-ink">
            Last relay status: {relay_status_label(@last_camera_relay_session.status)}
          </div>
          <div :if={present?(relay_termination_text(@last_camera_relay_session))} class="mt-1">
            {relay_termination_text(@last_camera_relay_session)}
          </div>
          <div :if={present?(relay_failure_reason_text(@last_camera_relay_session))} class="mt-1">
            {relay_failure_reason_text(@last_camera_relay_session)}
          </div>
          <div :if={present?(relay_close_reason_text(@last_camera_relay_session))} class="mt-1">
            {relay_close_reason_text(@last_camera_relay_session)}
          </div>
        </div>
      </div>
    </.ui_panel>

    <.ui_panel :if={@camera_relay_tiles != []}>
      <:header>
        <div class="flex items-center justify-between gap-3">
          <div>
            <div class="text-sm font-semibold">Topology Camera Tile Set</div>
            <div class="text-xs text-sr-muted">
              Bounded multi-camera relay viewing from clustered topology endpoints.
            </div>
          </div>
          <div class="flex items-center gap-2">
            <.ui_badge size="sm" variant="outline">
              {length(@camera_relay_tiles)} / {camera_relay_tile_limit()}
            </.ui_badge>
            <.ui_button
              type="button"
              phx-click="close_camera_relay_tile_set"
              size="xs"
              variant="outline"
            >
              Close All
            </.ui_button>
          </div>
        </div>
      </:header>

      <div class="space-y-3">
        <div
          :if={present?(@camera_relay_tile_notice)}
          class="rounded-lg border border-info/30 bg-info/10 px-3 py-2 text-xs text-info-content"
        >
          {@camera_relay_tile_notice}
        </div>

        <div class="grid grid-cols-1 gap-3 xl:grid-cols-2">
          <div
            :for={tile <- @camera_relay_tiles}
            id={"camera-relay-tile-#{camera_relay_tile_dom_id(tile)}"}
            class="rounded-xl border border-sr-line/70 bg-sr-subtle/20 p-3 shadow-sm"
          >
            <div class="flex items-start justify-between gap-3">
              <div class="min-w-0">
                <div class="truncate text-sm font-medium text-sr-ink">
                  {camera_relay_tile_label(tile)}
                </div>
                <div
                  :if={present?(camera_relay_tile_profile_label(tile))}
                  class="mt-1 text-xs text-sr-muted"
                >
                  {camera_relay_tile_profile_label(tile)}
                </div>
                <.link
                  :if={present?(camera_relay_tile_device_uid(tile))}
                  navigate={~p"/devices/#{camera_relay_tile_device_uid(tile)}"}
                  class="text-sr-brand hover:underline mt-1 inline-block text-xs"
                >
                  View device
                </.link>
              </div>
              <div class="flex items-center gap-2">
                <.ui_badge
                  :if={camera_relay_tile_status_label(tile)}
                  size="sm"
                  variant={camera_relay_tile_badge_variant(tile)}
                >
                  {camera_relay_tile_status_label(tile)}
                </.ui_badge>
                <.ui_button
                  :if={camera_relay_tile_session_id(tile)}
                  type="button"
                  phx-click="close_camera_relay_tile"
                  phx-value-relay_session_id={camera_relay_tile_session_id(tile)}
                  size="xs"
                  variant="outline"
                >
                  Stop
                </.ui_button>
                <.ui_button
                  :if={!camera_relay_tile_session_id(tile)}
                  type="button"
                  phx-click="dismiss_camera_relay_tile"
                  phx-value-tile_id={tile.tile_id}
                  size="xs"
                  variant="ghost"
                >
                  Dismiss
                </.ui_button>
              </div>
            </div>

            <div
              :if={camera_relay_tile_active?(tile)}
              id={"topology-camera-relay-tile-stream-#{camera_relay_tile_dom_id(tile)}"}
              phx-hook="CameraRelayStatusStream"
              phx-update="ignore"
              data-stream-path={camera_relay_tile_stream_path(tile)}
              data-preferred-playback-transport={
                relay_preferred_playback_transport(camera_relay_tile_session(tile))
              }
              data-available-playback-transports={
                relay_available_playback_transports(camera_relay_tile_session(tile))
              }
              data-playback-codec-hint={relay_playback_codec_hint(camera_relay_tile_session(tile))}
              data-playback-container-hint={
                relay_playback_container_hint(camera_relay_tile_session(tile))
              }
              data-webrtc-playback-transport={
                relay_webrtc_playback_transport(camera_relay_tile_session(tile))
              }
              data-webrtc-signaling-path={
                relay_webrtc_signaling_path(camera_relay_tile_session(tile))
              }
              data-webrtc-ice-servers={relay_webrtc_ice_servers_json(camera_relay_tile_session(tile))}
              class="mt-3 space-y-1"
            >
              <div class="overflow-hidden rounded-md border border-sr-line/70 bg-sr-control/20">
                <canvas
                  data-role="video-canvas"
                  class="block aspect-video w-full bg-neutral/80 object-contain"
                />
                <video
                  data-role="video-element"
                  class="hidden aspect-video w-full bg-neutral/80 object-contain"
                  muted
                  playsinline
                  autoplay
                />
              </div>
              <div data-role="transport-status" class="text-xs text-sr-muted">
                Connecting browser stream...
              </div>
              <div data-role="player-status" class="text-xs text-sr-muted">
                Waiting for browser decoder...
              </div>
              <div data-role="compatibility-status" class="text-xs text-sr-muted">
                Preferred transport: {relay_preferred_playback_transport(
                  camera_relay_tile_session(tile)
                )}
              </div>
              <div data-role="relay-status" class="text-xs font-medium text-sr-ink">
                Relay status: {camera_relay_tile_session_status_label(tile)}
              </div>
              <div
                data-role="playback-state"
                data-state={camera_relay_tile_playback_state(tile)}
                class="text-xs text-sr-muted"
              >
                Playback state: {camera_relay_tile_playback_state(tile)}
              </div>
              <div data-role="viewer-count" class="text-xs text-sr-muted">
                Viewer count: {camera_relay_tile_viewer_count(tile)}
              </div>
              <div data-role="termination-kind" class="text-xs text-info/80">
                {camera_relay_tile_termination_text(tile)}
              </div>
              <div data-role="failure-reason" class="text-xs text-error/80">
                {camera_relay_tile_failure_reason_text(tile)}
              </div>
              <div data-role="close-reason" class="text-xs text-warning/80">
                {camera_relay_tile_close_reason_text(tile)}
              </div>
              <div data-role="binary-stats" class="text-xs text-sr-muted">
                Chunks: 0  Bytes: 0
              </div>
              <div data-role="relay-detail" class="text-xs text-sr-muted">
                Cluster tile playback is attached to the persisted relay session.
              </div>
            </div>

            <div
              :if={!camera_relay_tile_active?(tile)}
              class={[
                "mt-3 rounded-lg border p-3 text-xs",
                camera_relay_tile_viewer_state_container_class(tile)
              ]}
            >
              <div class="font-medium">
                {camera_relay_tile_status_label(tile) || "Relay pending"}
              </div>
              <div
                :if={present?(camera_relay_tile_viewer_detail(tile))}
                class="mt-1 leading-5 opacity-90"
              >
                {camera_relay_tile_viewer_detail(tile)}
              </div>
              <div
                :if={present?(camera_relay_tile_failure_reason_text(tile))}
                class="mt-1 opacity-90"
              >
                {camera_relay_tile_failure_reason_text(tile)}
              </div>
              <div
                :if={present?(camera_relay_tile_close_reason_text(tile))}
                class="mt-1 opacity-90"
              >
                {camera_relay_tile_close_reason_text(tile)}
              </div>
            </div>
          </div>
        </div>
      </div>
    </.ui_panel>
    """
  end

  def relay_status_label(status) when is_atom(status), do: status |> Atom.to_string() |> String.capitalize()
  def relay_status_label(status) when is_binary(status), do: String.capitalize(status)
  def relay_status_label(_), do: "Requested"

  def relay_status_badge_variant(:active), do: "success"
  def relay_status_badge_variant("active"), do: "success"
  def relay_status_badge_variant(:opening), do: "warning"
  def relay_status_badge_variant("opening"), do: "warning"
  def relay_status_badge_variant(:closing), do: "warning"
  def relay_status_badge_variant("closing"), do: "warning"
  def relay_status_badge_variant(:failed), do: "error"
  def relay_status_badge_variant("failed"), do: "error"
  def relay_status_badge_variant(_), do: "ghost"

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

  def relay_playback_contract(session) when is_map(session) do
    session
    |> Map.merge(relay_webrtc_metadata(session))
    |> RelayPlayback.browser_metadata()
  end

  def relay_playback_contract(_session), do: RelayPlayback.browser_metadata(%{})

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

  def relay_webrtc_metadata(%{id: _relay_session_id} = session), do: ServiceRadarWebNG.CameraRelayWebRTC.metadata(session)

  def relay_webrtc_metadata(_session), do: %{}

  def relay_close_reason_text(session) do
    session
    |> Map.get(:close_reason)
    |> case do
      value when is_binary(value) and value != "" -> "Close reason: #{value}"
      _ -> ""
    end
  end

  def relay_failure_reason_text(session) do
    session
    |> Map.get(:failure_reason)
    |> case do
      value when is_binary(value) and value != "" -> "Failure reason: #{value}"
      _ -> ""
    end
  end

  def relay_termination_text(session) do
    case Map.get(session, :termination_kind) do
      value when is_binary(value) and value != "" ->
        "Termination: #{value |> String.replace("_", " ") |> String.capitalize()}"

      _ ->
        ""
    end
  end

  def camera_relay_stream_path(%{id: relay_session_id}) when is_binary(relay_session_id) do
    ~p"/v1/camera-relay-sessions/#{relay_session_id}/stream"
  end

  def camera_relay_stream_path(_session), do: nil

  def relay_session_terminal?(%{status: status}), do: status in [:closed, :failed, "closed", "failed"]
  def relay_session_terminal?(_session), do: false

  def viewer_state_badge_variant(:auth_required), do: "warning"
  def viewer_state_badge_variant(:unavailable), do: "warning"
  def viewer_state_badge_variant(:unauthorized), do: "error"
  def viewer_state_badge_variant(:relay_error), do: "error"
  def viewer_state_badge_variant(_kind), do: "outline"

  def viewer_state_container_class(:auth_required) do
    "border-warning/40 bg-warning/10 text-warning-content"
  end

  def viewer_state_container_class(:unavailable) do
    "border-warning/40 bg-warning/10 text-warning-content"
  end

  def viewer_state_container_class(:unauthorized) do
    "border-error/40 bg-error/10 text-error-content"
  end

  def viewer_state_container_class(:relay_error) do
    "border-error/40 bg-error/10 text-error-content"
  end

  def viewer_state_container_class(_kind), do: "border-sr-line/70 bg-sr-subtle/20 text-sr-ink"

  def camera_relay_tile_limit do
    case Application.get_env(:serviceradar_web_ng, :camera_relay_tile_limit, @default_camera_relay_tile_limit) do
      value when is_integer(value) and value > 0 -> value
      _other -> @default_camera_relay_tile_limit
    end
  end

  def camera_relay_tile_dom_id(tile) do
    (Map.get(tile, :tile_id) || Ecto.UUID.generate())
    |> to_string()
    |> String.replace(~r/[^a-zA-Z0-9_-]/u, "-")
  end

  def camera_relay_tile_session_id(tile) do
    tile
    |> Map.get(:relay_session, %{})
    |> Map.get(:id)
  end

  def camera_relay_tile_session(tile), do: Map.get(tile, :relay_session, %{})

  def camera_relay_tile_label(tile) do
    Map.get(tile, :camera_label) || "Cluster camera"
  end

  def camera_relay_tile_profile_label(tile), do: Map.get(tile, :profile_label)
  def camera_relay_tile_device_uid(tile), do: Map.get(tile, :device_uid)

  def camera_relay_tile_active?(tile) do
    session = Map.get(tile, :relay_session)
    is_map(session) and not relay_session_terminal?(session)
  end

  def camera_relay_tile_stream_path(tile) do
    tile
    |> Map.get(:relay_session)
    |> camera_relay_stream_path()
  end

  def camera_relay_tile_status_label(tile) do
    cond do
      is_map(Map.get(tile, :relay_session)) ->
        relay_status_label(Map.get(tile.relay_session, :status))

      is_map(Map.get(tile, :viewer_state)) ->
        Map.get(tile.viewer_state, :title)

      true ->
        nil
    end
  end

  def camera_relay_tile_session_status_label(tile) do
    tile
    |> Map.get(:relay_session, %{})
    |> Map.get(:status)
    |> relay_status_label()
  end

  def camera_relay_tile_badge_variant(tile) do
    cond do
      is_map(Map.get(tile, :relay_session)) ->
        relay_status_badge_variant(Map.get(tile.relay_session, :status))

      is_map(Map.get(tile, :viewer_state)) ->
        viewer_state_badge_variant(Map.get(tile.viewer_state, :kind))

      true ->
        "ghost"
    end
  end

  def camera_relay_tile_playback_state(tile) do
    tile
    |> Map.get(:relay_session, %{})
    |> relay_playback_state()
  end

  def camera_relay_tile_viewer_count(tile) do
    tile
    |> Map.get(:relay_session, %{})
    |> Map.get(:viewer_count, 0)
  end

  def camera_relay_tile_termination_text(tile) do
    tile
    |> Map.get(:relay_session)
    |> case do
      session when is_map(session) -> relay_termination_text(session)
      _ -> ""
    end
  end

  def camera_relay_tile_failure_reason_text(tile) do
    tile
    |> Map.get(:relay_session)
    |> case do
      session when is_map(session) -> relay_failure_reason_text(session)
      _ -> ""
    end
  end

  def camera_relay_tile_close_reason_text(tile) do
    tile
    |> Map.get(:relay_session)
    |> case do
      session when is_map(session) -> relay_close_reason_text(session)
      _ -> ""
    end
  end

  def camera_relay_tile_viewer_detail(tile) do
    case Map.get(tile, :viewer_state) do
      %{detail: detail} -> detail
      _ -> nil
    end
  end

  def camera_relay_tile_viewer_state_container_class(tile) do
    case Map.get(tile, :viewer_state) do
      %{kind: kind} -> viewer_state_container_class(kind)
      _ -> "border-sr-line/70 bg-sr-subtle/20 text-sr-ink"
    end
  end

  def camera_context_label(%{camera_label: value}) when is_binary(value) and value != "", do: value
  def camera_context_label(_context), do: "Selected camera"

  def camera_context_profile_label(%{profile_label: value}) when is_binary(value), do: value
  def camera_context_profile_label(_context), do: nil

  def camera_context_device_uid(%{device_uid: value}) when is_binary(value), do: value
  def camera_context_device_uid(_context), do: nil

  def normalize_presence(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  def normalize_presence(_value), do: nil

  def present?(value) when is_binary(value), do: String.trim(value) != ""
  def present?(_value), do: false
end
