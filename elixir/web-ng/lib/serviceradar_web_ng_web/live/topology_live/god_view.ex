defmodule ServiceRadarWebNGWeb.TopologyLive.GodView do
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadarWebNG.Topology.GodViewSnapshot
  alias ServiceRadarWebNGWeb.FeatureFlags
  alias ServiceRadarWebNGWeb.TopologyLive.GodViewCameraRelay
  alias ServiceRadarWebNGWeb.TopologyLive.GodViewControlState
  alias ServiceRadarWebNGWeb.TopologyLive.GodViewMtrOverlay
  alias ServiceRadarWebNGWeb.TopologyLive.GodViewStreamState
  alias ServiceRadarWebNGWeb.TopologyLive.GodViewTemplate

  @impl true
  def mount(_params, _session, socket) do
    if FeatureFlags.god_view_enabled?() do
      socket =
        socket
        |> assign(:page_title, "Network Topology")
        |> assign(:current_path, "/topology")
        |> assign(:snapshot_url, ~p"/topology/snapshot/latest")
        |> assign(:schema_version, GodViewSnapshot.schema_version())
        |> assign(:stream_state, :idle)
        |> assign(:last_revision, nil)
        |> assign(:last_generated_at, nil)
        |> assign(:last_bytes, nil)
        |> assign(:last_node_count, nil)
        |> assign(:last_edge_count, nil)
        |> assign(:last_renderer_mode, nil)
        |> assign(:last_network_ms, nil)
        |> assign(:last_decode_ms, nil)
        |> assign(:last_render_ms, nil)
        |> assign(:last_bitmap_metadata, nil)
        |> assign(:last_zoom_tier, nil)
        |> assign(:last_zoom_mode, "local")
        |> assign(:zoom_mode, "local")
        |> assign(:causal_filters, %{
          root_cause: true,
          affected: true,
          healthy: true,
          unknown: true
        })
        |> assign(:visual_layers, %{
          mantle: true,
          crust: true,
          atmosphere: true,
          security: true
        })
        |> assign(:topology_layers, %{
          backbone: true,
          inferred: false,
          endpoints: false,
          mtr_paths: true
        })
        |> assign(:selected_camera_context, nil)
        |> assign(:active_camera_relay_session, nil)
        |> assign(:last_camera_relay_session, nil)
        |> assign(:camera_relay_viewer_state, nil)
        |> assign(:camera_relay_tiles, [])
        |> assign(:camera_relay_tile_notice, nil)
        |> assign(:mtr_paths_cache, nil)
        |> assign(:pipeline_stats, %{})
        |> assign(:controls_collapsed, true)

      socket =
        if connected?(socket) do
          GodViewMtrOverlay.push_path_data(socket)
        else
          socket
        end

      {:ok, socket}
    else
      {:ok,
       socket
       |> put_flash(:error, "God-View is not enabled in this environment.")
       |> push_navigate(to: ~p"/dashboard")}
    end
  end

  @impl true
  def handle_event("god_view_stream_stats", params, socket) do
    {:noreply, GodViewStreamState.assign_stats(socket, params)}
  end

  def handle_event("god_view_stream_retrying", _params, socket) do
    {:noreply, GodViewStreamState.assign_retrying(socket)}
  end

  def handle_event("god_view_stream_error", params, socket) do
    {:noreply, GodViewStreamState.assign_error(socket, params)}
  end

  def handle_event("toggle_causal_filter", %{"state" => state}, socket) do
    {:noreply, GodViewControlState.toggle_causal_filter(socket, state)}
  end

  def handle_event("reset_view", _params, socket) do
    {:noreply, GodViewControlState.reset_view(socket)}
  end

  def handle_event("set_zoom_mode", %{"mode" => mode}, socket) do
    {:noreply, GodViewControlState.set_zoom_mode(socket, mode)}
  end

  def handle_event("toggle_visual_layer", %{"layer" => layer}, socket) do
    {:noreply, GodViewControlState.toggle_visual_layer(socket, layer)}
  end

  def handle_event("toggle_topology_layer", %{"layer" => layer}, socket) do
    {:noreply, GodViewControlState.toggle_topology_layer(socket, layer)}
  end

  def handle_event("enable_attachment_layers", _params, socket) do
    {:noreply, GodViewControlState.enable_attachment_layers(socket)}
  end

  def handle_event("toggle_controls_panel", _params, socket) do
    {:noreply, GodViewControlState.toggle_controls_panel(socket)}
  end

  def handle_event("god_view_open_camera_relay", params, socket) do
    {:noreply, GodViewCameraRelay.open(socket, params)}
  end

  def handle_event("close_camera_relay", _params, socket) do
    {:noreply, GodViewCameraRelay.close(socket)}
  end

  def handle_event("god_view_open_camera_relay_cluster", %{"camera_tiles" => camera_tiles} = params, socket) do
    {:noreply, GodViewCameraRelay.open_cluster(socket, camera_tiles, params)}
  end

  def handle_event("close_camera_relay_tile", %{"relay_session_id" => relay_session_id}, socket) do
    {:noreply, GodViewCameraRelay.close_tile(socket, relay_session_id)}
  end

  def handle_event("dismiss_camera_relay_tile", %{"tile_id" => tile_id}, socket) do
    {:noreply, GodViewCameraRelay.dismiss_tile(socket, tile_id)}
  end

  def handle_event("close_camera_relay_tile_set", _params, socket) do
    {:noreply, GodViewCameraRelay.close_tile_set(socket)}
  end

  def handle_event("set_controls_panel", %{"collapsed" => collapsed}, socket) do
    {:noreply, GodViewControlState.set_controls_panel(socket, collapsed)}
  end

  @impl true
  def handle_info({:refresh_camera_relay_session, relay_session_id}, socket) do
    {:noreply, GodViewCameraRelay.refresh(socket, relay_session_id)}
  end

  @impl true
  def render(assigns), do: GodViewTemplate.render(assigns)
end
