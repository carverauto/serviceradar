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
       |> assign(:schema_version, GodViewSnapshot.schema_version())
       |> assign(:stream_state, :idle)
       |> assign(:last_revision, nil)
       |> assign(:last_generated_at, nil)}
    else
      {:ok,
       socket
       |> put_flash(:error, "God-View is not enabled in this environment.")
       |> push_navigate(to: ~p"/analytics")}
    end
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
      </div>
    </Layouts.app>
    """
  end
end
