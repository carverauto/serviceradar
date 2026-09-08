defmodule ServiceRadarWebNGWeb.TopologyLive.GodViewTemplate do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  import ServiceRadarWebNGWeb.TopologyLive.GodViewCameraRelayComponents,
    only: [camera_relay_panels: 1]

  import ServiceRadarWebNGWeb.TopologyLive.GodViewTemplateComponents,
    only: [pipeline_telemetry: 1, stream_contract: 1, surface: 1]

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} srql={%{page_path: @current_path}}>
      <div class="mx-auto max-w-7xl p-6 space-y-6">
        <.surface
          snapshot_url={@snapshot_url}
          stream_state={@stream_state}
          last_node_count={@last_node_count}
          last_edge_count={@last_edge_count}
          pipeline_stats={@pipeline_stats}
          controls_collapsed={@controls_collapsed}
          visual_layers={@visual_layers}
          zoom_mode={@zoom_mode}
          causal_filters={@causal_filters}
          topology_layers={@topology_layers}
          timezone={@current_scope.user.timezone || "Etc/UTC"}
        />

        <.stream_contract
          schema_version={@schema_version}
          stream_state={@stream_state}
          last_revision={@last_revision}
          last_generated_at={@last_generated_at}
          last_bytes={@last_bytes}
          last_node_count={@last_node_count}
          last_edge_count={@last_edge_count}
          last_network_ms={@last_network_ms}
          last_renderer_mode={@last_renderer_mode}
          last_zoom_tier={@last_zoom_tier}
          last_zoom_mode={@last_zoom_mode}
          last_decode_ms={@last_decode_ms}
          last_render_ms={@last_render_ms}
          last_bitmap_metadata={@last_bitmap_metadata}
          timezone={@current_scope.user.timezone || "Etc/UTC"}
        />

        <.pipeline_telemetry pipeline_stats={@pipeline_stats} />
        <.camera_relay_panels
          selected_camera_context={@selected_camera_context}
          active_camera_relay_session={@active_camera_relay_session}
          last_camera_relay_session={@last_camera_relay_session}
          camera_relay_viewer_state={@camera_relay_viewer_state}
          camera_relay_tiles={@camera_relay_tiles}
          camera_relay_tile_notice={@camera_relay_tile_notice}
        />
      </div>
    </Layouts.app>
    """
  end
end
