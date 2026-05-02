defmodule ServiceRadarWebNGWeb.Admin.DashboardPackageLive.Index do
  @moduledoc """
  LiveView for importing and enabling browser dashboard packages.
  """

  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.SettingsComponents

  alias ServiceRadar.Dashboards.DashboardPackage
  alias ServiceRadarWebNG.Dashboards
  alias ServiceRadarWebNG.Plugins.Storage
  alias ServiceRadarWebNG.RBAC

  require Logger

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
          max_file_size: @manifest_upload_bytes
        )
        |> allow_upload(:wasm,
          accept: ~w(.wasm),
          max_entries: 1,
          max_file_size: Storage.max_upload_bytes()
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

    with {:ok, manifest_json} <- consume_single_upload(socket, :manifest),
         {:ok, wasm} <- consume_single_upload(socket, :wasm),
         {:ok, package} <-
           Dashboards.import_package_json(manifest_json, wasm,
             scope: scope,
             source_type: :upload,
             source_ref: blank_to_nil(params["source_ref"]),
             source_manifest_path: blank_to_nil(params["source_manifest_path"]),
             signature: %{"kind" => "local_upload"}
           ),
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
         {:ok, _instance} <-
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
           ) do
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

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.settings_shell current_path={@current_path}>
        <.settings_nav current_path={@current_path} current_scope={@current_scope} />

        <div class="flex flex-wrap items-center justify-between gap-4">
          <div>
            <h1 class="text-2xl font-semibold text-base-content">Dashboard Packages</h1>
            <p class="text-sm text-base-content/60">
              Import browser WASM dashboard packages and expose them as ServiceRadar dashboard routes.
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
              <p class="text-xs text-base-content/60">{length(@packages)} package(s)</p>
            </div>
          </:header>

          <%= if @packages == [] do %>
            <div class="rounded-box border border-dashed border-base-300 bg-base-100 p-8 text-center">
              <div class="text-sm font-semibold">No dashboard packages imported</div>
              <p class="mt-1 text-xs text-base-content/60">
                Import a manifest JSON file and browser WASM renderer to create the first package.
              </p>
            </div>
          <% else %>
            <div class="overflow-x-auto">
              <table class="table table-sm">
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
                  <tr :for={package <- @packages} class="hover:bg-base-200/40">
                    <td>
                      <div class="font-medium">{package.name}</div>
                      <div class="font-mono text-xs text-base-content/60">
                        {package.dashboard_id} · {package.version}
                      </div>
                    </td>
                    <td>
                      <div class="text-xs">{package.renderer["interface_version"] || "unknown"}</div>
                      <div class="font-mono text-xs text-base-content/60">
                        {short_hash(package.content_hash)}
                      </div>
                    </td>
                    <td class="text-xs">{length(package.data_frames || [])}</td>
                    <td>
                      <div class="flex flex-wrap gap-1">
                        <span class={status_badge(package.status)}>
                          {status_label(package.status)}
                        </span>
                        <span class={verification_badge(package.verification_status)}>
                          {package.verification_status || "unverified"}
                        </span>
                      </div>
                    </td>
                    <td>
                      <div
                        :for={instance <- package_instances(@enabled_instances, package)}
                        class="text-xs"
                      >
                        <.link
                          navigate={~p"/dashboards/#{instance.route_slug}"}
                          class="link link-primary"
                        >
                          /dashboards/{instance.route_slug}
                        </.link>
                      </div>
                    </td>
                    <td class="text-right">
                      <div class="flex justify-end gap-2">
                        <.link
                          patch={~p"/settings/dashboards/packages/#{package.id}"}
                          class="btn btn-ghost btn-xs"
                        >
                          Details
                        </.link>
                        <button
                          :if={@can_manage_packages and package.status != :enabled}
                          class="btn btn-primary btn-xs"
                          phx-click="enable_package"
                          phx-value-id={package.id}
                        >
                          Enable
                        </button>
                        <button
                          :if={@can_manage_packages and package.status == :enabled}
                          class="btn btn-outline btn-xs"
                          phx-click="disable_package"
                          phx-value-id={package.id}
                        >
                          Disable
                        </button>
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
      </.settings_shell>
    </Layouts.app>
    """
  end

  attr(:form, :map, required: true)
  attr(:errors, :list, required: true)
  attr(:uploads, :map, required: true)

  defp import_modal(assigns) do
    ~H"""
    <div class="modal modal-open">
      <div class="modal-box max-w-2xl">
        <div class="flex items-start justify-between gap-4">
          <div>
            <h2 class="text-lg font-semibold">Import Dashboard Package</h2>
            <p class="text-sm text-base-content/60">
              Upload the manifest JSON and matching browser WASM renderer.
            </p>
          </div>
          <button class="btn btn-ghost btn-sm btn-square" phx-click="close_modal">
            <.icon name="hero-x-mark" class="size-5" />
          </button>
        </div>

        <.error_list errors={@errors} />

        <.form
          for={@form}
          as={:import}
          phx-change="import_change"
          phx-submit="import_package"
          class="mt-5 space-y-4"
        >
          <div class="grid gap-4 sm:grid-cols-2">
            <label class="form-control">
              <span class="label-text">Manifest JSON</span>
              <.live_file_input
                upload={@uploads.manifest}
                class="file-input file-input-bordered file-input-sm w-full"
              />
            </label>
            <label class="form-control">
              <span class="label-text">Renderer WASM</span>
              <.live_file_input
                upload={@uploads.wasm}
                class="file-input file-input-bordered file-input-sm w-full"
              />
            </label>
          </div>

          <div class="grid gap-4 sm:grid-cols-2">
            <label class="form-control">
              <span class="label-text">Source ref</span>
              <input
                class="input input-bordered input-sm"
                name="import[source_ref]"
                value={@form["source_ref"]}
              />
            </label>
            <label class="form-control">
              <span class="label-text">Manifest path</span>
              <input
                class="input input-bordered input-sm"
                name="import[source_manifest_path]"
                value={@form["source_manifest_path"]}
              />
            </label>
          </div>

          <div class="rounded-box border border-base-300 bg-base-200/40 p-3">
            <label class="label cursor-pointer justify-start gap-3 p-0">
              <input
                type="checkbox"
                class="checkbox checkbox-sm"
                name="import[enable]"
                checked={@form["enable"] == "true"}
                value="true"
              />
              <span class="label-text">Enable package after import</span>
            </label>
            <label class="label mt-3 cursor-pointer justify-start gap-3 p-0">
              <input
                type="checkbox"
                class="checkbox checkbox-sm"
                name="import[create_instance]"
                checked={@form["create_instance"] == "true"}
                value="true"
              />
              <span class="label-text">Create default dashboard route</span>
            </label>
          </div>

          <div class="modal-action">
            <button type="button" class="btn btn-ghost" phx-click="close_modal">Cancel</button>
            <button type="submit" class="btn btn-primary">
              <.icon name="hero-arrow-up-tray" class="size-4" /> Import
            </button>
          </div>
        </.form>
      </div>
      <div class="modal-backdrop" phx-click="close_modal"></div>
    </div>
    """
  end

  attr(:package, :any, required: true)
  attr(:instances, :list, required: true)
  attr(:instance_form, :map, required: true)
  attr(:errors, :list, required: true)
  attr(:can_manage_packages, :boolean, required: true)

  defp details_modal(assigns) do
    ~H"""
    <div class="modal modal-open">
      <div class="modal-box max-w-4xl">
        <div class="flex items-start justify-between gap-4">
          <div>
            <h2 class="text-lg font-semibold">{@package.name}</h2>
            <p class="font-mono text-xs text-base-content/60">
              {@package.dashboard_id} · {@package.version}
            </p>
          </div>
          <button class="btn btn-ghost btn-sm btn-square" phx-click="close_modal">
            <.icon name="hero-x-mark" class="size-5" />
          </button>
        </div>

        <.error_list errors={@errors} />

        <div class="mt-5 grid gap-4 lg:grid-cols-[1fr_18rem]">
          <div class="space-y-4">
            <div class="rounded-box border border-base-300 p-4">
              <div class="text-sm font-semibold">Renderer</div>
              <dl class="mt-3 grid gap-2 text-xs sm:grid-cols-2">
                <div>
                  <dt class="text-base-content/60">Interface</dt>
                  <dd class="font-mono">{@package.renderer["interface_version"] || "unknown"}</dd>
                </div>
                <div>
                  <dt class="text-base-content/60">Artifact</dt>
                  <dd class="font-mono">{@package.renderer["artifact"]}</dd>
                </div>
                <div class="sm:col-span-2">
                  <dt class="text-base-content/60">SHA256</dt>
                  <dd class="break-all font-mono">
                    {@package.content_hash || @package.renderer["sha256"]}
                  </dd>
                </div>
              </dl>
            </div>

            <div class="rounded-box border border-base-300 p-4">
              <div class="text-sm font-semibold">Data Frames</div>
              <div class="mt-3 space-y-3">
                <div :for={frame <- @package.data_frames || []} class="rounded-lg bg-base-200/60 p-3">
                  <div class="flex flex-wrap items-center gap-2">
                    <span class="badge badge-outline">{frame["id"]}</span>
                    <span class="badge badge-ghost">{frame["encoding"]}</span>
                    <span :if={frame["limit"]} class="badge badge-ghost">limit {frame["limit"]}</span>
                  </div>
                  <div class="mt-2 font-mono text-xs text-base-content/70">{frame["query"]}</div>
                </div>
              </div>
            </div>
          </div>

          <aside class="space-y-4">
            <div class="rounded-box border border-base-300 p-4">
              <div class="text-sm font-semibold">Status</div>
              <div class="mt-3 flex flex-wrap gap-2">
                <span class={status_badge(@package.status)}>{status_label(@package.status)}</span>
                <span class={verification_badge(@package.verification_status)}>
                  {@package.verification_status || "unverified"}
                </span>
              </div>
              <div class="mt-4 flex gap-2">
                <button
                  :if={@can_manage_packages and @package.status != :enabled}
                  class="btn btn-primary btn-sm"
                  phx-click="enable_package"
                  phx-value-id={@package.id}
                >
                  Enable
                </button>
                <button
                  :if={@can_manage_packages and @package.status == :enabled}
                  class="btn btn-outline btn-sm"
                  phx-click="disable_package"
                  phx-value-id={@package.id}
                >
                  Disable
                </button>
              </div>
            </div>

            <div class="rounded-box border border-base-300 p-4">
              <div class="text-sm font-semibold">Routes</div>
              <div :if={@instances == []} class="mt-2 text-xs text-base-content/60">
                No enabled routes.
              </div>
              <div :for={instance <- @instances} class="mt-2 text-xs">
                <.link navigate={~p"/dashboards/#{instance.route_slug}"} class="link link-primary">
                  /dashboards/{instance.route_slug}
                </.link>
              </div>
            </div>

            <.form
              :if={@can_manage_packages}
              for={@instance_form}
              as={:instance}
              phx-change="instance_change"
              phx-submit="create_instance"
              class="rounded-box border border-base-300 p-4 space-y-3"
            >
              <div class="text-sm font-semibold">Create Dashboard Route</div>
              <label class="form-control">
                <span class="label-text">Name</span>
                <input
                  class="input input-bordered input-sm"
                  name="instance[name]"
                  value={@instance_form["name"]}
                />
              </label>
              <label class="form-control">
                <span class="label-text">Route slug</span>
                <input
                  class="input input-bordered input-sm"
                  name="instance[route_slug]"
                  value={@instance_form["route_slug"]}
                />
              </label>
              <label class="form-control">
                <span class="label-text">Placement</span>
                <select class="select select-bordered select-sm" name="instance[placement]">
                  <option value="dashboard" selected={@instance_form["placement"] == "dashboard"}>
                    Dashboard
                  </option>
                  <option value="map" selected={@instance_form["placement"] == "map"}>Map</option>
                  <option value="custom" selected={@instance_form["placement"] == "custom"}>
                    Custom
                  </option>
                </select>
              </label>
              <label class="form-control">
                <span class="label-text">Settings JSON</span>
                <textarea
                  class="textarea textarea-bordered min-h-28 font-mono text-xs"
                  name="instance[settings_json]"
                >{@instance_form["settings_json"]}</textarea>
              </label>
              <button type="submit" class="btn btn-primary btn-sm w-full">
                <.icon name="hero-plus" class="size-4" /> Create Route
              </button>
            </.form>
          </aside>
        </div>
      </div>
      <div class="modal-backdrop" phx-click="close_modal"></div>
    </div>
    """
  end

  attr(:errors, :list, required: true)

  defp error_list(assigns) do
    ~H"""
    <div :if={@errors != []} class="alert alert-error mt-4">
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

  defp maybe_create_instance_after_import(package, %{"create_instance" => "true"}, scope) do
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
    )
  end

  defp maybe_create_instance_after_import(_package, _params, _scope), do: {:ok, nil}

  defp ensure_package_enabled(%DashboardPackage{status: :enabled} = package, _scope), do: {:ok, package}

  defp ensure_package_enabled(%DashboardPackage{} = package, scope),
    do: Dashboards.enable_package(package.id, scope: scope)

  defp consume_single_upload(socket, upload_name) do
    case consume_uploaded_entries(socket, upload_name, fn %{path: path}, _entry ->
           {:ok, File.read!(path)}
         end) do
      [payload] -> {:ok, payload}
      [] -> {:error, "Upload #{upload_name} before importing"}
      _ -> {:error, "Upload exactly one #{upload_name} file"}
    end
  end

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
      "source_ref" => "",
      "source_manifest_path" => "",
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
      "settings_json" => "{}"
    }
  end

  defp default_instance_form do
    %{"name" => "", "route_slug" => "", "placement" => "dashboard", "settings_json" => "{}"}
  end

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

  defp short_hash(value) when is_binary(value) and byte_size(value) >= 12, do: String.slice(value, 0, 12)
  defp short_hash(value) when is_binary(value), do: value
  defp short_hash(_value), do: "not stored"

  defp status_badge(:enabled), do: "badge badge-success badge-outline"
  defp status_badge(:staged), do: "badge badge-warning badge-outline"
  defp status_badge(:disabled), do: "badge badge-ghost"
  defp status_badge(:revoked), do: "badge badge-error badge-outline"
  defp status_badge(_), do: "badge badge-ghost"

  defp status_label(value) when is_atom(value), do: Atom.to_string(value)
  defp status_label(value), do: to_string(value || "unknown")

  defp verification_badge("verified"), do: "badge badge-success"
  defp verification_badge("failed"), do: "badge badge-error"
  defp verification_badge(_), do: "badge badge-ghost"

  defp format_error({:invalid_settings, errors}) when is_list(errors), do: Enum.join(errors, "; ")
  defp format_error(errors) when is_list(errors), do: Enum.join(errors, "; ")
  defp format_error(error) when is_binary(error), do: error
  defp format_error(error), do: inspect(error)
end
