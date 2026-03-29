defmodule ServiceRadarWebNGWeb.Admin.EdgePackageLive.Index do
  @moduledoc """
  LiveView for managing edge onboarding packages.

  Uses AshPhoenix.Form for form handling with the OnboardingPackage Ash resource.
  """
  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.SettingsComponents

  alias Ash.Error.Invalid
  alias ServiceRadar.Edge.OnboardingPackage
  alias ServiceRadarWebNG.Shell
  alias ServiceRadarWebNG.Edge.BundleGenerator
  alias ServiceRadarWebNG.Edge.ComponentID
  alias ServiceRadarWebNG.Edge.OnboardingEvents
  alias ServiceRadarWebNG.Edge.OnboardingPackages
  alias ServiceRadarWebNG.Edge.PubSub, as: EdgePubSub
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.GatewayHelpers

  require Logger

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if RBAC.can?(scope, "settings.edge.manage") do
      security_mode = OnboardingPackages.configured_security_mode()

      {gateway_options, default_gateway_id} = load_gateway_state()
      actor = user_actor(socket)

      socket =
        socket
        |> assign(:page_title, "Edge Onboarding")
        |> assign(:packages, OnboardingPackages.list(%{limit: 50}, actor: actor))
        |> assign(:show_create_modal, false)
        |> assign(:show_details_modal, false)
        |> assign(:selected_package, nil)
        |> assign(:package_events, [])
        |> assign(:created_tokens, nil)
        |> assign(:creating, false)
        |> assign(:create_form, build_create_form(security_mode))
        |> assign(:filter_status, nil)
        |> assign(:security_mode, security_mode)
        |> assign(:selected_component_type, "agent")
        |> assign(:partition_value, "default")
        |> assign(:host_ip_value, "")
        |> assign(:gateway_options, gateway_options)
        |> assign(:default_gateway_id, default_gateway_id)

      if connected?(socket) do
        EdgePubSub.subscribe_packages()
      end

      {:ok, socket}
    else
      {:ok,
       socket
       |> put_flash(:error, "You don't have permission to access Edge Ops.")
       |> push_navigate(to: ~p"/analytics")}
    end
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params), do: socket

  defp apply_action(socket, :new, params) do
    socket
    |> assign(:show_create_modal, true)
    |> assign(:selected_component_type, component_type_from_params(params))
  end

  defp apply_action(socket, :show, %{"id" => id}) do
    actor = user_actor(socket)

    case OnboardingPackages.get(id, actor: actor) do
      {:ok, package} ->
        events = OnboardingEvents.list_for_package(id, actor: actor, limit: 20)

        socket
        |> assign(:selected_package, package)
        |> assign(:package_events, events)
        |> assign(:show_details_modal, true)

      {:error, :not_found} ->
        socket
        |> put_flash(:error, "Package not found")
        |> push_navigate(to: ~p"/admin/edge-packages")
    end
  end

  @impl true
  def handle_event("open_create_modal", _params, socket) do
    security_mode = socket.assigns.security_mode

    {gateway_options, default_gateway_id} = load_gateway_state()

    {:noreply,
     socket
     |> assign(:show_create_modal, true)
     |> assign(:create_form, build_create_form(security_mode))
     |> assign(:created_tokens, nil)
     |> assign(:selected_component_type, "agent")
     |> assign(:partition_value, "default")
     |> assign(:host_ip_value, "")
     |> assign(:gateway_options, gateway_options)
     |> assign(:default_gateway_id, default_gateway_id)}
  end

  def handle_event("close_create_modal", _params, socket) do
    security_mode = socket.assigns.security_mode

    {gateway_options, default_gateway_id} = load_gateway_state()

    socket =
      socket
      |> assign(:show_create_modal, false)
      |> assign(:create_form, build_create_form(security_mode))
      |> assign(:created_tokens, nil)
      |> assign(:partition_value, "default")
      |> assign(:host_ip_value, "")
      |> assign(:gateway_options, gateway_options)
      |> assign(:default_gateway_id, default_gateway_id)
      |> maybe_return_to_index()

    {:noreply, socket}
  end

  def handle_event("close_details_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_details_modal, false)
     |> assign(:selected_package, nil)
     |> assign(:package_events, [])}
  end

  def handle_event("validate_create", %{"form" => params}, socket) do
    params = ensure_gateway_id(params, socket.assigns.default_gateway_id)
    component_type = params["component_type"] || "agent"
    partition = params["partition"] || socket.assigns.partition_value
    host_ip = params["host_ip"] || socket.assigns.host_ip_value

    form = AshPhoenix.Form.validate(socket.assigns.create_form, params)

    {:noreply,
     socket
     |> assign(:create_form, form)
     |> assign(:selected_component_type, component_type)
     |> assign(:partition_value, partition)
     |> assign(:host_ip_value, host_ip)}
  end

  def handle_event("create_package", %{"form" => params}, socket) do
    params = ensure_gateway_id(params, socket.assigns.default_gateway_id)
    form = AshPhoenix.Form.validate(socket.assigns.create_form, params)

    if form.valid? do
      # Show loading state while creating package and generating certificates
      base_url = base_url()

      socket = assign(socket, :creating, true)

      # Extract validated form data
      actor = get_actor(socket)
      attrs = build_package_attrs_from_form(params, socket.assigns.security_mode)

      # Issue certificates via the selected agent-gateway
      Logger.info("[EdgePackage] create: base_url=#{base_url} component_type=#{params["component_type"] || "agent"}")

      result =
        OnboardingPackages.create_with_gateway_cert(attrs,
          actor: actor
        )

      case result do
        {:ok, package_result} ->
          security_mode = socket.assigns.security_mode

          {:noreply,
           socket
           |> assign(:creating, false)
           |> assign(:created_tokens, package_result)
           |> assign(:packages, OnboardingPackages.list(%{limit: 50}, actor: user_actor(socket)))
           |> assign(:create_form, build_create_form(security_mode))
           |> put_flash(:info, "Package created with gateway-issued certificates")}

        {:error, :gateway_unavailable} ->
          {:noreply,
           socket
           |> assign(:creating, false)
           |> put_flash(
             :error,
             "Agent gateway is unavailable. Ensure a gateway is online and try again."
           )}

        {:error, :ca_not_available} ->
          {:noreply,
           socket
           |> assign(:creating, false)
           |> put_flash(
             :error,
             "Gateway CA is not available. Ensure root-key.pem is mounted on the gateway."
           )}

        {:error, :certificate_issue_failed} ->
          {:noreply,
           socket
           |> assign(:creating, false)
           |> put_flash(
             :error,
             "Gateway failed to issue certificates. Check gateway logs and try again."
           )}

        {:error, :openssl_failed} ->
          {:noreply,
           socket
           |> assign(:creating, false)
           |> put_flash(
             :error,
             "Certificate generation failed on the gateway (openssl error)."
           )}

        {:error, :invalid_identity} ->
          {:noreply,
           socket
           |> assign(:creating, false)
           |> put_flash(:error, "Missing gateway or component identity for package creation.")}

        {:error, %Invalid{} = error} ->
          form = AshPhoenix.Form.add_error(form, error)

          {:noreply,
           socket
           |> assign(:creating, false)
           |> assign(:create_form, form)
           |> put_flash(:error, "Failed to create package")}

        {:error, error} ->
          Logger.error("[EdgePackage] create failed: #{inspect(error)}", [])
          error_msg = format_error(error)

          {:noreply,
           socket
           |> assign(:creating, false)
           |> put_flash(:error, "Failed to create package: #{error_msg}")}
      end
    else
      {:noreply,
       socket
       |> assign(:create_form, form)
       |> put_flash(:error, "Please fix the errors below")}
    end
  end

  def handle_event("revoke_package", %{"id" => id}, socket) do
    actor = get_actor(socket)

    case OnboardingPackages.revoke(id,
           actor: actor,
           reason: "Revoked from admin UI"
         ) do
      {:ok, _package} ->
        {:noreply,
         socket
         |> assign(:packages, OnboardingPackages.list(%{limit: 50}, actor: user_actor(socket)))
         |> assign(:show_details_modal, false)
         |> assign(:selected_package, nil)
         |> put_flash(:info, "Package revoked successfully")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Package not found")}

      {:error, :already_revoked} ->
        {:noreply, put_flash(socket, :error, "Package is already revoked")}
    end
  end

  def handle_event("delete_package", %{"id" => id}, socket) do
    actor = get_actor(socket)

    case OnboardingPackages.delete(id,
           actor: actor,
           reason: "Deleted from admin UI"
         ) do
      {:ok, _package} ->
        {:noreply,
         socket
         |> assign(:packages, OnboardingPackages.list(%{limit: 50}, actor: user_actor(socket)))
         |> assign(:show_details_modal, false)
         |> assign(:selected_package, nil)
         |> put_flash(:info, "Package deleted successfully")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete package")}
    end
  end

  def handle_event("filter", %{"status" => status}, socket) do
    filters = %{limit: 50}
    filters = if status == "", do: filters, else: Map.put(filters, :status, [status])

    {:noreply,
     socket
     |> assign(:filter_status, if(status == "", do: nil, else: status))
     |> assign(:packages, OnboardingPackages.list(filters, actor: user_actor(socket)))}
  end

  def handle_event("copy_token", %{"token" => token}, socket) do
    {:noreply,
     socket
     |> push_event("clipboard", %{text: token})
     |> put_flash(:info, "Token copied to clipboard")}
  end

  @impl true
  def handle_info({:edge_package_created, _package}, socket) do
    {:noreply, refresh_packages(socket)}
  end

  def handle_info({:edge_package_updated, package}, socket) do
    socket = refresh_packages(socket)

    socket =
      if (socket.assigns.show_details_modal and
            socket.assigns.selected_package) &&
           socket.assigns.selected_package.id == package.id do
        assign(socket, :selected_package, package)
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_info({:edge_package_deleted, package}, socket) do
    socket = refresh_packages(socket)

    socket =
      if (socket.assigns.show_details_modal and
            socket.assigns.selected_package) &&
           socket.assigns.selected_package.id == package.id do
        socket
        |> assign(:show_details_modal, false)
        |> assign(:selected_package, nil)
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.settings_shell current_path="/admin/edge-packages">
        <.settings_nav current_path="/admin/edge-packages" current_scope={@current_scope} />
        <.edge_nav
          current_path="/admin/edge-packages"
          class="mt-2"
          current_scope={@current_scope}
        />

        <div class="flex flex-wrap items-center justify-between gap-4">
          <div>
            <h1 class="text-2xl font-semibold text-base-content">Edge Onboarding</h1>
            <p class="text-sm text-base-content/60">
              Manage edge component onboarding packages for agents.
            </p>
          </div>
          <.link navigate={~p"/admin/edge-packages/new?component_type=agent"}>
            <.ui_button variant="primary" size="sm">
              <.icon name="hero-plus" class="size-4" /> New Package
            </.ui_button>
          </.link>
        </div>

        <.ui_panel>
          <:header>
            <div>
              <div class="text-sm font-semibold">Packages</div>
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
                <option value="issued" selected={@filter_status == "issued"}>Issued</option>
                <option value="delivered" selected={@filter_status == "delivered"}>Delivered</option>
                <option value="activated" selected={@filter_status == "activated"}>Activated</option>
                <option value="revoked" selected={@filter_status == "revoked"}>Revoked</option>
              </select>
            </div>
          </:header>

          <div class="overflow-x-auto">
            <%= if @packages == [] do %>
              <div class="rounded-xl border border-dashed border-base-200 bg-base-100 p-8 text-center">
                <div class="text-sm font-semibold text-base-content">No packages found</div>
                <p class="mt-1 text-xs text-base-content/60">
                  Create a new package to onboard edge components.
                </p>
              </div>
            <% else %>
              <table class="table table-sm">
                <thead>
                  <tr class="text-xs uppercase tracking-wide text-base-content/60">
                    <th>Label</th>
                    <th>Type</th>
                    <th>Status</th>
                    <th>Created</th>
                    <th>Expires</th>
                    <th></th>
                  </tr>
                </thead>
                <tbody>
                  <%= for package <- @packages do %>
                    <tr class="hover:bg-base-200/30">
                      <td>
                        <div class="font-medium">{package.label}</div>
                        <div class="text-xs text-base-content/60 font-mono">
                          {package.component_id}
                        </div>
                        <div class="text-xs text-base-content/60 font-mono">
                          {String.slice(package.id, 0, 8)}...
                        </div>
                      </td>
                      <td>
                        <.ui_badge variant="ghost" size="xs">
                          {package.component_type}
                        </.ui_badge>
                      </td>
                      <td>
                        <.status_badge status={package.status} />
                      </td>
                      <td class="text-xs text-base-content/70">
                        {format_datetime(package.created_at)}
                      </td>
                      <td class="text-xs text-base-content/70">
                        {format_datetime(package.download_token_expires_at)}
                      </td>
                      <td>
                        <div class="flex gap-1">
                          <.ui_button
                            variant="ghost"
                            size="xs"
                            navigate={~p"/admin/edge-packages/#{package.id}"}
                          >
                            View
                          </.ui_button>
                          <.ui_button
                            :if={package.status == :issued}
                            variant="ghost"
                            size="xs"
                            phx-click="revoke_package"
                            phx-value-id={package.id}
                            data-confirm="Are you sure you want to revoke this package?"
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
      </.settings_shell>

      <.create_modal
        :if={@show_create_modal}
        form={to_form(@create_form)}
        created_tokens={@created_tokens}
        creating={@creating}
        security_mode={@security_mode}
        selected_component_type={@selected_component_type}
        partition_value={@partition_value}
        host_ip_value={@host_ip_value}
        gateway_options={@gateway_options}
        default_gateway_id={@default_gateway_id}
      />

      <.details_modal
        :if={@show_details_modal}
        package={@selected_package}
        events={@package_events}
      />
    </Layouts.app>
    """
  end

  defp create_modal(assigns) do
    ~H"""
    <dialog id="create_modal" class="modal modal-open">
      <div class="modal-box max-w-2xl">
        <form method="dialog">
          <button
            class="btn btn-sm btn-circle btn-ghost absolute right-2 top-2"
            phx-click="close_create_modal"
            disabled={@creating}
          >
            x
          </button>
        </form>

        <%= if @creating do %>
          <div class="text-center py-8">
            <span class="loading loading-spinner loading-lg text-primary"></span>
            <h3 class="text-lg font-bold mt-4">Creating Package</h3>
            <p class="text-sm text-base-content/70 mt-2">
              Generating certificates and preparing your onboarding package...
            </p>
            <p class="text-xs text-base-content/50 mt-1">
              This may take a moment if this is your first edge package.
            </p>
          </div>
        <% else %>
          <%= if @created_tokens do %>
            <.success_content created_tokens={@created_tokens} />
          <% else %>
            <h3 class="text-lg font-bold">Create Edge Package</h3>
            <p class="py-2 text-sm text-base-content/70">
              Create an onboarding package to deploy an edge component.
            </p>

            <div class="alert alert-info text-sm mb-4">
              <.icon name="hero-sparkles" class="size-5" />
              <div>
                <div class="font-medium">Zero-touch provisioning</div>
                <p class="text-xs opacity-80">
                  Certificates are generated automatically. You'll get a one-liner
                  install command to run on your target server.
                </p>
              </div>
            </div>

            <.form
              for={@form}
              id="create_package_form"
              phx-change="validate_create"
              phx-submit="create_package"
              class="space-y-4"
            >
              <.input
                field={@form[:label]}
                type="text"
                label="Label"
                placeholder="e.g., production-gateway-01"
                required
              />
              <p class="text-xs text-base-content/60 -mt-2 ml-1">
                A descriptive name for this component. Used to generate the component ID.
              </p>

              <.input field={@form[:component_type]} type="hidden" value={@selected_component_type} />
              <div class="text-sm text-base-content/70">
                <span class="font-medium text-base-content">Component Type:</span>
                <span class="ml-1 text-base-content">Agent</span>
              </div>

              <%= if @selected_component_type == "agent" do %>
                <.input
                  field={@form[:gateway_id]}
                  type="select"
                  label="Parent Gateway ID"
                  options={@gateway_options}
                  prompt="Select a gateway..."
                  disabled={@gateway_options == []}
                  value={@default_gateway_id}
                />
                <p class="text-xs text-base-content/60 -mt-2 ml-1">
                  The gateway that will manage this agent.
                </p>
                <%= if @gateway_options == [] do %>
                  <p class="text-xs text-warning -mt-1 ml-1">
                    No gateways registered yet. Start a gateway before creating an agent package.
                  </p>
                <% end %>
              <% end %>

              <div class="collapse collapse-arrow bg-base-200 rounded-lg">
                <input type="checkbox" />
                <div class="collapse-title text-sm font-medium py-2">
                  Advanced options
                </div>
                <div class="collapse-content space-y-4">
                  <%= if @selected_component_type == "agent" do %>
                    <.input
                      name="partition"
                      label="Partition"
                      value={@partition_value}
                      placeholder="default"
                    />
                    <p class="text-xs text-base-content/60 -mt-2 ml-1">
                      Partition identifier for the agent (default: default).
                    </p>

                    <.input
                      name="host_ip"
                      label="Host IP (Optional)"
                      value={@host_ip_value}
                      placeholder="Leave blank to auto-detect during enrollment"
                    />
                    <p class="text-xs text-base-content/60 -mt-2 ml-1">
                      Optional static host IP for the agent. If blank, enrollment auto-detects.
                    </p>
                  <% end %>

                  <.input
                    field={@form[:notes]}
                    type="textarea"
                    label="Notes (Optional)"
                    placeholder="Additional notes about this package"
                  />

                  <div class="form-control">
                    <label class="label">
                      <span class="label-text text-xs">Security Mode</span>
                    </label>
                    <div class="flex items-center gap-2">
                      <.ui_badge variant="ghost" size="xs">
                        {String.upcase(to_string(@security_mode))}
                      </.ui_badge>
                      <span class="text-xs text-base-content/50">
                        (Set by deployment)
                      </span>
                    </div>
                  </div>
                </div>
              </div>

              <div class="modal-action">
                <button type="button" class="btn" phx-click="close_create_modal">Cancel</button>
                <button type="submit" class="btn btn-primary">Create Package</button>
              </div>
            </.form>
          <% end %>
        <% end %>
      </div>
      <form method="dialog" class="modal-backdrop">
        <button phx-click="close_create_modal">close</button>
      </form>
    </dialog>
    """
  end

  defp success_content(assigns) do
    package = assigns.created_tokens.package
    download_token = assigns.created_tokens.download_token
    certificate_data = Map.get(assigns.created_tokens, :certificate_data)
    component_type = to_string(package.component_type)
    base_url = base_url()

    onboarding_token =
      case ServiceRadarWebNG.Edge.encode_onboarding_token(package.id, download_token, base_url) do
        {:ok, token} -> token
        _ -> nil
      end

    enroll_cmd =
      if component_type == "agent" and is_binary(onboarding_token) do
        "sudo /usr/local/bin/serviceradar-cli enroll --core-url #{Shell.literal(base_url)} --token #{Shell.literal(onboarding_token)}"
      end

    docker_cmd =
      if component_type == "agent" do
        nil
      else
        BundleGenerator.docker_install_command(package, download_token)
      end

    systemd_cmd =
      if component_type == "agent" do
        nil
      else
        BundleGenerator.systemd_install_command(package, download_token)
      end

    assigns =
      assigns
      |> assign(:package, package)
      |> assign(:download_token, download_token)
      |> assign(:certificate_data, certificate_data)
      |> assign(:docker_cmd, docker_cmd)
      |> assign(:systemd_cmd, systemd_cmd)
      |> assign(:onboarding_token, onboarding_token)
      |> assign(:enroll_cmd, enroll_cmd)
      |> assign(:component_type, component_type)

    ~H"""
    <div class="space-y-6">
      <div class="text-center">
        <div class="inline-flex items-center justify-center w-16 h-16 rounded-full bg-success/10 mb-4">
          <.icon name="hero-check-circle" class="size-10 text-success" />
        </div>
        <h3 class="text-xl font-bold">Package Created Successfully</h3>
        <p class="text-sm text-base-content/70 mt-1">
          Your edge component package is ready for deployment.
        </p>
      </div>

      <%= if @component_type == "agent" do %>
        <div class="divider">Enroll Agent</div>
        <div class="space-y-3">
          <p class="text-sm text-base-content/70">
            Run this command on the target host to enroll the agent. Uses sudo to write
            <code class="bg-base-200 px-1 rounded text-xs">/etc/serviceradar</code>
            and restart the agent.
          </p>
          <p class="text-xs text-base-content/50">
            The gateway address is derived from your deployment configuration by default.
          </p>
          <div class="relative">
            <pre class="bg-base-200 p-3 rounded-lg text-xs font-mono overflow-x-auto whitespace-pre-wrap break-all"><code>{@enroll_cmd}</code></pre>
            <button
              type="button"
              class="btn btn-sm btn-ghost absolute top-2 right-2"
              phx-click="copy_token"
              phx-value-token={@enroll_cmd}
              title="Copy enroll command"
            >
              <.icon name="hero-clipboard" class="size-4" />
            </button>
          </div>
        </div>
      <% else %>
        <div class="divider">Quick Install</div>

        <div class="tabs tabs-boxed">
          <input type="radio" name="install_tabs" class="tab" aria-label="Docker" checked />
          <div class="tab-content bg-base-100 border-base-300 rounded-box p-4 mt-2">
            <p class="text-sm text-base-content/70 mb-3">
              Run this command on your target server to install via Docker:
            </p>
            <div class="relative">
              <pre class="bg-base-200 p-3 rounded-lg text-xs font-mono overflow-x-auto whitespace-pre-wrap break-all"><code>{@docker_cmd}</code></pre>
              <button
                type="button"
                class="btn btn-sm btn-ghost absolute top-2 right-2"
                phx-click="copy_token"
                phx-value-token={@docker_cmd}
              >
                <.icon name="hero-clipboard" class="size-4" />
              </button>
            </div>
          </div>

          <input type="radio" name="install_tabs" class="tab" aria-label="systemd" />
          <div class="tab-content bg-base-100 border-base-300 rounded-box p-4 mt-2">
            <p class="text-sm text-base-content/70 mb-3">
              Run this command on your target server to install via systemd:
            </p>
            <div class="relative">
              <pre class="bg-base-200 p-3 rounded-lg text-xs font-mono overflow-x-auto whitespace-pre-wrap break-all"><code>{@systemd_cmd}</code></pre>
              <button
                type="button"
                class="btn btn-sm btn-ghost absolute top-2 right-2"
                phx-click="copy_token"
                phx-value-token={@systemd_cmd}
              >
                <.icon name="hero-clipboard" class="size-4" />
              </button>
            </div>
          </div>
        </div>
      <% end %>

      <div class="divider">Package Details</div>

      <div class="grid grid-cols-2 gap-4 text-sm">
        <div>
          <div class="text-xs uppercase tracking-wide text-base-content/60">Component ID</div>
          <code class="font-mono text-xs break-all">{@package.component_id}</code>
        </div>
        <div>
          <div class="text-xs uppercase tracking-wide text-base-content/60">Package ID</div>
          <code class="font-mono text-xs">{String.slice(@package.id, 0, 8)}...</code>
        </div>
        <div>
          <div class="text-xs uppercase tracking-wide text-base-content/60">Component Type</div>
          <span>{@package.component_type}</span>
        </div>
        <div>
          <div class="text-xs uppercase tracking-wide text-base-content/60">Token Expires</div>
          <span>{format_expiry(@package.download_token_expires_at)}</span>
        </div>
        <%= if @certificate_data do %>
          <div>
            <div class="text-xs uppercase tracking-wide text-base-content/60">Certificate CN</div>
            <code class="font-mono text-xs break-all">{cert_cn(@certificate_data)}</code>
          </div>
        <% end %>
      </div>

      <%= if is_binary(@onboarding_token) do %>
        <div class="collapse collapse-arrow bg-base-200">
          <input type="checkbox" />
          <div class="collapse-title text-sm font-medium">
            Show onboarding token (edgepkg-v2)
          </div>
          <div class="collapse-content">
            <div class="flex items-center gap-2">
              <code class="flex-1 text-xs font-mono break-all bg-base-100 p-2 rounded">
                {@onboarding_token}
              </code>
              <button
                type="button"
                class="btn btn-sm btn-ghost"
                phx-click="copy_token"
                phx-value-token={@onboarding_token}
              >
                <.icon name="hero-clipboard" class="size-4" />
              </button>
            </div>
          </div>
        </div>
      <% end %>

      <div class="alert alert-info text-sm">
        <.icon name="hero-information-circle" class="size-5" />
        <div>
          <div class="font-semibold">What's included in the bundle?</div>
          <ul class="list-disc list-inside text-xs mt-1 text-base-content/80">
            <li>Component TLS certificate and private key</li>
            <li>CA certificate chain for verification</li>
            <li>Pre-configured config.yaml</li>
            <li>Platform-detecting install script</li>
          </ul>
        </div>
      </div>

      <div class="modal-action">
        <button type="button" class="btn btn-primary" phx-click="close_create_modal">
          Done
        </button>
      </div>
    </div>
    """
  end

  defp format_expiry(nil), do: "N/A"

  defp format_expiry(%DateTime{} = dt) do
    now = DateTime.utc_now()
    diff = DateTime.diff(dt, now, :hour)

    cond do
      diff < 0 -> "Expired"
      diff < 24 -> "#{diff}h remaining"
      diff < 48 -> "Tomorrow"
      true -> Calendar.strftime(dt, "%Y-%m-%d %H:%M")
    end
  end

  defp format_expiry(%NaiveDateTime{} = dt) do
    dt |> DateTime.from_naive!("Etc/UTC") |> format_expiry()
  end

  defp base_url do
    ServiceRadarWebNGWeb.Endpoint.url()
  end

  defp maybe_return_to_index(socket) do
    if socket.assigns.live_action == :new do
      push_patch(socket, to: ~p"/admin/edge-packages")
    else
      socket
    end
  end

  defp refresh_packages(socket) do
    assign(socket, :packages, OnboardingPackages.list(%{limit: 50}, actor: user_actor(socket)))
  end

  defp cert_cn(%{spiffe_id: spiffe_id}) when is_binary(spiffe_id) do
    # Extract component info from SPIFFE ID
    # spiffe://serviceradar.local/<type>/<partition>/<component>
    case String.split(spiffe_id, "/") do
      [_, _, _, _type, partition, component] ->
        "#{component}.#{partition}.serviceradar"

      _ ->
        spiffe_id
    end
  end

  defp cert_cn(_), do: "N/A"

  defp details_modal(assigns) do
    ~H"""
    <dialog id="details_modal" class="modal modal-open">
      <div class="modal-box max-w-2xl">
        <form method="dialog">
          <button
            class="btn btn-sm btn-circle btn-ghost absolute right-2 top-2"
            phx-click="close_details_modal"
          >
            x
          </button>
        </form>

        <h3 class="text-lg font-bold">Package Details</h3>

        <div class="mt-4 space-y-4">
          <div class="grid grid-cols-2 gap-4">
            <div>
              <div class="text-xs uppercase tracking-wide text-base-content/60">Label</div>
              <div class="font-medium">{@package.label}</div>
            </div>
            <div>
              <div class="text-xs uppercase tracking-wide text-base-content/60">Status</div>
              <.status_badge status={@package.status} />
            </div>
            <div>
              <div class="text-xs uppercase tracking-wide text-base-content/60">Component Type</div>
              <div>{@package.component_type}</div>
            </div>
            <div>
              <div class="text-xs uppercase tracking-wide text-base-content/60">Component ID</div>
              <code class="text-sm font-mono break-all">{@package.component_id}</code>
            </div>
            <div>
              <div class="text-xs uppercase tracking-wide text-base-content/60">Security Mode</div>
              <div>{@package.security_mode}</div>
            </div>
            <div>
              <div class="text-xs uppercase tracking-wide text-base-content/60">Created</div>
              <div class="text-sm">{format_datetime(@package.created_at)}</div>
            </div>
            <div>
              <div class="text-xs uppercase tracking-wide text-base-content/60">Token Expires</div>
              <div class="text-sm">{format_datetime(@package.download_token_expires_at)}</div>
            </div>
          </div>

          <div>
            <div class="text-xs uppercase tracking-wide text-base-content/60 mb-1">Package ID</div>
            <code class="text-sm font-mono bg-base-200 p-2 rounded block">{@package.id}</code>
          </div>

          <%= if @package.gateway_id do %>
            <div>
              <div class="text-xs uppercase tracking-wide text-base-content/60 mb-1">Gateway ID</div>
              <code class="text-sm font-mono bg-base-200 p-2 rounded block">
                {@package.gateway_id}
              </code>
            </div>
          <% end %>

          <%= if @package.parent_id do %>
            <div>
              <div class="text-xs uppercase tracking-wide text-base-content/60 mb-1">Parent ID</div>
              <code class="text-sm font-mono bg-base-200 p-2 rounded block">
                {@package.parent_id}
              </code>
            </div>
          <% end %>

          <%!-- Checker details removed: checkers no longer supported --%>

          <%= if @package.notes do %>
            <div>
              <div class="text-xs uppercase tracking-wide text-base-content/60 mb-1">Notes</div>
              <div class="text-sm">{@package.notes}</div>
            </div>
          <% end %>

          <div class="divider">Events</div>

          <%= if @events == [] do %>
            <p class="text-sm text-base-content/60">No events recorded yet.</p>
          <% else %>
            <div class="overflow-x-auto rounded-lg border border-base-200/60">
              <table class="table table-xs">
                <thead>
                  <tr class="text-[11px] uppercase tracking-wide text-base-content/50">
                    <th>Event</th>
                    <th>Actor</th>
                    <th>Time</th>
                  </tr>
                </thead>
                <tbody>
                  <%= for event <- @events do %>
                    <tr>
                      <td>
                        <.ui_badge variant={event_variant(event.event_type)} size="xs">
                          {event.event_type}
                        </.ui_badge>
                      </td>
                      <td class="text-xs">{event.actor || "system"}</td>
                      <td class="text-xs font-mono">{format_datetime(event.event_time)}</td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            </div>
          <% end %>
        </div>

        <div class="modal-action">
          <%= if @package.status == :issued do %>
            <button
              type="button"
              class="btn btn-warning"
              phx-click="revoke_package"
              phx-value-id={@package.id}
              data-confirm="Are you sure you want to revoke this package?"
            >
              Revoke Package
            </button>
          <% end %>
          <button
            type="button"
            class="btn btn-error btn-outline"
            phx-click="delete_package"
            phx-value-id={@package.id}
            data-confirm="Are you sure you want to delete this package? This cannot be undone."
          >
            Delete
          </button>
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
    # Handle both atom and string status for backwards compatibility
    status = if is_atom(assigns.status), do: Atom.to_string(assigns.status), else: assigns.status

    variant =
      case status do
        "issued" -> "info"
        "delivered" -> "success"
        "activated" -> "success"
        "revoked" -> "error"
        "expired" -> "warning"
        "deleted" -> "ghost"
        _ -> "ghost"
      end

    assigns = assigns |> assign(:variant, variant) |> assign(:status_str, status)

    ~H"""
    <.ui_badge variant={@variant} size="xs">{@status_str}</.ui_badge>
    """
  end

  defp event_variant(event_type) do
    # Handle both atom and string event types
    type_str = if is_atom(event_type), do: Atom.to_string(event_type), else: event_type

    case type_str do
      "created" -> "info"
      "delivered" -> "success"
      "activated" -> "success"
      "revoked" -> "error"
      "deleted" -> "ghost"
      _ -> "ghost"
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

  # Build AshPhoenix.Form for creating OnboardingPackage
  defp build_create_form(security_mode) do
    AshPhoenix.Form.for_create(OnboardingPackage, :create,
      domain: ServiceRadar.Edge,
      transform_params: fn _form, params, _action ->
        # Convert component_type string to atom if needed (allowlist prevents DoS via atom exhaustion)
        params = Map.put(params, "component_type", :agent)

        # Set security mode from environment config
        params = Map.put(params, "security_mode", security_mode)

        params
      end
    )
  end

  defp get_actor(socket) do
    case socket.assigns[:current_scope] do
      %{user: user} when not is_nil(user) -> user
      _ -> nil
    end
  end

  defp user_actor(socket) do
    socket.assigns[:ash_actor] || get_actor(socket)
  end

  defp build_package_attrs_from_form(params, security_mode) do
    component_type = params["component_type"] || "agent"
    label = params["label"] || ""
    component_id = generate_component_id(label, component_type)
    metadata_json = build_metadata_json(component_type, params)
    partition_id = params["partition"] || "default"

    add_parent_type(
      %{
        label: label,
        component_id: component_id,
        component_type: component_type,
        gateway_id: params["gateway_id"],
        site: if(component_type == "agent", do: partition_id),
        security_mode: security_mode,
        notes: params["notes"],
        parent_id: params["parent_id"],
        metadata_json: metadata_json
      },
      component_type
    )
  end

  # Generate a component_id from label and type
  # e.g., "Production Gateway 01" -> "gateway-production-gateway-01"
  defp generate_component_id(label, component_type) when is_binary(label) and label != "" do
    ComponentID.generate(label, component_type)
  end

  defp generate_component_id(_, component_type) do
    ComponentID.generate(nil, component_type)
  end

  defp add_parent_type(attrs, "agent"), do: Map.put(attrs, :parent_type, "gateway")
  defp add_parent_type(attrs, _), do: attrs

  defp build_metadata_json("agent", params) do
    host_ip =
      case params["host_ip"] do
        value when is_binary(value) and value != "" -> value
        _ -> "PLACEHOLDER_HOST_IP"
      end

    metadata =
      %{}
      |> maybe_put("partition", params["partition"])
      |> Map.put("host_ip", host_ip)

    encode_metadata(metadata)
  end

  defp build_metadata_json(_, _params), do: nil

  defp maybe_put(metadata, _key, value) when value in [nil, ""], do: metadata
  defp maybe_put(metadata, key, value), do: Map.put(metadata, key, value)

  defp encode_metadata(metadata) when map_size(metadata) == 0, do: nil
  defp encode_metadata(metadata), do: Jason.encode!(metadata)

  defp component_type_from_params(_params), do: "agent"

  defp ensure_gateway_id(params, nil), do: params

  defp ensure_gateway_id(params, default_gateway_id) do
    case params["gateway_id"] do
      value when is_binary(value) and value != "" ->
        params

      _ ->
        Map.put(params, "gateway_id", default_gateway_id)
    end
  end

  defp load_gateway_options do
    gateways = fetch_gateways_from_tracker()
    GatewayHelpers.gateway_options(gateways)
  end

  # Use GatewayTracker (ETS-based) via RPC for reliable gateway discovery.
  # Horde-based GatewayRegistry is process-linked and can lose registrations.
  defp fetch_gateways_from_tracker do
    [Node.self() | Node.list()]
    |> Task.async_stream(
      fn node ->
        :rpc.call(node, ServiceRadar.GatewayTracker, :list_gateways, [], 1_500)
      end,
      timeout: 2_000,
      on_timeout: :kill_task,
      max_concurrency: 4
    )
    |> Enum.flat_map(fn
      {:ok, gateways} when is_list(gateways) -> gateways
      _ -> []
    end)
    |> Enum.uniq_by(& &1.gateway_id)
  end

  defp default_gateway_id([{_label, id}]), do: id
  defp default_gateway_id(_), do: nil

  defp load_gateway_state do
    options = load_gateway_options()
    {options, default_gateway_id(options)}
  end

  defp format_error(%Invalid{errors: errors}) do
    Enum.map_join(errors, ", ", &format_error/1)
  end

  defp format_error(%Ash.Error.Forbidden{}), do: "Not authorized to create packages."
  defp format_error(%Ash.Error.Unknown{}), do: "Unknown error"

  defp format_error(%{__exception__: true} = error), do: Exception.message(error)
  defp format_error(%{message: message}), do: message
  defp format_error(error) when is_binary(error), do: error
  defp format_error(error) when is_atom(error), do: to_string(error)
  defp format_error(error), do: inspect(error)
end
