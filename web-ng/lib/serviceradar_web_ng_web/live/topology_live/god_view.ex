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
       |> assign(:causal_filters, %{
         root_cause: true,
         affected: true,
         healthy: true,
         unknown: true
       })}
    else
      {:ok,
       socket
       |> put_flash(:error, "God-View is not enabled in this environment.")
       |> push_navigate(to: ~p"/analytics")}
    end
  end

  @impl true
  def handle_event("god_view_stream_stats", params, socket) do
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
     |> assign(:last_render_ms, Map.get(params, "render_ms"))}
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

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} srql={%{page_path: @current_path}}>
      <div class="mx-auto max-w-7xl p-6 space-y-6">
        <.header>
          God-View Topology
          <:subtitle>
            Feature-flagged phase-1 scaffold for topology snapshots and causal blast radius rendering.
          </:subtitle>
        </.header>

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
              <div class="text-xs uppercase tracking-wide text-base-content/60">Decode (ms)</div>
              <div class="text-sm font-mono mt-1">{@last_decode_ms || "—"}</div>
            </div>
            <div class="rounded-lg border border-base-200 bg-base-200/30 p-3">
              <div class="text-xs uppercase tracking-wide text-base-content/60">Render (ms)</div>
              <div class="text-sm font-mono mt-1">{@last_render_ms || "—"}</div>
            </div>
          </div>
        </.ui_panel>

        <.ui_panel>
          <:header>
            <div class="text-sm font-semibold">Phase 1 Scope</div>
          </:header>
          <ul class="list-disc pl-5 text-sm text-base-content/80 space-y-1">
            <li>Binary topology snapshot ingestion and schema compatibility checks</li>
            <li>Server-provided causal bitmaps for blast-radius rendering states</li>
            <li>Feature-gated rollout with explicit performance telemetry targets</li>
          </ul>
        </.ui_panel>

        <.ui_panel>
          <:header>
            <div class="text-sm font-semibold">Causal Filters</div>
          </:header>
          <div class="flex flex-wrap gap-2">
            <button
              type="button"
              class={filter_button_class(@causal_filters.root_cause)}
              phx-click="toggle_causal_filter"
              phx-value-state="root_cause"
            >
              Root Cause
            </button>
            <button
              type="button"
              class={filter_button_class(@causal_filters.affected)}
              phx-click="toggle_causal_filter"
              phx-value-state="affected"
            >
              Affected
            </button>
            <button
              type="button"
              class={filter_button_class(@causal_filters.healthy)}
              phx-click="toggle_causal_filter"
              phx-value-state="healthy"
            >
              Healthy
            </button>
            <button
              type="button"
              class={filter_button_class(@causal_filters.unknown)}
              phx-click="toggle_causal_filter"
              phx-value-state="unknown"
            >
              Unknown
            </button>
          </div>
        </.ui_panel>

        <.ui_panel>
          <:header>
            <div class="text-sm font-semibold">Binary Stream Preview</div>
          </:header>
          <div
            id="god-view-binary-stream"
            phx-hook="GodViewBinaryStream"
            phx-update="ignore"
            data-url={@snapshot_url}
            data-interval-ms="5000"
            class="rounded-lg border border-base-200 bg-base-200/20 p-3 text-xs font-mono"
          >
            waiting for snapshot...
          </div>
        </.ui_panel>
      </div>
    </Layouts.app>
    """
  end

  defp stringify_filter_keys(filters) do
    Map.new(filters, fn {k, v} -> {Atom.to_string(k), v} end)
  end

  defp filter_button_class(true), do: "btn btn-sm btn-primary"
  defp filter_button_class(false), do: "btn btn-sm btn-ghost"
end
