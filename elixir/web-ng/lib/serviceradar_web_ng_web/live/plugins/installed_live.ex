defmodule ServiceRadarWebNGWeb.Plugins.InstalledLive do
  @moduledoc """
  Installed view of the Wasm plugin pages: one row per logical plugin
  (`plugin_id`), not per package version.

  Rows come from `ServiceRadarWebNG.Plugins.PluginFleet.summaries/2`, a page at
  a time; the page number lives in the URL and the rows are streamed. Nothing
  is read in the disconnected render.
  """

  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.Plugins.Components

  alias ServiceRadarWebNG.Plugins.Assignments
  alias ServiceRadarWebNG.Plugins.PluginFleet
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.Plugins.OrphanedAssignments
  alias ServiceRadarWebNGWeb.Settings.Shell

  require Logger

  @page_size 50
  @plugin_assignment_manage_permission "settings.plugins.manage"

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if RBAC.can?(scope, "plugins.view") do
      {:ok,
       socket
       |> assign(:can_stage_plugins, RBAC.can?(scope, "plugins.stage"))
       |> assign(:can_assign_plugins, RBAC.can?(scope, @plugin_assignment_manage_permission))
       |> assign(:page_title, "Plugins")
       |> assign(:current_path, nil)
       |> assign(:plugins_base_path, "/admin/plugins")
       |> assign(:loaded?, false)
       |> assign(:plugins_total, 0)
       |> assign(:plugins_page, 1)
       |> assign(:plugins_page_size, @page_size)
       |> assign(:orphaned_assignments, [])
       |> stream_configure(:plugins, dom_id: &"installed-plugin-#{dom_id_segment(&1.plugin_id)}")
       |> stream(:plugins, [])}
    else
      {:ok,
       socket
       |> put_flash(:error, "You don't have permission to access Plugins.")
       |> redirect(to: ~p"/dashboard")}
    end
  end

  @impl true
  def handle_params(params, url, socket) do
    socket =
      socket
      |> assign(:current_path, current_path_from_url(url))
      |> assign(:plugins_base_path, plugins_base_path_from_url(url))

    cond do
      not connected?(socket) ->
        {:noreply, socket}

      socket.assigns.loaded? ->
        {:noreply, load_plugins(socket, Map.get(params, "page", 1))}

      true ->
        {:noreply,
         socket
         |> load_plugins(Map.get(params, "page", 1))
         |> assign_orphaned_assignments()
         |> assign(:loaded?, true)}
    end
  end

  @impl true
  def handle_event("plugins_page", %{"page" => page}, socket) do
    page = clamp_page(page, socket.assigns.plugins_total, socket.assigns.plugins_page_size)
    {:noreply, push_patch(socket, to: socket.assigns.plugins_base_path <> "?page=#{page}")}
  end

  def handle_event("refresh", _params, socket) do
    {:noreply,
     socket
     |> load_plugins(socket.assigns.plugins_page)
     |> assign_orphaned_assignments()}
  end

  def handle_event("retract_orphaned_assignment", _params, %{assigns: %{can_assign_plugins: false}} = socket) do
    {:noreply, put_flash(socket, :error, "You don't have permission to manage plugin assignments.")}
  end

  def handle_event("retract_orphaned_assignment", %{"id" => id}, socket) do
    {:noreply, retract_orphaned_assignments(socket, [id])}
  end

  def handle_event("retract_all_orphaned_assignments", _params, %{assigns: %{can_assign_plugins: false}} = socket) do
    {:noreply, put_flash(socket, :error, "You don't have permission to manage plugin assignments.")}
  end

  def handle_event("retract_all_orphaned_assignments", _params, socket) do
    {:noreply, retract_orphaned_assignments(socket, :all)}
  end

  defp load_plugins(socket, page) do
    %{entries: entries, total: total, page: page} =
      PluginFleet.summaries(socket.assigns.current_scope, page: page, page_size: @page_size)

    socket
    |> assign(:plugins_total, total)
    |> assign(:plugins_page, page)
    |> stream(:plugins, entries, reset: true)
  end

  # Only operators who can retract them see the report: it names credential
  # rules and target policies the viewer may not otherwise read.
  defp assign_orphaned_assignments(%{assigns: %{can_assign_plugins: false}} = socket), do: socket

  defp assign_orphaned_assignments(socket) do
    case Assignments.list_orphaned() do
      {:ok, orphans} ->
        assign(socket, :orphaned_assignments, orphans)

      {:error, error} ->
        Logger.warning("Failed to list orphaned plugin assignments", reason: inspect(error))
        assign(socket, :orphaned_assignments, [])
    end
  end

  defp retract_orphaned_assignments(socket, selection) do
    case Assignments.retract_orphaned(selection, scope: socket.assigns.current_scope) do
      {:ok, %{retracted: count}} ->
        socket
        |> assign_orphaned_assignments()
        |> put_flash(:info, "Retracted #{count} orphaned assignment(s)")

      {:error, error} ->
        Logger.warning("Failed to retract orphaned plugin assignments", reason: inspect(error))

        socket
        |> assign_orphaned_assignments()
        |> put_flash(:error, "Failed to retract orphaned assignments")
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <Shell.settings_chrome
        current_path={@current_path || @plugins_base_path}
        current_scope={@current_scope}
        active_view={@settings_active_view}
        active_category={@settings_active_category}
        breadcrumbs={@settings_breadcrumbs}
        nav_tree={@settings_nav_tree}
        palette={@settings_palette}
        stats={@settings_stats}
      >
        <.plugins_nav
          active={:installed}
          base_path={@plugins_base_path}
          can_stage_plugins={@can_stage_plugins}
        >
          <:actions>
            <.ui_button variant="ghost" size="sm" phx-click="refresh">
              <.icon name="hero-arrow-path" class="size-4" /> Refresh
            </.ui_button>
          </:actions>
        </.plugins_nav>

        <OrphanedAssignments.panel orphans={@orphaned_assignments} />

        <.ui_panel id="installed-plugins">
          <:header>
            <div>
              <div class="text-sm font-semibold">Installed plugins</div>
              <p class="text-xs text-sr-muted">
                <%= if @loaded? do %>
                  {@plugins_total} plugin(s). Each row covers every version of one plugin.
                <% else %>
                  Loading plugins…
                <% end %>
              </p>
            </div>
          </:header>

          <div class="sr-ui-table-shell">
            <table class={ui_table_class(size: "sm")}>
              <thead>
                <tr class="text-xs uppercase tracking-wide text-sr-muted">
                  <th>Plugin</th>
                  <th>Running</th>
                  <th>Latest approved</th>
                  <th>Update policy</th>
                  <th>Assignments</th>
                  <th>Health</th>
                  <th>Owners</th>
                  <th></th>
                </tr>
              </thead>
              <tbody id="installed-plugins-rows" phx-update="stream">
                <tr id="installed-plugins-empty" class="hidden only:table-row">
                  <td colspan="8" class="py-6 text-center text-xs text-sr-muted">
                    {if @loaded?, do: "No plugins imported yet.", else: "Loading plugins…"}
                  </td>
                </tr>
                <tr
                  :for={{dom_id, plugin} <- @streams.plugins}
                  id={dom_id}
                  class="hover:bg-sr-subtle/30"
                >
                  <td>
                    <div class="font-medium">{plugin.name}</div>
                    <div class="text-xs text-sr-muted font-mono">{plugin.plugin_id}</div>
                  </td>
                  <td class="text-xs">
                    <span :if={plugin.running_versions == []} class="text-sr-muted">—</span>
                    <div :for={running <- plugin.running_versions} class="whitespace-nowrap">
                      {running.version || "unknown"}
                      <span class="text-sr-muted">× {running.assignments}</span>
                    </div>
                  </td>
                  <td class="text-xs">
                    <div>{(plugin.latest_approved && plugin.latest_approved.version) || "—"}</div>
                    <.ui_badge
                      :if={plugin.awaiting_review?}
                      id={"installed-plugin-#{dom_id_segment(plugin.plugin_id)}-awaiting-review"}
                      variant="warning"
                      size="xs"
                    >
                      {plugin.newest_staged.version} awaiting review
                    </.ui_badge>
                  </td>
                  <td class="text-xs whitespace-nowrap">
                    {update_policy_label(plugin.update_policies)}
                  </td>
                  <td class="text-xs">
                    <div>{plugin.assignments.enabled} enabled</div>
                    <div
                      :if={plugin.assignments.behind_latest > 0}
                      id={"installed-plugin-#{dom_id_segment(plugin.plugin_id)}-behind"}
                      class="text-warning"
                    >
                      {plugin.assignments.behind_latest} behind latest
                    </div>
                    <div :if={plugin.assignments.disabled > 0} class="text-sr-muted">
                      {plugin.assignments.disabled} disabled
                    </div>
                  </td>
                  <td>
                    <.ui_badge variant={health_variant(plugin.health.status)} size="xs">
                      {health_label(plugin.health.status)}
                    </.ui_badge>
                  </td>
                  <td class="text-xs">
                    <div :if={plugin.owners.manual > 0}>Manual × {plugin.owners.manual}</div>
                    <div :for={policy <- plugin.owners.target_policies}>
                      Policy {policy.name || policy.id}
                      <span class="text-sr-muted">× {policy.assignments}</span>
                    </div>
                    <div :for={rule <- plugin.owners.credential_rules}>
                      <.link href={rule.href} class="text-sr-brand hover:underline">Credential rule</.link>
                      <span class="text-sr-muted">× {rule.assignments}</span>
                    </div>
                  </td>
                  <td>
                    <.ui_button
                      :if={plugin.primary_package_id}
                      variant="ghost"
                      size="xs"
                      navigate={plugins_show_path(@plugins_base_path, plugin.primary_package_id)}
                    >
                      View
                    </.ui_button>
                  </td>
                </tr>
              </tbody>
            </table>
            <.pagination_controls
              id_prefix="installed-plugins"
              event="plugins_page"
              page={@plugins_page}
              total_items={@plugins_total}
              page_size={@plugins_page_size}
            />
          </div>
        </.ui_panel>
      </Shell.settings_chrome>
    </Layouts.app>
    """
  end

  defp update_policy_label(%{track_latest_approved: 0, pinned: 0}), do: "—"

  defp update_policy_label(%{track_latest_approved: tracking, pinned: pinned}) do
    [tracking > 0 && "#{tracking} tracking latest", pinned > 0 && "#{pinned} pinned"]
    |> Enum.filter(& &1)
    |> Enum.join(" · ")
  end

  defp health_variant("healthy"), do: "success"
  defp health_variant("action_required"), do: "error"
  defp health_variant("unavailable"), do: "warning"
  defp health_variant(_status), do: "ghost"

  defp health_label("healthy"), do: "Healthy"
  defp health_label("action_required"), do: "Action required"
  defp health_label("unavailable"), do: "Unavailable"
  defp health_label(_status), do: "Not assigned"
end
