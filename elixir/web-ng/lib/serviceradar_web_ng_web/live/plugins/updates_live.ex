defmodule ServiceRadarWebNGWeb.Plugins.UpdatesLive do
  @moduledoc """
  Updates view of the Wasm plugin pages: imported package versions, filtered by
  status and source. It opens on staged packages, the ones awaiting review;
  review itself happens on the package page (`Plugins.ShowLive`).

  The package list is read once the socket is connected; the disconnected
  render does no database work.
  """

  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.Plugins.Components

  alias ServiceRadarWebNG.Plugins.Packages
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.Settings.Shell

  @package_page_size 10

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if RBAC.can?(scope, "plugins.view") do
      {:ok,
       socket
       |> assign(:can_stage_plugins, RBAC.can?(scope, "plugins.stage"))
       |> assign(:page_title, "Plugin updates")
       |> assign(:current_path, nil)
       |> assign(:plugins_base_path, "/admin/plugins")
       |> assign(:loaded?, false)
       |> assign(:packages, [])
       |> assign(:package_page, 1)
       |> assign(:package_page_size, @package_page_size)
       |> assign(:filter_status, "staged")
       |> assign(:filter_source_type, nil)}
    else
      {:ok,
       socket
       |> put_flash(:error, "You don't have permission to access Plugins.")
       |> redirect(to: ~p"/dashboard")}
    end
  end

  @impl true
  def handle_params(_params, url, socket) do
    socket =
      socket
      |> assign(:current_path, current_path_from_url(url))
      |> assign(:plugins_base_path, plugins_base_path_from_url(url))

    if connected?(socket) and not socket.assigns.loaded? do
      {:noreply, socket |> assign(:loaded?, true) |> load_packages()}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("filter", params, socket) do
    {:noreply,
     socket
     |> assign(:filter_status, normalize_filter(Map.get(params, "status", socket.assigns.filter_status)))
     |> assign(
       :filter_source_type,
       normalize_filter(Map.get(params, "source_type", socket.assigns.filter_source_type))
     )
     |> assign(:package_page, 1)
     |> load_packages()}
  end

  def handle_event("package_page", %{"page" => page}, socket) do
    page = clamp_page(page, length(socket.assigns.packages), socket.assigns.package_page_size)

    {:noreply, assign(socket, :package_page, page)}
  end

  def handle_event("refresh", _params, socket) do
    {:noreply, load_packages(socket)}
  end

  defp load_packages(socket) do
    filters =
      %{}
      |> maybe_put_filter("status", socket.assigns.filter_status)
      |> maybe_put_filter("source_type", socket.assigns.filter_source_type)

    assign(socket, :packages, Packages.list(filters, scope: socket.assigns.current_scope))
  end

  defp maybe_put_filter(filters, _key, nil), do: filters
  defp maybe_put_filter(filters, key, value), do: Map.put(filters, key, value)

  defp normalize_filter(nil), do: nil
  defp normalize_filter(""), do: nil
  defp normalize_filter(value) when is_binary(value), do: value
  defp normalize_filter(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_filter(_), do: nil

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
          active={:updates}
          base_path={@plugins_base_path}
          can_stage_plugins={@can_stage_plugins}
        >
          <:actions>
            <.ui_button variant="ghost" size="sm" phx-click="refresh">
              <.icon name="hero-arrow-path" class="size-4" /> Refresh
            </.ui_button>
          </:actions>
        </.plugins_nav>

        <.ui_panel id="imported-plugin-packages">
          <:header>
            <div>
              <div class="text-sm font-semibold">Imported packages</div>
              <p class="text-xs text-sr-muted">
                {length(@packages)} package(s) match. Staged packages are awaiting review; open one to approve or deny it.
              </p>
            </div>
            <form
              id="filter-imported-plugin-packages"
              phx-change="filter"
              class="flex flex-wrap items-center justify-end gap-2"
            >
              <label for="imported-plugin-status-filter" class="sr-only">Package status</label>
              <select
                id="imported-plugin-status-filter"
                name="status"
                class={ui_field_class(size: "sm")}
              >
                <option value="">All statuses</option>
                <option value="staged" selected={@filter_status == "staged"}>Staged</option>
                <option value="approved" selected={@filter_status == "approved"}>Approved</option>
                <option value="denied" selected={@filter_status == "denied"}>Denied</option>
                <option value="revoked" selected={@filter_status == "revoked"}>Revoked</option>
              </select>
              <label for="imported-plugin-source-filter" class="sr-only">Package source</label>
              <select
                id="imported-plugin-source-filter"
                name="source_type"
                class={ui_field_class(size: "sm")}
              >
                <option value="">All sources</option>
                <option value="upload" selected={@filter_source_type == "upload"}>Upload</option>
                <option value="github" selected={@filter_source_type == "github"}>GitHub</option>
                <option value="first_party" selected={@filter_source_type == "first_party"}>
                  First-party
                </option>
              </select>
            </form>
          </:header>

          <%= if @packages == [] do %>
            <div class="rounded-xl border border-dashed border-sr-line bg-sr-surface p-8 text-center">
              <div class="text-sm font-semibold text-sr-ink">No packages found</div>
              <p class="mt-1 text-xs text-sr-muted">
                Stage a plugin package to begin the review workflow.
              </p>
            </div>
          <% else %>
            <div class="sr-ui-table-shell">
              <table class={ui_table_class(size: "sm")}>
                <thead>
                  <tr class="text-xs uppercase tracking-wide text-sr-muted">
                    <th>Plugin</th>
                    <th>Version</th>
                    <th>Status</th>
                    <th>Source</th>
                    <th>Updated</th>
                    <th></th>
                  </tr>
                </thead>
                <tbody>
                  <%= for package <- paginated_items(@packages, @package_page, @package_page_size) do %>
                    <tr
                      id={"imported-plugin-package-#{package.id}"}
                      class="hover:bg-sr-subtle/30"
                    >
                      <td>
                        <div class="font-medium">{package.name}</div>
                        <div class="text-xs text-sr-muted font-mono">{package.plugin_id}</div>
                      </td>
                      <td class="text-xs">{package.version}</td>
                      <td>
                        <.status_badge status={package.status} />
                      </td>
                      <td>
                        <.ui_badge variant="ghost" size="xs">
                          {package.source_type}
                        </.ui_badge>
                      </td>
                      <td class="text-xs text-sr-muted">
                        <.user_time
                          id={"admin-plugin-package-#{package.id}-updated-at"}
                          value={package.updated_at || package.inserted_at}
                          timezone={@current_scope.user.timezone || "Etc/UTC"}
                          style={:compact}
                        />
                      </td>
                      <td>
                        <.ui_button
                          variant="ghost"
                          size="xs"
                          navigate={plugins_show_path(@plugins_base_path, package.id)}
                        >
                          View
                        </.ui_button>
                      </td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
              <.pagination_controls
                id_prefix="plugin-packages"
                event="package_page"
                page={@package_page}
                total_items={length(@packages)}
                page_size={@package_page_size}
              />
            </div>
          <% end %>
        </.ui_panel>
      </Shell.settings_chrome>
    </Layouts.app>
    """
  end
end
