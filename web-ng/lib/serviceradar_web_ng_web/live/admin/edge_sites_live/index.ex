defmodule ServiceRadarWebNGWeb.Admin.EdgeSitesLive.Index do
  @moduledoc """
  LiveView for managing edge sites and NATS leaf server deployments.

  Tenant admin view for:
  - Creating edge sites (deployment locations)
  - Viewing NATS leaf server status
  - Downloading configuration bundles
  - Managing site-specific collectors
  """
  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.AdminComponents

  require Ash.Query

  alias ServiceRadar.Edge.EdgeSite

  @impl true
  def mount(_params, _session, socket) do
    tenant_id = get_tenant_id(socket)

    socket =
      socket
      |> assign(:page_title, "Edge Sites")
      |> assign(:show_create_modal, false)
      |> assign(:filter_status, nil)
      |> load_sites(tenant_id)

    {:ok, socket}
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
    tenant_id = get_tenant_id(socket)

    name = params["name"]
    slug = params["slug"]
    nats_leaf_url = params["nats_leaf_url"]

    case create_site(tenant_id, name, slug, nats_leaf_url) do
      {:ok, site} ->
        {:noreply,
         socket
         |> assign(:show_create_modal, false)
         |> load_sites(tenant_id)
         |> put_flash(:info, "Edge site '#{site.name}' created successfully")
         |> push_navigate(to: ~p"/admin/edge-sites/#{site.id}")}

      {:error, changeset} ->
        error_msg = format_errors(changeset)
        {:noreply, put_flash(socket, :error, "Failed to create site: #{error_msg}")}
    end
  end

  def handle_event("filter", params, socket) do
    tenant_id = get_tenant_id(socket)
    status = params["status"]

    {:noreply,
     socket
     |> assign(:filter_status, if(status == "", do: nil, else: status))
     |> load_sites(tenant_id)}
  end

  def handle_event("refresh", _params, socket) do
    tenant_id = get_tenant_id(socket)
    {:noreply, load_sites(socket, tenant_id)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-6xl p-6 space-y-6">
        <.admin_nav current_path="/admin/edge-sites" />

        <div class="flex flex-wrap items-center justify-between gap-4">
          <div>
            <h1 class="text-2xl font-semibold text-base-content">Edge Sites</h1>
            <p class="text-sm text-base-content/60">
              Manage NATS leaf server deployments in your edge network.
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
              <p class="text-xs text-base-content/60">
                {@sites |> length()} site(s)
              </p>
            </div>
            <div class="flex gap-2">
              <select
                name="status"
                class="select select-sm select-bordered"
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
              <div class="rounded-xl border border-dashed border-base-200 bg-base-100 p-8 text-center">
                <div class="inline-flex items-center justify-center w-12 h-12 rounded-full bg-primary/10 mb-4">
                  <.icon name="hero-building-office-2" class="size-6 text-primary" />
                </div>
                <div class="text-sm font-semibold text-base-content">No edge sites</div>
                <p class="mt-1 text-xs text-base-content/60">
                  Create an edge site to deploy a NATS leaf server in your network.
                </p>
                <div class="mt-4">
                  <.ui_button variant="primary" size="sm" phx-click="open_create_modal">
                    Create Edge Site
                  </.ui_button>
                </div>
              </div>
            <% else %>
              <table class="table table-sm">
                <thead>
                  <tr class="text-xs uppercase tracking-wide text-base-content/60">
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
                    <tr class="hover:bg-base-200/30">
                      <td>
                        <div class="font-medium">{site.name}</div>
                        <div class="text-xs text-base-content/60 font-mono">{site.slug}</div>
                      </td>
                      <td>
                        <.site_status_badge status={site.status} />
                      </td>
                      <td>
                        <.leaf_status site={site} />
                      </td>
                      <td class="text-xs text-base-content/70">
                        {format_relative_time(site.last_seen_at)}
                      </td>
                      <td class="text-xs text-base-content/70">
                        {format_datetime(site.inserted_at)}
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
      </div>

      <.create_modal :if={@show_create_modal} />
    </Layouts.app>
    """
  end

  defp info_card(assigns) do
    ~H"""
    <div class="alert alert-info">
      <.icon name="hero-information-circle" class="size-5" />
      <div>
        <div class="font-semibold">Edge NATS Leaf Deployment</div>
        <div class="text-xs text-base-content/70">
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
    <dialog id="create_modal" class="modal modal-open">
      <div class="modal-box">
        <form method="dialog">
          <button
            class="btn btn-sm btn-circle btn-ghost absolute right-2 top-2"
            phx-click="close_create_modal"
          >
            x
          </button>
        </form>

        <h3 class="text-lg font-bold">Create Edge Site</h3>
        <p class="py-2 text-sm text-base-content/70">
          Create a new edge site to deploy a NATS leaf server in your network.
        </p>

        <form phx-submit="create_site" class="mt-4 space-y-4">
          <div class="form-control">
            <label class="label">
              <span class="label-text">Site Name</span>
            </label>
            <input
              type="text"
              name="name"
              class="input input-bordered w-full"
              placeholder="e.g., NYC Office, Factory Floor 3"
              required
            />
          </div>

          <div class="form-control">
            <label class="label">
              <span class="label-text">Slug</span>
            </label>
            <input
              type="text"
              name="slug"
              class="input input-bordered w-full font-mono"
              placeholder="e.g., nyc-office, factory-3"
              pattern="[a-z0-9][a-z0-9\-]*[a-z0-9]|[a-z0-9]"
            />
            <label class="label">
              <span class="label-text-alt text-base-content/60">
                Lowercase letters, numbers, and dashes only. Leave blank to auto-generate.
              </span>
            </label>
          </div>

          <div class="form-control">
            <label class="label">
              <span class="label-text">Local NATS URL (optional)</span>
            </label>
            <input
              type="text"
              name="nats_leaf_url"
              class="input input-bordered w-full font-mono"
              placeholder="e.g., nats://10.0.1.50:4222"
            />
            <label class="label">
              <span class="label-text-alt text-base-content/60">
                The URL collectors will use to connect to the local NATS leaf.
                Update after deployment if unknown.
              </span>
            </label>
          </div>

          <div class="modal-action">
            <button type="button" class="btn" phx-click="close_create_modal">Cancel</button>
            <button type="submit" class="btn btn-primary">Create Site</button>
          </div>
        </form>
      </div>
      <form method="dialog" class="modal-backdrop">
        <button phx-click="close_create_modal">close</button>
      </form>
    </dialog>
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
            <span class="loading loading-spinner loading-xs"></span>
            <span class="text-xs">Provisioning</span>
          <% _ -> %>
            <span class="status status-neutral"></span>
            <span class="text-xs">Unknown</span>
        <% end %>
      </div>
    <% else %>
      <span class="text-xs text-base-content/50">-</span>
    <% end %>
    """
  end

  # Data loading

  defp load_sites(socket, tenant_id) do
    filter_status = socket.assigns[:filter_status]

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
      case Ash.read(query, tenant: tenant_id, authorize?: false) do
        {:ok, sites} -> sites
        {:error, _} -> []
      end

    assign(socket, :sites, sites)
  end

  # Actions

  defp create_site(tenant_id, name, slug, nats_leaf_url) do
    attrs = %{name: name}
    attrs = if slug && slug != "", do: Map.put(attrs, :slug, slug), else: attrs

    attrs =
      if nats_leaf_url && nats_leaf_url != "",
        do: Map.put(attrs, :nats_leaf_url, nats_leaf_url),
        else: attrs

    EdgeSite
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.Changeset.force_change_attribute(:tenant_id, tenant_id)
    |> Ash.create(authorize?: false)
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

  defp get_tenant_id(socket) do
    case socket.assigns[:current_scope] do
      %{user: %{tenant_id: tenant_id}} when not is_nil(tenant_id) -> tenant_id
      _ -> nil
    end
  end

  defp format_datetime(nil), do: "-"

  defp format_datetime(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  end

  defp format_datetime(%NaiveDateTime{} = dt) do
    dt
    |> DateTime.from_naive!("Etc/UTC")
    |> format_datetime()
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
