defmodule ServiceRadarWebNGWeb.Settings.AgentsLive.EdgePipelineReadiness do
  @moduledoc """
  The edge pipeline readiness report (`ServiceRadar.Edge.PipelineReadiness.report/0`): every
  agent that would be off the durable edge-record pipeline, with each reason. Read-only; the
  same report is served at `GET /api/admin/agents/edge-pipeline-readiness`.
  """

  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.EdgePipelineComponents, only: [edge_pipeline_conditions: 1]

  alias ServiceRadar.Edge.PipelineReadiness
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.Settings.Shell

  @permission "settings.edge.manage"

  @impl true
  def mount(_params, _session, socket) do
    if RBAC.can?(socket.assigns.current_scope, @permission) do
      {:ok,
       socket
       |> assign(:page_title, "Edge Pipeline Readiness")
       |> assign(:current_path, "/settings/agents/edge-pipeline")
       |> assign(:blocked_count, nil)
       |> assign(:error, nil)
       |> stream_configure(:entries, dom_id: &entry_dom_id/1)
       |> stream(:entries, [])}
    else
      {:ok,
       socket
       |> put_flash(:error, "You do not have access to edge pipeline readiness")
       |> push_navigate(to: ~p"/settings/profile")}
    end
  end

  @impl true
  def handle_params(_params, _url, socket) do
    if connected?(socket) do
      {:noreply, load_report(socket)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    if RBAC.can?(socket.assigns.current_scope, @permission) do
      {:noreply, load_report(socket)}
    else
      {:noreply, put_flash(socket, :error, "You do not have access to edge pipeline readiness")}
    end
  end

  defp load_report(socket) do
    case PipelineReadiness.report() do
      {:ok, entries} ->
        socket
        |> assign(:blocked_count, length(entries))
        |> assign(:error, nil)
        |> stream(:entries, entries, reset: true)

      {:error, reason} ->
        socket
        |> assign(:blocked_count, nil)
        |> assign(:error, "The readiness report could not be read: #{inspect(reason)}")
        |> stream(:entries, [], reset: true)
    end
  end

  defp entry_dom_id(entry), do: "edge-readiness-" <> Base.url_encode64(entry.agent_id, padding: false)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <Shell.settings_chrome
        current_path={@current_path}
        current_scope={@current_scope}
        active_view={@settings_active_view}
        active_category={@settings_active_category}
        breadcrumbs={@settings_breadcrumbs}
        nav_tree={@settings_nav_tree}
        palette={@settings_palette}
        stats={@settings_stats}
      >
        <div class="space-y-6">
          <div class="flex flex-wrap items-center justify-between gap-4">
            <div>
              <h1 class="text-2xl font-semibold text-sr-ink">Edge Pipeline Readiness</h1>
              <p class="text-sm text-sr-muted">
                Agents that would be off the durable edge-record pipeline once it is the only
                agent data path, and why. This report changes nothing.
              </p>
            </div>
            <.ui_button variant="ghost" size="sm" phx-click="refresh">
              <.icon name="hero-arrow-path" class="size-4" /> Refresh
            </.ui_button>
          </div>

          <div :if={@error} class="rounded-xl border border-error/30 bg-error/5 p-4">
            <p class="text-sm text-error">{@error}</p>
          </div>

          <div
            :if={@blocked_count == 0}
            id="edge-readiness-ready"
            class="rounded-xl border border-success/30 bg-success/5 p-4"
          >
            <p class="text-sm text-success">Every agent is ready for the edge-record pipeline.</p>
          </div>

          <.ui_panel :if={is_integer(@blocked_count) and @blocked_count > 0}>
            <:header>
              <div class="text-sm font-semibold">
                {@blocked_count} {if @blocked_count == 1, do: "agent", else: "agents"} not ready
              </div>
            </:header>
            <div class="sr-ui-table-shell">
              <table class={ui_table_class(size: "sm", class: "w-full")}>
                <thead>
                  <tr>
                    <th>Agent</th>
                    <th>Partition</th>
                    <th>Reasons</th>
                  </tr>
                </thead>
                <tbody id="edge-readiness-entries" phx-update="stream">
                  <tr :for={{dom_id, entry} <- @streams.entries} id={dom_id}>
                    <td class="align-top">
                      <.link navigate={~p"/agents/#{entry.agent_id}"} class="font-mono text-xs">
                        {entry.agent_id}
                      </.link>
                      <div :if={entry.name} class="text-xs text-sr-muted">{entry.name}</div>
                    </td>
                    <td class="align-top font-mono text-xs">{entry.partition}</td>
                    <td class="align-top">
                      <.edge_pipeline_conditions conditions={entry.conditions} />
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </.ui_panel>
        </div>
      </Shell.settings_chrome>
    </Layouts.app>
    """
  end
end
