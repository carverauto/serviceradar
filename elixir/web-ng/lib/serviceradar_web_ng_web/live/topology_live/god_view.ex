defmodule ServiceRadarWebNGWeb.TopologyLive.GodView do
  use ServiceRadarWebNGWeb, :live_view

  require Logger

  alias ServiceRadarWebNG.Graph, as: AgeGraph
  alias ServiceRadarWebNG.Topology.GodViewSnapshot
  alias ServiceRadarWebNGWeb.FeatureFlags

  @default_decode_alert_ms 20.0
  @default_render_alert_ms 40.0

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

    {:noreply,
     socket |> assign(:zoom_mode, mode) |> push_event("god_view:set_zoom_mode", %{mode: mode})}
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

  def handle_event("set_controls_panel", %{"collapsed" => collapsed}, socket) do
    {:noreply, assign(socket, :controls_collapsed, truthy?(collapsed))}
  end

  defp maybe_emit_client_perf_alert(params, pipeline_stats)
       when is_map(params) and is_map(pipeline_stats) do
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
                empty_topology_message(
                  @stream_state,
                  @last_node_count,
                  @last_edge_count,
                  @pipeline_stats
                )
              }
              class="pointer-events-none absolute inset-0 z-10 flex items-center justify-center"
            >
              <div class="max-w-xl rounded-lg border border-warning/30 bg-base-100/90 px-5 py-4 text-center shadow-lg backdrop-blur-sm">
                <div class="text-sm font-semibold text-warning">Topology unavailable</div>
                <div class="mt-1 text-xs text-base-content/70">
                  {empty_topology_message(
                    @stream_state,
                    @last_node_count,
                    @last_edge_count,
                    @pipeline_stats
                  )}
                </div>
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
      </div>
    </Layouts.app>
    """
  end

  defp push_mtr_path_data(socket) do
    push_event(socket, "god_view:mtr_path_data", %{paths: load_mtr_paths()})
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
    else
      nil
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
    if Atom.to_string(k) == key, do: value, else: nil
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

  defp empty_topology_message(stream_state, last_node_count, last_edge_count, pipeline_stats) do
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
        "The topology stream failed. Check web-ng/runtime-graph logs and AGE topology data."

      stream_state == :ok and node_count == 0 and edge_count == 0 ->
        "No topology nodes or edges were returned from AGE. Verify topology ingestion is writing graph relations."

      true ->
        nil
    end
  end

  defp normalize_zoom_mode("global"), do: "global"
  defp normalize_zoom_mode("regional"), do: "regional"
  defp normalize_zoom_mode("local"), do: "local"
  defp normalize_zoom_mode(_), do: "auto"

  defp truthy?(value) when is_boolean(value), do: value
  defp truthy?(value) when value in ["true", "1", 1, true], do: true
  defp truthy?(_), do: false
end
