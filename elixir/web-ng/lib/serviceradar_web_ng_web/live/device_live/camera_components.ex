defmodule ServiceRadarWebNGWeb.DeviceLive.CameraComponents do
  @moduledoc false

  use ServiceRadarWebNGWeb, :html

  alias ServiceRadar.Camera.RelayPlayback
  alias ServiceRadar.Camera.RelayTermination

  attr(:camera_sources, :list, default: [])
  attr(:inventory_error, :string, default: nil)
  attr(:active_session, :any, default: nil)
  attr(:last_session, :any, default: nil)

  def camera_streams_section(assigns) do
    sources = normalize_camera_sources_for_display(assigns.camera_sources)

    assigns =
      assigns
      |> assign(:sources, sources)
      |> assign(:has_sources, sources != [])
      |> assign(:active_session_key, camera_relay_session_key(assigns.active_session))
      |> assign(:last_session_key, camera_relay_session_key(assigns.last_session))
      |> assign(:active_stream_path, camera_relay_stream_path(assigns.active_session))

    ~H"""
    <div class="rounded-xl border border-sr-line bg-sr-surface">
      <div class="px-4 py-3 border-b border-sr-line flex items-center justify-between gap-3">
        <div class="flex items-center gap-2">
          <.icon name="hero-video-camera" class="size-4 text-secondary" />
          <span class="text-sm font-semibold">Camera Streams</span>
        </div>
        <span :if={@active_session} class="text-xs text-sr-muted">
          Session {String.slice(@active_session.id || "", 0, 8)}
        </span>
      </div>

      <div class="p-4 space-y-4">
        <div
          :if={is_binary(@inventory_error)}
          class="rounded-lg border border-warning/30 bg-warning/5 px-3 py-2 text-sm text-warning"
        >
          {@inventory_error}
        </div>

        <div :if={not @has_sources} class="text-sm text-sr-muted">
          No relay-capable camera streams are mapped to this device yet.
        </div>

        <.camera_relay_stream_panel
          :if={@active_session}
          active_session={@active_session}
          active_stream_path={@active_stream_path}
        />

        <div :for={source <- @sources} class="rounded-xl border border-sr-line/80 bg-base-50/40">
          <div class="flex flex-wrap items-center justify-between gap-3 border-b border-sr-line/80 px-4 py-3">
            <div>
              <div class="font-medium text-sm">{source.display_name}</div>
              <div class="mt-1 flex flex-wrap items-center gap-2 text-xs text-sr-muted">
                <span>{String.upcase(source.vendor)}</span>
                <span :if={present?(source.assigned_agent_id)}>agent {source.assigned_agent_id}</span>
                <span :if={present?(source.assigned_gateway_id)}>
                  gateway {source.assigned_gateway_id}
                </span>
              </div>
              <div
                :if={present?(source.availability_reason)}
                class="mt-1 text-xs text-sr-muted"
              >
                {source.availability_reason}
              </div>
            </div>
            <div class="flex items-center gap-2">
              <.ui_badge size="sm" variant={camera_source_status_variant(source)}>
                {camera_source_status_label(source)}
              </.ui_badge>
              <.ui_badge size="sm" variant="outline">
                {length(source.stream_profiles)} profile{if length(source.stream_profiles) == 1,
                  do: "",
                  else: "s"}
              </.ui_badge>
            </div>
          </div>

          <div class="divide-y divide-sr-line/70">
            <div
              :for={profile <- source.stream_profiles}
              class="flex flex-wrap items-center justify-between gap-3 px-4 py-3"
            >
              <div>
                <div class="font-medium text-sm">{profile.profile_name}</div>
                <div class="mt-1 flex flex-wrap gap-2 text-xs text-sr-muted">
                  <span :if={present?(profile.codec_hint)}>{String.upcase(profile.codec_hint)}</span>
                  <span :if={present?(profile.container_hint)}>{profile.container_hint}</span>
                  <span :if={present?(profile.rtsp_transport)}>RTSP {profile.rtsp_transport}</span>
                </div>
              </div>

              <div class="flex flex-wrap items-center gap-2">
                <%= cond do %>
                  <% @active_session_key == {source.id, profile.id} -> %>
                    <.ui_badge size="sm" variant={relay_status_variant(@active_session.status)}>
                      {relay_status_label(@active_session.status)}
                    </.ui_badge>
                    <.ui_button
                      :if={relay_session_closable?(@active_session)}
                      phx-click="close_camera_relay"
                      variant="outline"
                      size="xs"
                    >
                      Stop Relay
                    </.ui_button>
                  <% @last_session_key == {source.id, profile.id} -> %>
                    <.ui_badge size="sm" variant={relay_status_variant(@last_session.status)}>
                      {relay_status_label(@last_session.status)}
                    </.ui_badge>
                    <span
                      :if={present?(relay_termination_label(@last_session))}
                      class="text-xs text-info"
                    >
                      {relay_termination_label(@last_session)}
                    </span>
                    <span
                      :if={present?(Map.get(@last_session, :failure_reason))}
                      class="text-xs text-error"
                      title={Map.get(@last_session, :failure_reason)}
                    >
                      {Map.get(@last_session, :failure_reason)}
                    </span>
                    <span
                      :if={present?(Map.get(@last_session, :close_reason))}
                      class="text-xs text-warning"
                      title={Map.get(@last_session, :close_reason)}
                    >
                      {Map.get(@last_session, :close_reason)}
                    </span>
                    <%= if camera_source_openable?(source) do %>
                      <div class="flex flex-wrap items-center gap-2">
                        <.ui_button
                          phx-click="open_camera_relay"
                          phx-value-camera_source_id={source.id}
                          phx-value-stream_profile_id={profile.id}
                          variant="outline"
                          size="xs"
                        >
                          Open Relay
                        </.ui_button>
                        <.ui_button
                          :if={camera_profile_supports_insecure_tls_override?(source, profile)}
                          phx-click="open_camera_relay"
                          phx-value-camera_source_id={source.id}
                          phx-value-stream_profile_id={profile.id}
                          phx-value-insecure_skip_verify="true"
                          variant="ghost"
                          size="xs"
                        >
                          Skip TLS Verify
                        </.ui_button>
                      </div>
                    <% else %>
                      <span class="text-xs text-error">Relay unavailable</span>
                    <% end %>
                  <% true -> %>
                    <%= if camera_source_openable?(source) do %>
                      <div class="flex flex-wrap items-center gap-2">
                        <.ui_button
                          phx-click="open_camera_relay"
                          phx-value-camera_source_id={source.id}
                          phx-value-stream_profile_id={profile.id}
                          variant="outline"
                          size="xs"
                          disabled={not is_nil(@active_session)}
                        >
                          Open Relay
                        </.ui_button>
                        <.ui_button
                          :if={camera_profile_supports_insecure_tls_override?(source, profile)}
                          phx-click="open_camera_relay"
                          phx-value-camera_source_id={source.id}
                          phx-value-stream_profile_id={profile.id}
                          phx-value-insecure_skip_verify="true"
                          variant="ghost"
                          size="xs"
                          disabled={not is_nil(@active_session)}
                        >
                          Skip TLS Verify
                        </.ui_button>
                      </div>
                    <% else %>
                      <span class="text-xs text-error">Relay unavailable</span>
                    <% end %>
                <% end %>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr(:active_session, :any, required: true)
  attr(:active_stream_path, :string, default: nil)

  def camera_relay_stream_panel(assigns) do
    ~H"""
    <div class="rounded-lg border border-info/20 bg-info/5 p-3">
      <div
        id={"camera-relay-stream-#{@active_session.id}"}
        phx-hook="CameraRelayStatusStream"
        phx-update="ignore"
        data-stream-path={@active_stream_path}
        data-preferred-playback-transport={relay_preferred_playback_transport(@active_session)}
        data-available-playback-transports={relay_available_playback_transports(@active_session)}
        data-playback-codec-hint={relay_playback_codec_hint(@active_session)}
        data-playback-container-hint={relay_playback_container_hint(@active_session)}
        data-webrtc-playback-transport={relay_webrtc_playback_transport(@active_session)}
        data-webrtc-signaling-path={relay_webrtc_signaling_path(@active_session)}
        data-webrtc-ice-servers={relay_webrtc_ice_servers_json(@active_session)}
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
          Preferred transport: {relay_preferred_playback_transport(@active_session)}
        </div>
        <div data-role="relay-status" class="text-xs font-medium text-sr-ink">
          Relay status: {relay_status_label(@active_session.status)}
        </div>
        <div
          data-role="playback-state"
          data-state={relay_playback_state(@active_session)}
          class="text-xs text-sr-muted"
        >
          Playback state: {relay_playback_state(@active_session)}
        </div>
        <div data-role="viewer-count" class="text-xs text-sr-muted">
          Viewer count: {Map.get(@active_session, :viewer_count, 0)}
        </div>
        <div data-role="termination-kind" class="text-xs text-info/80">
          {relay_termination_text(@active_session)}
        </div>
        <div data-role="close-reason" class="text-xs text-warning/80">
          {relay_close_reason_text(@active_session)}
        </div>
        <div data-role="binary-stats" class="text-xs text-sr-muted">
          Chunks: 0  Bytes: 0
        </div>
        <div data-role="relay-detail" class="text-xs text-sr-muted">
          Browser viewer channel is attached to the persisted relay session.
        </div>
      </div>
    </div>
    """
  end

  def normalize_camera_sources_for_display(sources) do
    sources
    |> Enum.map(fn source ->
      %{
        id: source.id,
        vendor: source.vendor || "camera",
        display_name: camera_source_display_name(source),
        source_url: source.source_url,
        assigned_agent_id: source.assigned_agent_id,
        assigned_gateway_id: source.assigned_gateway_id,
        availability_status: camera_source_availability_status(source),
        availability_reason: camera_source_availability_reason(source),
        stream_profiles:
          source
          |> Map.get(:stream_profiles, [])
          |> Enum.filter(&Map.get(&1, :relay_eligible, false))
          |> Enum.sort_by(fn profile ->
            {
              String.downcase(to_string(Map.get(profile, :profile_name, ""))),
              to_string(Map.get(profile, :id, ""))
            }
          end)
      }
    end)
    |> Enum.reject(&Enum.empty?(&1.stream_profiles))
    |> Enum.sort_by(fn source ->
      {
        String.downcase(source.display_name),
        String.downcase(to_string(source.vendor))
      }
    end)
  end

  def camera_source_display_name(source) do
    source.display_name || source.vendor_camera_id || source.device_uid || "Camera"
  end

  def camera_source_availability_status(source) when is_map(source) do
    source
    |> Map.get(:availability_status)
    |> case do
      value when is_binary(value) ->
        trimmed = String.trim(value)
        if trimmed == "", do: nil, else: String.downcase(trimmed)

      _ ->
        nil
    end
  end

  def camera_source_availability_status(_source), do: nil

  def camera_source_availability_reason(source) when is_map(source) do
    source
    |> Map.get(:availability_reason)
    |> case do
      value when is_binary(value) ->
        trimmed = String.trim(value)
        if trimmed == "", do: nil, else: trimmed

      _ ->
        nil
    end
  end

  def camera_source_availability_reason(_source), do: nil

  defp camera_source_openable?(source) do
    camera_source_availability_status(source) != "unavailable"
  end

  defp camera_profile_supports_insecure_tls_override?(source, profile) do
    source
    |> camera_profile_source_url(profile)
    |> case do
      value when is_binary(value) ->
        String.starts_with?(String.downcase(String.trim(value)), "rtsps://")

      _other ->
        false
    end
  end

  def camera_profile_source_url(source, profile) when is_map(profile) do
    case Map.get(profile, :source_url_override) do
      value when is_binary(value) and value != "" -> value
      _other -> if(is_map(source), do: Map.get(source, :source_url))
    end
  end

  def camera_profile_source_url(_source, _profile), do: nil

  def camera_source_status_label(source) do
    case camera_source_availability_status(source) do
      "available" -> "Available"
      "degraded" -> "Degraded"
      "unavailable" -> "Unavailable"
      _ -> "Unknown"
    end
  end

  def camera_source_status_variant(source) do
    case camera_source_availability_status(source) do
      "available" -> "success"
      "degraded" -> "warning"
      "unavailable" -> "error"
      _ -> "ghost"
    end
  end

  def camera_streams_visible?(camera_sources, inventory_error, active_session, last_session) do
    inventory_error ||
      not is_nil(active_session) ||
      not is_nil(last_session) ||
      camera_sources
      |> normalize_camera_sources_for_display()
      |> Enum.any?()
  end

  def camera_relay_session_key(nil), do: nil

  def camera_relay_session_key(session) do
    {Map.get(session, :camera_source_id), Map.get(session, :stream_profile_id)}
  end

  def relay_status_label(status) when is_atom(status), do: status |> Atom.to_string() |> String.capitalize()

  def relay_status_label(status) when is_binary(status), do: String.capitalize(status)
  def relay_status_label(_), do: "Requested"

  def relay_status_variant(:active), do: "success"
  def relay_status_variant("active"), do: "success"
  def relay_status_variant(:opening), do: "warning"
  def relay_status_variant("opening"), do: "warning"
  def relay_status_variant(:closing), do: "warning"
  def relay_status_variant("closing"), do: "warning"
  def relay_status_variant(:failed), do: "error"
  def relay_status_variant("failed"), do: "error"
  def relay_status_variant(_), do: "ghost"

  def relay_playback_state(%{status: status, media_ingest_id: media_ingest_id})
      when status in [:active, "active"] and is_binary(media_ingest_id) and media_ingest_id != "" do
    "ready"
  end

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
    case Map.get(session || %{}, :close_reason) do
      value when is_binary(value) ->
        trimmed = String.trim(value)
        if trimmed == "", do: "", else: "Close reason: #{trimmed}"

      value when is_nil(value) ->
        ""

      value ->
        "Close reason: #{value}"
    end
  end

  def relay_termination_label(session) do
    session
    |> relay_termination_kind()
    |> RelayTermination.label()
    |> case do
      value when is_binary(value) -> value
      _other -> ""
    end
  end

  def relay_termination_text(session) do
    case relay_termination_label(session) do
      "" -> ""
      label -> "Termination: #{label}"
    end
  end

  def relay_termination_kind(session) when is_map(session) do
    Map.get(session, :termination_kind) || Map.get(session, "termination_kind")
  end

  def relay_termination_kind(_session), do: nil

  def camera_relay_stream_path(%{id: relay_session_id}) when is_binary(relay_session_id) do
    ~p"/v1/camera-relay-sessions/#{relay_session_id}/stream"
  end

  def camera_relay_stream_path(_session), do: nil

  defp relay_session_closable?(%{status: status}) do
    status in [:requested, :opening, :active, "requested", "opening", "active"]
  end

  defp relay_session_closable?(_session), do: false

  def relay_session_terminal?(%{status: status}), do: status in [:closed, :failed, "closed", "failed"]

  def relay_session_terminal?(_session), do: false

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value), do: not is_nil(value)
end
