defmodule ServiceRadarWebNGWeb.Admin.CollectorLive.Index do
  @moduledoc """
  LiveView for managing collector packages.

  Tenant admin view for:
  - Creating collector packages (flowgger, trapd, netflow, otel)
  - Viewing issued NATS credentials
  - Revoking collector credentials
  """
  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.AdminComponents

  require Ash.Query

  alias ServiceRadar.Edge.CollectorPackage
  alias ServiceRadar.Edge.NatsCredential
  alias ServiceRadar.Identity.Tenant
  alias ServiceRadarWebNG.Collectors.PubSub, as: CollectorPubSub

  @collector_types [
    {"Syslog Collector (Flowgger)", :flowgger},
    {"SNMP Trap Receiver", :trapd},
    {"NetFlow Collector", :netflow},
    {"OpenTelemetry Collector", :otel}
  ]

  @impl true
  def mount(_params, _session, socket) do
    tenant_id = get_tenant_id(socket)

    # Subscribe to real-time updates for this tenant's collectors
    if connected?(socket) and tenant_id do
      CollectorPubSub.subscribe_tenant_collectors(tenant_id)
      CollectorPubSub.subscribe_tenant_nats(tenant_id)
    end

    socket =
      socket
      |> assign(:page_title, "Collectors")
      |> assign(:collector_types, @collector_types)
      |> assign(:show_create_modal, false)
      |> assign(:show_details_modal, false)
      |> assign(:selected_package, nil)
      |> assign(:created_package, nil)
      |> assign(:created_download_token, nil)
      |> assign(:filter_status, nil)
      |> assign(:filter_type, nil)
      |> load_tenant_status(tenant_id)
      |> load_packages(tenant_id)
      |> load_credentials(tenant_id)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params), do: socket

  defp apply_action(socket, :show, %{"id" => id}) do
    tenant_id = get_tenant_id(socket)

    case get_package(id, tenant_id) do
      {:ok, package} ->
        socket
        |> assign(:selected_package, package)
        |> assign(:show_details_modal, true)

      {:error, :not_found} ->
        socket
        |> put_flash(:error, "Package not found")
        |> push_navigate(to: ~p"/admin/collectors")
    end
  end

  @impl true
  def handle_event("open_create_modal", _params, socket) do
    {:noreply, assign(socket, :show_create_modal, true)}
  end

  def handle_event("close_create_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_create_modal, false)
     |> assign(:created_package, nil)
     |> assign(:created_download_token, nil)}
  end

  def handle_event("close_details_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_details_modal, false)
     |> assign(:selected_package, nil)}
  end

  def handle_event("create_package", params, socket) do
    tenant_id = get_tenant_id(socket)

    collector_type = params["collector_type"]
    site = params["site"]
    hostname = params["hostname"]

    case create_package(tenant_id, collector_type, site, hostname) do
      {:ok, package, download_token} ->
        {:noreply,
         socket
         |> assign(:created_package, package)
         |> assign(:created_download_token, download_token)
         |> load_packages(tenant_id)
         |> put_flash(:info, "Collector package created")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to create package")}
    end
  end

  def handle_event("revoke_package", %{"id" => id}, socket) do
    tenant_id = get_tenant_id(socket)

    case revoke_package(id, tenant_id) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:show_details_modal, false)
         |> assign(:selected_package, nil)
         |> load_packages(tenant_id)
         |> load_credentials(tenant_id)
         |> put_flash(:info, "Package revoked")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to revoke package")}
    end
  end

  def handle_event("filter", params, socket) do
    tenant_id = get_tenant_id(socket)
    status = params["status"]
    type = params["collector_type"]

    {:noreply,
     socket
     |> assign(:filter_status, if(status == "", do: nil, else: status))
     |> assign(:filter_type, if(type == "", do: nil, else: type))
     |> load_packages(tenant_id)}
  end

  def handle_event("copy_token", %{"token" => token}, socket) do
    {:noreply,
     socket
     |> push_event("clipboard", %{text: token})
     |> put_flash(:info, "Copied to clipboard")}
  end

  def handle_event("refresh", _params, socket) do
    tenant_id = get_tenant_id(socket)

    {:noreply,
     socket
     |> load_tenant_status(tenant_id)
     |> load_packages(tenant_id)
     |> load_credentials(tenant_id)}
  end

  # PubSub event handlers for real-time updates

  @impl true
  def handle_info({:package_created, _package}, socket) do
    tenant_id = get_tenant_id(socket)
    {:noreply, load_packages(socket, tenant_id)}
  end

  def handle_info({:package_updated, _package, _old_status, _new_status}, socket) do
    tenant_id = get_tenant_id(socket)

    {:noreply,
     socket
     |> load_packages(tenant_id)
     |> put_flash(:info, "Package status updated")}
  end

  def handle_info({:package_revoked, _package}, socket) do
    tenant_id = get_tenant_id(socket)

    {:noreply,
     socket
     |> load_packages(tenant_id)
     |> load_credentials(tenant_id)
     |> put_flash(:info, "Package revoked")}
  end

  def handle_info({:credential_created, _credential}, socket) do
    tenant_id = get_tenant_id(socket)
    {:noreply, load_credentials(socket, tenant_id)}
  end

  def handle_info({:credential_revoked, _credential}, socket) do
    tenant_id = get_tenant_id(socket)
    {:noreply, load_credentials(socket, tenant_id)}
  end

  def handle_info({:tenant_nats_updated, _tenant_id, _status}, socket) do
    tenant_id = get_tenant_id(socket)
    {:noreply, load_tenant_status(socket, tenant_id)}
  end

  # Catch-all for unhandled messages
  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-6xl p-6 space-y-6">
        <.admin_nav current_path="/admin/collectors" />

        <div class="flex flex-wrap items-center justify-between gap-4">
          <div>
            <h1 class="text-2xl font-semibold text-base-content">Collectors</h1>
            <p class="text-sm text-base-content/60">
              Manage NATS-connected data collectors for your tenant.
            </p>
          </div>
          <div class="flex gap-2">
            <.ui_button variant="ghost" size="sm" phx-click="refresh">
              <.icon name="hero-arrow-path" class="size-4" /> Refresh
            </.ui_button>
            <.ui_button
              variant="primary"
              size="sm"
              phx-click="open_create_modal"
              disabled={@tenant_status != :ready}
            >
              <.icon name="hero-plus" class="size-4" /> New Collector
            </.ui_button>
          </div>
        </div>

        <.tenant_status_card tenant_status={@tenant_status} tenant_public_key={@tenant_public_key} />

        <.ui_panel>
          <:header>
            <div>
              <div class="text-sm font-semibold">Collector Packages</div>
              <p class="text-xs text-base-content/60">
                {@packages |> length()} package(s)
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
                <option value="ready" selected={@filter_status == "ready"}>Ready</option>
                <option value="downloaded" selected={@filter_status == "downloaded"}>
                  Downloaded
                </option>
                <option value="revoked" selected={@filter_status == "revoked"}>Revoked</option>
              </select>
              <select
                name="collector_type"
                class="select select-sm select-bordered"
                phx-change="filter"
              >
                <option value="">All Types</option>
                <%= for {label, value} <- @collector_types do %>
                  <option value={value} selected={@filter_type == to_string(value)}>{label}</option>
                <% end %>
              </select>
            </div>
          </:header>

          <div class="overflow-x-auto">
            <%= if @packages == [] do %>
              <div class="rounded-xl border border-dashed border-base-200 bg-base-100 p-8 text-center">
                <div class="text-sm font-semibold text-base-content">No collectors found</div>
                <p class="mt-1 text-xs text-base-content/60">
                  <%= if @tenant_status != :ready do %>
                    Your NATS account is being provisioned. Please wait...
                  <% else %>
                    Create a new collector package to start sending data.
                  <% end %>
                </p>
              </div>
            <% else %>
              <table class="table table-sm">
                <thead>
                  <tr class="text-xs uppercase tracking-wide text-base-content/60">
                    <th>Collector</th>
                    <th>Type</th>
                    <th>Status</th>
                    <th>Site</th>
                    <th>Created</th>
                    <th></th>
                  </tr>
                </thead>
                <tbody>
                  <%= for package <- @packages do %>
                    <tr class="hover:bg-base-200/30">
                      <td>
                        <div class="font-medium font-mono text-xs">{package.user_name}</div>
                        <div class="text-xs text-base-content/60">
                          {String.slice(package.id, 0, 8)}...
                        </div>
                      </td>
                      <td>
                        <.collector_type_badge type={package.collector_type} />
                      </td>
                      <td>
                        <.status_badge status={package.status} />
                      </td>
                      <td class="text-xs">{package.site || "-"}</td>
                      <td class="text-xs text-base-content/70">
                        {format_datetime(package.inserted_at)}
                      </td>
                      <td>
                        <div class="flex gap-1">
                          <.ui_button
                            variant="ghost"
                            size="xs"
                            navigate={~p"/admin/collectors/#{package.id}"}
                          >
                            View
                          </.ui_button>
                          <.ui_button
                            :if={package.status in [:pending, :ready, :downloaded]}
                            variant="ghost"
                            size="xs"
                            phx-click="revoke_package"
                            phx-value-id={package.id}
                            data-confirm="Are you sure you want to revoke this collector?"
                          >
                            Revoke
                          </.ui_button>
                        </div>
                      </td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            <% end %>
          </div>
        </.ui_panel>

        <.ui_panel>
          <:header>
            <div class="flex items-center gap-2">
              <.icon name="hero-key" class="size-4 text-secondary" />
              <span class="font-semibold text-sm">NATS Credentials</span>
            </div>
          </:header>

          <%= if @credentials == [] do %>
            <div class="text-center py-4 text-sm text-base-content/60">
              No credentials issued yet.
            </div>
          <% else %>
            <div class="overflow-x-auto">
              <table class="table table-xs">
                <thead>
                  <tr class="text-[11px] uppercase tracking-wide text-base-content/50">
                    <th>User</th>
                    <th>Type</th>
                    <th>Status</th>
                    <th>Issued</th>
                    <th>Expires</th>
                  </tr>
                </thead>
                <tbody>
                  <%= for cred <- @credentials do %>
                    <tr>
                      <td class="font-mono text-xs">{cred.user_name}</td>
                      <td>
                        <.collector_type_badge type={cred.collector_type} size="xs" />
                      </td>
                      <td>
                        <.status_badge status={cred.status} size="xs" />
                      </td>
                      <td class="text-xs">{format_datetime(cred.issued_at)}</td>
                      <td class="text-xs">{format_datetime(cred.expires_at)}</td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            </div>
          <% end %>
        </.ui_panel>
      </div>

      <.create_modal
        :if={@show_create_modal}
        collector_types={@collector_types}
        created_package={@created_package}
        download_token={@created_download_token}
      />

      <.details_modal
        :if={@show_details_modal}
        package={@selected_package}
      />
    </Layouts.app>
    """
  end

  defp tenant_status_card(assigns) do
    ~H"""
    <div class="alert">
      <div class="flex items-center gap-3">
        <%= case @tenant_status do %>
          <% :ready -> %>
            <.icon name="hero-check-circle" class="size-6 text-success" />
            <div>
              <div class="font-semibold">NATS Account Ready</div>
              <div class="text-xs text-base-content/60 font-mono">
                {String.slice(@tenant_public_key || "", 0, 20)}...
              </div>
            </div>
          <% :pending -> %>
            <span class="loading loading-spinner loading-sm"></span>
            <div>
              <div class="font-semibold">Provisioning NATS Account</div>
              <div class="text-xs text-base-content/60">
                Please wait while your account is being set up...
              </div>
            </div>
          <% :error -> %>
            <.icon name="hero-exclamation-triangle" class="size-6 text-error" />
            <div>
              <div class="font-semibold">NATS Account Error</div>
              <div class="text-xs text-base-content/60">
                There was an issue provisioning your account. Please contact support.
              </div>
            </div>
          <% _ -> %>
            <.icon name="hero-clock" class="size-6 text-warning" />
            <div>
              <div class="font-semibold">NATS Account Not Configured</div>
              <div class="text-xs text-base-content/60">
                Your account is being set up.
              </div>
            </div>
        <% end %>
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

        <%= if @created_package do %>
          <div class="text-center">
            <div class="inline-flex items-center justify-center w-16 h-16 rounded-full bg-success/10 mb-4">
              <.icon name="hero-check-circle" class="size-10 text-success" />
            </div>
            <h3 class="text-xl font-bold">Collector Created</h3>
            <p class="text-sm text-base-content/70 mt-1">
              Your collector package is being provisioned.
            </p>
          </div>

          <div class="mt-6 space-y-4">
            <div class="grid grid-cols-2 gap-4 text-sm">
              <div>
                <div class="text-xs uppercase tracking-wide text-base-content/60">User Name</div>
                <code class="font-mono text-xs">{@created_package.user_name}</code>
              </div>
              <div>
                <div class="text-xs uppercase tracking-wide text-base-content/60">Type</div>
                <span>{@created_package.collector_type}</span>
              </div>
            </div>

            <%= if @download_token do %>
              <div class="bg-base-200 rounded-lg p-3">
                <div class="flex items-center justify-between mb-2">
                  <div class="text-xs uppercase tracking-wide text-base-content/60">
                    Download Token
                  </div>
                  <button
                    type="button"
                    class="btn btn-xs btn-ghost"
                    phx-click="copy_token"
                    phx-value-token={@download_token}
                  >
                    <.icon name="hero-clipboard-document" class="size-3" /> Copy
                  </button>
                </div>
                <code class="font-mono text-xs break-all">{@download_token}</code>
              </div>

              <div class="alert alert-warning text-xs">
                <.icon name="hero-exclamation-triangle" class="size-4" />
                <span>
                  <strong>Save this token!</strong> It can only be shown once.
                  Use it to download the package after provisioning completes.
                </span>
              </div>
            <% else %>
              <div class="alert alert-info text-xs">
                <.icon name="hero-information-circle" class="size-4" />
                <span>
                  Credentials are being generated. Check back in a moment to download.
                </span>
              </div>
            <% end %>
          </div>

          <div class="modal-action">
            <button type="button" class="btn btn-primary" phx-click="close_create_modal">
              Done
            </button>
          </div>
        <% else %>
          <h3 class="text-lg font-bold">Create Collector Package</h3>
          <p class="py-2 text-sm text-base-content/70">
            Create a new NATS-connected collector for sending data to the platform.
          </p>

          <form phx-submit="create_package" class="mt-4 space-y-4">
            <div class="form-control">
              <label class="label">
                <span class="label-text">Collector Type</span>
              </label>
              <select name="collector_type" class="select select-bordered w-full" required>
                <%= for {label, value} <- @collector_types do %>
                  <option value={value}>{label}</option>
                <% end %>
              </select>
            </div>

            <div class="form-control">
              <label class="label">
                <span class="label-text">Site (optional)</span>
              </label>
              <input
                type="text"
                name="site"
                class="input input-bordered w-full"
                placeholder="e.g., datacenter-1, office-nyc"
              />
              <label class="label">
                <span class="label-text-alt text-base-content/60">
                  Deployment location for this collector
                </span>
              </label>
            </div>

            <div class="form-control">
              <label class="label">
                <span class="label-text">Hostname (optional)</span>
              </label>
              <input
                type="text"
                name="hostname"
                class="input input-bordered w-full"
                placeholder="e.g., collector-01.example.com"
              />
            </div>

            <div class="modal-action">
              <button type="button" class="btn" phx-click="close_create_modal">Cancel</button>
              <button type="submit" class="btn btn-primary">Create Collector</button>
            </div>
          </form>
        <% end %>
      </div>
      <form method="dialog" class="modal-backdrop">
        <button phx-click="close_create_modal">close</button>
      </form>
    </dialog>
    """
  end

  defp details_modal(assigns) do
    ~H"""
    <dialog id="details_modal" class="modal modal-open">
      <div class="modal-box">
        <form method="dialog">
          <button
            class="btn btn-sm btn-circle btn-ghost absolute right-2 top-2"
            phx-click="close_details_modal"
          >
            x
          </button>
        </form>

        <h3 class="text-lg font-bold">Collector Details</h3>

        <div class="mt-4 space-y-4">
          <div class="grid grid-cols-2 gap-4">
            <div>
              <div class="text-xs uppercase tracking-wide text-base-content/60">User Name</div>
              <code class="font-mono text-sm">{@package.user_name}</code>
            </div>
            <div>
              <div class="text-xs uppercase tracking-wide text-base-content/60">Status</div>
              <.status_badge status={@package.status} />
            </div>
            <div>
              <div class="text-xs uppercase tracking-wide text-base-content/60">Type</div>
              <.collector_type_badge type={@package.collector_type} />
            </div>
            <div>
              <div class="text-xs uppercase tracking-wide text-base-content/60">Site</div>
              <span class="text-sm">{@package.site || "-"}</span>
            </div>
            <div>
              <div class="text-xs uppercase tracking-wide text-base-content/60">Hostname</div>
              <span class="text-sm">{@package.hostname || "-"}</span>
            </div>
            <div>
              <div class="text-xs uppercase tracking-wide text-base-content/60">Created</div>
              <span class="text-sm">{format_datetime(@package.inserted_at)}</span>
            </div>
          </div>

          <div>
            <div class="text-xs uppercase tracking-wide text-base-content/60 mb-1">Package ID</div>
            <code class="text-sm font-mono bg-base-200 p-2 rounded block">{@package.id}</code>
          </div>

          <%= if @package.error_message do %>
            <div class="alert alert-error text-sm">
              <.icon name="hero-exclamation-triangle" class="size-4" />
              {@package.error_message}
            </div>
          <% end %>
        </div>

        <div class="modal-action">
          <%= if @package.status in [:pending, :ready, :downloaded] do %>
            <button
              type="button"
              class="btn btn-warning"
              phx-click="revoke_package"
              phx-value-id={@package.id}
              data-confirm="Are you sure you want to revoke this collector?"
            >
              Revoke
            </button>
          <% end %>
          <button type="button" class="btn" phx-click="close_details_modal">Close</button>
        </div>
      </div>
      <form method="dialog" class="modal-backdrop">
        <button phx-click="close_details_modal">close</button>
      </form>
    </dialog>
    """
  end

  defp status_badge(assigns) do
    size = assigns[:size] || "sm"
    status = assigns.status

    variant =
      case status do
        :pending -> "warning"
        :provisioning -> "info"
        :ready -> "success"
        :downloaded -> "success"
        :installed -> "success"
        :revoked -> "error"
        :failed -> "error"
        _ -> "ghost"
      end

    assigns = assigns |> assign(:variant, variant) |> assign(:size, size)

    ~H"""
    <.ui_badge variant={@variant} size={@size}>{@status}</.ui_badge>
    """
  end

  defp collector_type_badge(assigns) do
    size = assigns[:size] || "sm"
    type = assigns.type

    {label, variant} =
      case type do
        :flowgger -> {"Syslog", "info"}
        :trapd -> {"SNMP", "secondary"}
        :netflow -> {"NetFlow", "accent"}
        :otel -> {"OTel", "primary"}
        _ -> {to_string(type), "ghost"}
      end

    assigns = assigns |> assign(:label, label) |> assign(:variant, variant) |> assign(:size, size)

    ~H"""
    <.ui_badge variant={@variant} size={@size}>{@label}</.ui_badge>
    """
  end

  # Data loading

  defp load_tenant_status(socket, tenant_id) do
    case Tenant
         |> Ash.Query.for_read(:read)
         |> Ash.Query.filter(id == ^tenant_id)
         |> Ash.Query.select([:nats_account_status, :nats_account_public_key])
         |> Ash.read_one(authorize?: false) do
      {:ok, tenant} when not is_nil(tenant) ->
        socket
        |> assign(:tenant_status, tenant.nats_account_status)
        |> assign(:tenant_public_key, tenant.nats_account_public_key)

      _ ->
        socket
        |> assign(:tenant_status, nil)
        |> assign(:tenant_public_key, nil)
    end
  end

  defp load_packages(socket, tenant_id) do
    filter_status = socket.assigns[:filter_status]
    filter_type = socket.assigns[:filter_type]

    query =
      CollectorPackage
      |> Ash.Query.for_read(:read)
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.Query.limit(50)

    query =
      if filter_status do
        status_atom = String.to_existing_atom(filter_status)
        Ash.Query.filter(query, status == ^status_atom)
      else
        query
      end

    query =
      if filter_type do
        type_atom = String.to_existing_atom(filter_type)
        Ash.Query.filter(query, collector_type == ^type_atom)
      else
        query
      end

    packages =
      case Ash.read(query, tenant: tenant_id, authorize?: false) do
        {:ok, packages} -> packages
        {:error, _} -> []
      end

    assign(socket, :packages, packages)
  end

  defp load_credentials(socket, tenant_id) do
    credentials =
      case NatsCredential
           |> Ash.Query.for_read(:read)
           |> Ash.Query.sort(inserted_at: :desc)
           |> Ash.Query.limit(20)
           |> Ash.read(tenant: tenant_id, authorize?: false) do
        {:ok, creds} -> creds
        {:error, _} -> []
      end

    assign(socket, :credentials, credentials)
  end

  # Actions

  defp create_package(tenant_id, collector_type, site, hostname) do
    type_atom = String.to_existing_atom(collector_type)

    changeset =
      CollectorPackage
      |> Ash.Changeset.for_create(:create, %{
        collector_type: type_atom,
        site: site,
        hostname: hostname
      })
      |> Ash.Changeset.force_change_attribute(:tenant_id, tenant_id)

    case Ash.create(changeset, authorize?: false) do
      {:ok, package} ->
        # Extract the download token that was set during creation
        download_token = Ash.Changeset.get_attribute(changeset, :__download_token_secret__)
        {:ok, package, download_token}

      {:error, error} ->
        {:error, error}
    end
  end

  defp get_package(id, tenant_id) do
    case CollectorPackage
         |> Ash.Query.for_read(:read)
         |> Ash.Query.filter(id == ^id)
         |> Ash.read_one(tenant: tenant_id, authorize?: false) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, package} -> {:ok, package}
      {:error, error} -> {:error, error}
    end
  end

  defp revoke_package(id, tenant_id) do
    case get_package(id, tenant_id) do
      {:ok, package} ->
        package
        |> Ash.Changeset.for_update(:revoke)
        |> Ash.Changeset.set_argument(:reason, "Revoked from admin UI")
        |> Ash.update(authorize?: false)

      error ->
        error
    end
  end

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
end
