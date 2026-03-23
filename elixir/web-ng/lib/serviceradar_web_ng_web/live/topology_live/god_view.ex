defmodule ServiceRadarWebNGWeb.TopologyLive.GodView do
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadar.Camera.RelayPlayback
  alias ServiceRadar.Camera.RelaySession
  alias ServiceRadarWebNG.Graph, as: AgeGraph
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNG.Topology.GodViewSnapshot
  alias ServiceRadarWebNGWeb.FeatureFlags

  require Logger

  @default_decode_alert_ms 20.0
  @default_render_alert_ms 40.0
  @mtr_paths_cache_ttl_ms 10_000
  @camera_relay_poll_interval_ms 1_000
  @camera_relay_tile_limit 4

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
          endpoints: true,
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
          push_mtr_path_data(socket)
        else
          socket
        end

      {:ok, socket}
    else
      {:ok,
       socket
       |> put_flash(:error, "God-View is not enabled in this environment.")
       |> push_navigate(to: ~p"/analytics")}
    end
  end

  @impl true
  def handle_event("god_view_stream_stats", params, socket) do
    pipeline_stats =
      params
      |> Map.get("pipeline_stats", %{})
      |> normalize_pipeline_stats()

    maybe_emit_client_perf_alert(params, pipeline_stats)

    {:noreply,
     socket
     |> assign(:stream_state, :ok)
     |> assign(:schema_version, Map.get(params, "schema_version", socket.assigns.schema_version))
     |> assign(:last_revision, Map.get(params, "revision"))
     |> assign(:last_generated_at, Map.get(params, "generated_at"))
     |> assign(:last_bytes, Map.get(params, "bytes"))
     |> assign(:last_node_count, Map.get(params, "node_count"))
     |> assign(:last_edge_count, Map.get(params, "edge_count"))
     |> assign(:last_renderer_mode, Map.get(params, "renderer_mode"))
     |> assign(:last_network_ms, Map.get(params, "network_ms"))
     |> assign(:last_decode_ms, Map.get(params, "decode_ms"))
     |> assign(:last_render_ms, Map.get(params, "render_ms"))
     |> assign(:last_bitmap_metadata, Map.get(params, "bitmap_metadata"))
     |> assign(:pipeline_stats, pipeline_stats)
     |> assign(:last_zoom_tier, Map.get(params, "zoom_tier"))
     |> assign(:last_zoom_mode, Map.get(params, "zoom_mode", socket.assigns.last_zoom_mode))}
  end

  def handle_event("god_view_stream_error", _params, socket) do
    {:noreply, assign(socket, :stream_state, :error)}
  end

  def handle_event("toggle_causal_filter", %{"state" => state}, socket) do
    key =
      case state do
        "root_cause" -> :root_cause
        "affected" -> :affected
        "healthy" -> :healthy
        _ -> :unknown
      end

    filters = Map.update!(socket.assigns.causal_filters, key, &(!&1))

    {:noreply,
     socket
     |> assign(:causal_filters, filters)
     |> push_event("god_view:set_filters", %{filters: stringify_filter_keys(filters)})}
  end

  def handle_event("reset_view", _params, socket) do
    {:noreply, push_event(socket, "god_view:reset_view", %{})}
  end

  def handle_event("set_zoom_mode", %{"mode" => mode}, socket) do
    requested_mode = normalize_zoom_mode(mode)
    current_mode = socket.assigns.zoom_mode || "local"

    mode =
      if requested_mode == "auto" and current_mode == "auto" do
        "local"
      else
        requested_mode
      end

    {:noreply, socket |> assign(:zoom_mode, mode) |> push_event("god_view:set_zoom_mode", %{mode: mode})}
  end

  def handle_event("toggle_visual_layer", %{"layer" => layer}, socket) do
    key =
      case layer do
        "mantle" -> :mantle
        "crust" -> :crust
        "atmosphere" -> :atmosphere
        _ -> :security
      end

    layers = Map.update!(socket.assigns.visual_layers, key, &(!&1))

    {:noreply,
     socket
     |> assign(:visual_layers, layers)
     |> push_event("god_view:set_layers", %{layers: stringify_filter_keys(layers)})}
  end

  def handle_event("toggle_topology_layer", %{"layer" => layer}, socket) do
    key =
      case layer do
        "backbone" -> :backbone
        "inferred" -> :inferred
        "mtr_paths" -> :mtr_paths
        _ -> :endpoints
      end

    layers = Map.update!(socket.assigns.topology_layers, key, &(!&1))

    socket =
      socket
      |> assign(:topology_layers, layers)
      |> push_event("god_view:set_topology_layers", %{layers: stringify_filter_keys(layers)})

    socket =
      if key == :mtr_paths do
        if layers.mtr_paths,
          do: push_mtr_path_data(socket),
          else: push_event(socket, "god_view:mtr_path_data", %{paths: []})
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_event("toggle_controls_panel", _params, socket) do
    {:noreply, update(socket, :controls_collapsed, &(!&1))}
  end

  def handle_event(
        "god_view_open_camera_relay",
        %{"camera_source_id" => camera_source_id, "stream_profile_id" => stream_profile_id} = params,
        socket
      ) do
    scope = socket.assigns.current_scope

    cond do
      not can_view_device?(scope) ->
        context = selected_camera_context(params)

        {:noreply,
         socket
         |> assign(:selected_camera_context, context)
         |> assign(:camera_relay_viewer_state, viewer_state_from_error(:forbidden))
         |> put_flash(:error, "You are not authorized to start a camera relay")}

      not is_nil(socket.assigns.active_camera_relay_session) ->
        {:noreply, put_flash(socket, :error, "Close the current camera relay before starting another")}

      true ->
        with {:ok, camera_source_id} <- normalize_uuid_param(camera_source_id),
             {:ok, stream_profile_id} <- normalize_uuid_param(stream_profile_id),
             {:ok, session} <-
               relay_session_manager().request_open(
                 camera_source_id,
                 stream_profile_id,
                 scope: scope
               ) do
          context = selected_camera_context(params)

          {:noreply,
           socket
           |> assign(:selected_camera_context, context)
           |> assign(:active_camera_relay_session, session)
           |> assign(:last_camera_relay_session, nil)
           |> assign(:camera_relay_viewer_state, nil)
           |> tap(fn _socket -> schedule_camera_relay_refresh(session.id) end)
           |> put_flash(:info, "Camera relay requested from topology")}
        else
          {:error, reason} ->
            context = selected_camera_context(params)

            {:noreply,
             socket
             |> assign(:selected_camera_context, context)
             |> assign(:camera_relay_viewer_state, viewer_state_from_error(reason))
             |> put_flash(:error, format_camera_relay_error(reason))}
        end
    end
  end

  def handle_event("close_camera_relay", _params, socket) do
    scope = socket.assigns.current_scope
    active_session = socket.assigns.active_camera_relay_session

    cond do
      not can_view_device?(scope) ->
        {:noreply,
         socket
         |> assign(:camera_relay_viewer_state, viewer_state_from_error(:forbidden))
         |> put_flash(:error, "You are not authorized to stop a camera relay")}

      is_nil(active_session) ->
        {:noreply, socket}

      true ->
        case relay_session_manager().request_close(
               active_session.id,
               reason: "viewer closed topology view",
               scope: scope
             ) do
          {:ok, session} ->
            {:noreply,
             socket
             |> assign(:active_camera_relay_session, session)
             |> assign(:camera_relay_viewer_state, viewer_state_from_session(session))
             |> tap(fn _socket -> schedule_camera_relay_refresh(session.id) end)
             |> put_flash(:info, "Camera relay closing")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, format_camera_relay_error(reason))}
        end
    end
  end

  def handle_event("god_view_open_camera_relay_cluster", %{"camera_tiles" => camera_tiles} = params, socket) do
    scope = socket.assigns.current_scope

    if can_view_device?(scope) do
      requested_tiles = normalize_camera_tile_params(camera_tiles)
      tile_limit = camera_relay_tile_limit()
      limited_tiles = Enum.take(requested_tiles, tile_limit)
      omitted_count = max(length(requested_tiles) - length(limited_tiles), 0)

      if limited_tiles == [] do
        {:noreply,
         socket
         |> assign(:camera_relay_tile_notice, "No valid camera relays were available for this cluster")
         |> put_flash(:error, "No valid camera relays were available for this cluster")}
      else
        maybe_close_camera_relay_tiles(socket.assigns.camera_relay_tiles, scope, "replaced by a new topology tile set")

        opened_tiles =
          Enum.map(limited_tiles, fn tile ->
            case relay_session_manager().request_open(
                   tile.camera_source_id,
                   tile.stream_profile_id,
                   scope: scope
                 ) do
              {:ok, session} ->
                schedule_camera_relay_refresh(session.id)
                build_camera_relay_tile(tile, session: session)

              {:error, reason} ->
                build_camera_relay_tile(tile, viewer_state: viewer_state_from_error(reason))
            end
          end)

        notice = cluster_camera_tile_notice(opened_tiles, omitted_count, params)

        {:noreply,
         socket
         |> assign(:camera_relay_tiles, opened_tiles)
         |> assign(:camera_relay_tile_notice, notice)
         |> put_flash(:info, cluster_camera_tile_flash_message(opened_tiles, omitted_count))}
      end
    else
      {:noreply,
       socket
       |> assign(:camera_relay_tile_notice, "You are not authorized to start cluster camera relays")
       |> put_flash(:error, "You are not authorized to start cluster camera relays")}
    end
  end

  def handle_event("close_camera_relay_tile", %{"relay_session_id" => relay_session_id}, socket) do
    scope = socket.assigns.current_scope

    if can_view_device?(scope) do
      case normalize_uuid_param(relay_session_id) do
        {:ok, normalized_id} ->
          case relay_session_manager().request_close(
                 normalized_id,
                 reason: "viewer closed topology tile",
                 scope: scope
               ) do
            {:ok, session} ->
              schedule_camera_relay_refresh(session.id)

              {:noreply,
               update_camera_relay_tile(socket, session.id, fn tile ->
                 tile
                 |> Map.put(:relay_session, session)
                 |> Map.put(:viewer_state, viewer_state_from_session(session))
               end)}

            {:error, reason} ->
              {:noreply,
               socket
               |> assign(:camera_relay_tile_notice, format_camera_relay_error(reason))
               |> put_flash(:error, format_camera_relay_error(reason))}
          end

        {:error, _reason} ->
          {:noreply, socket}
      end
    else
      {:noreply,
       socket
       |> assign(:camera_relay_tile_notice, "You are not authorized to stop cluster camera relays")
       |> put_flash(:error, "You are not authorized to stop cluster camera relays")}
    end
  end

  def handle_event("dismiss_camera_relay_tile", %{"tile_id" => tile_id}, socket) do
    {:noreply,
     update(socket, :camera_relay_tiles, fn tiles ->
       Enum.reject(tiles, &(Map.get(&1, :tile_id) == tile_id))
     end)}
  end

  def handle_event("close_camera_relay_tile_set", _params, socket) do
    scope = socket.assigns.current_scope

    if can_view_device?(scope) do
      maybe_close_camera_relay_tiles(socket.assigns.camera_relay_tiles, scope, "viewer closed topology tile set")

      {:noreply,
       socket
       |> assign(:camera_relay_tile_notice, "Cluster camera relays closing")
       |> assign(:camera_relay_tiles, mark_camera_relay_tiles_closing(socket.assigns.camera_relay_tiles))}
    else
      {:noreply,
       socket
       |> assign(:camera_relay_tile_notice, "You are not authorized to stop cluster camera relays")
       |> put_flash(:error, "You are not authorized to stop cluster camera relays")}
    end
  end

  def handle_event("set_controls_panel", %{"collapsed" => collapsed}, socket) do
    {:noreply, assign(socket, :controls_collapsed, truthy?(collapsed))}
  end

  @impl true
  def handle_info({:refresh_camera_relay_session, relay_session_id}, socket) do
    current_session =
      socket.assigns.active_camera_relay_session || socket.assigns.last_camera_relay_session

    if is_map(current_session) and Map.get(current_session, :id) == relay_session_id do
      case fetch_camera_relay_session(socket.assigns.current_scope, relay_session_id) do
        {:ok, nil} ->
          {:noreply, assign(socket, :active_camera_relay_session, nil)}

        {:ok, session} ->
          {:noreply, apply_camera_relay_session_update(socket, session)}

        {:error, reason} ->
          Logger.warning("Topology camera relay refresh failed for #{relay_session_id}: #{inspect(reason)}")

          {:noreply, assign(socket, :camera_relay_viewer_state, viewer_state_from_error(reason))}
      end
    else
      case fetch_camera_relay_tile_session(socket.assigns.camera_relay_tiles, relay_session_id) do
        nil ->
          {:noreply, socket}

        _tile ->
          case fetch_camera_relay_session(socket.assigns.current_scope, relay_session_id) do
            {:ok, nil} ->
              {:noreply,
               update(socket, :camera_relay_tiles, fn tiles ->
                 Enum.reject(tiles, &(camera_relay_tile_session_id(&1) == relay_session_id))
               end)}

            {:ok, session} ->
              {:noreply,
               update_camera_relay_tile(socket, relay_session_id, fn tile ->
                 tile
                 |> Map.put(:relay_session, session)
                 |> Map.put(:viewer_state, viewer_state_from_session(session))
               end)}

            {:error, reason} ->
              Logger.warning("Topology camera relay tile refresh failed for #{relay_session_id}: #{inspect(reason)}")

              {:noreply,
               update_camera_relay_tile(socket, relay_session_id, fn tile ->
                 Map.put(tile, :viewer_state, viewer_state_from_error(reason))
               end)}
          end
      end
    end
  end

  defp maybe_emit_client_perf_alert(params, pipeline_stats) when is_map(params) and is_map(pipeline_stats) do
    decode_ms = numeric_ms(Map.get(params, "decode_ms"))
    render_ms = numeric_ms(Map.get(params, "render_ms"))
    node_count = numeric_count(Map.get(params, "node_count"))
    edge_count = numeric_count(Map.get(params, "edge_count"))

    if decode_ms > decode_alert_ms_threshold() do
      emit_client_perf_alert(
        "decode_ms_high",
        decode_ms,
        render_ms,
        node_count,
        edge_count,
        pipeline_stats
      )
    end

    if render_ms > render_alert_ms_threshold() do
      emit_client_perf_alert(
        "render_ms_high",
        decode_ms,
        render_ms,
        node_count,
        edge_count,
        pipeline_stats
      )
    end
  end

  defp maybe_emit_client_perf_alert(_params, _pipeline_stats), do: :ok

  defp emit_client_perf_alert(alert, decode_ms, render_ms, node_count, edge_count, pipeline_stats) do
    measurements = %{
      decode_ms: decode_ms,
      render_ms: render_ms,
      node_count: node_count,
      edge_count: edge_count
    }

    metadata = %{alert: alert, pipeline_stats: pipeline_stats}

    :telemetry.execute([:serviceradar, :god_view, :client, :perf_alert], measurements, metadata)

    Logger.warning(
      "god_view_client_perf_alert #{alert} decode_ms=#{decode_ms} render_ms=#{render_ms} " <>
        "nodes=#{node_count} edges=#{edge_count} pipeline_stats=#{inspect(pipeline_stats)}"
    )
  end

  defp decode_alert_ms_threshold do
    Application.get_env(
      :serviceradar_web_ng,
      :god_view_client_decode_alert_ms,
      @default_decode_alert_ms
    )
  end

  defp render_alert_ms_threshold do
    Application.get_env(
      :serviceradar_web_ng,
      :god_view_client_render_alert_ms,
      @default_render_alert_ms
    )
  end

  defp numeric_ms(value) when is_number(value), do: value * 1.0

  defp numeric_ms(value) when is_binary(value) do
    case Float.parse(value) do
      {parsed, _rest} -> parsed
      _ -> 0.0
    end
  end

  defp numeric_ms(_), do: 0.0

  defp numeric_count(value) when is_integer(value), do: max(value, 0)

  defp numeric_count(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, _rest} -> max(parsed, 0)
      _ -> 0
    end
  end

  defp numeric_count(_), do: 0

  @impl true
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
                      title="Reset view to fit all nodes"
                    >
                      Reset View
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

  defp push_mtr_path_data(socket) do
    {paths, socket} = cached_mtr_paths(socket)
    push_event(socket, "god_view:mtr_path_data", %{paths: paths})
  end

  defp cached_mtr_paths(socket) do
    now_ms = System.monotonic_time(:millisecond)

    case socket.assigns do
      %{mtr_paths_cache: %{at_ms: at_ms, paths: paths}}
      when is_integer(at_ms) and now_ms - at_ms < @mtr_paths_cache_ttl_ms and is_list(paths) ->
        {paths, socket}

      _ ->
        paths = load_mtr_paths()
        {paths, assign(socket, :mtr_paths_cache, %{at_ms: now_ms, paths: paths})}
    end
  end

  defp load_mtr_paths do
    cypher = """
    MATCH (a)-[r:MTR_PATH]->(b)
    WHERE a.id IS NOT NULL AND b.id IS NOT NULL
      AND (a:Device OR a:MtrHop)
      AND (b:Device OR b:MtrHop)
    RETURN {
      source: a.id,
      target: b.id,
      source_addr: coalesce(a.addr, ''),
      target_addr: coalesce(b.addr, ''),
      avg_us: coalesce(r.avg_us, 0),
      loss_pct: coalesce(r.loss_pct, 0.0),
      jitter_us: coalesce(r.jitter_us, 0),
      from_hop: coalesce(r.from_hop, 0),
      to_hop: coalesce(r.to_hop, 0),
      agent_id: coalesce(r.agent_id, '')
    }
    LIMIT 500
    """

    case AgeGraph.query(cypher) do
      {:ok, rows} when is_list(rows) ->
        rows
        |> Enum.map(&normalize_mtr_path_row/1)
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  rescue
    _ -> []
  end

  defp normalize_mtr_path_row(%{} = row) do
    row =
      if map_size(row) == 1 do
        [{_k, v}] = Map.to_list(row)
        if is_map(v), do: v, else: row
      else
        row
      end

    source = Map.get(row, "source") || Map.get(row, :source)
    target = Map.get(row, "target") || Map.get(row, :target)

    if is_binary(source) and is_binary(target) do
      %{
        source: source,
        target: target,
        source_addr: mtr_str(row, "source_addr"),
        target_addr: mtr_str(row, "target_addr"),
        avg_us: mtr_int(row, "avg_us"),
        loss_pct: mtr_float(row, "loss_pct"),
        jitter_us: mtr_int(row, "jitter_us"),
        from_hop: mtr_int(row, "from_hop"),
        to_hop: mtr_int(row, "to_hop"),
        agent_id: mtr_str(row, "agent_id")
      }
    end
  end

  defp normalize_mtr_path_row(_), do: nil

  defp mtr_str(row, key) do
    case mtr_get(row, key) do
      nil -> ""
      val -> to_string(val)
    end
  end

  defp mtr_get(row, key) when is_map(row) and is_binary(key) do
    case Map.get(row, key) do
      nil ->
        mtr_atom_key_value(row, key)

      value ->
        value
    end
  end

  defp mtr_get(_row, _key), do: nil

  defp mtr_atom_key_value(row, key) do
    Enum.find_value(row, fn
      {k, v} when is_atom(k) -> mtr_atom_match(k, key, v)
      _ -> nil
    end)
  end

  defp mtr_atom_match(k, key, value) do
    if Atom.to_string(k) == key, do: value
  end

  defp mtr_int(row, key) do
    val = mtr_get(row, key)

    case val do
      v when is_integer(v) ->
        v

      v when is_float(v) ->
        round(v)

      v when is_binary(v) ->
        case Integer.parse(v) do
          {i, _} -> i
          :error -> 0
        end

      _ ->
        0
    end
  end

  defp mtr_float(row, key) do
    val = mtr_get(row, key)

    case val do
      v when is_float(v) ->
        v

      v when is_integer(v) ->
        v * 1.0

      v when is_binary(v) ->
        case Float.parse(v) do
          {f, _} -> f
          :error -> 0.0
        end

      _ ->
        0.0
    end
  end

  defp stringify_filter_keys(filters) do
    Map.new(filters, fn {k, v} -> {Atom.to_string(k), v} end)
  end

  defp overlay_filter_button_class(true), do: "btn btn-xs btn-primary h-7 min-h-7"
  defp overlay_filter_button_class(false), do: "btn btn-xs btn-ghost h-7 min-h-7"
  defp overlay_zoom_button_class(true), do: "btn btn-xs btn-secondary h-7 min-h-7"
  defp overlay_zoom_button_class(false), do: "btn btn-xs btn-ghost h-7 min-h-7"

  defp format_bitmap_meta(nil), do: "—"

  defp format_bitmap_meta(metadata) when is_map(metadata) do
    root = bitmap_meta_entry(metadata, "root_cause", :root_cause)
    affected = bitmap_meta_entry(metadata, "affected", :affected)
    healthy = bitmap_meta_entry(metadata, "healthy", :healthy)
    unknown = bitmap_meta_entry(metadata, "unknown", :unknown)

    "#{root.count}/#{affected.count}/#{healthy.count}/#{unknown.count} " <>
      "nodes | #{root.bytes}/#{affected.bytes}/#{healthy.bytes}/#{unknown.bytes} bytes"
  end

  defp format_bitmap_meta(_), do: "—"

  defp bitmap_meta_entry(metadata, string_key, atom_key) do
    entry = Map.get(metadata, string_key) || Map.get(metadata, atom_key) || %{}

    %{
      count: Map.get(entry, "count") || Map.get(entry, :count) || 0,
      bytes: Map.get(entry, "bytes") || Map.get(entry, :bytes) || 0
    }
  end

  defp normalize_pipeline_stats(stats) when is_map(stats) do
    keys = [
      :raw_links,
      :unique_pairs,
      :final_edges,
      :final_direct,
      :final_inferred,
      :final_attachment,
      :unresolved_endpoints
    ]

    Enum.reduce(keys, %{}, fn key, acc ->
      raw = Map.get(stats, key) || Map.get(stats, Atom.to_string(key))
      parsed = parse_pipeline_stat(raw)

      if is_integer(parsed), do: Map.put(acc, key, parsed), else: acc
    end)
  end

  defp normalize_pipeline_stats(_), do: %{}

  defp parse_pipeline_stat(raw) when is_integer(raw), do: raw

  defp parse_pipeline_stat(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {value, ""} -> value
      _ -> nil
    end
  end

  defp parse_pipeline_stat(_), do: nil

  defp empty_topology_state(stream_state, last_node_count, last_edge_count, pipeline_stats) do
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

  defp normalize_zoom_mode("global"), do: "global"
  defp normalize_zoom_mode("regional"), do: "regional"
  defp normalize_zoom_mode("local"), do: "local"
  defp normalize_zoom_mode(_), do: "auto"

  defp can_view_device?(scope), do: RBAC.can?(scope, "devices.view")

  defp relay_status_label(status) when is_atom(status), do: status |> Atom.to_string() |> String.capitalize()
  defp relay_status_label(status) when is_binary(status), do: String.capitalize(status)
  defp relay_status_label(_), do: "Requested"

  defp relay_status_badge_class(:active), do: "badge-success"
  defp relay_status_badge_class("active"), do: "badge-success"
  defp relay_status_badge_class(:opening), do: "badge-warning"
  defp relay_status_badge_class("opening"), do: "badge-warning"
  defp relay_status_badge_class(:closing), do: "badge-warning"
  defp relay_status_badge_class("closing"), do: "badge-warning"
  defp relay_status_badge_class(:failed), do: "badge-error"
  defp relay_status_badge_class("failed"), do: "badge-error"
  defp relay_status_badge_class(_), do: "badge-ghost"

  defp relay_playback_state(%{status: status, media_ingest_id: media_ingest_id})
       when status in [:active, "active"] and is_binary(media_ingest_id) and media_ingest_id != "", do: "ready"

  defp relay_playback_state(%{status: status}) when status in [:requested, :opening, "requested", "opening"],
    do: "pending"

  defp relay_playback_state(%{status: status}) when status in [:closing, "closing"], do: "closing"
  defp relay_playback_state(%{status: status}) when status in [:closed, "closed"], do: "closed"
  defp relay_playback_state(%{status: status}) when status in [:failed, "failed"], do: "failed"
  defp relay_playback_state(_session), do: "pending"

  defp relay_preferred_playback_transport(session) do
    session
    |> relay_playback_contract()
    |> Map.get(:preferred_playback_transport, "")
  end

  defp relay_available_playback_transports(session) do
    session
    |> relay_playback_contract()
    |> Map.get(:available_playback_transports, [])
    |> Enum.join(",")
  end

  defp relay_playback_codec_hint(session) do
    session
    |> relay_playback_contract()
    |> Map.get(:playback_codec_hint, "h264")
  end

  defp relay_playback_container_hint(session) do
    session
    |> relay_playback_contract()
    |> Map.get(:playback_container_hint, "annexb")
  end

  defp relay_playback_contract(session) when is_map(session), do: RelayPlayback.browser_metadata(session)
  defp relay_playback_contract(_session), do: RelayPlayback.browser_metadata(%{})

  defp relay_close_reason_text(session) do
    session
    |> Map.get(:close_reason)
    |> case do
      value when is_binary(value) and value != "" -> "Close reason: #{value}"
      _ -> ""
    end
  end

  defp relay_failure_reason_text(session) do
    session
    |> Map.get(:failure_reason)
    |> case do
      value when is_binary(value) and value != "" -> "Failure reason: #{value}"
      _ -> ""
    end
  end

  defp relay_termination_text(session) do
    case Map.get(session, :termination_kind) do
      value when is_binary(value) and value != "" ->
        "Termination: #{value |> String.replace("_", " ") |> String.capitalize()}"

      _ ->
        ""
    end
  end

  defp camera_relay_stream_path(%{id: relay_session_id}) when is_binary(relay_session_id) do
    ~p"/v1/camera-relay-sessions/#{relay_session_id}/stream"
  end

  defp camera_relay_stream_path(_session), do: nil

  defp relay_session_terminal?(%{status: status}), do: status in [:closed, :failed, "closed", "failed"]
  defp relay_session_terminal?(_session), do: false

  defp apply_camera_relay_session_update(socket, session) do
    viewer_state = viewer_state_from_session(session)

    if relay_session_terminal?(session) do
      socket
      |> assign(:active_camera_relay_session, nil)
      |> assign(:last_camera_relay_session, session)
      |> assign(:camera_relay_viewer_state, viewer_state)
    else
      schedule_camera_relay_refresh(session.id)

      socket
      |> assign(:active_camera_relay_session, session)
      |> assign(:last_camera_relay_session, nil)
      |> assign(:camera_relay_viewer_state, viewer_state)
    end
  end

  defp schedule_camera_relay_refresh(relay_session_id) when is_binary(relay_session_id) do
    Process.send_after(self(), {:refresh_camera_relay_session, relay_session_id}, camera_relay_poll_interval_ms())
  end

  defp schedule_camera_relay_refresh(_relay_session_id), do: :ok

  defp camera_relay_poll_interval_ms do
    case Application.get_env(:serviceradar_web_ng, :camera_relay_poll_interval_ms, @camera_relay_poll_interval_ms) do
      value when is_integer(value) and value > 0 -> value
      _other -> @camera_relay_poll_interval_ms
    end
  end

  defp relay_session_manager do
    Application.get_env(
      :serviceradar_web_ng,
      :camera_relay_session_manager,
      ServiceRadar.Camera.RelaySessionManager
    )
  end

  defp fetch_camera_relay_session(scope, relay_session_id) do
    fetcher =
      Application.get_env(
        :serviceradar_web_ng,
        :camera_relay_session_fetcher,
        fn id, opts -> RelaySession.get_by_id(id, opts) end
      )

    fetcher.(relay_session_id, scope: scope)
  end

  defp normalize_uuid_param(value) when is_binary(value) do
    trimmed = String.trim(value)

    case Ecto.UUID.cast(trimmed) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_uuid}
    end
  end

  defp normalize_uuid_param(_value), do: {:error, :invalid_uuid}

  defp format_camera_relay_error({:agent_offline, _agent_id}), do: "Assigned agent is offline for this camera source"
  defp format_camera_relay_error(:forbidden), do: "You are not authorized for camera relay access"
  defp format_camera_relay_error(:invalid_uuid), do: "Invalid camera relay request"
  defp format_camera_relay_error(reason) when is_binary(reason), do: reason
  defp format_camera_relay_error(reason), do: inspect(reason)

  defp viewer_state_from_session(%{status: status} = session) when status in [:failed, "failed"] do
    reason = Map.get(session, :failure_reason) || Map.get(session, :close_reason) || "camera relay failed"
    viewer_state_from_error(reason)
  end

  defp viewer_state_from_session(_session), do: nil

  defp viewer_state_from_error(:forbidden) do
    %{
      kind: :unauthorized,
      title: "Not Authorized",
      detail: "This viewer does not have permission to open or control camera relays from topology.",
      hint: "Use an account with device viewing access before retrying."
    }
  end

  defp viewer_state_from_error(:invalid_uuid) do
    %{
      kind: :relay_error,
      title: "Invalid Camera Request",
      detail: "The selected topology camera action did not include a valid relay identifier.",
      hint: "Refresh topology data and retry from the camera node details panel."
    }
  end

  defp viewer_state_from_error({:agent_offline, agent_id}) do
    %{
      kind: :unavailable,
      title: "Camera Relay Unavailable",
      detail: "Assigned agent #{agent_id} is offline and cannot open the camera relay.",
      hint: "Verify the edge agent and gateway are connected before retrying."
    }
  end

  defp viewer_state_from_error(reason) when is_binary(reason) do
    normalized_reason = String.trim(reason)
    classification = classify_camera_relay_issue(normalized_reason)

    case classification do
      :auth_required ->
        %{
          kind: :auth_required,
          title: "Camera Authentication Required",
          detail: normalized_reason,
          hint: "Update camera credentials or source configuration, then retry the relay."
        }

      :unavailable ->
        %{
          kind: :unavailable,
          title: "Camera Relay Unavailable",
          detail: normalized_reason,
          hint: "Check camera reachability, assigned agent/gateway health, and inventory assignment."
        }

      :unauthorized ->
        %{
          kind: :unauthorized,
          title: "Not Authorized",
          detail: normalized_reason,
          hint: "Use an account with camera relay access before retrying."
        }

      :relay_error ->
        %{
          kind: :relay_error,
          title: "Camera Relay Error",
          detail: normalized_reason,
          hint: "Review relay logs and the assigned agent/gateway path for the failure."
        }
    end
  end

  defp viewer_state_from_error(reason), do: viewer_state_from_error(inspect(reason))

  defp classify_camera_relay_issue(reason) when is_binary(reason) do
    downcased = String.downcase(reason)

    cond do
      String.contains?(downcased, ["forbidden", "unauthorized", "not authorized"]) ->
        :unauthorized

      String.contains?(downcased, ["auth", "credential", "forbidden by camera", "access denied"]) ->
        :auth_required

      String.contains?(downcased, [
        "offline",
        "not assigned",
        "unavailable",
        "inactive",
        "streamable",
        "not found",
        "reach",
        "gateway",
        "agent"
      ]) ->
        :unavailable

      true ->
        :relay_error
    end
  end

  defp viewer_state_badge_class(:auth_required), do: "badge-warning"
  defp viewer_state_badge_class(:unavailable), do: "badge-warning"
  defp viewer_state_badge_class(:unauthorized), do: "badge-error"
  defp viewer_state_badge_class(:relay_error), do: "badge-error"
  defp viewer_state_badge_class(_kind), do: "badge-outline"

  defp viewer_state_container_class(:auth_required) do
    "border-warning/40 bg-warning/10 text-warning-content"
  end

  defp viewer_state_container_class(:unavailable) do
    "border-warning/40 bg-warning/10 text-warning-content"
  end

  defp viewer_state_container_class(:unauthorized) do
    "border-error/40 bg-error/10 text-error-content"
  end

  defp viewer_state_container_class(:relay_error) do
    "border-error/40 bg-error/10 text-error-content"
  end

  defp viewer_state_container_class(_kind), do: "border-base-300/70 bg-base-200/20 text-base-content"

  defp normalize_camera_tile_params(camera_tiles) when is_list(camera_tiles) do
    camera_tiles
    |> Enum.reduce([], fn tile, acc ->
      case normalize_camera_tile_param(tile) do
        nil -> acc
        normalized -> [normalized | acc]
      end
    end)
    |> Enum.reverse()
    |> Enum.uniq_by(&{&1.camera_source_id, &1.stream_profile_id})
  end

  defp normalize_camera_tile_params(_camera_tiles), do: []

  defp normalize_camera_tile_param(%{} = tile) do
    with {:ok, camera_source_id} <-
           normalize_uuid_param(Map.get(tile, "camera_source_id") || Map.get(tile, :camera_source_id)),
         {:ok, stream_profile_id} <-
           normalize_uuid_param(Map.get(tile, "stream_profile_id") || Map.get(tile, :stream_profile_id)) do
      %{
        camera_source_id: camera_source_id,
        stream_profile_id: stream_profile_id,
        device_uid: normalize_presence(Map.get(tile, "device_uid") || Map.get(tile, :device_uid)),
        camera_label: normalize_presence(Map.get(tile, "camera_label") || Map.get(tile, :camera_label)),
        profile_label: normalize_presence(Map.get(tile, "profile_label") || Map.get(tile, :profile_label))
      }
    else
      {:error, _reason} -> nil
    end
  end

  defp normalize_camera_tile_param(_tile), do: nil

  defp build_camera_relay_tile(tile, opts) when is_map(tile) do
    relay_session = Keyword.get(opts, :session)
    viewer_state = Keyword.get(opts, :viewer_state)

    %{
      tile_id:
        if(is_map(relay_session) and is_binary(Map.get(relay_session, :id)),
          do: relay_session.id,
          else: "tile-" <> Ecto.UUID.generate()
        ),
      relay_session: relay_session,
      viewer_state: viewer_state,
      device_uid: Map.get(tile, :device_uid),
      camera_label: Map.get(tile, :camera_label),
      profile_label: Map.get(tile, :profile_label)
    }
  end

  defp camera_relay_tile_limit do
    case Application.get_env(:serviceradar_web_ng, :camera_relay_tile_limit, @camera_relay_tile_limit) do
      value when is_integer(value) and value > 0 -> value
      _other -> @camera_relay_tile_limit
    end
  end

  defp maybe_close_camera_relay_tiles(camera_relay_tiles, scope, reason)
       when is_list(camera_relay_tiles) and is_binary(reason) do
    Enum.each(camera_relay_tiles, fn tile ->
      case camera_relay_tile_session_id(tile) do
        relay_session_id when is_binary(relay_session_id) ->
          _ =
            relay_session_manager().request_close(
              relay_session_id,
              reason: reason,
              scope: scope
            )

          :ok

        _other ->
          :ok
      end
    end)
  end

  defp maybe_close_camera_relay_tiles(_camera_relay_tiles, _scope, _reason), do: :ok

  defp mark_camera_relay_tiles_closing(camera_relay_tiles) when is_list(camera_relay_tiles) do
    Enum.map(camera_relay_tiles, fn tile ->
      case Map.get(tile, :relay_session) do
        %{status: status} = session when status not in [:closed, :failed, "closed", "failed"] ->
          tile
          |> Map.put(:relay_session, Map.put(session, :status, :closing))
          |> Map.put(:viewer_state, viewer_state_from_session(Map.put(session, :status, :closing)))

        _other ->
          tile
      end
    end)
  end

  defp mark_camera_relay_tiles_closing(_camera_relay_tiles), do: []

  defp cluster_camera_tile_notice(opened_tiles, omitted_count, params)
       when is_list(opened_tiles) and is_integer(omitted_count) and is_map(params) do
    cluster_label =
      params
      |> Map.get("cluster_label")
      |> normalize_presence()

    active_count = Enum.count(opened_tiles, &camera_relay_tile_active?/1)

    base =
      if present?(cluster_label),
        do: "Opened #{active_count} camera relays from #{cluster_label}.",
        else: "Opened #{active_count} camera relays from the selected cluster."

    if omitted_count > 0 do
      "#{base} #{omitted_count} additional cameras were skipped to stay within the tile limit."
    else
      base
    end
  end

  defp cluster_camera_tile_notice(_opened_tiles, _omitted_count, _params), do: nil

  defp cluster_camera_tile_flash_message(opened_tiles, omitted_count)
       when is_list(opened_tiles) and is_integer(omitted_count) do
    active_count = Enum.count(opened_tiles, &camera_relay_tile_active?/1)

    if omitted_count > 0 do
      "Opened #{active_count} camera relays. #{omitted_count} were skipped to stay within the tile limit."
    else
      "Opened #{active_count} camera relays from the selected cluster"
    end
  end

  defp fetch_camera_relay_tile_session(camera_relay_tiles, relay_session_id)
       when is_list(camera_relay_tiles) and is_binary(relay_session_id) do
    Enum.find(camera_relay_tiles, &(camera_relay_tile_session_id(&1) == relay_session_id))
  end

  defp fetch_camera_relay_tile_session(_camera_relay_tiles, _relay_session_id), do: nil

  defp update_camera_relay_tile(socket, relay_session_id, updater)
       when is_binary(relay_session_id) and is_function(updater, 1) do
    update(socket, :camera_relay_tiles, fn tiles ->
      Enum.map(tiles, fn tile ->
        if camera_relay_tile_session_id(tile) == relay_session_id do
          updater.(tile)
        else
          tile
        end
      end)
    end)
  end

  defp camera_relay_tile_dom_id(tile) do
    (Map.get(tile, :tile_id) || Ecto.UUID.generate())
    |> to_string()
    |> String.replace(~r/[^a-zA-Z0-9_-]/u, "-")
  end

  defp camera_relay_tile_session_id(tile) do
    tile
    |> Map.get(:relay_session, %{})
    |> Map.get(:id)
  end

  defp camera_relay_tile_label(tile) do
    Map.get(tile, :camera_label) || "Cluster camera"
  end

  defp camera_relay_tile_profile_label(tile), do: Map.get(tile, :profile_label)
  defp camera_relay_tile_device_uid(tile), do: Map.get(tile, :device_uid)

  defp camera_relay_tile_active?(tile) do
    session = Map.get(tile, :relay_session)
    is_map(session) and not relay_session_terminal?(session)
  end

  defp camera_relay_tile_stream_path(tile) do
    tile
    |> Map.get(:relay_session)
    |> camera_relay_stream_path()
  end

  defp camera_relay_tile_status_label(tile) do
    cond do
      is_map(Map.get(tile, :relay_session)) ->
        relay_status_label(Map.get(tile.relay_session, :status))

      is_map(Map.get(tile, :viewer_state)) ->
        Map.get(tile.viewer_state, :title)

      true ->
        nil
    end
  end

  defp camera_relay_tile_session_status_label(tile) do
    tile
    |> Map.get(:relay_session, %{})
    |> Map.get(:status)
    |> relay_status_label()
  end

  defp camera_relay_tile_badge_class(tile) do
    cond do
      is_map(Map.get(tile, :relay_session)) ->
        relay_status_badge_class(Map.get(tile.relay_session, :status))

      is_map(Map.get(tile, :viewer_state)) ->
        viewer_state_badge_class(Map.get(tile.viewer_state, :kind))

      true ->
        "badge-ghost"
    end
  end

  defp camera_relay_tile_playback_state(tile) do
    tile
    |> Map.get(:relay_session, %{})
    |> relay_playback_state()
  end

  defp camera_relay_tile_viewer_count(tile) do
    tile
    |> Map.get(:relay_session, %{})
    |> Map.get(:viewer_count, 0)
  end

  defp camera_relay_tile_termination_text(tile) do
    tile
    |> Map.get(:relay_session)
    |> case do
      session when is_map(session) -> relay_termination_text(session)
      _ -> ""
    end
  end

  defp camera_relay_tile_failure_reason_text(tile) do
    tile
    |> Map.get(:relay_session)
    |> case do
      session when is_map(session) -> relay_failure_reason_text(session)
      _ -> ""
    end
  end

  defp camera_relay_tile_close_reason_text(tile) do
    tile
    |> Map.get(:relay_session)
    |> case do
      session when is_map(session) -> relay_close_reason_text(session)
      _ -> ""
    end
  end

  defp camera_relay_tile_viewer_detail(tile) do
    case Map.get(tile, :viewer_state) do
      %{detail: detail} -> detail
      _ -> nil
    end
  end

  defp camera_relay_tile_viewer_state_container_class(tile) do
    case Map.get(tile, :viewer_state) do
      %{kind: kind} -> viewer_state_container_class(kind)
      _ -> "border-base-300/70 bg-base-200/20 text-base-content"
    end
  end

  defp selected_camera_context(params) when is_map(params) do
    %{
      device_uid: normalize_presence(Map.get(params, "device_uid")),
      camera_label: normalize_presence(Map.get(params, "camera_label")),
      profile_label: normalize_presence(Map.get(params, "profile_label"))
    }
  end

  defp selected_camera_context(_params), do: nil

  defp camera_context_label(%{camera_label: value}) when is_binary(value) and value != "", do: value
  defp camera_context_label(_context), do: "Selected camera"

  defp camera_context_profile_label(%{profile_label: value}) when is_binary(value), do: value
  defp camera_context_profile_label(_context), do: nil

  defp camera_context_device_uid(%{device_uid: value}) when is_binary(value), do: value
  defp camera_context_device_uid(_context), do: nil

  defp normalize_presence(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_presence(_value), do: nil

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp truthy?(value) when is_boolean(value), do: value
  defp truthy?(value) when value in ["true", "1", 1, true], do: true
  defp truthy?(_), do: false
end
