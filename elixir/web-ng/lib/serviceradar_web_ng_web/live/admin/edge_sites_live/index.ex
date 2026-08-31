defmodule ServiceRadarWebNGWeb.Admin.EdgeSitesLive.Index do
  @moduledoc """
  LiveView for managing edge sites and NATS operations.

  In single-deployment architecture:
  - Creating edge sites (deployment locations)
  - Viewing NATS leaf server status
  - Downloading configuration bundles
  """
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadar.Edge.EdgeSite
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.Settings.Shell

  require Ash.Query

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if RBAC.can?(scope, "settings.edge.manage") do
      socket =
        socket
        |> assign(:page_title, "Edge Sites & NATS")
        |> assign(:show_create_modal, false)
        |> assign(:filter_status, nil)
        |> load_sites()

      {:ok, socket}
    else
      {:ok,
       socket
       |> put_flash(:error, "You don't have permission to access Edge Sites.")
       |> redirect(to: ~p"/dashboard")}
    end
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params), do: socket

  defp apply_action(socket, :new, _params) do
    assign(socket, :show_create_modal, true)
  end

  @impl true
  def handle_event("open_create_modal", _params, socket) do
    {:noreply, assign(socket, :show_create_modal, true)}
  end

  def handle_event("close_create_modal", _params, socket) do
    {:noreply, assign(socket, :show_create_modal, false)}
  end

  def handle_event("create_site", params, socket) do
    actor = get_actor(socket)

    name = params["name"]
    slug = params["slug"]
    nats_leaf_url = params["nats_leaf_url"]

    case create_site(actor, name, slug, nats_leaf_url) do
      {:ok, site} ->
        {:noreply,
         socket
         |> assign(:show_create_modal, false)
         |> load_sites()
         |> put_flash(:info, "Edge site '#{site.name}' created successfully")
         |> push_navigate(to: ~p"/admin/edge-sites/#{site.id}")}

      {:error, changeset} ->
        error_msg = format_errors(changeset)
        {:noreply, put_flash(socket, :error, "Failed to create site: #{error_msg}")}
    end
  end

  def handle_event("filter", params, socket) do
    status = params["status"]

    {:noreply,
     socket
     |> assign(:filter_status, if(status == "", do: nil, else: status))
     |> load_sites()}
  end

  def handle_event("refresh", _params, socket) do
    {:noreply, load_sites(socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <Shell.settings_chrome
        current_path="/admin/edge-sites"
        current_scope={@current_scope}
        active_view={@settings_active_view}
        active_category={@settings_active_category}
        breadcrumbs={@settings_breadcrumbs}
        nav_tree={@settings_nav_tree}
        palette={@settings_palette}
        stats={@settings_stats}
      >
        <div class="flex flex-wrap items-center justify-between gap-4">
          <div>
            <h1 class="text-2xl font-semibold text-sr-ink">Edge Sites & NATS</h1>
            <p class="text-sm text-sr-muted">
              Manage edge sites and NATS leaf deployments.
            </p>
          </div>
          <div class="flex gap-2">
            <.ui_button variant="ghost" size="sm" phx-click="refresh">
              <.icon name="hero-arrow-path" class="size-4" /> Refresh
            </.ui_button>
            <.ui_button variant="primary" size="sm" phx-click="open_create_modal">
              <.icon name="hero-plus" class="size-4" /> New Edge Site
            </.ui_button>
          </div>
        </div>

        <.info_card />

        <.ui_panel>
          <:header>
            <div>
              <div class="text-sm font-semibold">Edge Sites</div>
              <p class="text-xs text-sr-muted">
                {@sites |> length()} site(s)
              </p>
            </div>
            <div class="flex gap-2">
              <select
                name="status"
                class={ui_field_class(size: "sm")}
                phx-change="filter"
              >
                <option value="">All Statuses</option>
                <option value="pending" selected={@filter_status == "pending"}>Pending</option>
                <option value="active" selected={@filter_status == "active"}>Active</option>
                <option value="offline" selected={@filter_status == "offline"}>Offline</option>
              </select>
            </div>
          </:header>

          <div class="overflow-x-auto">
            <%= if @sites == [] do %>
              <div class="rounded-xl border border-dashed border-sr-line bg-sr-surface p-8 text-center">
                <div class="inline-flex items-center justify-center w-12 h-12 rounded-full bg-sr-brand/10 mb-4">
                  <.icon name="hero-building-office-2" class="size-6 text-sr-brand" />
                </div>
                <div class="text-sm font-semibold text-sr-ink">No edge sites</div>
                <p class="mt-1 text-xs text-sr-muted">
                  Create an edge site to deploy a NATS leaf server in your network.
                </p>
                <div class="mt-4">
                  <.ui_button variant="primary" size="sm" phx-click="open_create_modal">
                    Create Edge Site
                  </.ui_button>
                </div>
              </div>
            <% else %>
              <table class={ui_table_class(size: "sm")}>
                <thead>
                  <tr class="text-xs uppercase tracking-wide text-sr-muted">
                    <th>Site</th>
                    <th>Status</th>
                    <th>NATS Leaf</th>
                    <th>Last Seen</th>
                    <th>Created</th>
                    <th></th>
                  </tr>
                </thead>
                <tbody>
                  <%= for site <- @sites do %>
                    <tr class="hover:bg-sr-subtle/30">
                      <td>
                        <div class="font-medium">{site.name}</div>
                        <div class="text-xs text-sr-muted font-mono">{site.slug}</div>
                      </td>
                      <td>
                        <.site_status_badge status={site.status} />
                      </td>
                      <td>
                        <.leaf_status site={site} />
                      </td>
                      <td class="text-xs text-sr-muted">
                        {format_relative_time(site.last_seen_at)}
                      </td>
                      <td class="text-xs text-sr-muted">
                        <.user_time
                          id={"admin-edge-site-#{site.id}-inserted-at"}
                          value={site.inserted_at}
                          timezone={@current_scope.user.timezone || "Etc/UTC"}
                          style={:compact}
                        />
                      </td>
                      <td>
                        <.ui_button
                          variant="ghost"
                          size="xs"
                          navigate={~p"/admin/edge-sites/#{site.id}"}
                        >
                          View
                        </.ui_button>
                      </td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            <% end %>
          </div>
        </.ui_panel>
      </Shell.settings_chrome>

      <.create_modal :if={@show_create_modal} />
    </Layouts.app>
    """
  end

  defp info_card(assigns) do
    ~H"""
    <div class={ui_alert_class("info")}>
      <.icon name="hero-information-circle" class="size-5" />
      <div>
        <div class="font-semibold">Edge NATS Leaf Deployment</div>
        <div class="text-xs text-sr-muted">
          Edge sites deploy NATS leaf servers in your network. Collectors connect to the local
          leaf server for low latency and WAN resilience. The leaf forwards messages to the
          SaaS cluster.
        </div>
      </div>
    </div>
    """
  end

  defp create_modal(assigns) do
    ~H"""
    <.ui_modal id="create_modal" on_cancel="close_create_modal">
      <:title>Create Edge Site</:title>

      <p class="text-sm text-sr-muted">
        Create a new edge site to deploy a NATS leaf server in your network.
      </p>

      <form phx-submit="create_site" class="space-y-4">
        <div class="flex flex-col gap-1.5">
          <label class="flex items-center justify-between gap-2">
            <span class="text-sm font-medium text-sr-ink">Site Name</span>
          </label>
          <input
            type="text"
            name="name"
            class={ui_field_class(class: "w-full")}
            placeholder="e.g., NYC Office, Factory Floor 3"
            required
          />
        </div>

        <div class="flex flex-col gap-1.5">
          <label class="flex items-center justify-between gap-2">
            <span class="text-sm font-medium text-sr-ink">Slug</span>
          </label>
          <input
            type="text"
            name="slug"
            class={ui_field_class(mono: true, class: "w-full")}
            placeholder="e.g., nyc-office, factory-3"
            pattern="[a-z0-9][a-z0-9\-]*[a-z0-9]|[a-z0-9]"
          />
          <label class="flex items-center justify-between gap-2">
            <span class="text-xs text-sr-muted">
              Lowercase letters, numbers, and dashes only. Leave blank to auto-generate.
            </span>
          </label>
        </div>

        <div class="flex flex-col gap-1.5">
          <label class="flex items-center justify-between gap-2">
            <span class="text-sm font-medium text-sr-ink">Local NATS URL (optional)</span>
          </label>
          <input
            type="text"
            name="nats_leaf_url"
            class={ui_field_class(mono: true, class: "w-full")}
            placeholder="e.g., nats://10.0.1.50:4222"
          />
          <label class="flex items-center justify-between gap-2">
            <span class="text-xs text-sr-muted">
              The URL collectors will use to connect to the local NATS leaf.
              Update after deployment if unknown.
            </span>
          </label>
        </div>

        <div class="flex justify-end gap-2 pt-1">
          <.ui_button type="button" phx-click="close_create_modal" size="sm" variant="neutral">
            Cancel
          </.ui_button>
          <.ui_button type="submit" size="sm" variant="primary">Create Site</.ui_button>
        </div>
      </form>
    </.ui_modal>
    """
  end

  defp site_status_badge(assigns) do
    variant =
      case assigns.status do
        :pending -> "warning"
        :active -> "success"
        :offline -> "error"
        _ -> "ghost"
      end

    assigns = assign(assigns, :variant, variant)

    ~H"""
    <.ui_badge variant={@variant}>{@status}</.ui_badge>
    """
  end

  defp leaf_status(assigns) do
    leaf_server = Enum.find(assigns.site.nats_leaf_server || [], & &1)

    assigns = assign(assigns, :leaf_server, leaf_server)

    ~H"""
    <%= if @leaf_server do %>
      <div class="flex items-center gap-2">
        <%= case @leaf_server.status do %>
          <% :connected -> %>
            <span class="status status-success"></span>
            <span class="text-xs">Connected</span>
          <% :provisioned -> %>
            <span class="status status-warning"></span>
            <span class="text-xs">Ready</span>
          <% :disconnected -> %>
            <span class="status status-error"></span>
            <span class="text-xs">Disconnected</span>
          <% :pending -> %>
            <.ui_spinner size="xs" />
            <span class="text-xs">Provisioning</span>
          <% _ -> %>
            <span class="status status-neutral"></span>
            <span class="text-xs">Unknown</span>
        <% end %>
      </div>
    <% else %>
      <span class="text-xs text-sr-muted">-</span>
    <% end %>
    """
  end

  # Data loading

  defp load_sites(socket) do
    filter_status = socket.assigns[:filter_status]
    actor = get_actor(socket)

    query =
      EdgeSite
      |> Ash.Query.for_read(:read)
      |> Ash.Query.load(:nats_leaf_server)
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.Query.limit(50)

    query =
      if filter_status do
        status_atom = String.to_existing_atom(filter_status)
        Ash.Query.filter(query, status == ^status_atom)
      else
        query
      end

    sites =
      case Ash.read(query, actor: actor) do
        {:ok, sites} -> sites
        {:error, _} -> []
      end

    assign(socket, :sites, sites)
  end

  # Actions

  defp create_site(actor, name, slug, nats_leaf_url) do
    attrs = %{name: name}
    attrs = if slug && slug != "", do: Map.put(attrs, :slug, slug), else: attrs

    attrs =
      if nats_leaf_url && nats_leaf_url != "",
        do: Map.put(attrs, :nats_leaf_url, nats_leaf_url),
        else: attrs

    EdgeSite
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create(actor: actor)
  end

  defp format_errors(%Ash.Error.Invalid{} = error) do
    Enum.map_join(error.errors, ", ", fn err ->
      case err do
        %{field: field, message: msg} -> "#{field}: #{msg}"
        %{message: msg} -> msg
        _ -> inspect(err)
      end
    end)
  end

  defp format_errors(error), do: inspect(error)

  defp get_actor(socket) do
    case socket.assigns[:current_scope] do
      %{user: user} when not is_nil(user) -> user
      _ -> nil
    end
  end

  defp format_relative_time(nil), do: "Never"

  defp format_relative_time(%DateTime{} = dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      diff < 60 -> "#{diff}s ago"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86_400 -> "#{div(diff, 3600)}h ago"
      true -> "#{div(diff, 86_400)}d ago"
    end
  end
end
