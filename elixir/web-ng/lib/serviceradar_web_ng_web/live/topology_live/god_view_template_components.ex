defmodule ServiceRadarWebNGWeb.TopologyLive.GodViewTemplateComponents do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  def surface(assigns) do
    ~H"""
    <.ui_panel>
      <:header>
        <div class="text-sm font-semibold">Topology Surface</div>
      </:header>
      <div class="relative" data-god-view-safe-root="true">
        <div
          id="god-view-binary-stream"
          phx-hook="GodViewBinaryStream"
          phx-update="ignore"
          data-url={@snapshot_url}
          data-interval-ms="5000"
          data-timezone={@timezone}
          class="h-[70vh] min-h-[480px] w-full rounded-lg border border-sr-line bg-sr-subtle/20"
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
          <div class="max-w-xl rounded-lg border border-warning/30 bg-sr-surface/90 px-5 py-4 text-center shadow-lg backdrop-blur-sm">
            <div class="text-sm font-semibold text-warning">{empty_topology_state.title}</div>
            <div class="mt-1 text-xs text-sr-muted">{empty_topology_state.message}</div>
          </div>
        </div>

        <div
          :if={backbone_warning = backbone_empty_warning(@pipeline_stats)}
          id="god-view-backbone-empty-warning"
          class="pointer-events-none absolute inset-x-0 top-3 z-10 flex justify-center px-3"
          data-god-view-safe-area="top"
          data-testid="backbone-empty-warning"
        >
          <div
            role="alert"
            class="pointer-events-auto flex max-w-2xl flex-wrap items-center gap-x-3 gap-y-2 rounded-lg border border-warning/40 bg-sr-surface/90 px-4 py-2 shadow-lg backdrop-blur-sm"
          >
            <.ui_badge size="sm" variant="warning">Backbone unavailable</.ui_badge>
            <span class="text-xs text-sr-muted">
              This snapshot has no backbone topology edges; {backbone_warning.other_edges} attachment/inferred
              edges are available on the Inferred and Endpoints layers.
            </span>
            <span class="font-mono text-[10px] text-sr-muted">
              bb:{backbone_warning.counts.backbone} att:{backbone_warning.counts.attachment} inf:{backbone_warning.counts.inferred} host:{backbone_warning.counts.hosted} obs:{backbone_warning.counts.observed}
            </span>
            <.ui_button
              :if={!(@topology_layers.inferred and @topology_layers.endpoints)}
              type="button"
              phx-click="enable_attachment_layers"
              size="xs"
              variant="warning"
              class="h-7 min-h-7"
            >
              Show attachment layers
            </.ui_button>
          </div>
        </div>

        <div
          id="god-view-controls"
          phx-hook="GodViewControlsState"
          data-collapsed={to_string(@controls_collapsed)}
          data-god-view-safe-area="right"
          class="absolute right-3 top-3 z-20 pointer-events-auto"
        >
          <div class="w-[220px] rounded-lg border border-sr-line/70 bg-sr-surface/85 p-2 shadow-lg backdrop-blur-md">
            <div class="flex items-center justify-between gap-2">
              <div class="text-[10px] uppercase tracking-wide text-sr-muted">
                Controls
              </div>
              <.ui_button
                type="button"
                phx-click="toggle_controls_panel"
                title={if @controls_collapsed, do: "Expand controls", else: "Collapse controls"}
                size="xs"
                variant="ghost"
                class="h-6 min-h-6 px-2"
              >
                {if @controls_collapsed, do: "Expand", else: "Collapse"}
              </.ui_button>
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
              <.ui_button
                type="button"
                phx-click="reset_view"
                title="Reset view to fit all nodes"
                size="xs"
                variant="ghost"
                class="h-7 min-h-7"
              >
                Reset
              </.ui_button>
            </div>

            <div :if={!@controls_collapsed} class="space-y-2 mt-2">
              <div>
                <div class="text-[10px] uppercase tracking-wide text-sr-muted mb-1">
                  View
                </div>
                <div class={ui_join_class(class: "w-full")}>
                  <button
                    type="button"
                    class={"sr-ui-join-item flex-1 #{overlay_zoom_button_class(@zoom_mode == "auto")}"}
                    phx-click="set_zoom_mode"
                    phx-value-mode="auto"
                    title="Auto Focus"
                  >
                    Auto
                  </button>
                  <button
                    type="button"
                    class={"sr-ui-join-item flex-1 #{overlay_zoom_button_class(@zoom_mode == "global")}"}
                    phx-click="set_zoom_mode"
                    phx-value-mode="global"
                    title="World Aggregate"
                  >
                    World
                  </button>
                  <button
                    type="button"
                    class={"sr-ui-join-item flex-1 #{overlay_zoom_button_class(@zoom_mode == "regional")}"}
                    phx-click="set_zoom_mode"
                    phx-value-mode="regional"
                    title="Region Cells"
                  >
                    Region
                  </button>
                  <button
                    type="button"
                    class={"sr-ui-join-item flex-1 #{overlay_zoom_button_class(@zoom_mode == "local")}"}
                    phx-click="set_zoom_mode"
                    phx-value-mode="local"
                    title="Device Detail"
                  >
                    Detail
                  </button>
                </div>
                <.ui_button
                  type="button"
                  phx-click="reset_view"
                  title="Reset view and sr-ui-collapse expanded endpoint clusters"
                  size="xs"
                  variant="ghost"
                  class="h-7 min-h-7 w-full mt-1"
                >
                  Reset / Collapse
                </.ui_button>
              </div>

              <div>
                <div class="text-[10px] uppercase tracking-wide text-sr-muted mb-1">
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
                <div class="text-[10px] uppercase tracking-wide text-sr-muted mb-1">
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
                <div class="text-[10px] uppercase tracking-wide text-sr-muted mb-1">
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
    """
  end

  def stream_contract(assigns) do
    ~H"""
    <.ui_panel>
      <:header>
        <div class="text-sm font-semibold">Snapshot Stream Contract</div>
      </:header>

      <div class="grid grid-cols-1 gap-3 sm:grid-cols-2">
        <div class="rounded-lg border border-sr-line bg-sr-subtle/30 p-3">
          <div class="text-xs uppercase tracking-wide text-sr-muted">Schema Version</div>
          <div class="text-sm font-mono mt-1">{@schema_version}</div>
        </div>
        <div class="rounded-lg border border-sr-line bg-sr-subtle/30 p-3">
          <div class="text-xs uppercase tracking-wide text-sr-muted">Stream State</div>
          <div class="text-sm font-mono mt-1">{@stream_state}</div>
        </div>
        <div class="rounded-lg border border-sr-line bg-sr-subtle/30 p-3">
          <div class="text-xs uppercase tracking-wide text-sr-muted">Last Revision</div>
          <div class="text-sm font-mono mt-1">{@last_revision || "—"}</div>
        </div>
        <div class="rounded-lg border border-sr-line bg-sr-subtle/30 p-3">
          <div class="text-xs uppercase tracking-wide text-sr-muted">Generated At</div>
          <.user_time
            id="god-view-stream-generated-at"
            value={@last_generated_at}
            timezone={@timezone}
            style={:full}
            fallback="—"
            class="text-sm font-mono mt-1"
          />
        </div>
        <div class="rounded-lg border border-sr-line bg-sr-subtle/30 p-3">
          <div class="text-xs uppercase tracking-wide text-sr-muted">Payload Bytes</div>
          <div class="text-sm font-mono mt-1">{@last_bytes || "—"}</div>
        </div>
        <div class="rounded-lg border border-sr-line bg-sr-subtle/30 p-3">
          <div class="text-xs uppercase tracking-wide text-sr-muted">Node Count</div>
          <div class="text-sm font-mono mt-1">{@last_node_count || "—"}</div>
        </div>
        <div class="rounded-lg border border-sr-line bg-sr-subtle/30 p-3">
          <div class="text-xs uppercase tracking-wide text-sr-muted">Edge Count</div>
          <div class="text-sm font-mono mt-1">{@last_edge_count || "—"}</div>
        </div>
        <div class="rounded-lg border border-sr-line bg-sr-subtle/30 p-3">
          <div class="text-xs uppercase tracking-wide text-sr-muted">Network (ms)</div>
          <div class="text-sm font-mono mt-1">{@last_network_ms || "—"}</div>
        </div>
        <div class="rounded-lg border border-sr-line bg-sr-subtle/30 p-3">
          <div class="text-xs uppercase tracking-wide text-sr-muted">Renderer</div>
          <div class="text-sm font-mono mt-1">{@last_renderer_mode || "—"}</div>
        </div>
        <div class="rounded-lg border border-sr-line bg-sr-subtle/30 p-3">
          <div class="text-xs uppercase tracking-wide text-sr-muted">Zoom Tier</div>
          <div class="text-sm font-mono mt-1">{@last_zoom_tier || "—"}</div>
        </div>
        <div class="rounded-lg border border-sr-line bg-sr-subtle/30 p-3">
          <div class="text-xs uppercase tracking-wide text-sr-muted">Zoom Mode</div>
          <div class="text-sm font-mono mt-1">{@last_zoom_mode || "—"}</div>
        </div>
        <div class="rounded-lg border border-sr-line bg-sr-subtle/30 p-3">
          <div class="text-xs uppercase tracking-wide text-sr-muted">Decode (ms)</div>
          <div class="text-sm font-mono mt-1">{@last_decode_ms || "—"}</div>
        </div>
        <div class="rounded-lg border border-sr-line bg-sr-subtle/30 p-3">
          <div class="text-xs uppercase tracking-wide text-sr-muted">Render (ms)</div>
          <div class="text-sm font-mono mt-1">{@last_render_ms || "—"}</div>
        </div>
        <div class="rounded-lg border border-sr-line bg-sr-subtle/30 p-3">
          <div class="text-xs uppercase tracking-wide text-sr-muted">
            Bitmap Meta (r/a/h/u)
          </div>
          <div class="text-sm font-mono mt-1">{format_bitmap_meta(@last_bitmap_metadata)}</div>
        </div>
      </div>
    </.ui_panel>
    """
  end

  def pipeline_telemetry(assigns) do
    ~H"""
    <.ui_panel>
      <:header>
        <div class="text-sm font-semibold">Pipeline Telemetry</div>
      </:header>
      <div class="grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <div class="rounded-lg border border-sr-line bg-sr-subtle/30 p-3">
          <div class="text-xs uppercase tracking-wide text-sr-muted">Raw Observations</div>
          <div class="text-sm font-mono mt-1">{Map.get(@pipeline_stats, :raw_links, "—")}</div>
        </div>
        <div class="rounded-lg border border-sr-line bg-sr-subtle/30 p-3">
          <div class="text-xs uppercase tracking-wide text-sr-muted">Unique Pairs</div>
          <div class="text-sm font-mono mt-1">{Map.get(@pipeline_stats, :unique_pairs, "—")}</div>
        </div>
        <div class="rounded-lg border border-sr-line bg-sr-subtle/30 p-3">
          <div class="text-xs uppercase tracking-wide text-sr-muted">Final Edges</div>
          <div class="text-sm font-mono mt-1">{Map.get(@pipeline_stats, :final_edges, "—")}</div>
        </div>
        <div class="rounded-lg border border-sr-line bg-sr-subtle/30 p-3">
          <div class="text-xs uppercase tracking-wide text-sr-muted">
            Unresolved Endpoints
          </div>
          <div class="text-sm font-mono mt-1">
            {Map.get(@pipeline_stats, :unresolved_endpoints, "—")}
          </div>
        </div>
        <div class="rounded-lg border border-sr-line bg-sr-subtle/30 p-3">
          <div class="text-xs uppercase tracking-wide text-sr-muted">Direct</div>
          <div class="text-sm font-mono mt-1">{Map.get(@pipeline_stats, :final_direct, "—")}</div>
        </div>
        <div class="rounded-lg border border-sr-line bg-sr-subtle/30 p-3">
          <div class="text-xs uppercase tracking-wide text-sr-muted">Inferred</div>
          <div class="text-sm font-mono mt-1">
            {Map.get(@pipeline_stats, :final_inferred, "—")}
          </div>
        </div>
        <div class="rounded-lg border border-sr-line bg-sr-subtle/30 p-3">
          <div class="text-xs uppercase tracking-wide text-sr-muted">Attachments</div>
          <div class="text-sm font-mono mt-1">
            {Map.get(@pipeline_stats, :final_attachment, "—")}
          </div>
        </div>
      </div>
    </.ui_panel>
    """
  end

  def overlay_filter_button_class(true),
    do:
      "inline-flex h-7 min-h-7 items-center justify-center gap-1 rounded-sr-control border border-transparent bg-sr-brand px-2 text-xs font-semibold text-sr-on-brand"

  def overlay_filter_button_class(false),
    do:
      "inline-flex h-7 min-h-7 items-center justify-center gap-1 rounded-sr-control border border-transparent bg-transparent px-2 text-xs font-semibold text-sr-muted hover:bg-sr-subtle hover:text-sr-ink"

  def overlay_zoom_button_class(true),
    do:
      "inline-flex h-7 min-h-7 items-center justify-center gap-1 rounded-sr-control border border-sr-line bg-sr-subtle px-2 text-xs font-semibold text-sr-brand"

  def overlay_zoom_button_class(false), do: overlay_filter_button_class(false)

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

  @doc """
  Backbone-empty warning state: the served snapshot carries zero
  backbone-class edges while attachment/inferred/hosted/observed edges
  exist. Returns `nil` when the snapshot is healthy or per-class counts
  are not (yet) available in the pipeline stats.
  """
  def backbone_empty_warning(pipeline_stats) when is_map(pipeline_stats) do
    backbone =
      pipeline_class_count(pipeline_stats, :backbone_edge_count) ||
        pipeline_class_count(pipeline_stats, :edge_class_backbone)

    counts = %{
      backbone: backbone,
      attachment: pipeline_class_count(pipeline_stats, :edge_class_attachment) || 0,
      inferred: pipeline_class_count(pipeline_stats, :edge_class_inferred) || 0,
      hosted: pipeline_class_count(pipeline_stats, :edge_class_hosted) || 0,
      observed: pipeline_class_count(pipeline_stats, :edge_class_observed) || 0
    }

    other_edges = counts.attachment + counts.inferred + counts.hosted + counts.observed

    if backbone == 0 and other_edges > 0 do
      %{counts: counts, other_edges: other_edges}
    end
  end

  def backbone_empty_warning(_pipeline_stats), do: nil

  defp pipeline_class_count(pipeline_stats, key) do
    raw = Map.get(pipeline_stats, key) || Map.get(pipeline_stats, Atom.to_string(key))
    parse_pipeline_stat(raw)
  end
end
