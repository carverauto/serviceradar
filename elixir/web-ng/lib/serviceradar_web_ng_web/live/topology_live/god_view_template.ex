defmodule ServiceRadarWebNGWeb.TopologyLive.GodViewTemplate do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  alias ServiceRadar.Camera.RelayPlayback

  @default_camera_relay_tile_limit 4

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} srql={%{page_path: @current_path}}>
      <div class="mx-auto max-w-7xl p-6 space-y-6">
        <.ui_panel>
          <:header>
            <div class="text-sm font-semibold">Topology Surface</div>
          </:header>
          <div class="relative">
            <div
              id="god-view-binary-stream"
              phx-hook="GodViewBinaryStream"
              phx-update="ignore"
              data-url={@snapshot_url}
              data-interval-ms="5000"
              class="h-[70vh] min-h-[480px] w-full rounded-lg border border-base-200 bg-base-200/20"
            >
              loading topology surface...
            </div>

            <div
              :if={
                empty_topology_state =
                  empty_topology_state(
                    @stream_state,
                    @last_node_count,
                    @last_edge_count,
                    @pipeline_stats
                  )
              }
              class="pointer-events-none absolute inset-0 z-10 flex items-center justify-center"
            >
              <div class="max-w-xl rounded-lg border border-warning/30 bg-base-100/90 px-5 py-4 text-center shadow-lg backdrop-blur-sm">
                <div class="text-sm font-semibold text-warning">{empty_topology_state.title}</div>
                <div class="mt-1 text-xs text-base-content/70">{empty_topology_state.message}</div>
              </div>
            </div>

            <div
              id="god-view-controls"
              phx-hook="GodViewControlsState"
              data-collapsed={to_string(@controls_collapsed)}
              class="absolute right-3 top-3 z-20 pointer-events-auto"
            >
              <div class="w-[220px] rounded-lg border border-base-300/70 bg-base-100/85 p-2 shadow-lg backdrop-blur-md">
                <div class="flex items-center justify-between gap-2">
                  <div class="text-[10px] uppercase tracking-wide text-base-content/60">
                    Controls
                  </div>
                  <button
                    type="button"
                    class="btn btn-xs btn-ghost h-6 min-h-6 px-2"
                    phx-click="toggle_controls_panel"
                    title={if @controls_collapsed, do: "Expand controls", else: "Collapse controls"}
                  >
                    {if @controls_collapsed, do: "Expand", else: "Collapse"}
                  </button>
                </div>

                <div :if={@controls_collapsed} class="mt-2 grid grid-cols-3 gap-1">
                  <button
                    type="button"
                    class={overlay_filter_button_class(@visual_layers.atmosphere)}
                    phx-click="toggle_visual_layer"
                    phx-value-layer="atmosphere"
                    title="Traffic stream"
                  >
                    Traffic
                  </button>
                  <button
                    type="button"
                    class={overlay_zoom_button_class(@zoom_mode == "auto")}
                    phx-click="set_zoom_mode"
                    phx-value-mode="auto"
                    title="Auto Focus"
                  >
                    Auto
                  </button>
                  <button
                    type="button"
                    class="btn btn-xs btn-ghost h-7 min-h-7"
                    phx-click="reset_view"
                    title="Reset view to fit all nodes"
                  >
                    Reset
                  </button>
                </div>

                <div :if={!@controls_collapsed} class="space-y-2 mt-2">
                  <div>
                    <div class="text-[10px] uppercase tracking-wide text-base-content/60 mb-1">
                      View
                    </div>
                    <div class="join w-full">
                      <button
                        type="button"
                        class={"join-item flex-1 #{overlay_zoom_button_class(@zoom_mode == "auto")}"}
                        phx-click="set_zoom_mode"
                        phx-value-mode="auto"
                        title="Auto Focus"
                      >
                        Auto
                      </button>
                      <button
                        type="button"
                        class={"join-item flex-1 #{overlay_zoom_button_class(@zoom_mode == "global")}"}
                        phx-click="set_zoom_mode"
                        phx-value-mode="global"
                        title="World Aggregate"
                      >
                        World
                      </button>
                      <button
                        type="button"
                        class={"join-item flex-1 #{overlay_zoom_button_class(@zoom_mode == "regional")}"}
                        phx-click="set_zoom_mode"
                        phx-value-mode="regional"
                        title="Region Cells"
                      >
                        Region
                      </button>
                      <button
                        type="button"
                        class={"join-item flex-1 #{overlay_zoom_button_class(@zoom_mode == "local")}"}
                        phx-click="set_zoom_mode"
                        phx-value-mode="local"
                        title="Device Detail"
                      >
                        Detail
                      </button>
                    </div>
                    <button
                      type="button"
                      class="btn btn-xs btn-ghost h-7 min-h-7 w-full mt-1"
                      phx-click="reset_view"
                      title="Reset view and collapse expanded endpoint clusters"
                    >
                      Reset / Collapse
                    </button>
                  </div>

                  <div>
                    <div class="text-[10px] uppercase tracking-wide text-base-content/60 mb-1">
                      Health
                    </div>
                    <div class="grid grid-cols-2 gap-1">
                      <button
                        type="button"
                        class={overlay_filter_button_class(@causal_filters.root_cause)}
                        phx-click="toggle_causal_filter"
                        phx-value-state="root_cause"
                        title="Root Cause Nodes"
                      >
                        Root
                      </button>
                      <button
                        type="button"
                        class={overlay_filter_button_class(@causal_filters.affected)}
                        phx-click="toggle_causal_filter"
                        phx-value-state="affected"
                        title="Affected Nodes"
                      >
                        Impact
                      </button>
                      <button
                        type="button"
                        class={overlay_filter_button_class(@causal_filters.healthy)}
                        phx-click="toggle_causal_filter"
                        phx-value-state="healthy"
                        title="Healthy Nodes"
                      >
                        Healthy
                      </button>
                      <button
                        type="button"
                        class={overlay_filter_button_class(@causal_filters.unknown)}
                        phx-click="toggle_causal_filter"
                        phx-value-state="unknown"
                        title="Unknown State Nodes"
                      >
                        Unknown
                      </button>
                    </div>
                  </div>

                  <div>
                    <div class="text-[10px] uppercase tracking-wide text-base-content/60 mb-1">
                      Layers
                    </div>
                    <div class="grid grid-cols-2 gap-1">
                      <button
                        type="button"
                        class={overlay_filter_button_class(@visual_layers.mantle)}
                        phx-click="toggle_visual_layer"
                        phx-value-layer="mantle"
                        title="Link Lines"
                      >
                        Links
                      </button>
                      <button
                        type="button"
                        class={overlay_filter_button_class(@visual_layers.crust)}
                        phx-click="toggle_visual_layer"
                        phx-value-layer="crust"
                        title="Arc Glow"
                      >
                        Arcs
                      </button>
                      <button
                        type="button"
                        class={overlay_filter_button_class(@visual_layers.atmosphere)}
                        phx-click="toggle_visual_layer"
                        phx-value-layer="atmosphere"
                        title="Traffic stream"
                      >
                        Traffic
                      </button>
                      <button
                        type="button"
                        class={overlay_filter_button_class(@visual_layers.security)}
                        phx-click="toggle_visual_layer"
                        phx-value-layer="security"
                        title="Security Pulse"
                      >
                        Pulse
                      </button>
                    </div>
                  </div>

                  <div>
                    <div class="text-[10px] uppercase tracking-wide text-base-content/60 mb-1">
                      Topology
                    </div>
                    <div class="grid grid-cols-2 gap-1">
                      <button
                        type="button"
                        class={overlay_filter_button_class(@topology_layers.backbone)}
                        phx-click="toggle_topology_layer"
                        phx-value-layer="backbone"
                        title="Backbone links"
                      >
                        Backbone
                      </button>
                      <button
                        type="button"
                        class={overlay_filter_button_class(@topology_layers.inferred)}
                        phx-click="toggle_topology_layer"
                        phx-value-layer="inferred"
                        title="Inferred links"
                      >
                        Inferred
                      </button>
                      <button
                        type="button"
                        class={overlay_filter_button_class(@topology_layers.endpoints)}
                        phx-click="toggle_topology_layer"
                        phx-value-layer="endpoints"
                        title="Endpoint attachments"
                      >
                        Endpoints
                      </button>
                      <button
                        type="button"
                        class={overlay_filter_button_class(@topology_layers.mtr_paths)}
                        phx-click="toggle_topology_layer"
                        phx-value-layer="mtr_paths"
                        title="MTR traceroute paths"
                      >
                        MTR
                      </button>
                    </div>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </.ui_panel>

        <.ui_panel>
          <:header>
            <div class="text-sm font-semibold">Snapshot Stream Contract</div>
          </:header>

          <div class="grid grid-cols-1 gap-3 sm:grid-cols-2">
            <div class="rounded-lg border border-base-200 bg-base-200/30 p-3">
              <div class="text-xs uppercase tracking-wide text-base-content/60">Schema Version</div>
              <div class="text-sm font-mono mt-1">{@schema_version}</div>
            </div>
            <div class="rounded-lg border border-base-200 bg-base-200/30 p-3">
              <div class="text-xs uppercase tracking-wide text-base-content/60">Stream State</div>
              <div class="text-sm font-mono mt-1">{@stream_state}</div>
            </div>
            <div class="rounded-lg border border-base-200 bg-base-200/30 p-3">
              <div class="text-xs uppercase tracking-wide text-base-content/60">Last Revision</div>
              <div class="text-sm font-mono mt-1">{@last_revision || "—"}</div>
            </div>
            <div class="rounded-lg border border-base-200 bg-base-200/30 p-3">
              <div class="text-xs uppercase tracking-wide text-base-content/60">Generated At</div>
              <div class="text-sm font-mono mt-1">{@last_generated_at || "—"}</div>
            </div>
            <div class="rounded-lg border border-base-200 bg-base-200/30 p-3">
              <div class="text-xs uppercase tracking-wide text-base-content/60">Payload Bytes</div>
              <div class="text-sm font-mono mt-1">{@last_bytes || "—"}</div>
            </div>
            <div class="rounded-lg border border-base-200 bg-base-200/30 p-3">
              <div class="text-xs uppercase tracking-wide text-base-content/60">Node Count</div>
              <div class="text-sm font-mono mt-1">{@last_node_count || "—"}</div>
            </div>
            <div class="rounded-lg border border-base-200 bg-base-200/30 p-3">
              <div class="text-xs uppercase tracking-wide text-base-content/60">Edge Count</div>
              <div class="text-sm font-mono mt-1">{@last_edge_count || "—"}</div>
            </div>
            <div class="rounded-lg border border-base-200 bg-base-200/30 p-3">
              <div class="text-xs uppercase tracking-wide text-base-content/60">Network (ms)</div>
              <div class="text-sm font-mono mt-1">{@last_network_ms || "—"}</div>
            </div>
            <div class="rounded-lg border border-base-200 bg-base-200/30 p-3">
              <div class="text-xs uppercase tracking-wide text-base-content/60">Renderer</div>
              <div class="text-sm font-mono mt-1">{@last_renderer_mode || "—"}</div>
            </div>
            <div class="rounded-lg border border-base-200 bg-base-200/30 p-3">
              <div class="text-xs uppercase tracking-wide text-base-content/60">Zoom Tier</div>
              <div class="text-sm font-mono mt-1">{@last_zoom_tier || "—"}</div>
            </div>
            <div class="rounded-lg border border-base-200 bg-base-200/30 p-3">
              <div class="text-xs uppercase tracking-wide text-base-content/60">Zoom Mode</div>
              <div class="text-sm font-mono mt-1">{@last_zoom_mode || "—"}</div>
            </div>
            <div class="rounded-lg border border-base-200 bg-base-200/30 p-3">
              <div class="text-xs uppercase tracking-wide text-base-content/60">Decode (ms)</div>
              <div class="text-sm font-mono mt-1">{@last_decode_ms || "—"}</div>
            </div>
            <div class="rounded-lg border border-base-200 bg-base-200/30 p-3">
              <div class="text-xs uppercase tracking-wide text-base-content/60">Render (ms)</div>
              <div class="text-sm font-mono mt-1">{@last_render_ms || "—"}</div>
            </div>
            <div class="rounded-lg border border-base-200 bg-base-200/30 p-3">
              <div class="text-xs uppercase tracking-wide text-base-content/60">
                Bitmap Meta (r/a/h/u)
              </div>
              <div class="text-sm font-mono mt-1">{format_bitmap_meta(@last_bitmap_metadata)}</div>
            </div>
          </div>
        </.ui_panel>

        <.ui_panel>
          <:header>
            <div class="text-sm font-semibold">Pipeline Telemetry</div>
          </:header>
          <div class="grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-4">
            <div class="rounded-lg border border-base-200 bg-base-200/30 p-3">
              <div class="text-xs uppercase tracking-wide text-base-content/60">Raw Observations</div>
              <div class="text-sm font-mono mt-1">{Map.get(@pipeline_stats, :raw_links, "—")}</div>
            </div>
            <div class="rounded-lg border border-base-200 bg-base-200/30 p-3">
              <div class="text-xs uppercase tracking-wide text-base-content/60">Unique Pairs</div>
              <div class="text-sm font-mono mt-1">{Map.get(@pipeline_stats, :unique_pairs, "—")}</div>
            </div>
            <div class="rounded-lg border border-base-200 bg-base-200/30 p-3">
              <div class="text-xs uppercase tracking-wide text-base-content/60">Final Edges</div>
              <div class="text-sm font-mono mt-1">{Map.get(@pipeline_stats, :final_edges, "—")}</div>
            </div>
            <div class="rounded-lg border border-base-200 bg-base-200/30 p-3">
              <div class="text-xs uppercase tracking-wide text-base-content/60">
                Unresolved Endpoints
              </div>
              <div class="text-sm font-mono mt-1">
                {Map.get(@pipeline_stats, :unresolved_endpoints, "—")}
              </div>
            </div>
            <div class="rounded-lg border border-base-200 bg-base-200/30 p-3">
              <div class="text-xs uppercase tracking-wide text-base-content/60">Direct</div>
              <div class="text-sm font-mono mt-1">{Map.get(@pipeline_stats, :final_direct, "—")}</div>
            </div>
            <div class="rounded-lg border border-base-200 bg-base-200/30 p-3">
              <div class="text-xs uppercase tracking-wide text-base-content/60">Inferred</div>
              <div class="text-sm font-mono mt-1">
                {Map.get(@pipeline_stats, :final_inferred, "—")}
              </div>
            </div>
            <div class="rounded-lg border border-base-200 bg-base-200/30 p-3">
              <div class="text-xs uppercase tracking-wide text-base-content/60">Attachments</div>
              <div class="text-sm font-mono mt-1">
                {Map.get(@pipeline_stats, :final_attachment, "—")}
              </div>
            </div>
          </div>
        </.ui_panel>

        <.ui_panel :if={
          @selected_camera_context || @active_camera_relay_session || @last_camera_relay_session
        }>
          <:header>
            <div class="flex items-center justify-between gap-3">
              <div>
                <div class="text-sm font-semibold">Topology Camera Viewer</div>
                <div class="text-xs text-base-content/60">
                  Opened from a God-View camera-capable node.
                </div>
              </div>
              <div class="flex items-center gap-2">
                <span
                  :if={@active_camera_relay_session}
                  class={[
                    "badge badge-sm",
                    relay_status_badge_class(@active_camera_relay_session.status)
                  ]}
                >
                  {relay_status_label(@active_camera_relay_session.status)}
                </span>
                <span
                  :if={!@active_camera_relay_session && @last_camera_relay_session}
                  class={[
                    "badge badge-sm",
                    relay_status_badge_class(@last_camera_relay_session.status)
                  ]}
                >
                  {relay_status_label(@last_camera_relay_session.status)}
                </span>
                <span
                  :if={@camera_relay_viewer_state}
                  class={[
                    "badge badge-sm",
                    viewer_state_badge_class(@camera_relay_viewer_state.kind)
                  ]}
                >
                  {@camera_relay_viewer_state.title}
                </span>
                <button
                  :if={@active_camera_relay_session}
                  type="button"
                  class="btn btn-xs btn-outline"
                  phx-click="close_camera_relay"
                >
                  Stop Relay
                </button>
              </div>
            </div>
          </:header>

          <div class="space-y-3">
            <div class="flex flex-wrap items-center gap-2 text-sm">
              <span class="font-medium text-base-content">
                {camera_context_label(@selected_camera_context)}
              </span>
              <span
                :if={present?(camera_context_profile_label(@selected_camera_context))}
                class="badge badge-outline badge-sm"
              >
                {camera_context_profile_label(@selected_camera_context)}
              </span>
              <.link
                :if={present?(camera_context_device_uid(@selected_camera_context))}
                navigate={~p"/devices/#{camera_context_device_uid(@selected_camera_context)}"}
                class="link link-primary text-xs"
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
              data-playback-container-hint={
                relay_playback_container_hint(@active_camera_relay_session)
              }
              data-webrtc-playback-transport={
                relay_webrtc_playback_transport(@active_camera_relay_session)
              }
              data-webrtc-signaling-path={relay_webrtc_signaling_path(@active_camera_relay_session)}
              data-webrtc-ice-servers={relay_webrtc_ice_servers_json(@active_camera_relay_session)}
              class="space-y-1"
            >
              <div class="overflow-hidden rounded-md border border-base-300/70 bg-base-300/20">
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
              <div data-role="transport-status" class="text-xs text-base-content/70">
                Connecting browser stream...
              </div>
              <div data-role="player-status" class="text-xs text-base-content/70">
                Waiting for browser decoder...
              </div>
              <div data-role="compatibility-status" class="text-xs text-base-content/70">
                Preferred transport: {relay_preferred_playback_transport(@active_camera_relay_session)}
              </div>
              <div data-role="relay-status" class="text-xs font-medium text-base-content">
                Relay status: {relay_status_label(@active_camera_relay_session.status)}
              </div>
              <div
                data-role="playback-state"
                data-state={relay_playback_state(@active_camera_relay_session)}
                class="text-xs text-base-content/70"
              >
                Playback state: {relay_playback_state(@active_camera_relay_session)}
              </div>
              <div data-role="viewer-count" class="text-xs text-base-content/70">
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
              <div data-role="binary-stats" class="text-xs text-base-content/60">
                Chunks: 0  Bytes: 0
              </div>
              <div data-role="relay-detail" class="text-xs text-base-content/60">
                Browser viewer channel is attached to the persisted relay session.
              </div>
            </div>

            <div
              :if={!@active_camera_relay_session && @last_camera_relay_session}
              class="rounded-lg border border-base-300/70 bg-base-200/20 p-3 text-xs text-base-content/70"
            >
              <div class="font-medium text-base-content">
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
                <div class="text-xs text-base-content/60">
                  Bounded multi-camera relay viewing from clustered topology endpoints.
                </div>
              </div>
              <div class="flex items-center gap-2">
                <span class="badge badge-outline badge-sm">
                  {length(@camera_relay_tiles)} / {camera_relay_tile_limit()}
                </span>
                <button
                  type="button"
                  class="btn btn-xs btn-outline"
                  phx-click="close_camera_relay_tile_set"
                >
                  Close All
                </button>
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
                class="rounded-xl border border-base-300/70 bg-base-200/20 p-3 shadow-sm"
              >
                <div class="flex items-start justify-between gap-3">
                  <div class="min-w-0">
                    <div class="truncate text-sm font-medium text-base-content">
                      {camera_relay_tile_label(tile)}
                    </div>
                    <div
                      :if={present?(camera_relay_tile_profile_label(tile))}
                      class="mt-1 text-xs text-base-content/60"
                    >
                      {camera_relay_tile_profile_label(tile)}
                    </div>
                    <.link
                      :if={present?(camera_relay_tile_device_uid(tile))}
                      navigate={~p"/devices/#{camera_relay_tile_device_uid(tile)}"}
                      class="link link-primary mt-1 inline-block text-xs"
                    >
                      View device
                    </.link>
                  </div>
                  <div class="flex items-center gap-2">
                    <span
                      :if={camera_relay_tile_status_label(tile)}
                      class={[
                        "badge badge-sm",
                        camera_relay_tile_badge_class(tile)
                      ]}
                    >
                      {camera_relay_tile_status_label(tile)}
                    </span>
                    <button
                      :if={camera_relay_tile_session_id(tile)}
                      type="button"
                      class="btn btn-xs btn-outline"
                      phx-click="close_camera_relay_tile"
                      phx-value-relay_session_id={camera_relay_tile_session_id(tile)}
                    >
                      Stop
                    </button>
                    <button
                      :if={!camera_relay_tile_session_id(tile)}
                      type="button"
                      class="btn btn-xs btn-ghost"
                      phx-click="dismiss_camera_relay_tile"
                      phx-value-tile_id={tile.tile_id}
                    >
                      Dismiss
                    </button>
                  </div>
                </div>

                <div
                  :if={camera_relay_tile_active?(tile)}
                  id={"topology-camera-relay-tile-stream-#{camera_relay_tile_dom_id(tile)}"}
                  phx-hook="CameraRelayStatusStream"
                  phx-update="ignore"
                  data-stream-path={camera_relay_tile_stream_path(tile)}
                  data-preferred-playback-transport={relay_preferred_playback_transport(tile.session)}
                  data-available-playback-transports={
                    relay_available_playback_transports(tile.session)
                  }
                  data-playback-codec-hint={relay_playback_codec_hint(tile.session)}
                  data-playback-container-hint={relay_playback_container_hint(tile.session)}
                  data-webrtc-playback-transport={relay_webrtc_playback_transport(tile.session)}
                  data-webrtc-signaling-path={relay_webrtc_signaling_path(tile.session)}
                  data-webrtc-ice-servers={relay_webrtc_ice_servers_json(tile.session)}
                  class="mt-3 space-y-1"
                >
                  <div class="overflow-hidden rounded-md border border-base-300/70 bg-base-300/20">
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
                  <div data-role="transport-status" class="text-xs text-base-content/70">
                    Connecting browser stream...
                  </div>
                  <div data-role="player-status" class="text-xs text-base-content/70">
                    Waiting for browser decoder...
                  </div>
                  <div data-role="compatibility-status" class="text-xs text-base-content/70">
                    Preferred transport: {relay_preferred_playback_transport(tile.session)}
                  </div>
                  <div data-role="relay-status" class="text-xs font-medium text-base-content">
                    Relay status: {camera_relay_tile_session_status_label(tile)}
                  </div>
                  <div
                    data-role="playback-state"
                    data-state={camera_relay_tile_playback_state(tile)}
                    class="text-xs text-base-content/70"
                  >
                    Playback state: {camera_relay_tile_playback_state(tile)}
                  </div>
                  <div data-role="viewer-count" class="text-xs text-base-content/70">
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
                  <div data-role="binary-stats" class="text-xs text-base-content/60">
                    Chunks: 0  Bytes: 0
                  </div>
                  <div data-role="relay-detail" class="text-xs text-base-content/60">
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
      </div>
    </Layouts.app>
    """
  end

  def overlay_filter_button_class(true), do: "btn btn-xs btn-primary h-7 min-h-7"
  def overlay_filter_button_class(false), do: "btn btn-xs btn-ghost h-7 min-h-7"
  def overlay_zoom_button_class(true), do: "btn btn-xs btn-secondary h-7 min-h-7"
  def overlay_zoom_button_class(false), do: "btn btn-xs btn-ghost h-7 min-h-7"

  def format_bitmap_meta(nil), do: "—"

  def format_bitmap_meta(metadata) when is_map(metadata) do
    root = bitmap_meta_entry(metadata, "root_cause", :root_cause)
    affected = bitmap_meta_entry(metadata, "affected", :affected)
    healthy = bitmap_meta_entry(metadata, "healthy", :healthy)
    unknown = bitmap_meta_entry(metadata, "unknown", :unknown)

    "#{root.count}/#{affected.count}/#{healthy.count}/#{unknown.count} " <>
      "nodes | #{root.bytes}/#{affected.bytes}/#{healthy.bytes}/#{unknown.bytes} bytes"
  end

  def format_bitmap_meta(_), do: "—"

  def bitmap_meta_entry(metadata, string_key, atom_key) do
    entry = Map.get(metadata, string_key) || Map.get(metadata, atom_key) || %{}

    %{
      count: Map.get(entry, "count") || Map.get(entry, :count) || 0,
      bytes: Map.get(entry, "bytes") || Map.get(entry, :bytes) || 0
    }
  end

  def parse_pipeline_stat(raw) when is_integer(raw), do: raw

  def parse_pipeline_stat(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {value, ""} -> value
      _ -> nil
    end
  end

  def parse_pipeline_stat(_), do: nil

  def empty_topology_state(stream_state, last_node_count, last_edge_count, pipeline_stats) do
    node_count =
      parse_pipeline_stat(last_node_count) ||
        Map.get(pipeline_stats, :final_nodes) ||
        Map.get(pipeline_stats, :raw_links)

    edge_count =
      parse_pipeline_stat(last_edge_count) ||
        Map.get(pipeline_stats, :final_edges) ||
        Map.get(pipeline_stats, :unique_pairs)

    cond do
      stream_state == :error ->
        %{
          title: "Topology unavailable",
          message: "The topology stream failed. Check web-ng/runtime-graph logs and AGE topology data."
        }

      stream_state == :retrying ->
        %{
          title: "Loading topology",
          message: "Waiting for the topology snapshot stream to hydrate. This usually resolves automatically."
        }

      stream_state == :ok and node_count == 0 and edge_count == 0 ->
        %{
          title: "No topology data yet",
          message:
            "No topology nodes or edges are available yet. Run discovery or mapper jobs to populate graph relations."
        }

      true ->
        nil
    end
  end

  def relay_status_label(status) when is_atom(status), do: status |> Atom.to_string() |> String.capitalize()
  def relay_status_label(status) when is_binary(status), do: String.capitalize(status)
  def relay_status_label(_), do: "Requested"

  def relay_status_badge_class(:active), do: "badge-success"
  def relay_status_badge_class("active"), do: "badge-success"
  def relay_status_badge_class(:opening), do: "badge-warning"
  def relay_status_badge_class("opening"), do: "badge-warning"
  def relay_status_badge_class(:closing), do: "badge-warning"
  def relay_status_badge_class("closing"), do: "badge-warning"
  def relay_status_badge_class(:failed), do: "badge-error"
  def relay_status_badge_class("failed"), do: "badge-error"
  def relay_status_badge_class(_), do: "badge-ghost"

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

  def viewer_state_badge_class(:auth_required), do: "badge-warning"
  def viewer_state_badge_class(:unavailable), do: "badge-warning"
  def viewer_state_badge_class(:unauthorized), do: "badge-error"
  def viewer_state_badge_class(:relay_error), do: "badge-error"
  def viewer_state_badge_class(_kind), do: "badge-outline"

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

  def viewer_state_container_class(_kind), do: "border-base-300/70 bg-base-200/20 text-base-content"

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

  def camera_relay_tile_badge_class(tile) do
    cond do
      is_map(Map.get(tile, :relay_session)) ->
        relay_status_badge_class(Map.get(tile.relay_session, :status))

      is_map(Map.get(tile, :viewer_state)) ->
        viewer_state_badge_class(Map.get(tile.viewer_state, :kind))

      true ->
        "badge-ghost"
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
      _ -> "border-base-300/70 bg-base-200/20 text-base-content"
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
