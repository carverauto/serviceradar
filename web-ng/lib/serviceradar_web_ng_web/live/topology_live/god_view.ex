defmodule ServiceRadarWebNGWeb.TopologyLive.GodView do
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadarWebNG.Topology.GodViewSnapshot
  alias ServiceRadarWebNGWeb.FeatureFlags

  @impl true
  def mount(_params, _session, socket) do
    if FeatureFlags.god_view_enabled?() do
      {:ok,
       socket
       |> assign(:page_title, "God-View Topology")
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
         endpoints: false
       })
       |> assign(:pipeline_stats, %{})
       |> assign(:controls_collapsed, true)}
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
        _ -> :endpoints
      end

    layers = Map.update!(socket.assigns.topology_layers, key, &(!&1))

    {:noreply,
     socket
     |> assign(:topology_layers, layers)
     |> push_event("god_view:set_topology_layers", %{layers: stringify_filter_keys(layers)})}
  end

  def handle_event("toggle_controls_panel", _params, socket) do
    {:noreply, update(socket, :controls_collapsed, &(!&1))}
  end

  def handle_event("set_controls_panel", %{"collapsed" => collapsed}, socket) do
    {:noreply, assign(socket, :controls_collapsed, truthy?(collapsed))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} srql={%{page_path: @current_path}}>
      <div class="mx-auto max-w-7xl p-6 space-y-6">
        <.header>
          God-View Topology
          <:subtitle>
            deck.gl WebGPU topology surface with live Arrow snapshots and causal overlays.
          </:subtitle>
        </.header>

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

                <div :if={@controls_collapsed} class="mt-2 grid grid-cols-2 gap-1">
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
                    <div class="grid grid-cols-3 gap-1">
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

      parsed =
        cond do
          is_integer(raw) ->
            raw

          is_binary(raw) ->
            case Integer.parse(raw) do
              {value, ""} -> value
              _ -> nil
            end

          true ->
            nil
        end

      if is_integer(parsed), do: Map.put(acc, key, parsed), else: acc
    end)
  end

  defp normalize_pipeline_stats(_), do: %{}

  defp normalize_zoom_mode("global"), do: "global"
  defp normalize_zoom_mode("regional"), do: "regional"
  defp normalize_zoom_mode("local"), do: "local"
  defp normalize_zoom_mode(_), do: "auto"

  defp truthy?(value) when is_boolean(value), do: value
  defp truthy?(value) when value in ["true", "1", 1, true], do: true
  defp truthy?(_), do: false
end
