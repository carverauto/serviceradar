defmodule ServiceRadarWebNGWeb.Admin.DashboardPackageLive.Index do
  @moduledoc """
  LiveView for importing and enabling browser dashboard packages.

  This settings surface stays gated on `plugins.view` / `plugins.stage` /
  `plugins.approve` — those permissions cover catalog import, verification, and
  package enablement. Binding a route creates a `DashboardInstance`, which Ash
  authorizes with `dashboards.packages.enable` (aliased from
  `cli.dashboard.enable`). Sharing a bound instance is a separate control on
  the package dashboard itself, available to the instance owner and to
  `dashboards.packages.share` holders.
  """

  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadar.Dashboards.DashboardInstance
  alias ServiceRadar.Dashboards.DashboardPackage
  alias ServiceRadarWebNG.Dashboards
  alias ServiceRadarWebNG.Plugins.Storage
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.Settings.Shell

  require Logger

  Module.register_attribute(__MODULE__, :sobelow_skip, accumulate: true)

  @manifest_upload_bytes 512 * 1024

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if RBAC.can?(scope, "plugins.view") do
      socket =
        socket
        |> assign(:page_title, "Dashboard Packages")
        |> assign(:current_path, "/settings/dashboards/packages")
        |> assign(:can_import_packages, RBAC.can?(scope, "plugins.stage"))
        |> assign(:can_manage_packages, RBAC.can?(scope, "plugins.approve"))
        |> assign(:packages, if(connected?(socket), do: list_packages(scope), else: []))
        |> assign(:enabled_instances, if(connected?(socket), do: list_enabled_instances(scope), else: []))
        |> assign(:show_import_modal, false)
        |> assign(:show_details_modal, false)
        |> assign(:selected_package, nil)
        |> assign(:import_form, default_import_form())
        |> assign(:instance_form, default_instance_form())
        |> assign(:form_errors, [])
        |> allow_upload(:manifest,
          accept: ~w(.json),
          max_entries: 1,
          max_file_size: @manifest_upload_bytes,
          auto_upload: true
        )
        |> allow_upload(:wasm,
          accept: ~w(.js .wasm),
          max_entries: 1,
          max_file_size: Storage.max_upload_bytes(),
          auto_upload: true
        )

      {:ok, socket}
    else
      {:ok,
       socket
       |> put_flash(:error, "You don't have permission to access dashboard packages.")
       |> redirect(to: ~p"/dashboard")}
    end
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:show_import_modal, false)
    |> assign(:show_details_modal, false)
    |> assign(:selected_package, nil)
    |> assign(:form_errors, [])
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:show_import_modal, true)
    |> assign(:show_details_modal, false)
    |> assign(:selected_package, nil)
    |> assign(:form_errors, [])
  end

  defp apply_action(socket, :show, %{"id" => id}) do
    if connected?(socket) do
      scope = socket.assigns.current_scope

      case Dashboards.get_package(id, scope: scope) do
        {:ok, package} ->
          socket
          |> assign(:show_import_modal, false)
          |> assign(:show_details_modal, true)
          |> assign(:selected_package, package)
          |> assign(:instance_form, default_instance_form(package))
          |> assign(:form_errors, [])

        {:error, :not_found} ->
          socket
          |> put_flash(:error, "Dashboard package not found")
          |> push_navigate(to: ~p"/settings/dashboards/packages")

        {:error, error} ->
          socket
          |> put_flash(:error, "Failed to load dashboard package: #{format_error(error)}")
          |> push_navigate(to: ~p"/settings/dashboards/packages")
      end
    else
      assign(socket, :show_details_modal, false)
    end
  end

  @impl true
  def handle_event("open_import_modal", _params, %{assigns: %{can_import_packages: false}} = socket) do
    {:noreply, put_flash(socket, :error, "You don't have permission to import dashboard packages.")}
  end

  def handle_event("open_import_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_import_modal, true)
     |> assign(:import_form, default_import_form())
     |> assign(:form_errors, [])}
  end

  def handle_event("close_modal", _params, socket) do
    {:noreply, push_navigate(socket, to: ~p"/settings/dashboards/packages")}
  end

  def handle_event("import_change", %{"import" => params}, socket) do
    {:noreply, assign(socket, :import_form, params)}
  end

  def handle_event("instance_change", %{"instance" => params}, socket) do
    {:noreply, assign(socket, :instance_form, params)}
  end

  def handle_event("refresh", _params, socket) do
    scope = socket.assigns.current_scope

    {:noreply,
     socket
     |> assign(:packages, list_packages(scope))
     |> assign(:enabled_instances, list_enabled_instances(scope))}
  end

  def handle_event("import_package", _params, %{assigns: %{can_import_packages: false}} = socket) do
    {:noreply, put_flash(socket, :error, "You don't have permission to import dashboard packages.")}
  end

  def handle_event("import_package", %{"import" => params}, socket) do
    scope = socket.assigns.current_scope

    with {:ok, package} <- import_package_from_source(socket, params, scope),
         {:ok, package} <- maybe_enable_after_import(package, params, scope),
         {:ok, _instance} <- maybe_create_instance_after_import(package, params, scope) do
      {:noreply,
       socket
       |> put_flash(:info, "Dashboard package imported")
       |> assign(:packages, list_packages(scope))
       |> assign(:enabled_instances, list_enabled_instances(scope))
       |> push_navigate(to: ~p"/settings/dashboards/packages/#{package.id}")}
    else
      {:error, error} ->
        message = format_error(error)

        Logger.warning("dashboard package import failed: #{inspect(error)}")

        {:noreply,
         socket
         |> assign(:form_errors, [message])
         |> put_flash(:error, "Import failed: #{message}")}
    end
  end

  def handle_event("enable_package", %{"id" => _id}, %{assigns: %{can_manage_packages: false}} = socket) do
    {:noreply, put_flash(socket, :error, "You don't have permission to enable dashboard packages.")}
  end

  def handle_event("enable_package", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    case Dashboards.enable_package(id, scope: scope) do
      {:ok, package} ->
        {:noreply,
         socket
         |> put_flash(:info, "Dashboard package enabled")
         |> refresh_package_assigns(package, scope)}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, "Enable failed: #{format_error(error)}")}
    end
  end

  def handle_event("disable_package", %{"id" => _id}, %{assigns: %{can_manage_packages: false}} = socket) do
    {:noreply, put_flash(socket, :error, "You don't have permission to disable dashboard packages.")}
  end

  def handle_event("disable_package", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    case Dashboards.disable_package(id, scope: scope) do
      {:ok, package} ->
        {:noreply,
         socket
         |> put_flash(:info, "Dashboard package disabled")
         |> refresh_package_assigns(package, scope)}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, "Disable failed: #{format_error(error)}")}
    end
  end

  def handle_event("create_instance", %{"instance" => params}, %{assigns: %{selected_package: package}} = socket)
      when not is_nil(package) do
    scope = socket.assigns.current_scope

    with {:ok, package} <- ensure_package_enabled(package, scope),
         {:ok, settings} <- parse_settings(params["settings_json"]),
         {:ok, instance} <-
           Dashboards.create_instance(
             package,
             %{
               name: normalize_string(params["name"]) || package.name,
               route_slug: normalize_slug(params["route_slug"]) || default_route_slug(package),
               placement: normalize_placement(params["placement"]),
               enabled: true,
               settings: settings
             },
             scope: scope
           ),
         {:ok, _instance} <- maybe_set_default_instance(instance, params, scope) do
      {:noreply,
       socket
       |> put_flash(:info, "Dashboard route enabled")
       |> assign(:enabled_instances, list_enabled_instances(scope))
       |> assign(:selected_package, package)
       |> assign(:instance_form, default_instance_form(package))}
    else
      {:error, error} ->
        message = format_error(error)
        {:noreply, socket |> assign(:form_errors, [message]) |> put_flash(:error, message)}
    end
  end

  def handle_event("create_instance", _params, socket) do
    {:noreply, put_flash(socket, :error, "Select a package before creating a dashboard route.")}
  end

  def handle_event("edit_instance", %{"id" => _id}, %{assigns: %{can_manage_packages: false}} = socket) do
    {:noreply, put_flash(socket, :error, "You don't have permission to edit dashboard routes.")}
  end

  def handle_event("edit_instance", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    case Dashboards.get_instance(id, scope: scope) do
      {:ok, instance} ->
        {:noreply, socket |> assign(:instance_form, instance_form(instance)) |> assign(:form_errors, [])}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, "Dashboard route not found: #{format_error(error)}")}
    end
  end

  def handle_event("cancel_instance_edit", _params, socket) do
    {:noreply,
     socket
     |> assign(:instance_form, default_instance_form(socket.assigns.selected_package))
     |> assign(:form_errors, [])}
  end

  def handle_event("update_instance", %{"instance" => _params}, %{assigns: %{can_manage_packages: false}} = socket) do
    {:noreply, put_flash(socket, :error, "You don't have permission to edit dashboard routes.")}
  end

  def handle_event("update_instance", %{"instance" => %{"id" => id} = params}, socket) do
    scope = socket.assigns.current_scope

    with {:ok, settings} <- parse_settings(params["settings_json"]),
         {:ok, _instance} <-
           Dashboards.update_instance(
             id,
             %{
               name: normalize_string(params["name"]),
               route_slug: normalize_slug(params["route_slug"]),
               placement: normalize_placement(params["placement"]),
               enabled: truthy?(params["enabled"]),
               settings: settings
             },
             scope: scope
           ) do
      {:noreply,
       socket
       |> put_flash(:info, "Dashboard route updated")
       |> assign(:enabled_instances, list_enabled_instances(scope))
       |> assign(:instance_form, default_instance_form(socket.assigns.selected_package))}
    else
      {:error, error} ->
        message = format_error(error)
        {:noreply, socket |> assign(:form_errors, [message]) |> put_flash(:error, message)}
    end
  end

  def handle_event("set_default_instance", %{"id" => _id}, %{assigns: %{can_manage_packages: false}} = socket) do
    {:noreply, put_flash(socket, :error, "You don't have permission to choose default dashboard routes.")}
  end

  def handle_event("set_default_instance", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    case Dashboards.set_default_instance(id, scope: scope) do
      {:ok, instance} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{instance.name} is now the default #{placement_label(instance.placement)} route")
         |> assign(:enabled_instances, list_enabled_instances(scope))}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, "Failed to set default route: #{format_error(error)}")}
    end
  end

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
        <div class="flex flex-wrap items-center justify-between gap-4">
          <div>
            <h1 class="text-2xl font-semibold text-sr-ink">Dashboard Packages</h1>
            <p class="text-sm text-sr-muted">
              Import browser dashboard packages and expose them as ServiceRadar dashboard routes.
            </p>
          </div>
          <div class="flex gap-2">
            <.ui_button variant="ghost" size="sm" phx-click="refresh">
              <.icon name="hero-arrow-path" class="size-4" /> Refresh
            </.ui_button>
            <.ui_button
              :if={@can_import_packages}
              variant="primary"
              size="sm"
              phx-click="open_import_modal"
            >
              <.icon name="hero-arrow-up-tray" class="size-4" /> Import Package
            </.ui_button>
          </div>
        </div>

        <.ui_panel>
          <:header>
            <div>
              <div class="text-sm font-semibold">Imported Packages</div>
              <p class="text-xs text-sr-muted">{length(@packages)} package(s)</p>
            </div>
          </:header>

          <%= if @packages == [] do %>
            <div class="rounded-sr-surface border border-dashed border-sr-line bg-sr-surface p-8 text-center">
              <div class="text-sm font-semibold">No dashboard packages imported</div>
              <p class="mt-1 text-xs text-sr-muted">
                Import a manifest JSON file and matching renderer artifact to create the first package.
              </p>
            </div>
          <% else %>
            <div class="sr-ui-table-shell">
              <table class={ui_table_class(size: "sm")}>
                <thead>
                  <tr>
                    <th>Package</th>
                    <th>Renderer</th>
                    <th>Frames</th>
                    <th>Status</th>
                    <th>Routes</th>
                    <th class="text-right">Actions</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={package <- @packages} class="hover:bg-sr-subtle/40">
                    <td>
                      <div class="font-medium">{package.name}</div>
                      <div class="font-mono text-xs text-sr-muted">
                        {package.dashboard_id} · {package.version}
                      </div>
                    </td>
                    <td>
                      <div class="text-xs">{package.renderer["interface_version"] || "unknown"}</div>
                      <div class="font-mono text-xs text-sr-muted">
                        {short_hash(package.content_hash)}
                      </div>
                    </td>
                    <td class="text-xs">{length(package.data_frames || [])}</td>
                    <td>
                      <div class="flex flex-wrap gap-1">
                        <.ui_badge size="sm" variant={status_badge_variant(package.status)}>
                          {status_label(package.status)}
                        </.ui_badge>
                        <.ui_badge
                          size="sm"
                          variant={verification_badge_variant(package.verification_status)}
                        >
                          {package.verification_status || "unverified"}
                        </.ui_badge>
                      </div>
                    </td>
                    <td>
                      <div
                        :for={instance <- package_instances(@enabled_instances, package)}
                        class="text-xs"
                      >
                        <.link
                          navigate={~p"/dashboards/#{instance.route_slug}"}
                          class="text-sr-brand hover:underline"
                        >
                          /dashboards/{instance.route_slug}
                        </.link>
                      </div>
                    </td>
                    <td class="text-right">
                      <div class="flex justify-end gap-2">
                        <.ui_button
                          patch={~p"/settings/dashboards/packages/#{package.id}"}
                          size="xs"
                          variant="ghost"
                        >
                          Details
                        </.ui_button>
                        <.ui_button
                          :if={@can_manage_packages and package.status != :enabled}
                          phx-click="enable_package"
                          phx-value-id={package.id}
                          size="xs"
                          variant="primary"
                        >
                          Enable
                        </.ui_button>
                        <.ui_button
                          :if={@can_manage_packages and package.status == :enabled}
                          phx-click="disable_package"
                          phx-value-id={package.id}
                          size="xs"
                          variant="outline"
                        >
                          Disable
                        </.ui_button>
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </.ui_panel>

        <.import_modal
          :if={@show_import_modal}
          form={@import_form}
          errors={@form_errors}
          uploads={@uploads}
        />

        <.details_modal
          :if={@show_details_modal and @selected_package}
          package={@selected_package}
          instances={package_instances(@enabled_instances, @selected_package)}
          instance_form={@instance_form}
          errors={@form_errors}
          can_manage_packages={@can_manage_packages}
        />
      </Shell.settings_chrome>
    </Layouts.app>
    """
  end

  attr(:form, :map, required: true)
  attr(:errors, :list, required: true)
  attr(:uploads, :map, required: true)

  defp import_modal(assigns) do
    ~H"""
    <dialog
      id="dashboard-package-import-modal"
      class="sr-ui-modal sr-ui-modal-open"
      phx-hook="DialogTopLayer"
      data-cancel="close_modal"
    >
      <div class="sr-ui-modal-box sr-ui-modal-box-md">
        <div class="flex items-start justify-between gap-4">
          <div>
            <h2 class="text-lg font-semibold">Import Dashboard Package</h2>
            <p class="text-sm text-sr-muted">
              Import a browser dashboard package from an upload or trusted GitHub source.
            </p>
          </div>
          <.ui_icon_button phx-click="close_modal" size="sm" variant="ghost">
            <.icon name="hero-x-mark" class="size-5" />
          </.ui_icon_button>
        </div>

        <.error_list errors={@errors} />

        <.form
          for={@form}
          as={:import}
          phx-change="import_change"
          phx-submit="import_package"
          class="mt-5 space-y-4"
        >
          <label class="flex flex-col gap-1.5">
            <span class="text-sm font-medium text-sr-ink">Source</span>
            <select name="import[source_type]" class={ui_field_class(size: "sm")}>
              <option value="upload" selected={@form["source_type"] in [nil, "", "upload"]}>
                Upload
              </option>
              <option value="github" selected={@form["source_type"] == "github"}>GitHub</option>
            </select>
          </label>

          <%= if @form["source_type"] == "github" do %>
            <div class="grid gap-4 sm:grid-cols-2">
              <label class="flex flex-col gap-1.5 sm:col-span-2">
                <span class="text-sm font-medium text-sr-ink">GitHub repo URL</span>
                <input
                  class={ui_field_class(size: "sm")}
                  name="import[source_repo_url]"
                  placeholder="https://github.com/org/repo"
                  value={@form["source_repo_url"]}
                />
              </label>
              <label class="flex flex-col gap-1.5">
                <span class="text-sm font-medium text-sr-ink">Ref</span>
                <input
                  class={ui_field_class(size: "sm")}
                  name="import[source_ref]"
                  placeholder="main"
                  value={@form["source_ref"]}
                />
              </label>
              <label class="flex flex-col gap-1.5">
                <span class="text-sm font-medium text-sr-ink">Manifest path</span>
                <input
                  class={ui_field_class(size: "sm")}
                  name="import[source_manifest_path]"
                  placeholder="dashboard.json"
                  value={@form["source_manifest_path"]}
                />
              </label>
              <label class="flex flex-col gap-1.5 sm:col-span-2">
                <span class="text-sm font-medium text-sr-ink">Renderer path override</span>
                <input
                  class={ui_field_class(size: "sm")}
                  name="import[renderer_path]"
                  placeholder="Use manifest renderer.artifact"
                  value={@form["renderer_path"]}
                />
              </label>
            </div>
          <% else %>
            <div class="grid gap-4 sm:grid-cols-2">
              <label class="flex flex-col gap-1.5">
                <span class="text-sm font-medium text-sr-ink">Manifest JSON</span>
                <.live_file_input
                  upload={@uploads.manifest}
                  class={
                    ui_field_class(
                      size: "sm",
                      class:
                        "w-full file:mr-3 file:rounded-sr-control file:border-0 file:bg-sr-subtle file:px-2 file:py-1 file:text-xs file:font-semibold file:text-sr-ink"
                    )
                  }
                />
              </label>
              <label class="flex flex-col gap-1.5">
                <span class="text-sm font-medium text-sr-ink">Renderer artifact</span>
                <.live_file_input
                  upload={@uploads.wasm}
                  class={
                    ui_field_class(
                      size: "sm",
                      class:
                        "w-full file:mr-3 file:rounded-sr-control file:border-0 file:bg-sr-subtle file:px-2 file:py-1 file:text-xs file:font-semibold file:text-sr-ink"
                    )
                  }
                />
              </label>
            </div>

            <div class="grid gap-4 sm:grid-cols-2">
              <label class="flex flex-col gap-1.5">
                <span class="text-sm font-medium text-sr-ink">Source ref</span>
                <input
                  class={ui_field_class(size: "sm")}
                  name="import[source_ref]"
                  value={@form["source_ref"]}
                />
              </label>
              <label class="flex flex-col gap-1.5">
                <span class="text-sm font-medium text-sr-ink">Manifest path</span>
                <input
                  class={ui_field_class(size: "sm")}
                  name="import[source_manifest_path]"
                  value={@form["source_manifest_path"]}
                />
              </label>
            </div>
          <% end %>

          <div class="rounded-sr-surface border border-sr-line bg-sr-subtle/40 p-3">
            <label class="flex cursor-pointer items-center justify-start gap-3 p-0">
              <input
                type="checkbox"
                class={ui_checkbox_class()}
                name="import[enable]"
                checked={@form["enable"] == "true"}
                value="true"
              />
              <span class="text-sm font-medium text-sr-ink">Enable package after import</span>
            </label>
            <label class="flex cursor-pointer items-center justify-start gap-3 mt-3  p-0">
              <input
                type="checkbox"
                class={ui_checkbox_class()}
                name="import[create_instance]"
                checked={@form["create_instance"] == "true"}
                value="true"
              />
              <span class="text-sm font-medium text-sr-ink">Create default dashboard route</span>
            </label>
          </div>

          <div class="sr-ui-modal-action">
            <.ui_button type="button" phx-click="close_modal" size="sm" variant="ghost">
              Cancel
            </.ui_button>
            <.ui_button type="submit" size="sm" variant="primary">
              <.icon name="hero-arrow-up-tray" class="size-4" /> Import
            </.ui_button>
          </div>
        </.form>
      </div>
    </dialog>
    """
  end

  attr(:package, :any, required: true)
  attr(:instances, :list, required: true)
  attr(:instance_form, :map, required: true)
  attr(:errors, :list, required: true)
  attr(:can_manage_packages, :boolean, required: true)

  defp details_modal(assigns) do
    ~H"""
    <dialog
      id="dashboard-package-details-modal"
      class="sr-ui-modal sr-ui-modal-open"
      phx-hook="DialogTopLayer"
      data-cancel="close_modal"
    >
      <div class="sr-ui-modal-box sr-ui-modal-box-lg">
        <div class="flex items-start justify-between gap-4">
          <div>
            <h2 class="text-lg font-semibold">{@package.name}</h2>
            <p class="font-mono text-xs text-sr-muted">
              {@package.dashboard_id} · {@package.version}
            </p>
          </div>
          <.ui_icon_button phx-click="close_modal" size="sm" variant="ghost">
            <.icon name="hero-x-mark" class="size-5" />
          </.ui_icon_button>
        </div>

        <.error_list errors={@errors} />

        <div class="mt-5 grid gap-4 lg:grid-cols-[1fr_18rem]">
          <div class="space-y-4">
            <div class="rounded-sr-surface border border-sr-line p-4">
              <div class="text-sm font-semibold">Renderer</div>
              <dl class="mt-3 grid gap-2 text-xs sm:grid-cols-2">
                <div>
                  <dt class="text-sr-muted">Interface</dt>
                  <dd class="font-mono">{@package.renderer["interface_version"] || "unknown"}</dd>
                </div>
                <div>
                  <dt class="text-sr-muted">Artifact</dt>
                  <dd class="font-mono">{@package.renderer["artifact"]}</dd>
                </div>
                <div class="sm:col-span-2">
                  <dt class="text-sr-muted">SHA256</dt>
                  <dd class="break-all font-mono">
                    {@package.content_hash || @package.renderer["sha256"]}
                  </dd>
                </div>
              </dl>
            </div>

            <div class="rounded-sr-surface border border-sr-line p-4">
              <div class="text-sm font-semibold">Data Frames</div>
              <div class="mt-3 space-y-3">
                <div :for={frame <- @package.data_frames || []} class="rounded-lg bg-sr-subtle/60 p-3">
                  <div class="flex flex-wrap items-center gap-2">
                    <.ui_badge size="sm" variant="outline">{frame["id"]}</.ui_badge>
                    <.ui_badge size="sm" variant="ghost">{frame["encoding"]}</.ui_badge>
                    <.ui_badge :if={frame["limit"]} size="sm" variant="ghost">
                      limit {frame["limit"]}
                    </.ui_badge>
                  </div>
                  <div class="mt-2 font-mono text-xs text-sr-muted">{frame["query"]}</div>
                </div>
              </div>
            </div>
          </div>

          <aside class="space-y-4">
            <div class="rounded-sr-surface border border-sr-line p-4">
              <div class="text-sm font-semibold">Status</div>
              <div class="mt-3 flex flex-wrap gap-2">
                <.ui_badge size="sm" variant={status_badge_variant(@package.status)}>
                  {status_label(@package.status)}
                </.ui_badge>
                <.ui_badge
                  size="sm"
                  variant={verification_badge_variant(@package.verification_status)}
                >
                  {@package.verification_status || "unverified"}
                </.ui_badge>
              </div>
              <div class="mt-4 flex gap-2">
                <.ui_button
                  :if={@can_manage_packages and @package.status != :enabled}
                  phx-click="enable_package"
                  phx-value-id={@package.id}
                  size="sm"
                  variant="primary"
                >
                  Enable
                </.ui_button>
                <.ui_button
                  :if={@can_manage_packages and @package.status == :enabled}
                  phx-click="disable_package"
                  phx-value-id={@package.id}
                  size="sm"
                  variant="outline"
                >
                  Disable
                </.ui_button>
              </div>
            </div>

            <div class="rounded-sr-surface border border-sr-line p-4">
              <div class="text-sm font-semibold">Routes</div>
              <div :if={@instances == []} class="mt-2 text-xs text-sr-muted">
                No enabled routes.
              </div>
              <div :for={instance <- @instances} class="mt-3 rounded-lg bg-sr-subtle/50 p-3 text-xs">
                <div class="flex items-start justify-between gap-3">
                  <div class="min-w-0">
                    <div class="flex flex-wrap items-center gap-2">
                      <.link
                        navigate={~p"/dashboards/#{instance.route_slug}"}
                        class="text-sr-brand hover:underline"
                      >
                        /dashboards/{instance.route_slug}
                      </.link>
                      <.ui_badge :if={instance.is_default} size="xs" variant="info">
                        Default
                      </.ui_badge>
                      <.ui_badge size="xs" variant="ghost">
                        {placement_label(instance.placement)}
                      </.ui_badge>
                    </div>
                    <div class="mt-1 truncate text-sr-muted">{instance.name}</div>
                  </div>
                  <div :if={@can_manage_packages} class="flex shrink-0 items-center gap-1">
                    <.ui_icon_button
                      :if={!instance.is_default}
                      type="button"
                      phx-click="set_default_instance"
                      phx-value-id={instance.id}
                      title="Set as default"
                      size="xs"
                      variant="ghost"
                    >
                      <.icon name="hero-star" class="size-3.5" />
                    </.ui_icon_button>
                    <.ui_icon_button
                      type="button"
                      phx-click="edit_instance"
                      phx-value-id={instance.id}
                      title="Edit route settings"
                      size="xs"
                      variant="ghost"
                    >
                      <.icon name="hero-pencil" class="size-3.5" />
                    </.ui_icon_button>
                  </div>
                </div>
              </div>
            </div>

            <.form
              :if={@can_manage_packages}
              for={@instance_form}
              as={:instance}
              phx-change="instance_change"
              phx-submit={
                if editing_instance?(@instance_form), do: "update_instance", else: "create_instance"
              }
              class="rounded-sr-surface border border-sr-line p-4 space-y-3"
            >
              <input
                :if={editing_instance?(@instance_form)}
                type="hidden"
                name="instance[id]"
                value={@instance_form["id"]}
              />
              <div class="flex items-center justify-between gap-3">
                <div class="text-sm font-semibold">
                  <%= if editing_instance?(@instance_form) do %>
                    Edit Dashboard Route
                  <% else %>
                    Create Dashboard Route
                  <% end %>
                </div>
                <.ui_button
                  :if={editing_instance?(@instance_form)}
                  type="button"
                  phx-click="cancel_instance_edit"
                  size="xs"
                  variant="ghost"
                >
                  Cancel
                </.ui_button>
              </div>
              <label class="flex flex-col gap-1.5">
                <span class="text-sm font-medium text-sr-ink">Name</span>
                <input
                  class={ui_field_class(size: "sm")}
                  name="instance[name]"
                  value={@instance_form["name"]}
                />
              </label>
              <label class="flex flex-col gap-1.5">
                <span class="text-sm font-medium text-sr-ink">Route slug</span>
                <input
                  class={ui_field_class(size: "sm")}
                  name="instance[route_slug]"
                  value={@instance_form["route_slug"]}
                />
              </label>
              <label class="flex flex-col gap-1.5">
                <span class="text-sm font-medium text-sr-ink">Placement</span>
                <select class={ui_field_class(size: "sm")} name="instance[placement]">
                  <option value="dashboard" selected={@instance_form["placement"] == "dashboard"}>
                    Dashboard
                  </option>
                  <option value="map" selected={@instance_form["placement"] == "map"}>Map</option>
                  <option value="custom" selected={@instance_form["placement"] == "custom"}>
                    Custom
                  </option>
                </select>
              </label>
              <label
                :if={editing_instance?(@instance_form)}
                class="flex cursor-pointer items-center justify-start gap-3 p-0"
              >
                <input
                  type="checkbox"
                  class={ui_checkbox_class()}
                  name="instance[enabled]"
                  checked={@instance_form["enabled"] == "true"}
                  value="true"
                />
                <span class="text-sm font-medium text-sr-ink">Route enabled</span>
              </label>
              <label
                :if={!editing_instance?(@instance_form)}
                class="flex cursor-pointer items-center justify-start gap-3 p-0"
              >
                <input
                  type="checkbox"
                  class={ui_checkbox_class()}
                  name="instance[is_default]"
                  checked={@instance_form["is_default"] == "true"}
                  value="true"
                />
                <span class="text-sm font-medium text-sr-ink">Use as default for this placement</span>
              </label>
              <label class="flex flex-col gap-1.5">
                <span class="text-sm font-medium text-sr-ink">Settings JSON</span>
                <textarea
                  class={ui_field_class(mono: true, class: "min-h-28 py-2.5 text-xs")}
                  name="instance[settings_json]"
                >{@instance_form["settings_json"]}</textarea>
              </label>
              <.ui_button type="submit" size="sm" variant="primary" class="w-full">
                <%= if editing_instance?(@instance_form) do %>
                  <.icon name="hero-check" class="size-4" /> Save Route
                <% else %>
                  <.icon name="hero-plus" class="size-4" /> Create Route
                <% end %>
              </.ui_button>
            </.form>
          </aside>
        </div>
      </div>
    </dialog>
    """
  end

  attr(:errors, :list, required: true)

  defp error_list(assigns) do
    ~H"""
    <div :if={@errors != []} class={ui_alert_class(variant: "error", class: "mt-4")}>
      <div>
        <div class="font-semibold">Fix the following issue(s)</div>
        <ul class="mt-1 list-inside list-disc text-sm">
          <li :for={error <- @errors}>{error}</li>
        </ul>
      </div>
    </div>
    """
  end

  defp list_packages(scope), do: Dashboards.list_packages(%{limit: 250}, scope: scope)
  defp list_enabled_instances(scope), do: Dashboards.enabled_instances(scope: scope)

  defp refresh_package_assigns(socket, package, scope) do
    socket
    |> assign(:packages, list_packages(scope))
    |> assign(:enabled_instances, list_enabled_instances(scope))
    |> assign(:selected_package, package)
  end

  defp maybe_enable_after_import(package, %{"enable" => "true"}, scope),
    do: Dashboards.enable_package(package.id, scope: scope)

  defp maybe_enable_after_import(package, _params, _scope), do: {:ok, package}

  defp import_package_from_source(_socket, %{"source_type" => "github"} = params, scope) do
    Dashboards.import_package_github(
      %{
        source_repo_url: blank_to_nil(params["source_repo_url"]),
        source_commit: blank_to_nil(params["source_ref"]),
        source_manifest_path: blank_to_nil(params["source_manifest_path"]),
        renderer_path: blank_to_nil(params["renderer_path"])
      },
      scope: scope
    )
  end

  defp import_package_from_source(socket, params, scope) do
    with {:ok, manifest_json, renderer_artifact} <- consume_package_uploads(socket) do
      Dashboards.import_package_json(manifest_json, renderer_artifact,
        scope: scope,
        source_type: :upload,
        source_ref: blank_to_nil(params["source_ref"]),
        source_manifest_path: blank_to_nil(params["source_manifest_path"]),
        signature: %{"kind" => "local_upload"}
      )
    end
  end

  defp maybe_create_instance_after_import(package, %{"create_instance" => "true"}, scope) do
    with {:ok, instance} <-
           Dashboards.create_instance(
             package,
             %{
               name: package.name,
               route_slug: default_route_slug(package),
               placement: :dashboard,
               enabled: true,
               settings: %{}
             },
             scope: scope
           ) do
      Dashboards.set_default_instance(instance.id, scope: scope)
    end
  end

  defp maybe_create_instance_after_import(_package, _params, _scope), do: {:ok, nil}

  defp maybe_set_default_instance(%DashboardInstance{} = instance, params, scope) do
    if truthy?(params["is_default"]) do
      Dashboards.set_default_instance(instance.id, scope: scope)
    else
      {:ok, instance}
    end
  end

  defp ensure_package_enabled(%DashboardPackage{status: :enabled} = package, _scope), do: {:ok, package}

  defp ensure_package_enabled(%DashboardPackage{} = package, scope),
    do: Dashboards.enable_package(package.id, scope: scope)

  defp consume_package_uploads(socket) do
    with :ok <- validate_upload_ready(socket, :manifest),
         :ok <- validate_upload_ready(socket, :wasm),
         {:ok, manifest_json} <- consume_single_upload(socket, :manifest),
         {:ok, renderer_artifact} <- consume_single_upload(socket, :wasm) do
      {:ok, manifest_json, renderer_artifact}
    end
  end

  defp validate_upload_ready(socket, upload_name) do
    {completed_entries, in_progress_entries} = uploaded_entries(socket, upload_name)

    cond do
      completed_entries == [] and in_progress_entries == [] ->
        {:error, "Upload #{upload_label(upload_name)} before importing"}

      in_progress_entries != [] ->
        {:error, "Wait for the #{upload_label(upload_name)} upload to finish before importing"}

      true ->
        :ok
    end
  end

  # Sobelow flags the File.read! below as directory traversal because it cannot see where
  # `path` comes from. It is not user input: consume_uploaded_entries/3 hands back a temp file
  # that Phoenix created and named itself, and reading it is the documented LiveView upload
  # pattern. The uploaded CONTENT is untrusted and is validated downstream; the path is not.
  @sobelow_skip ["Traversal.FileModule"]
  defp consume_single_upload(socket, upload_name) do
    case consume_uploaded_entries(socket, upload_name, fn %{path: path}, _entry ->
           {:ok, File.read!(path)}
         end) do
      [payload] -> {:ok, payload}
      [] -> {:error, "Upload #{upload_label(upload_name)} before importing"}
      _ -> {:error, "Upload exactly one #{upload_label(upload_name)} file"}
    end
  end

  defp upload_label(:manifest), do: "manifest"
  defp upload_label(:wasm), do: "renderer artifact"
  defp upload_label(upload_name), do: to_string(upload_name)

  defp parse_settings(nil), do: {:ok, %{}}
  defp parse_settings(""), do: {:ok, %{}}

  defp parse_settings(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:ok, _} -> {:error, "Settings JSON must be an object"}
      {:error, error} -> {:error, "Settings JSON is invalid: #{Exception.message(error)}"}
    end
  end

  defp package_instances(instances, %DashboardPackage{} = package) do
    Enum.filter(instances, &(&1.dashboard_package_id == package.id))
  end

  defp default_import_form do
    %{
      "source_type" => "upload",
      "source_repo_url" => "",
      "source_ref" => "",
      "source_manifest_path" => "",
      "renderer_path" => "",
      "enable" => "true",
      "create_instance" => "true"
    }
  end

  defp default_instance_form(nil), do: default_instance_form()

  defp default_instance_form(%DashboardPackage{} = package) do
    %{
      "name" => package.name,
      "route_slug" => default_route_slug(package),
      "placement" => "dashboard",
      "is_default" => "false",
      "settings_json" => "{}"
    }
  end

  defp default_instance_form do
    %{
      "name" => "",
      "route_slug" => "",
      "placement" => "dashboard",
      "is_default" => "false",
      "settings_json" => "{}"
    }
  end

  defp instance_form(%DashboardInstance{} = instance) do
    %{
      "id" => instance.id,
      "name" => instance.name || "",
      "route_slug" => instance.route_slug || "",
      "placement" => Atom.to_string(instance.placement || :dashboard),
      "enabled" => bool_string(instance.enabled),
      "settings_json" => encode_settings(instance.settings || %{})
    }
  end

  defp editing_instance?(%{"id" => id}) when is_binary(id) and id != "", do: true
  defp editing_instance?(_form), do: false

  defp encode_settings(settings) when is_map(settings), do: Jason.encode!(settings, pretty: true)
  defp encode_settings(_settings), do: "{}"

  defp default_route_slug(%DashboardPackage{} = package) do
    [package.dashboard_id, package.version]
    |> Enum.join("-")
    |> normalize_slug()
    |> case do
      nil -> "dashboard-package"
      slug -> slug
    end
  end

  defp normalize_placement(value) when value in ~w(dashboard map custom), do: String.to_existing_atom(value)
  defp normalize_placement(_value), do: :dashboard

  defp normalize_slug(value) do
    value
    |> normalize_string()
    |> case do
      nil ->
        nil

      string ->
        string
        |> String.downcase()
        |> String.replace(~r/[^a-z0-9_-]+/, "-")
        |> String.trim("-")
        |> case do
          "" -> nil
          slug -> slug
        end
    end
  end

  defp normalize_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalize_string(_value), do: nil

  defp blank_to_nil(value), do: normalize_string(value)

  defp truthy?(value), do: value in [true, "true", "on", "1", 1]

  defp bool_string(true), do: "true"
  defp bool_string(_), do: "false"

  defp placement_label(value) when is_atom(value), do: value |> Atom.to_string() |> placement_label()
  defp placement_label("dashboard"), do: "Dashboard"
  defp placement_label("map"), do: "Map"
  defp placement_label("custom"), do: "Custom"
  defp placement_label(value), do: to_string(value || "Dashboard")

  defp short_hash(value) when is_binary(value) and byte_size(value) >= 12, do: String.slice(value, 0, 12)
  defp short_hash(value) when is_binary(value), do: value
  defp short_hash(_value), do: "not stored"

  defp status_badge_variant(:enabled), do: "success"
  defp status_badge_variant(:staged), do: "warning"
  defp status_badge_variant(:disabled), do: "ghost"
  defp status_badge_variant(:revoked), do: "error"
  defp status_badge_variant(_), do: "ghost"

  defp status_label(value) when is_atom(value), do: Atom.to_string(value)
  defp status_label(value), do: to_string(value || "unknown")

  defp verification_badge_variant("verified"), do: "success"
  defp verification_badge_variant("failed"), do: "error"
  defp verification_badge_variant(_), do: "ghost"

  defp format_error({:invalid_settings, errors}) when is_list(errors), do: Enum.join(errors, "; ")
  defp format_error(errors) when is_list(errors), do: Enum.join(errors, "; ")
  defp format_error(error) when is_binary(error), do: error
  defp format_error(error), do: inspect(error)
end
