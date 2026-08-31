defmodule ServiceRadarWebNGWeb.Admin.EdgePackageLive.Index do
  @moduledoc """
  LiveView for managing edge onboarding packages.

  Uses AshPhoenix.Form for form handling with the OnboardingPackage Ash resource.
  """
  use ServiceRadarWebNGWeb, :live_view

  alias Ash.Error.Invalid
  alias ServiceRadar.Edge.OnboardingPackage
  alias ServiceRadarWebNG.Edge.BundleGenerator
  alias ServiceRadarWebNG.Edge.ComponentID
  alias ServiceRadarWebNG.Edge.OnboardingEvents
  alias ServiceRadarWebNG.Edge.OnboardingPackages
  alias ServiceRadarWebNG.Edge.PubSub, as: EdgePubSub
  alias ServiceRadarWebNG.Plugins.AddonAssignments
  alias ServiceRadarWebNG.Plugins.AddonPackages
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.GatewayHelpers
  alias ServiceRadarWebNGWeb.Settings.Shell

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
        |> assign(:approved_addons, AddonPackages.list_approved_latest(scope: scope))

      if connected?(socket) do
        EdgePubSub.subscribe_packages()
      end

      {:ok, socket}
    else
      {:ok,
       socket
       |> put_flash(:error, "You don't have permission to access Edge Ops.")
       |> push_navigate(to: ~p"/dashboard")}
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
     |> assign(:default_gateway_id, default_gateway_id)
     |> assign(:approved_addons, AddonPackages.list_approved_latest(scope: socket.assigns.current_scope))}
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
      |> assign(:approved_addons, AddonPackages.list_approved_latest(scope: socket.assigns.current_scope))
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

          assignment_result =
            assign_initial_addons(
              package_result.package,
              selected_initial_addon_ids(params),
              socket.assigns.current_scope
            )

          {:noreply,
           socket
           |> assign(:creating, false)
           |> assign(:created_tokens, package_result)
           |> assign(:packages, OnboardingPackages.list(%{limit: 50}, actor: user_actor(socket)))
           |> assign(:create_form, build_create_form(security_mode))
           |> put_flash(:info, package_created_message(assignment_result))}

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

        {:error, {:edge_onboarding_quota_exceeded, _bucket, retry_after}} ->
          {:noreply,
           socket
           |> assign(:creating, false)
           |> put_flash(:error, "Package creation quota exceeded. Try again in #{retry_after} seconds.")}

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
      <Shell.settings_chrome
        current_path="/admin/edge-packages"
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
            <h1 class="text-2xl font-semibold text-sr-ink">Edge Onboarding</h1>
            <p class="text-sm text-sr-muted">
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
              <p class="text-xs text-sr-muted">
                {@packages |> length()} package(s)
              </p>
            </div>
            <div class="flex gap-2">
              <select
                name="status"
                class={ui_field_class(size: "sm")}
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
              <div class="rounded-xl border border-dashed border-sr-line bg-sr-surface p-8 text-center">
                <div class="text-sm font-semibold text-sr-ink">No packages found</div>
                <p class="mt-1 text-xs text-sr-muted">
                  Create a new package to onboard edge components.
                </p>
              </div>
            <% else %>
              <table class={ui_table_class(size: "sm")}>
                <thead>
                  <tr class="text-xs uppercase tracking-wide text-sr-muted">
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
                    <tr class="hover:bg-sr-subtle/30">
                      <td>
                        <div class="font-medium">{package.label}</div>
                        <div class="text-xs text-sr-muted font-mono">
                          {package.component_id}
                        </div>
                        <div class="text-xs text-sr-muted font-mono">
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
                      <td class="text-xs text-sr-muted">
                        <.user_time
                          id={"admin-edge-package-#{package.id}-created-at"}
                          value={package.created_at}
                          timezone={@current_scope.user.timezone || "Etc/UTC"}
                          style={:compact}
                        />
                      </td>
                      <td class="text-xs text-sr-muted">
                        <.user_time
                          id={"admin-edge-package-#{package.id}-download-token-expires-at"}
                          value={package.download_token_expires_at}
                          timezone={@current_scope.user.timezone || "Etc/UTC"}
                          style={:compact}
                        />
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
      </Shell.settings_chrome>

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
        approved_addons={@approved_addons}
      />

      <.details_modal
        :if={@show_details_modal}
        package={@selected_package}
        events={@package_events}
        timezone={@current_scope.user.timezone || "Etc/UTC"}
      />
    </Layouts.app>
    """
  end

  defp create_modal(assigns) do
    ~H"""
    <dialog id="create_modal" class="sr-ui-modal sr-ui-modal-open" phx-hook="DialogTopLayer">
      <div class="sr-ui-modal-box sr-ui-modal-box-md">
        <form method="dialog">
          <.ui_icon_button
            phx-click="close_create_modal"
            disabled={@creating}
            size="sm"
            variant="ghost"
            class="absolute right-2 top-2"
          >
            x
          </.ui_icon_button>
        </form>

        <%= if @creating do %>
          <div class="text-center py-8">
            <.ui_spinner size="lg" />
            <h3 class="text-lg font-bold mt-4">Creating Package</h3>
            <p class="text-sm text-sr-muted mt-2">
              Generating certificates and preparing your onboarding package...
            </p>
            <p class="text-xs text-sr-muted mt-1">
              This may take a moment if this is your first edge package.
            </p>
          </div>
        <% else %>
          <%= if @created_tokens do %>
            <.success_content created_tokens={@created_tokens} />
          <% else %>
            <h3 class="text-lg font-bold">Create Edge Package</h3>
            <p class="py-2 text-sm text-sr-muted">
              Create an onboarding package to deploy an edge component.
            </p>

            <div class={ui_alert_class(variant: "info", class: "text-sm mb-4")}>
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
              <p class="text-xs text-sr-muted -mt-2 ml-1">
                A descriptive name for this component. Used to generate the component ID.
              </p>

              <.input field={@form[:component_type]} type="hidden" value={@selected_component_type} />
              <div class="text-sm text-sr-muted">
                <span class="font-medium text-sr-ink">Component Type:</span>
                <span class="ml-1 text-sr-ink">Agent</span>
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
                <p class="text-xs text-sr-muted -mt-2 ml-1">
                  The gateway that will manage this agent.
                </p>
                <%= if @gateway_options == [] do %>
                  <p class="text-xs text-warning -mt-1 ml-1">
                    No gateways registered yet. Start a gateway before creating an agent package.
                  </p>
                <% end %>
              <% end %>

              <div class="sr-ui-collapse sr-ui-collapse-arrow bg-sr-subtle rounded-lg">
                <input type="checkbox" />
                <div class="sr-ui-collapse-title text-sm font-medium py-2">
                  Advanced options
                </div>
                <div class="sr-ui-collapse-content space-y-4">
                  <%= if @selected_component_type == "agent" do %>
                    <.input
                      name="partition"
                      label="Partition"
                      value={@partition_value}
                      placeholder="default"
                    />
                    <p class="text-xs text-sr-muted -mt-2 ml-1">
                      Partition identifier for the agent (default: default).
                    </p>

                    <.input
                      name="host_ip"
                      label="Host IP (Optional)"
                      value={@host_ip_value}
                      placeholder="Leave blank to auto-detect during enrollment"
                    />
                    <p class="text-xs text-sr-muted -mt-2 ml-1">
                      Optional static host IP for the agent. If blank, enrollment auto-detects.
                    </p>
                  <% end %>

                  <.input
                    field={@form[:notes]}
                    type="textarea"
                    label="Notes (Optional)"
                    placeholder="Additional notes about this package"
                  />

                  <div :if={@selected_component_type == "agent"} class="flex flex-col gap-1.5">
                    <label class="flex items-center justify-between gap-2">
                      <span class="text-sm font-medium text-sr-ink">Initial Feature Set</span>
                    </label>
                    <select
                      name="form[initial_addon_package_ids][]"
                      class={ui_field_class(class: "min-h-28 w-full")}
                      multiple
                      size={min(max(length(@approved_addons), 3), 8)}
                    >
                      <%= for addon <- @approved_addons do %>
                        <option value={addon.id}>
                          {addon.name} v{addon.version} ({addon.addon_id})
                        </option>
                      <% end %>
                    </select>
                    <p class="mt-1 text-xs text-sr-muted">
                      Only the latest approved version of each add-on is listed. Selected
                      add-ons are assigned to the generated agent identity when the package
                      is created.
                    </p>
                    <p :if={@approved_addons == []} class="mt-1 text-xs text-warning">
                      No approved add-ons are available yet.
                    </p>
                  </div>

                  <div class="flex flex-col gap-1.5">
                    <label class="flex items-center justify-between gap-2">
                      <span class="text-xs font-medium text-sr-ink">Security Mode</span>
                    </label>
                    <div class="flex items-center gap-2">
                      <.ui_badge variant="ghost" size="xs">
                        {String.upcase(to_string(@security_mode))}
                      </.ui_badge>
                      <span class="text-xs text-sr-muted">
                        (Set by deployment)
                      </span>
                    </div>
                  </div>
                </div>
              </div>

              <div class="sr-ui-modal-action">
                <.ui_button type="button" phx-click="close_create_modal" size="sm" variant="neutral">
                  Cancel
                </.ui_button>
                <.ui_button type="submit" size="sm" variant="primary">Create Package</.ui_button>
              </div>
            </.form>
          <% end %>
        <% end %>
      </div>
      <form method="dialog" class="sr-ui-modal-backdrop">
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
        "sudo " <> BundleGenerator.agent_enroll_command(onboarding_token, base_url)
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
      |> assign(:enroll_cmd_error, enroll_cmd_error(onboarding_token, enroll_cmd))
      |> assign(:component_type, component_type)

    ~H"""
    <div class="space-y-6">
      <div class="text-center">
        <div class="inline-flex items-center justify-center w-16 h-16 rounded-full bg-success/10 mb-4">
          <.icon name="hero-check-circle" class="size-10 text-success" />
        </div>
        <h3 class="text-xl font-bold">Package Created Successfully</h3>
        <p class="text-sm text-sr-muted mt-1">
          Your edge component package is ready for deployment.
        </p>
      </div>

      <%= if @component_type == "agent" do %>
        <div class="sr-ui-divider">Enroll Agent</div>
        <div class="space-y-3">
          <p class="text-sm text-sr-muted">
            Run this command on the target host to enroll the agent. Uses sudo to write
            <code class="bg-sr-subtle px-1 rounded text-xs">/etc/serviceradar</code>
            and restart the agent.
          </p>
          <p class="text-xs text-sr-muted">
            The gateway address is derived from your deployment configuration by default.
          </p>
          <%= if is_binary(@enroll_cmd) and @enroll_cmd != "" do %>
            <div class="relative">
              <pre class="bg-sr-subtle p-3 rounded-lg text-xs font-mono overflow-x-auto whitespace-pre-wrap break-all"><code>{@enroll_cmd}</code></pre>
              <.ui_button
                type="button"
                phx-click="copy_token"
                phx-value-token={@enroll_cmd}
                title="Copy enroll command"
                size="sm"
                variant="ghost"
                class="absolute top-2 right-2"
              >
                <.icon name="hero-clipboard" class="size-4" />
              </.ui_button>
            </div>
          <% else %>
            <div class={ui_alert_class(variant: "error", class: "alert-soft")}>
              <.icon name="hero-exclamation-triangle" class="size-5 shrink-0" />
              <span>{@enroll_cmd_error}</span>
            </div>
          <% end %>
        </div>
      <% else %>
        <div class="sr-ui-divider">Quick Install</div>

        <div class="sr-ui-tabs sr-ui-tabs-boxed">
          <input type="radio" name="install_tabs" class="sr-ui-tab" aria-label="Docker" checked />
          <div class="sr-ui-tab-content bg-sr-surface border-sr-line rounded-sr-surface p-4 mt-2">
            <p class="text-sm text-sr-muted mb-3">
              Run this command on your target server to install via Docker:
            </p>
            <div class="relative">
              <pre class="bg-sr-subtle p-3 rounded-lg text-xs font-mono overflow-x-auto whitespace-pre-wrap break-all"><code>{@docker_cmd}</code></pre>
              <.ui_button
                type="button"
                phx-click="copy_token"
                phx-value-token={@docker_cmd}
                size="sm"
                variant="ghost"
                class="absolute top-2 right-2"
              >
                <.icon name="hero-clipboard" class="size-4" />
              </.ui_button>
            </div>
          </div>

          <input type="radio" name="install_tabs" class="sr-ui-tab" aria-label="systemd" />
          <div class="sr-ui-tab-content bg-sr-surface border-sr-line rounded-sr-surface p-4 mt-2">
            <p class="text-sm text-sr-muted mb-3">
              Run this command on your target server to install via systemd:
            </p>
            <div class="relative">
              <pre class="bg-sr-subtle p-3 rounded-lg text-xs font-mono overflow-x-auto whitespace-pre-wrap break-all"><code>{@systemd_cmd}</code></pre>
              <.ui_button
                type="button"
                phx-click="copy_token"
                phx-value-token={@systemd_cmd}
                size="sm"
                variant="ghost"
                class="absolute top-2 right-2"
              >
                <.icon name="hero-clipboard" class="size-4" />
              </.ui_button>
            </div>
          </div>
        </div>
      <% end %>

      <div class="sr-ui-divider">Package Details</div>

      <div class="grid grid-cols-2 gap-4 text-sm">
        <div>
          <div class="text-xs uppercase tracking-wide text-sr-muted">Component ID</div>
          <code class="font-mono text-xs break-all">{@package.component_id}</code>
        </div>
        <div>
          <div class="text-xs uppercase tracking-wide text-sr-muted">Package ID</div>
          <code class="font-mono text-xs">{String.slice(@package.id, 0, 8)}...</code>
        </div>
        <div>
          <div class="text-xs uppercase tracking-wide text-sr-muted">Component Type</div>
          <span>{@package.component_type}</span>
        </div>
        <div>
          <div class="text-xs uppercase tracking-wide text-sr-muted">Token Expires</div>
          <span>{format_expiry(@package.download_token_expires_at)}</span>
        </div>
        <%= if @certificate_data do %>
          <div>
            <div class="text-xs uppercase tracking-wide text-sr-muted">Certificate CN</div>
            <code class="font-mono text-xs break-all">{cert_cn(@certificate_data)}</code>
          </div>
        <% end %>
      </div>

      <%= if is_binary(@onboarding_token) do %>
        <div class="sr-ui-collapse sr-ui-collapse-arrow bg-sr-subtle">
          <input type="checkbox" />
          <div class="sr-ui-collapse-title text-sm font-medium">
            Show onboarding token (edgepkg-v3)
          </div>
          <div class="sr-ui-collapse-content">
            <div class="flex items-center gap-2">
              <code class="flex-1 text-xs font-mono break-all bg-sr-surface p-2 rounded">
                {@onboarding_token}
              </code>
              <.ui_button
                type="button"
                phx-click="copy_token"
                phx-value-token={@onboarding_token}
                size="sm"
                variant="ghost"
              >
                <.icon name="hero-clipboard" class="size-4" />
              </.ui_button>
            </div>
          </div>
        </div>
      <% end %>

      <div class={ui_alert_class(variant: "info", class: "text-sm")}>
        <.icon name="hero-information-circle" class="size-5" />
        <div>
          <div class="font-semibold">What's included in the bundle?</div>
          <ul class="list-disc list-inside text-xs mt-1 text-sr-ink/90">
            <li>Component TLS certificate and private key</li>
            <li>CA certificate chain for verification</li>
            <li>Pre-configured config.yaml</li>
            <li>Platform-detecting install script</li>
          </ul>
        </div>
      </div>

      <div class="sr-ui-modal-action">
        <.ui_button type="button" phx-click="close_create_modal" size="sm" variant="primary">
          Done
        </.ui_button>
      </div>
    </div>
    """
  end

  defp enroll_cmd_error(onboarding_token, enroll_cmd)

  defp enroll_cmd_error(_onboarding_token, enroll_cmd) when is_binary(enroll_cmd) and enroll_cmd != "", do: nil

  defp enroll_cmd_error(nil, _enroll_cmd),
    do: "The onboarding command could not be generated because the token signing key is not configured on web-ng."

  defp enroll_cmd_error(_onboarding_token, _enroll_cmd),
    do: "The onboarding command could not be generated for this package."

  defp format_expiry(nil), do: "N/A"

  defp format_expiry(%DateTime{} = dt) do
    now = DateTime.utc_now()
    diff = DateTime.diff(dt, now, :hour)

    cond do
      diff < 0 -> "Expired"
      diff < 24 -> "#{diff}h remaining"
      diff < 48 -> "Tomorrow"
      true -> "in #{div(diff, 24)}d"
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

  attr :package, :map, required: true
  attr :events, :list, required: true
  attr :timezone, :string, required: true

  defp details_modal(assigns) do
    ~H"""
    <dialog id="details_modal" class="sr-ui-modal sr-ui-modal-open" phx-hook="DialogTopLayer">
      <div class="sr-ui-modal-box sr-ui-modal-box-md">
        <form method="dialog">
          <.ui_icon_button
            phx-click="close_details_modal"
            size="sm"
            variant="ghost"
            class="absolute right-2 top-2"
          >
            x
          </.ui_icon_button>
        </form>

        <h3 class="text-lg font-bold">Package Details</h3>

        <div class="mt-4 space-y-4">
          <div class="grid grid-cols-2 gap-4">
            <div>
              <div class="text-xs uppercase tracking-wide text-sr-muted">Label</div>
              <div class="font-medium">{@package.label}</div>
            </div>
            <div>
              <div class="text-xs uppercase tracking-wide text-sr-muted">Status</div>
              <.status_badge status={@package.status} />
            </div>
            <div>
              <div class="text-xs uppercase tracking-wide text-sr-muted">Component Type</div>
              <div>{@package.component_type}</div>
            </div>
            <div>
              <div class="text-xs uppercase tracking-wide text-sr-muted">Component ID</div>
              <code class="text-sm font-mono break-all">{@package.component_id}</code>
            </div>
            <div>
              <div class="text-xs uppercase tracking-wide text-sr-muted">Security Mode</div>
              <div>{@package.security_mode}</div>
            </div>
            <div>
              <div class="text-xs uppercase tracking-wide text-sr-muted">Created</div>
              <.user_time
                id={"admin-edge-package-#{@package.id}-detail-created-at"}
                value={@package.created_at}
                timezone={@timezone}
                style={:compact}
                class="text-sm"
              />
            </div>
            <div>
              <div class="text-xs uppercase tracking-wide text-sr-muted">Token Expires</div>
              <.user_time
                id={"admin-edge-package-#{@package.id}-detail-download-token-expires-at"}
                value={@package.download_token_expires_at}
                timezone={@timezone}
                style={:compact}
                class="text-sm"
              />
            </div>
          </div>

          <div>
            <div class="text-xs uppercase tracking-wide text-sr-muted mb-1">Package ID</div>
            <code class="text-sm font-mono bg-sr-subtle p-2 rounded block">{@package.id}</code>
          </div>

          <%= if @package.gateway_id do %>
            <div>
              <div class="text-xs uppercase tracking-wide text-sr-muted mb-1">Gateway ID</div>
              <code class="text-sm font-mono bg-sr-subtle p-2 rounded block">
                {@package.gateway_id}
              </code>
            </div>
          <% end %>

          <%= if @package.parent_id do %>
            <div>
              <div class="text-xs uppercase tracking-wide text-sr-muted mb-1">Parent ID</div>
              <code class="text-sm font-mono bg-sr-subtle p-2 rounded block">
                {@package.parent_id}
              </code>
            </div>
          <% end %>

          <%!-- Checker details removed: checkers no longer supported --%>

          <%= if @package.notes do %>
            <div>
              <div class="text-xs uppercase tracking-wide text-sr-muted mb-1">Notes</div>
              <div class="text-sm">{@package.notes}</div>
            </div>
          <% end %>

          <div class="sr-ui-divider">Events</div>

          <%= if @events == [] do %>
            <p class="text-sm text-sr-muted">No events recorded yet.</p>
          <% else %>
            <div class="sr-ui-table-shell">
              <table class={ui_table_class(size: "xs")}>
                <thead>
                  <tr class="text-[11px] uppercase tracking-wide text-sr-muted">
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
                      <td class="text-xs font-mono">
                        <.user_time
                          id={"admin-edge-package-#{@package.id}-event-#{event.id}-event-time"}
                          value={event.event_time}
                          timezone={@timezone}
                          style={:compact}
                        />
                      </td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            </div>
          <% end %>
        </div>

        <div class="sr-ui-modal-action">
          <%= if @package.status == :issued do %>
            <.ui_button
              type="button"
              phx-click="revoke_package"
              phx-value-id={@package.id}
              data-confirm="Are you sure you want to revoke this package?"
              size="sm"
              variant="warning"
            >
              Revoke Package
            </.ui_button>
          <% end %>
          <.ui_button
            type="button"
            phx-click="delete_package"
            phx-value-id={@package.id}
            data-confirm="Are you sure you want to delete this package? This cannot be undone."
            size="sm"
            variant="outline"
          >
            Delete
          </.ui_button>
          <.ui_button type="button" phx-click="close_details_modal" size="sm" variant="neutral">
            Close
          </.ui_button>
        </div>
      </div>
      <form method="dialog" class="sr-ui-modal-backdrop">
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

  # Build AshPhoenix.Form for creating OnboardingPackage
  defp build_create_form(security_mode) do
    AshPhoenix.Form.for_create(OnboardingPackage, :create,
      domain: ServiceRadar.Edge,
      transform_params: fn _form, params, _action ->
        # Convert component_type string to atom if needed (allowlist prevents DoS via atom exhaustion)
        params = Map.put(params, "component_type", :agent)
        params = Map.delete(params, "initial_addon_package_ids")

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

  defp selected_initial_addon_ids(params) do
    params
    |> Map.get("initial_addon_package_ids", [])
    |> List.wrap()
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp assign_initial_addons(_package, [], _scope), do: {:ok, 0}

  defp assign_initial_addons(%OnboardingPackage{component_type: :agent} = package, addon_package_ids, scope) do
    Enum.reduce_while(addon_package_ids, {:ok, 0}, fn addon_package_id, {:ok, count} ->
      attrs = %{
        agent_uid: package.component_id,
        addon_package_id: addon_package_id,
        params: %{},
        args: []
      }

      case AddonAssignments.create(attrs, scope: scope) do
        {:ok, _assignment} -> {:cont, {:ok, count + 1}}
        {:error, error} -> {:halt, {:error, error, count}}
      end
    end)
  end

  defp assign_initial_addons(_package, _addon_package_ids, _scope), do: {:ok, 0}

  defp package_created_message({:ok, 0}), do: "Package created with gateway-issued certificates"

  defp package_created_message({:ok, 1}) do
    "Package created with gateway-issued certificates and 1 initial add-on assignment"
  end

  defp package_created_message({:ok, count}) do
    "Package created with gateway-issued certificates and #{count} initial add-on assignments"
  end

  defp package_created_message({:error, error, count}) do
    "Package created, but only #{count} initial add-on assignment(s) were created: #{format_error(error)}"
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
