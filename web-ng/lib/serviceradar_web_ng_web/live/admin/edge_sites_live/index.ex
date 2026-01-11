defmodule ServiceRadarWebNGWeb.Admin.EdgeSitesLive.Index do
  @moduledoc """
  LiveView for managing edge sites and NATS operations.

  Tenant admin view for:
  - Creating edge sites (deployment locations)
  - Viewing NATS leaf server status
  - Reviewing NATS operator and tenant account health
  - Downloading configuration bundles
  - Managing site-specific collectors
  """
  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.SettingsComponents

  require Ash.Query

  alias ServiceRadar.Edge.EdgeSite
  alias ServiceRadar.Identity.Tenant
  alias ServiceRadar.Infrastructure.NatsOperator

  @impl true
  def mount(_params, _session, socket) do
    tenant_id = get_tenant_id(socket)

    socket =
      socket
      |> assign(:page_title, "Edge Sites & NATS")
      |> assign(:show_create_modal, false)
      |> assign(:filter_status, nil)
      |> assign(:nats_filter_status, nil)
      |> load_sites(tenant_id)
      |> load_operator_status()
      |> load_tenant_accounts()

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

  def handle_event("filter_nats_tenants", %{"status" => status}, socket) do
    {:noreply,
     socket
     |> assign(:nats_filter_status, if(status == "", do: nil, else: status))
     |> load_tenant_accounts()}
  end

  def handle_event("reprovision_nats", %{"id" => tenant_id}, socket) do
    case reprovision_tenant(tenant_id) do
      {:ok, _} ->
        {:noreply,
         socket
         |> load_tenant_accounts()
         |> put_flash(:info, "Reprovisioning job enqueued")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Tenant not found")}

      {:error, :not_retriable} ->
        {:noreply, put_flash(socket, :error, "Tenant is not in a retriable state")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to enqueue reprovisioning")}
    end
  end

  def handle_event("refresh", _params, socket) do
    tenant_id = get_tenant_id(socket)

    {:noreply,
     socket
     |> load_sites(tenant_id)
     |> load_operator_status()
     |> load_tenant_accounts()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.settings_shell current_path="/admin/edge-sites">
        <.settings_nav current_path="/admin/edge-sites" />
        <.edge_nav current_path="/admin/edge-sites" class="mt-2" />

        <div class="flex flex-wrap items-center justify-between gap-4">
          <div>
            <h1 class="text-2xl font-semibold text-base-content">Edge Sites & NATS</h1>
            <p class="text-sm text-base-content/60">
              Manage edge sites, NATS leaf deployments, and tenant NATS accounts.
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

        <div class="space-y-4">
          <div>
            <div class="text-sm font-semibold">NATS Administration</div>
            <p class="text-xs text-base-content/60">
              Operator status and tenant account provisioning across the fleet.
            </p>
          </div>

          <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
            <.operator_status_card operator={@operator} />
            <.system_account_card operator={@operator} />
          </div>
        </div>

        <.ui_panel>
          <:header>
            <div>
              <div class="text-sm font-semibold">Tenant NATS Accounts</div>
              <p class="text-xs text-base-content/60">
                {@tenants |> length()} tenant(s)
              </p>
            </div>
            <div class="flex gap-2">
              <select
                name="status"
                class="select select-sm select-bordered"
                phx-change="filter_nats_tenants"
              >
                <option value="">All Statuses</option>
                <option value="pending" selected={@nats_filter_status == "pending"}>Pending</option>
                <option value="ready" selected={@nats_filter_status == "ready"}>Ready</option>
                <option value="error" selected={@nats_filter_status == "error"}>Error</option>
              </select>
            </div>
          </:header>

          <div class="overflow-x-auto">
            <%= if @tenants == [] do %>
              <div class="rounded-xl border border-dashed border-base-200 bg-base-100 p-8 text-center">
                <div class="text-sm font-semibold text-base-content">No tenants found</div>
                <p class="mt-1 text-xs text-base-content/60">
                  Tenants will appear here once created.
                </p>
              </div>
            <% else %>
              <table class="table table-sm">
                <thead>
                  <tr class="text-xs uppercase tracking-wide text-base-content/60">
                    <th>Tenant</th>
                    <th>NATS Status</th>
                    <th>Account Public Key</th>
                    <th>Provisioned</th>
                    <th></th>
                  </tr>
                </thead>
                <tbody>
                  <%= for tenant <- @tenants do %>
                    <tr
                      class="hover:bg-base-200/30 cursor-pointer"
                      phx-click={JS.navigate(~p"/admin/nats/tenants/#{tenant.id}")}
                    >
                      <td>
                        <div class="font-medium text-primary hover:underline">{tenant.name}</div>
                        <div class="text-xs text-base-content/60">{tenant.slug}</div>
                      </td>
                      <td>
                        <.nats_status_badge status={tenant.nats_account_status} />
                      </td>
                      <td class="font-mono text-xs">
                        <%= if tenant.nats_account_public_key do %>
                          {String.slice(tenant.nats_account_public_key, 0, 12)}...
                        <% else %>
                          <span class="text-base-content/40">-</span>
                        <% end %>
                      </td>
                      <td class="text-xs text-base-content/70">
                        {format_datetime(tenant.nats_account_provisioned_at)}
                      </td>
                      <td>
                        <div class="flex gap-1">
                          <%= if tenant.nats_account_status in [:error, :pending, :failed] do %>
                            <.ui_button
                              variant="ghost"
                              size="xs"
                              phx-click="reprovision_nats"
                              phx-value-id={tenant.id}
                            >
                              <.icon name="hero-arrow-path" class="size-3" /> Retry
                            </.ui_button>
                          <% end %>
                          <.link
                            navigate={~p"/admin/nats/tenants/#{tenant.id}"}
                            class="btn btn-ghost btn-xs"
                          >
                            <.icon name="hero-eye" class="size-3" /> View
                          </.link>
                        </div>
                      </td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            <% end %>
          </div>
        </.ui_panel>
      </.settings_shell>

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

  defp operator_status_card(assigns) do
    ~H"""
    <.ui_panel>
      <:header>
        <div class="flex items-center gap-2">
          <.icon name="hero-server-stack" class="size-5 text-primary" />
          <span class="font-semibold">Operator Status</span>
        </div>
      </:header>

      <%= if @operator do %>
        <div class="space-y-3">
          <div class="flex items-center gap-2">
            <.nats_status_badge status={@operator.status} />
            <span class="text-sm">{@operator.name}</span>
          </div>

          <div class="grid grid-cols-2 gap-4 text-sm">
            <div>
              <div class="text-xs uppercase tracking-wide text-base-content/60">Public Key</div>
              <code class="text-xs font-mono">
                <%= if @operator.public_key do %>
                  {String.slice(@operator.public_key, 0, 16)}...
                <% else %>
                  <span class="text-base-content/40">Not set</span>
                <% end %>
              </code>
            </div>
            <div>
              <div class="text-xs uppercase tracking-wide text-base-content/60">Bootstrapped</div>
              <span class="text-xs">{format_datetime(@operator.bootstrapped_at)}</span>
            </div>
          </div>

          <%= if @operator.error_message do %>
            <div class="alert alert-error text-xs">
              <.icon name="hero-exclamation-triangle" class="size-4" />
              {@operator.error_message}
            </div>
          <% end %>
        </div>
      <% else %>
        <div class="text-center py-6">
          <div class="inline-flex items-center justify-center w-12 h-12 rounded-full bg-warning/10 mb-3">
            <.icon name="hero-exclamation-triangle" class="size-6 text-warning" />
          </div>
          <div class="text-sm font-semibold">Not Initialized</div>
          <p class="text-xs text-base-content/60 mt-1">
            Generate a bootstrap token and run the CLI to initialize.
          </p>
        </div>
      <% end %>
    </.ui_panel>
    """
  end

  defp system_account_card(assigns) do
    ~H"""
    <.ui_panel>
      <:header>
        <div class="flex items-center gap-2">
          <.icon name="hero-cog-6-tooth" class="size-5 text-secondary" />
          <span class="font-semibold">System Account</span>
        </div>
      </:header>

      <%= if @operator && @operator.system_account_public_key do %>
        <div class="space-y-3">
          <div class="flex items-center gap-2">
            <.ui_badge variant="success" size="sm">Active</.ui_badge>
          </div>

          <div>
            <div class="text-xs uppercase tracking-wide text-base-content/60">Public Key</div>
            <code class="text-xs font-mono">
              {String.slice(@operator.system_account_public_key, 0, 16)}...
            </code>
          </div>

          <p class="text-xs text-base-content/60">
            The system account is used for internal NATS server operations
            like monitoring and administration.
          </p>
        </div>
      <% else %>
        <div class="text-center py-6">
          <div class="inline-flex items-center justify-center w-12 h-12 rounded-full bg-base-200 mb-3">
            <.icon name="hero-cog-6-tooth" class="size-6 text-base-content/40" />
          </div>
          <div class="text-sm font-semibold text-base-content/60">Not Configured</div>
          <p class="text-xs text-base-content/40 mt-1">
            System account will be created during bootstrap.
          </p>
        </div>
      <% end %>
    </.ui_panel>
    """
  end

  defp nats_status_badge(assigns) do
    status = assigns.status

    {variant, label} =
      case status do
        :ready -> {"success", "Ready"}
        :pending -> {"warning", "Pending"}
        :error -> {"error", "Error"}
        :failed -> {"error", "Failed"}
        nil -> {"ghost", "Not Set"}
        other -> {"ghost", to_string(other)}
      end

    assigns = assigns |> assign(:variant, variant) |> assign(:label, label)

    ~H"""
    <.ui_badge variant={@variant} size="xs">{@label}</.ui_badge>
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

  defp load_operator_status(socket) do
    operator =
      case NatsOperator
           |> Ash.Query.for_read(:get_current)
           |> Ash.Query.limit(1)
           |> Ash.read_one(authorize?: false) do
        {:ok, operator} -> operator
        {:error, _} -> nil
      end

    assign(socket, :operator, operator)
  end

  defp load_tenant_accounts(socket) do
    filter_status = socket.assigns[:nats_filter_status]

    query =
      Tenant
      |> Ash.Query.for_read(:for_nats_provisioning)
      |> Ash.Query.select([
        :id,
        :slug,
        :name,
        :nats_account_status,
        :nats_account_public_key,
        :nats_account_provisioned_at
      ])
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.Query.limit(100)

    query =
      if filter_status do
        status_atom = String.to_existing_atom(filter_status)
        Ash.Query.filter(query, nats_account_status == ^status_atom)
      else
        query
      end

    tenants =
      case Ash.read(query, authorize?: false) do
        {:ok, tenants} -> tenants
        {:error, _} -> []
      end

    assign(socket, :tenants, tenants)
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

  defp reprovision_tenant(tenant_id) do
    with {:ok, tenant} <- get_tenant(tenant_id),
         :ok <- validate_retriable(tenant) do
      ServiceRadar.NATS.Workers.CreateAccountWorker.enqueue(tenant_id)
    end
  end

  defp get_tenant(tenant_id) do
    case Tenant
         |> Ash.Query.for_read(:for_nats_provisioning)
         |> Ash.Query.filter(id == ^tenant_id)
         |> Ash.read_one(authorize?: false) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, tenant} -> {:ok, tenant}
      {:error, error} -> {:error, error}
    end
  end

  defp validate_retriable(tenant) do
    if tenant.nats_account_status in [:error, :pending, :failed] do
      :ok
    else
      {:error, :not_retriable}
    end
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
