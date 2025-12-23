defmodule ServiceRadarWebNGWeb.Admin.EdgePackageLive.Index do
  @moduledoc """
  LiveView for managing edge onboarding packages.
  """
  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.AdminComponents

  alias ServiceRadarWebNG.Edge.OnboardingPackages
  alias ServiceRadarWebNG.Edge.OnboardingPackage
  alias ServiceRadarWebNG.Edge.OnboardingEvents
  alias ServiceRadarWebNG.Edge.ComponentTemplates

  @impl true
  def mount(_params, _session, socket) do
    security_mode = OnboardingPackages.configured_security_mode()

    socket =
      socket
      |> assign(:page_title, "Edge Onboarding")
      |> assign(:packages, OnboardingPackages.list(%{limit: 50}))
      |> assign(:show_create_modal, false)
      |> assign(:show_details_modal, false)
      |> assign(:selected_package, nil)
      |> assign(:package_events, [])
      |> assign(:created_tokens, nil)
      |> assign(:create_form, to_form(empty_changeset()))
      |> assign(:filter_status, nil)
      |> assign(:filter_component_type, nil)
      |> assign(:security_mode, security_mode)
      |> assign(:selected_component_type, "poller")
      |> assign(:checker_templates, [])
      |> load_templates(security_mode)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params), do: socket
  defp apply_action(socket, :new, _params), do: assign(socket, :show_create_modal, true)

  defp apply_action(socket, :show, %{"id" => id}) do
    case OnboardingPackages.get(id) do
      {:ok, package} ->
        events = OnboardingEvents.list_for_package(id, limit: 20)

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
    {:noreply,
     socket
     |> assign(:show_create_modal, true)
     |> assign(:create_form, to_form(empty_changeset()))
     |> assign(:created_tokens, nil)
     |> assign(:selected_component_type, "poller")}
  end

  def handle_event("close_create_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_create_modal, false)
     |> assign(:create_form, to_form(empty_changeset()))
     |> assign(:created_tokens, nil)}
  end

  def handle_event("close_details_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_details_modal, false)
     |> assign(:selected_package, nil)
     |> assign(:package_events, [])}
  end

  def handle_event("validate_create", %{"onboarding_package" => params}, socket) do
    component_type = params["component_type"] || "poller"

    changeset =
      %OnboardingPackage{}
      |> OnboardingPackage.create_changeset(params)
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:create_form, to_form(changeset))
     |> assign(:selected_component_type, component_type)}
  end

  def handle_event("create_package", %{"onboarding_package" => params}, socket) do
    actor = get_actor(socket)
    attrs = build_package_attrs(params, socket.assigns.security_mode)

    case OnboardingPackages.create(attrs, actor: actor) do
      {:ok, result} ->
        {:noreply,
         socket
         |> assign(:created_tokens, result)
         |> assign(:packages, OnboardingPackages.list(%{limit: 50}))
         |> put_flash(:info, "Package created successfully")}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:create_form, to_form(changeset))
         |> put_flash(:error, "Failed to create package")}
    end
  end

  def handle_event("revoke_package", %{"id" => id}, socket) do
    user = socket.assigns.current_scope.user
    actor = if user, do: user.email, else: "system"

    case OnboardingPackages.revoke(id, actor: actor, reason: "Revoked from admin UI") do
      {:ok, _package} ->
        {:noreply,
         socket
         |> assign(:packages, OnboardingPackages.list(%{limit: 50}))
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
    user = socket.assigns.current_scope.user
    actor = if user, do: user.email, else: "system"

    case OnboardingPackages.delete(id, actor: actor, reason: "Deleted from admin UI") do
      {:ok, _package} ->
        {:noreply,
         socket
         |> assign(:packages, OnboardingPackages.list(%{limit: 50}))
         |> assign(:show_details_modal, false)
         |> assign(:selected_package, nil)
         |> put_flash(:info, "Package deleted successfully")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete package")}
    end
  end

  def handle_event("filter", %{"status" => status, "component_type" => type}, socket) do
    filters = %{limit: 50}
    filters = if status != "", do: Map.put(filters, :status, [status]), else: filters
    filters = if type != "", do: Map.put(filters, :component_type, [type]), else: filters

    {:noreply,
     socket
     |> assign(:filter_status, if(status == "", do: nil, else: status))
     |> assign(:filter_component_type, if(type == "", do: nil, else: type))
     |> assign(:packages, OnboardingPackages.list(filters))}
  end

  def handle_event("copy_token", %{"token" => token}, socket) do
    {:noreply,
     socket
     |> push_event("clipboard", %{text: token})
     |> put_flash(:info, "Token copied to clipboard")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-6xl p-6 space-y-6">
        <.admin_nav current_path="/admin/edge-packages" />

        <div class="flex flex-wrap items-center justify-between gap-4">
          <div>
            <h1 class="text-2xl font-semibold text-base-content">Edge Onboarding</h1>
            <p class="text-sm text-base-content/60">
              Manage edge component onboarding packages for pollers, agents, and checkers.
            </p>
          </div>
          <.ui_button variant="primary" size="sm" phx-click="open_create_modal">
            <.icon name="hero-plus" class="size-4" /> New Package
          </.ui_button>
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
              <select
                name="component_type"
                class="select select-sm select-bordered"
                phx-change="filter"
              >
                <option value="">All Types</option>
                <option value="poller" selected={@filter_component_type == "poller"}>Poller</option>
                <option value="agent" selected={@filter_component_type == "agent"}>Agent</option>
                <option value="checker" selected={@filter_component_type == "checker"}>
                  Checker
                </option>
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
                            :if={package.status == "issued"}
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
      </div>

      <.create_modal
        :if={@show_create_modal}
        form={@create_form}
        created_tokens={@created_tokens}
        security_mode={@security_mode}
        selected_component_type={@selected_component_type}
        checker_templates={@checker_templates}
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
      <div class="modal-box max-w-lg">
        <form method="dialog">
          <button
            class="btn btn-sm btn-circle btn-ghost absolute right-2 top-2"
            phx-click="close_create_modal"
          >
            x
          </button>
        </form>

        <%= if @created_tokens do %>
          <h3 class="text-lg font-bold">Package Created</h3>
          <p class="py-2 text-sm text-base-content/70">
            Save these tokens securely. They will not be shown again.
          </p>

          <div class="space-y-4 mt-4">
            <div class="rounded-lg border border-base-200 bg-base-200/30 p-4">
              <div class="text-xs uppercase tracking-wide text-base-content/60 mb-2">
                Download Token
              </div>
              <div class="flex items-center gap-2">
                <code class="flex-1 text-sm font-mono break-all bg-base-100 p-2 rounded">
                  {@created_tokens.download_token}
                </code>
                <button
                  type="button"
                  class="btn btn-sm btn-ghost"
                  phx-click="copy_token"
                  phx-value-token={@created_tokens.download_token}
                >
                  <.icon name="hero-clipboard" class="size-4" />
                </button>
              </div>
            </div>

            <div class="rounded-lg border border-base-200 bg-base-200/30 p-4">
              <div class="text-xs uppercase tracking-wide text-base-content/60 mb-2">
                Package ID
              </div>
              <div class="flex items-center gap-2">
                <code class="flex-1 text-sm font-mono break-all bg-base-100 p-2 rounded">
                  {@created_tokens.package.id}
                </code>
                <button
                  type="button"
                  class="btn btn-sm btn-ghost"
                  phx-click="copy_token"
                  phx-value-token={@created_tokens.package.id}
                >
                  <.icon name="hero-clipboard" class="size-4" />
                </button>
              </div>
            </div>

            <div class="alert alert-warning text-sm">
              <.icon name="hero-exclamation-triangle" class="size-5" />
              <span>
                Use these tokens with the CLI:
                <code>
                  serviceradar edge package download --id &lt;id&gt; --download-token &lt;token&gt;
                </code>
              </span>
            </div>
          </div>

          <div class="modal-action">
            <button type="button" class="btn btn-primary" phx-click="close_create_modal">
              Done
            </button>
          </div>
        <% else %>
          <h3 class="text-lg font-bold">Create Edge Package</h3>
          <p class="py-2 text-sm text-base-content/70">
            Create a new onboarding package for an edge component.
          </p>

          <.form
            for={@form}
            id="create_package_form"
            phx-change="validate_create"
            phx-submit="create_package"
            class="space-y-4 mt-4"
          >
            <.input
              field={@form[:label]}
              type="text"
              label="Label"
              placeholder="e.g., production-poller-01"
              required
            />

            <.input
              field={@form[:component_type]}
              type="select"
              label="Component Type"
              options={[{"Poller", "poller"}, {"Agent", "agent"}, {"Checker", "checker"}]}
            />

            <div class="form-control">
              <label class="label">
                <span class="label-text">Security Mode</span>
              </label>
              <div class="flex items-center gap-2">
                <.ui_badge variant="info" size="sm">
                  {String.upcase(@security_mode)}
                </.ui_badge>
                <span class="text-xs text-base-content/60">
                  (Configured by deployment environment)
                </span>
              </div>
            </div>

            <%= if @selected_component_type == "checker" do %>
              <div class="form-control">
                <label class="label">
                  <span class="label-text">Checker Kind</span>
                </label>
                <%= if @checker_templates != [] do %>
                  <select
                    name="onboarding_package[checker_kind]"
                    class="select select-bordered w-full"
                  >
                    <option value="">Select checker template...</option>
                    <%= for template <- @checker_templates do %>
                      <option value={template.kind}>{template.kind}</option>
                    <% end %>
                    <option value="_custom">Custom (enter below)</option>
                  </select>
                <% else %>
                  <input
                    type="text"
                    name="onboarding_package[checker_kind]"
                    class="input input-bordered w-full"
                    placeholder="e.g., sysmon, snmp, rperf-checker"
                  />
                <% end %>
                <label class="label">
                  <span class="label-text-alt text-base-content/60">
                    The type of checker to configure
                  </span>
                </label>
              </div>

              <div class="form-control">
                <label class="label">
                  <span class="label-text">Checker Config (JSON, optional)</span>
                </label>
                <textarea
                  name="onboarding_package[checker_config_json]"
                  class="textarea textarea-bordered w-full font-mono text-sm"
                  rows="4"
                  placeholder='{"interval": 30, "timeout": 10}'
                ></textarea>
                <label class="label">
                  <span class="label-text-alt text-base-content/60">
                    Custom configuration JSON for the checker
                  </span>
                </label>
              </div>
            <% end %>

            <.input
              field={@form[:poller_id]}
              type="text"
              label="Poller ID (Optional)"
              placeholder="Enter the poller ID to assign this package to"
            />

            <.input
              field={@form[:notes]}
              type="textarea"
              label="Notes (Optional)"
              placeholder="Additional notes about this package"
            />

            <div class="modal-action">
              <button type="button" class="btn" phx-click="close_create_modal">Cancel</button>
              <button type="submit" class="btn btn-primary">Create Package</button>
            </div>
          </.form>
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

          <%= if @package.poller_id do %>
            <div>
              <div class="text-xs uppercase tracking-wide text-base-content/60 mb-1">Poller ID</div>
              <code class="text-sm font-mono bg-base-200 p-2 rounded block">
                {@package.poller_id}
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

          <%= if @package.checker_kind do %>
            <div>
              <div class="text-xs uppercase tracking-wide text-base-content/60 mb-1">
                Checker Kind
              </div>
              <div class="text-sm">{@package.checker_kind}</div>
            </div>
          <% end %>

          <%= if @package.checker_config_json && @package.checker_config_json != %{} do %>
            <div>
              <div class="text-xs uppercase tracking-wide text-base-content/60 mb-1">
                Checker Config
              </div>
              <code class="text-xs font-mono bg-base-200 p-2 rounded block whitespace-pre-wrap">
                {Jason.encode!(@package.checker_config_json, pretty: true)}
              </code>
            </div>
          <% end %>

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
          <%= if @package.status == "issued" do %>
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
    variant =
      case assigns.status do
        "issued" -> "info"
        "delivered" -> "success"
        "activated" -> "success"
        "revoked" -> "error"
        "expired" -> "warning"
        "deleted" -> "ghost"
        _ -> "ghost"
      end

    assigns = assign(assigns, :variant, variant)

    ~H"""
    <.ui_badge variant={@variant} size="xs">{@status}</.ui_badge>
    """
  end

  defp event_variant(event_type) do
    case event_type do
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

  defp empty_changeset do
    %OnboardingPackage{}
    |> OnboardingPackage.create_changeset(%{})
  end

  # Load templates for checkers
  defp load_templates(socket, security_mode) do
    checker_templates =
      case ComponentTemplates.list("checker", security_mode) do
        {:ok, templates} -> templates
        {:error, _} -> []
      end

    assign(socket, :checker_templates, checker_templates)
  end

  defp get_actor(socket) do
    case socket.assigns.current_scope.user do
      nil -> "system"
      user -> user.email
    end
  end

  defp build_package_attrs(params, security_mode) do
    component_type = params["component_type"] || "poller"

    %{
      label: params["label"],
      component_type: component_type,
      poller_id: params["poller_id"],
      security_mode: security_mode,
      notes: params["notes"],
      parent_id: params["parent_id"],
      checker_kind: params["checker_kind"],
      checker_config_json: parse_checker_config(params["checker_config_json"])
    }
    |> add_parent_type(component_type)
  end

  defp parse_checker_config(nil), do: %{}
  defp parse_checker_config(""), do: %{}
  defp parse_checker_config(config) when is_map(config), do: config

  defp parse_checker_config(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, config} -> config
      {:error, _} -> %{}
    end
  end

  defp add_parent_type(attrs, "agent"), do: Map.put(attrs, :parent_type, "poller")
  defp add_parent_type(attrs, "checker"), do: Map.put(attrs, :parent_type, "agent")
  defp add_parent_type(attrs, _), do: attrs
end
