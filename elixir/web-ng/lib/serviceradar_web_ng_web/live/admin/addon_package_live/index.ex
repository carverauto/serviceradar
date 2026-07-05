defmodule ServiceRadarWebNGWeb.Admin.AddonPackageLive.Index do
  @moduledoc """
  Edge Ops LiveView for native agent add-ons (feature sets, issue 3425).

  Operators browse approved add-on packages, configure one from its
  config.schema.json, and assign it to an agent (creating an AddonAssignment that
  the control plane compiles into the agent config and pushes down). The catalog
  and assignment writes go through the web-ng context modules which wrap the
  serviceradar_core ServiceRadar.Plugins.Addon* Ash resources.
  """

  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.PluginConfigForm

  alias ServiceRadar.AgentRuntimeMetadata
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Plugins.RetiredNativeAddons
  alias ServiceRadarWebNG.Plugins.AddonAssignments
  alias ServiceRadarWebNG.Plugins.AddonFleet
  alias ServiceRadarWebNG.Plugins.AddonPackages
  alias ServiceRadarWebNG.Plugins.AddonProfiles
  alias ServiceRadarWebNG.Plugins.NativeAddonImporter
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.Settings.Shell

  require Ash.Query

  @cohort_options [
    {"Connected Agents", "connected"},
    {"Custom Agent IDs", "custom"}
  ]

  @official_release_tag_regex ~r/^v(?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+)$/
  @inert_sample_addon_ids MapSet.new(["sample", "rust-sample"])

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if RBAC.can?(scope, "plugins.view") do
      packages = list_addon_packages(scope)
      release_options = combined_release_options([], packages)

      {:ok,
       socket
       |> assign(:can_assign_addons, RBAC.can?(scope, "plugins.assign"))
       |> assign(:can_review_addons, RBAC.can?(scope, "settings.plugins.manage"))
       |> assign(:page_title, "Add-ons")
       |> assign(:current_path, nil)
       |> assign(:addons_base_path, "/settings/agents/addons")
       |> assign(:packages, packages)
       |> assign(:first_party_catalog, [])
       |> assign(:first_party_catalog_all, [])
       |> assign(:first_party_catalog_error, nil)
       |> assign(:first_party_catalog_status, nil)
       |> assign(:first_party_release_options, release_options)
       |> assign(:first_party_release_tag, selected_first_party_release(release_options, nil))
       |> assign(:first_party_release_selected?, false)
       |> assign(:first_party_repo_url, first_party_repo_url())
       |> assign(:agents, list_agents(scope))
       |> assign(:cohort_options, @cohort_options)
       |> assign(:show_details_modal, false)
       |> assign(:selected_package, nil)
       |> assign(:newer_approved_package, nil)
       |> assign(:import_running?, false)
       |> assign(:assignments, [])
       |> assign(:addon_profiles, [])
       |> assign(:assignment_preview, empty_assignment_preview())
       |> assign(:assignment_form, default_assignment_form())
       |> assign(:profile_form, default_profile_form())
       |> tap(fn _socket -> if connected?(socket), do: send(self(), :load_first_party_addon_catalog) end)}
    else
      {:ok,
       socket
       |> put_flash(:error, "You don't have permission to access Add-ons.")
       |> redirect(to: ~p"/dashboard")}
    end
  end

  @impl true
  def handle_params(params, url, socket) do
    socket =
      socket
      |> assign(:current_path, current_path_from_url(url))
      |> assign(:addons_base_path, addons_base_path_from_url(url))

    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:show_details_modal, false)
    |> assign(:selected_package, nil)
    |> assign(:newer_approved_package, nil)
  end

  defp apply_action(socket, :show, %{"id" => id}) do
    scope = socket.assigns.current_scope

    case AddonPackages.get(id, scope: scope) do
      {:ok, package} ->
        socket
        |> assign(:selected_package, package)
        |> assign(:newer_approved_package, newer_approved_package(socket.assigns.packages, package))
        |> assign(:show_details_modal, true)
        |> assign(:assignment_form, default_assignment_form())
        |> assign(:assignment_preview, build_assignment_preview(default_assignment_form(), package, scope))
        |> assign(:assignments, list_assignments_for_package(package.id, scope))
        |> assign(:addon_profiles, list_profiles_for_package(package.id, scope))
        |> assign(:profile_form, default_profile_form(package))

      _ ->
        socket
        |> put_flash(:error, "Add-on not found.")
        |> push_navigate(to: socket.assigns.addons_base_path)
    end
  end

  @impl true
  def handle_info(:load_first_party_addon_catalog, socket) do
    {:noreply, load_first_party_catalog(socket)}
  end

  @impl true
  def handle_async(:import_first_party_catalog, {:ok, result}, socket) do
    socket = assign(socket, :import_running?, false)

    case result do
      {:ok, summary} ->
        release_label = socket.assigns.first_party_release_tag || "the selected release"

        {:noreply,
         socket
         |> put_flash(:info, import_summary_message(summary, release_label))
         |> assign(:packages, list_addon_packages(socket.assigns.current_scope))
         |> load_first_party_catalog()}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "First-party add-on import failed: #{format_error(reason)}")
         |> load_first_party_catalog()}
    end
  end

  def handle_async(:import_first_party_catalog, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(:import_running?, false)
     |> put_flash(:error, "First-party add-on import failed: #{format_error(reason)}")}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    packages = list_addon_packages(socket.assigns.current_scope)

    {:noreply,
     socket
     |> assign(:packages, packages)
     |> assign_first_party_catalog_view(socket.assigns.first_party_catalog_all, socket.assigns.first_party_release_tag)}
  end

  def handle_event("sync_first_party_catalog", _params, socket) do
    {:noreply, load_first_party_catalog(socket)}
  end

  def handle_event("select_first_party_release", %{"release_tag" => release_tag}, socket) do
    {:noreply,
     socket
     |> assign(:first_party_release_selected?, true)
     |> assign_first_party_catalog_view(socket.assigns.first_party_catalog_all, release_tag)}
  end

  def handle_event("import_first_party_catalog", _params, %{assigns: %{can_review_addons: false}} = socket) do
    {:noreply, put_flash(socket, :error, "You don't have permission to import add-ons.")}
  end

  def handle_event("import_first_party_catalog", _params, %{assigns: %{import_running?: true}} = socket) do
    {:noreply, socket}
  end

  def handle_event("import_first_party_catalog", _params, socket) do
    repo_url = socket.assigns.first_party_repo_url
    release_tag = socket.assigns.first_party_release_tag
    limit = first_party_sync_limit()

    {:noreply,
     socket
     |> assign(:import_running?, true)
     |> start_async(:import_first_party_catalog, fn ->
       AddonPackages.sync_first_party_addons(
         repo_url: repo_url,
         release_tag: release_tag,
         limit: limit
       )
     end)}
  end

  def handle_event("import_first_party_addon", _params, %{assigns: %{can_review_addons: false}} = socket) do
    {:noreply, put_flash(socket, :error, "You don't have permission to import add-ons.")}
  end

  def handle_event("import_first_party_addon", params, socket) do
    attrs = %{
      repo_url: socket.assigns.first_party_repo_url,
      release_tag: params["release_tag"],
      addon_id: params["addon_id"],
      version: params["version"]
    }

    if RetiredNativeAddons.retired?(attrs.addon_id) do
      {:noreply, put_flash(socket, :error, "This add-on is retired: #{RetiredNativeAddons.reason(attrs.addon_id)}")}
    else
      case NativeAddonImporter.import(attrs) do
        {:ok, package} ->
          {:noreply,
           socket
           |> put_flash(:info, "Imported first-party add-on #{package.name} #{package.version}")
           |> assign(:packages, list_addon_packages(socket.assigns.current_scope))
           |> load_first_party_catalog()}

        {:error, reason} ->
          {:noreply,
           socket
           |> put_flash(:error, "First-party add-on import failed: #{format_error(reason)}")
           |> load_first_party_catalog()}
      end
    end
  end

  def handle_event("view_package", %{"id" => id}, socket) do
    {:noreply, push_patch(socket, to: socket.assigns.addons_base_path <> "/" <> id)}
  end

  def handle_event("close_details", _params, socket) do
    {:noreply, push_patch(socket, to: socket.assigns.addons_base_path)}
  end

  def handle_event("assignment_change", %{"assignment" => form}, socket) do
    form = Map.merge(default_assignment_form(), form)

    {:noreply,
     socket
     |> assign(:assignment_form, form)
     |> assign(
       :assignment_preview,
       build_assignment_preview(form, socket.assigns.selected_package, socket.assigns.current_scope)
     )}
  end

  def handle_event("profile_change", %{"profile" => form}, socket) do
    {:noreply, assign(socket, :profile_form, Map.merge(default_profile_form(socket.assigns.selected_package), form))}
  end

  def handle_event("create_assignment", _params, %{assigns: %{can_assign_addons: false}} = socket) do
    {:noreply, put_flash(socket, :error, "You don't have permission to assign add-ons.")}
  end

  def handle_event("create_assignment", %{"assignment" => form}, socket) do
    scope = socket.assigns.current_scope
    package = socket.assigns.selected_package
    form = Map.merge(default_assignment_form(), form)

    with {:ok, agent_uids} <- fetch_assignment_agent_uids(form, package, scope),
         {:ok, params} <- parse_params(form, package.config_schema) do
      case create_assignments(agent_uids, package, params, parse_args(Map.get(form, "args")), scope) do
        {:ok, count} ->
          {:noreply,
           socket
           |> put_flash(:info, assignment_success_message(count))
           |> assign(:assignments, list_assignments_for_package(package.id, scope))
           |> assign(:assignment_form, default_assignment_form())
           |> assign(:assignment_preview, build_assignment_preview(default_assignment_form(), package, scope))}

        {:error, error, _created_count} ->
          {:noreply, put_flash(socket, :error, "Failed to assign: #{format_error(error)}")}
      end
    else
      {:error, :missing_agent} ->
        {:noreply, put_flash(socket, :error, "Select an agent.")}

      {:error, :empty_cohort} ->
        {:noreply, put_flash(socket, :error, "The selected cohort has no compatible agents.")}

      {:error, {:invalid_params, message}} ->
        {:noreply, put_flash(socket, :error, "Invalid configuration: #{message}")}
    end
  end

  def handle_event("create_profile", _params, %{assigns: %{can_assign_addons: false}} = socket) do
    {:noreply, put_flash(socket, :error, "You don't have permission to assign add-ons.")}
  end

  def handle_event("create_profile", %{"profile" => form}, socket) do
    scope = socket.assigns.current_scope
    package = socket.assigns.selected_package
    form = Map.merge(default_profile_form(package), form)

    with {:ok, params} <- parse_profile_params(form),
         {:ok, priority} <- parse_positive_integer(Map.get(form, "priority"), 100),
         {:ok, max_targets} <- parse_positive_integer(Map.get(form, "max_targets"), 10_000),
         {:ok, target_query} <- profile_target_query(Map.get(form, "target_query")),
         {:ok, attrs} <- profile_attrs(form, package, params, priority, max_targets, target_query) do
      case AddonProfiles.create(attrs, scope: scope) do
        {:ok, _profile} ->
          {:noreply,
           socket
           |> put_flash(:info, "Add-on profile created.")
           |> assign(:addon_profiles, list_profiles_for_package(package.id, scope))
           |> assign(:profile_form, default_profile_form(package))}

        {:error, error} ->
          {:noreply, put_flash(socket, :error, "Failed to create profile: #{format_error(error)}")}
      end
    else
      {:error, {:invalid_params, message}} ->
        {:noreply, put_flash(socket, :error, "Invalid profile configuration: #{message}")}

      {:error, :missing_target_query} ->
        {:noreply, put_flash(socket, :error, "Enter an SRQL target query before creating a profile.")}

      {:error, :invalid_integer} ->
        {:noreply, put_flash(socket, :error, "Priority and max targets must be positive integers.")}
    end
  end

  def handle_event("reconcile_profile", _params, %{assigns: %{can_assign_addons: false}} = socket) do
    {:noreply, put_flash(socket, :error, "You don't have permission to assign add-ons.")}
  end

  def handle_event("reconcile_profile", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope
    package = socket.assigns.selected_package

    case AddonProfiles.reconcile(id, scope: scope) do
      {:ok, summary} ->
        {:noreply,
         socket
         |> put_flash(:info, profile_reconcile_message(summary))
         |> assign(:addon_profiles, list_profiles_for_package(package.id, scope))
         |> assign(:assignments, list_assignments_for_package(package.id, scope))}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, "Profile reconcile failed: #{format_error(error)}")}
    end
  end

  def handle_event("approve_package", %{"id" => id, "review" => form}, socket) do
    scope = socket.assigns.current_scope
    package = socket.assigns.selected_package
    approved_capabilities = parse_selected_capabilities(form)

    cond do
      not socket.assigns.can_review_addons ->
        {:noreply, put_flash(socket, :error, "You don't have permission to review add-ons.")}

      package_capabilities(package) != [] and approved_capabilities == [] ->
        {:noreply, put_flash(socket, :error, "Select at least one approved capability.")}

      true ->
        attrs = %{approved_capabilities: approved_capabilities}

        case AddonPackages.approve(id, attrs,
               scope: scope,
               approved_by: approved_by(socket.assigns.current_scope)
             ) do
          {:ok, updated} ->
            {:noreply,
             socket
             |> put_flash(:info, "Add-on approved.")
             |> assign(:packages, list_addon_packages(scope))
             |> assign_first_party_catalog_view(
               socket.assigns.first_party_catalog_all,
               socket.assigns.first_party_release_tag
             )
             |> assign(:selected_package, updated)
             |> assign(:assignment_preview, build_assignment_preview(socket.assigns.assignment_form, updated, scope))}

          {:error, error} ->
            {:noreply, put_flash(socket, :error, "Failed to approve: #{format_error(error)}")}
        end
    end
  end

  def handle_event("deny_package", %{"id" => id, "review" => form}, socket) do
    scope = socket.assigns.current_scope

    if socket.assigns.can_review_addons do
      attrs = %{denied_reason: present_text(Map.get(form, "denied_reason"))}

      case AddonPackages.deny(id, attrs, scope: scope) do
        {:ok, updated} ->
          {:noreply,
           socket
           |> put_flash(:info, "Add-on denied.")
           |> assign(:packages, list_addon_packages(scope))
           |> assign_first_party_catalog_view(
             socket.assigns.first_party_catalog_all,
             socket.assigns.first_party_release_tag
           )
           |> assign(:selected_package, updated)}

        {:error, error} ->
          {:noreply, put_flash(socket, :error, "Failed to deny: #{format_error(error)}")}
      end
    else
      {:noreply, put_flash(socket, :error, "You don't have permission to review add-ons.")}
    end
  end

  def handle_event("delete_assignment", _params, %{assigns: %{can_assign_addons: false}} = socket) do
    {:noreply, put_flash(socket, :error, "You don't have permission to manage add-ons.")}
  end

  def handle_event("delete_assignment", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope
    package = socket.assigns.selected_package

    case AddonAssignments.delete(id, scope: scope) do
      {:ok, _assignment} ->
        {:noreply,
         socket
         |> put_flash(:info, "Assignment removed.")
         |> assign(:assignments, list_assignments_for_package(package.id, scope))}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, "Failed to remove: #{format_error(error)}")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <Shell.settings_chrome
        current_path={@current_path || @addons_base_path}
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
            <h1 class="text-2xl font-semibold text-base-content">Add-ons</h1>
            <p class="text-sm text-base-content/60">
              Select native agent add-ons (feature sets) and push them down to your agents.
            </p>
          </div>
          <.ui_button variant="ghost" size="sm" phx-click="refresh">
            <.icon name="hero-arrow-path" class="size-4" /> Refresh
          </.ui_button>
        </div>

        <% catalog_rows =
          combined_catalog_rows(
            @first_party_catalog,
            @packages,
            @first_party_release_tag
          ) %>
        <% import_state = catalog_import_state(catalog_rows) %>

        <.ui_panel>
          <:header>
            <div class="flex flex-wrap items-center justify-between gap-3">
              <div>
                <div class="text-sm font-semibold">Add-on catalog</div>
                <p class="text-xs text-base-content/60">
                  Signed first-party add-ons and imported packages by release.
                </p>
              </div>
              <div class="flex flex-wrap items-center gap-2">
                <form
                  :if={@first_party_release_options != []}
                  id="select-addon-release-form"
                  phx-change="select_first_party_release"
                >
                  <select name="release_tag" class="select select-bordered select-sm">
                    <%= for release_tag <- @first_party_release_options do %>
                      <option value={release_tag} selected={release_tag == @first_party_release_tag}>
                        {release_tag}
                      </option>
                    <% end %>
                  </select>
                </form>
                <.ui_button variant="ghost" size="sm" phx-click="sync_first_party_catalog">
                  <.icon name="hero-arrow-path" class="size-4" /> Sync
                </.ui_button>
                <.ui_button
                  :if={@can_review_addons}
                  variant="primary"
                  size="sm"
                  disabled={@import_running? or import_state.importable == 0}
                  phx-click="import_first_party_catalog"
                >
                  <span :if={@import_running?} class="loading loading-spinner loading-xs"></span>
                  <.icon :if={not @import_running?} name="hero-arrow-down-tray" class="size-4" />
                  {import_all_label(@import_running?, import_state)}
                </.ui_button>
              </div>
            </div>
          </:header>

          <%= if @first_party_catalog_error do %>
            <div class="rounded-lg border border-error/30 bg-error/5 px-4 py-3 text-sm text-error">
              {@first_party_catalog_error}
            </div>
          <% end %>

          <%= if @first_party_catalog_status do %>
            <div class="mb-3 text-xs text-base-content/60">
              {@first_party_catalog_status}
            </div>
          <% end %>

          <%= cond do %>
            <% catalog_rows == [] and is_nil(@first_party_catalog_error) -> %>
              <div class="rounded-xl border border-dashed border-base-200 bg-base-100 p-6 text-center">
                <div class="text-sm font-semibold text-base-content">
                  No add-ons found for this release
                </div>
                <p class="mt-1 text-xs text-base-content/60">
                  Choose another release or sync the first-party catalog.
                </p>
              </div>
            <% catalog_rows != [] -> %>
              <div class="overflow-x-auto">
                <table class="table table-sm">
                  <thead>
                    <tr class="text-xs uppercase tracking-wide text-base-content/60">
                      <th>Add-on</th>
                      <th>Version</th>
                      <th>Release</th>
                      <th>Platforms</th>
                      <th>Status</th>
                      <th></th>
                    </tr>
                  </thead>
                  <tbody>
                    <%= for row <- catalog_rows do %>
                      <tr class="hover:bg-base-200/30">
                        <td>
                          <div class="font-medium">{row.name}</div>
                          <div class="text-xs text-base-content/60 font-mono">{row.addon_id}</div>
                        </td>
                        <td class="text-xs">{row.version}</td>
                        <td class="text-xs font-mono">{row.release_tag || "—"}</td>
                        <td class="text-xs">{row.platforms}</td>
                        <td>
                          <span class={["badge badge-sm", catalog_row_status_badge(row)]}>
                            {catalog_row_status(row)}
                          </span>
                        </td>
                        <td class="text-right">
                          <.ui_button
                            :if={row.package}
                            variant="ghost"
                            size="sm"
                            phx-click="view_package"
                            phx-value-id={row.package.id}
                          >
                            View
                          </.ui_button>
                          <.ui_button
                            :if={is_nil(row.package) and @can_review_addons and row.import_ready}
                            variant="ghost"
                            size="sm"
                            phx-click="import_first_party_addon"
                            phx-value-addon_id={row.addon_id}
                            phx-value-version={row.version}
                            phx-value-release_tag={row.release_tag}
                          >
                            Import
                          </.ui_button>
                        </td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>
          <% end %>
        </.ui_panel>

        <%= if @show_details_modal and @selected_package do %>
          <div class="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4">
            <div class="w-full max-w-4xl rounded-2xl bg-base-100 p-6 shadow-xl space-y-4 overflow-y-auto max-h-[90vh]">
              <div class="flex items-start justify-between gap-4">
                <div>
                  <h2 class="text-lg font-semibold text-base-content">{@selected_package.name}</h2>
                  <div class="text-xs text-base-content/60 font-mono">
                    {@selected_package.addon_id} · v{@selected_package.version}
                  </div>
                </div>
                <.ui_button variant="ghost" size="sm" phx-click="close_details">Close</.ui_button>
              </div>

              <dl class="grid grid-cols-2 gap-2 text-xs">
                <div>
                  <dt class="text-base-content/60">Delivery</dt>
                  <dd>{@selected_package.delivery}</dd>
                </div>
                <div>
                  <dt class="text-base-content/60">Supervision</dt>
                  <dd>{@selected_package.supervision}</dd>
                </div>
                <div class="col-span-2">
                  <dt class="text-base-content/60">Capabilities</dt>
                  <dd>{Enum.join(@selected_package.capabilities || [], ", ")}</dd>
                </div>
                <div class="col-span-2">
                  <dt class="text-base-content/60">Approved capabilities</dt>
                  <dd>{approved_capabilities_text(@selected_package)}</dd>
                </div>
              </dl>

              <div class="grid gap-3 md:grid-cols-2">
                <div class="rounded-xl border border-base-200 p-4 space-y-2">
                  <div class="text-sm font-semibold">Manifest & delivery</div>
                  <dl class="grid grid-cols-2 gap-2 text-xs">
                    <div>
                      <dt class="text-base-content/60">Kind</dt>
                      <dd>{@selected_package.kind}</dd>
                    </div>
                    <div>
                      <dt class="text-base-content/60">Binary</dt>
                      <dd class="font-mono">{@selected_package.binary || "—"}</dd>
                    </div>
                    <div class="col-span-2">
                      <dt class="text-base-content/60">Install path</dt>
                      <dd class="font-mono break-all">{@selected_package.install_path}</dd>
                    </div>
                    <div class="col-span-2">
                      <dt class="text-base-content/60">Supported artifacts</dt>
                      <dd class="flex flex-wrap gap-1">
                        <%= for platform <- addon_supported_platforms(@selected_package) do %>
                          <span class="badge badge-ghost badge-xs font-mono">{platform}</span>
                        <% end %>
                        <span
                          :if={addon_supported_platforms(@selected_package) == []}
                          class="text-base-content/50"
                        >
                          No per-architecture artifact gate
                        </span>
                      </dd>
                    </div>
                  </dl>
                </div>

                <div class="rounded-xl border border-base-200 p-4 space-y-2">
                  <div class="text-sm font-semibold">Provenance</div>
                  <dl class="space-y-2 text-xs">
                    <div>
                      <dt class="text-base-content/60">Source</dt>
                      <dd>{@selected_package.source_type}</dd>
                    </div>
                    <div>
                      <dt class="text-base-content/60">Release</dt>
                      <dd class="font-mono">{@selected_package.source_release_tag || "—"}</dd>
                    </div>
                    <div>
                      <dt class="text-base-content/60">OCI reference</dt>
                      <dd class="font-mono break-all">{@selected_package.source_oci_ref || "—"}</dd>
                    </div>
                    <div>
                      <dt class="text-base-content/60">Digest</dt>
                      <dd class="font-mono break-all">
                        {@selected_package.source_oci_digest || "—"}
                      </dd>
                    </div>
                    <div>
                      <dt class="text-base-content/60">Verification</dt>
                      <dd>
                        <span class={["badge badge-xs", verification_status_badge(@selected_package)]}>
                          {verification_status_label(@selected_package)}
                        </span>
                      </dd>
                    </div>
                    <div :if={present_text(@selected_package.verification_error)} class="col-span-2">
                      <dt class="text-base-content/60">Verification error</dt>
                      <dd class="text-error break-words">{@selected_package.verification_error}</dd>
                    </div>
                  </dl>
                </div>
              </div>

              <div
                :if={@newer_approved_package}
                class="flex flex-wrap items-center justify-between gap-3 rounded-xl border border-info/30 bg-info/5 p-4 text-sm"
              >
                <div>
                  A newer approved version of this add-on is available: <span class="font-mono">v{@newer_approved_package.version}</span>.
                  New assignments default to the latest approved version.
                </div>
                <.ui_button
                  variant="ghost"
                  size="sm"
                  phx-click="view_package"
                  phx-value-id={@newer_approved_package.id}
                >
                  Open latest
                </.ui_button>
              </div>

              <div
                :if={addon_blob_missing?(@selected_package)}
                class="rounded-xl border border-error/30 bg-error/5 p-4 text-sm text-error"
              >
                Object storage no longer has one or more native add-on artifacts for this package.
                Re-import the add-on before assigning it to agents.
              </div>

              <div
                :if={@selected_package.status == :staged}
                class="rounded-xl border border-warning/30 bg-warning/5 p-4 space-y-3"
              >
                <div class="text-sm font-semibold">Approval review</div>
                <p class="text-xs text-base-content/60">
                  Approve only the capabilities this add-on should be allowed to expose.
                </p>

                <form
                  id={"approve-addon-#{@selected_package.id}"}
                  phx-submit="approve_package"
                  phx-value-id={@selected_package.id}
                  class="space-y-3"
                >
                  <div class="flex flex-wrap gap-2">
                    <%= for cap <- package_capabilities(@selected_package) do %>
                      <label class="inline-flex items-center gap-2 rounded-lg border border-base-200 px-3 py-2 text-xs">
                        <input
                          type="checkbox"
                          name="review[approved_capabilities][]"
                          value={cap}
                          checked
                          class="checkbox checkbox-xs"
                        />
                        <span class="font-mono">{cap}</span>
                      </label>
                    <% end %>
                    <span
                      :if={package_capabilities(@selected_package) == []}
                      class="text-xs text-base-content/60"
                    >
                      This package declares no capabilities.
                    </span>
                  </div>
                  <div class="flex flex-wrap justify-end gap-2">
                    <button
                      :if={@can_review_addons}
                      type="submit"
                      class="btn btn-primary btn-sm"
                    >
                      Approve
                    </button>
                  </div>
                </form>

                <form
                  id={"deny-addon-#{@selected_package.id}"}
                  phx-submit="deny_package"
                  phx-value-id={@selected_package.id}
                  class="space-y-2"
                >
                  <label class="label"><span class="label-text">Deny reason</span></label>
                  <textarea
                    name="review[denied_reason]"
                    class="textarea textarea-bordered w-full text-sm min-h-[64px]"
                    placeholder="Reason this package should not be assigned"
                  ></textarea>
                  <div class="flex justify-end">
                    <button
                      :if={@can_review_addons}
                      type="submit"
                      class="btn btn-error btn-sm"
                    >
                      Deny
                    </button>
                  </div>
                </form>
              </div>

              <div
                :if={@selected_package.status in [:denied, :revoked]}
                class="rounded-xl border border-error/30 bg-error/5 p-4 text-sm"
              >
                <div class="font-semibold">Not assignable</div>
                <p class="mt-1 text-xs text-base-content/70">
                  {denied_reason_text(@selected_package)}
                </p>
              </div>

              <div class="rounded-xl border border-base-200 p-4 space-y-2">
                <div class="text-sm font-semibold">Current assignments</div>
                <%= if @assignments == [] do %>
                  <p class="text-xs text-base-content/60">Not assigned to any agent yet.</p>
                <% else %>
                  <ul class="divide-y divide-base-200">
                    <%= for assignment <- @assignments do %>
                      <li class="flex items-center justify-between gap-2 py-2">
                        <div class="min-w-0">
                          <div class="text-xs font-mono">{assignment.agent_uid}</div>
                          <div class="mt-1 flex flex-wrap gap-1">
                            <span class="badge badge-ghost badge-xs">
                              {assignment_source_text(assignment, @addon_profiles)}
                            </span>
                            <span
                              :if={assignment_reconcile_status(assignment, @addon_profiles)}
                              class={[
                                "badge badge-xs",
                                profile_report_status_badge(
                                  assignment_reconcile_status(assignment, @addon_profiles)
                                )
                              ]}
                            >
                              {profile_report_status_label(
                                assignment_reconcile_status(assignment, @addon_profiles)
                              )}
                            </span>
                            <span
                              :if={assignment_reconciled_at(assignment, @addon_profiles)}
                              class="badge badge-ghost badge-xs"
                            >
                              reconciled
                            </span>
                          </div>
                          <div
                            :if={assignment_reconcile_error(assignment, @addon_profiles)}
                            class="mt-1 truncate text-[11px] text-error"
                          >
                            {assignment_reconcile_error(assignment, @addon_profiles)}
                          </div>
                        </div>
                        <div class="flex items-center gap-2">
                          <span class={[
                            "badge badge-sm",
                            if(assignment.enabled, do: "badge-success", else: "badge-ghost")
                          ]}>
                            {if assignment.enabled, do: "enabled", else: "disabled"}
                          </span>
                          <button
                            :if={@can_assign_addons}
                            type="button"
                            class="btn btn-ghost btn-xs"
                            phx-click="delete_assignment"
                            phx-value-id={assignment.id}
                            data-confirm="Remove this add-on assignment?"
                          >
                            Remove
                          </button>
                        </div>
                      </li>
                    <% end %>
                  </ul>
                <% end %>
              </div>

              <div class="rounded-xl border border-base-200 p-4 space-y-3">
                <div class="flex items-center justify-between gap-3">
                  <div>
                    <div class="text-sm font-semibold">Profile assignment</div>
                    <p class="text-xs text-base-content/60">
                      Target agents with SRQL (e.g. <span class="font-mono">in:agents</span>), then reconcile to materialize eligible agent assignments.
                    </p>
                  </div>
                </div>

                <div
                  :if={not addon_package_assignable?(@selected_package)}
                  class="rounded-lg border border-warning/30 bg-warning/5 px-3 py-2 text-xs text-warning"
                >
                  <%= if addon_blob_missing?(@selected_package) do %>
                    Re-import this add-on package before creating profiles or assignments.
                  <% else %>
                    This add-on package is {@selected_package.status}; approve a verified package for the selected release before creating profiles or assignments.
                  <% end %>
                </div>

                <%= if @addon_profiles == [] do %>
                  <p class="text-xs text-base-content/60">No profiles for this add-on package.</p>
                <% else %>
                  <ul class="divide-y divide-base-200">
                    <%= for profile <- @addon_profiles do %>
                      <% report = profile_reconcile_report(profile) %>
                      <li class="flex items-center justify-between gap-3 py-2">
                        <div class="min-w-0">
                          <div class="truncate text-xs font-semibold">{profile.name}</div>
                          <div class="truncate font-mono text-[11px] text-base-content/60">
                            {profile.target_query}
                          </div>
                          <div class="mt-1 flex flex-wrap gap-1">
                            <span class="badge badge-ghost badge-xs">
                              priority {profile.priority}
                            </span>
                            <span class={[
                              "badge badge-xs",
                              if(profile.enabled, do: "badge-success", else: "badge-ghost")
                            ]}>
                              {if profile.enabled, do: "enabled", else: "disabled"}
                            </span>
                            <span :if={profile.last_reconciled_at} class="badge badge-ghost badge-xs">
                              reconciled
                            </span>
                            <span
                              :if={report.status}
                              class={["badge badge-xs", profile_report_status_badge(report.status)]}
                            >
                              {profile_report_status_label(report.status)}
                            </span>
                            <span
                              :for={chip <- profile_report_chips(report)}
                              class="badge badge-ghost badge-xs"
                            >
                              {chip}
                            </span>
                          </div>
                          <div
                            :if={profile_report_last_error(report)}
                            class="mt-1 truncate text-[11px] text-error"
                          >
                            {profile_report_last_error(report)}
                          </div>
                          <div
                            :if={profile_skip_chips(report) != []}
                            class="mt-1 flex flex-wrap gap-1"
                          >
                            <span
                              :for={chip <- profile_skip_chips(report)}
                              class="rounded bg-base-200 px-1.5 py-0.5 text-[10px] text-base-content/70"
                            >
                              {chip}
                            </span>
                          </div>
                        </div>
                        <button
                          :if={@can_assign_addons}
                          type="button"
                          class="btn btn-ghost btn-xs"
                          phx-click="reconcile_profile"
                          phx-value-id={profile.id}
                          disabled={not addon_package_assignable?(@selected_package)}
                        >
                          Reconcile
                        </button>
                      </li>
                    <% end %>
                  </ul>
                <% end %>

                <form
                  id="create-addon-profile-form"
                  phx-submit="create_profile"
                  phx-change="profile_change"
                  class="space-y-3"
                >
                  <div>
                    <label class="label"><span class="label-text">Profile Name</span></label>
                    <input
                      name="profile[name]"
                      class="input input-bordered w-full"
                      value={@profile_form["name"]}
                    />
                  </div>
                  <div>
                    <label class="label"><span class="label-text">SRQL Target Query</span></label>
                    <input
                      name="profile[target_query]"
                      class="input input-bordered w-full font-mono text-xs"
                      value={@profile_form["target_query"]}
                      placeholder="in:agents"
                    />
                  </div>
                  <details class="rounded border border-base-200 bg-base-200/30">
                    <summary class="cursor-pointer px-3 py-2 text-xs font-semibold uppercase text-base-content/70">
                      Advanced Profile Options
                    </summary>
                    <div class="space-y-3 border-t border-base-200 p-3">
                      <div class="grid gap-3 md:grid-cols-2">
                        <div>
                          <label class="label"><span class="label-text">Priority</span></label>
                          <input
                            name="profile[priority]"
                            class="input input-bordered w-full"
                            value={@profile_form["priority"]}
                          />
                        </div>
                        <div>
                          <label class="label"><span class="label-text">Max Targets</span></label>
                          <input
                            name="profile[max_targets]"
                            class="input input-bordered w-full"
                            value={@profile_form["max_targets"]}
                          />
                        </div>
                      </div>
                      <div>
                        <label class="label">
                          <span class="label-text">Args (one per line)</span>
                        </label>
                        <textarea
                          name="profile[args]"
                          class="textarea textarea-bordered w-full font-mono text-xs min-h-[42px]"
                        ><%= @profile_form["args"] %></textarea>
                      </div>
                      <div>
                        <label class="label"><span class="label-text">Params (JSON)</span></label>
                        <textarea
                          name="profile[params]"
                          class="textarea textarea-bordered w-full font-mono text-xs min-h-[70px]"
                        ><%= assignment_params_raw(@profile_form) %></textarea>
                      </div>
                    </div>
                  </details>
                  <div class="flex justify-end">
                    <button
                      type="submit"
                      class="btn btn-primary btn-sm"
                      disabled={
                        not addon_package_assignable?(@selected_package) or not @can_assign_addons
                      }
                    >
                      Create Profile
                    </button>
                  </div>
                </form>
              </div>

              <details
                id="advanced-manual-assignment-override"
                phx-hook="DetailsState"
                class="rounded-xl border border-base-200 p-4"
              >
                <summary class="cursor-pointer">
                  <div class="inline-flex flex-col gap-1 align-middle">
                    <span class="text-sm font-semibold">Advanced Manual Assignment Override</span>
                    <span class="text-xs text-base-content/60">
                      Assign directly to agents only when profile ownership is not appropriate.
                    </span>
                  </div>
                </summary>
                <form
                  id="create-addon-assignment-form"
                  phx-submit="create_assignment"
                  phx-change="assignment_change"
                  class="mt-3 space-y-3"
                >
                  <div class="grid gap-3 md:grid-cols-2">
                    <div>
                      <label class="label"><span class="label-text">Target</span></label>
                      <select name="assignment[target_mode]" class="select select-bordered w-full">
                        <option value="agent" selected={@assignment_form["target_mode"] == "agent"}>
                          Single agent
                        </option>
                        <option value="cohort" selected={@assignment_form["target_mode"] == "cohort"}>
                          Cohort
                        </option>
                      </select>
                    </div>
                    <div :if={@assignment_form["target_mode"] == "cohort"}>
                      <label class="label"><span class="label-text">Cohort</span></label>
                      <select name="assignment[cohort]" class="select select-bordered w-full">
                        <%= for {label, value} <- @cohort_options do %>
                          <option value={value} selected={@assignment_form["cohort"] == value}>
                            {label}
                          </option>
                        <% end %>
                      </select>
                    </div>
                    <div :if={@assignment_form["target_mode"] != "cohort"} class="md:col-span-2">
                      <label class="label"><span class="label-text">Agent</span></label>
                      <select name="assignment[agent_uid]" class="select select-bordered w-full">
                        <option value="">Select an agent</option>
                        <%= for agent <- @agents do %>
                          <option
                            value={agent.uid}
                            selected={@assignment_form["agent_uid"] == agent.uid}
                          >
                            {agent_label(agent)}
                          </option>
                        <% end %>
                      </select>
                    </div>
                  </div>

                  <div :if={
                    @assignment_form["target_mode"] == "cohort" and
                      @assignment_form["cohort"] == "custom"
                  }>
                    <label class="label"><span class="label-text">Custom Agent IDs</span></label>
                    <textarea
                      name="assignment[agent_ids]"
                      class="textarea textarea-bordered w-full font-mono text-xs min-h-[80px]"
                      placeholder="agent-1, agent-2 or one per line"
                    ><%= @assignment_form["agent_ids"] %></textarea>
                  </div>

                  <div
                    :if={show_assignment_preview?(@assignment_preview)}
                    id="addon-compatibility-preview"
                    class="rounded-lg border border-base-300 bg-base-200/30 px-4 py-3 text-sm"
                  >
                    <div class="flex flex-wrap items-center justify-between gap-3">
                      <div class="font-semibold text-base-content">Compatibility Preview</div>
                      <div class="text-xs text-base-content/60">
                        {assignment_preview_scope_text(@assignment_preview)}
                      </div>
                    </div>

                    <div class="mt-3 flex flex-wrap gap-2">
                      <.ui_badge variant="ghost" size="xs">
                        {@assignment_preview.selected_count} selected
                      </.ui_badge>
                      <.ui_badge variant="success" size="xs">
                        {@assignment_preview.compatible_count} compatible
                      </.ui_badge>
                      <.ui_badge
                        :if={@assignment_preview.unsupported_count > 0}
                        variant="error"
                        size="xs"
                      >
                        {@assignment_preview.unsupported_count} unsupported
                      </.ui_badge>
                      <.ui_badge
                        :if={@assignment_preview.unknown_count > 0}
                        variant="warning"
                        size="xs"
                      >
                        {@assignment_preview.unknown_count} unresolved
                      </.ui_badge>
                    </div>

                    <div
                      :if={assignment_preview_block_message(@assignment_preview)}
                      class="mt-3 text-[11px] font-medium text-warning"
                    >
                      {assignment_preview_block_message(@assignment_preview)}
                    </div>

                    <div :if={@assignment_preview.supported_platforms != []} class="mt-3 space-y-2">
                      <div class="text-[11px] uppercase tracking-wider text-base-content/50">
                        Add-on Supports
                      </div>
                      <div class="flex flex-wrap gap-1">
                        <%= for platform <- @assignment_preview.supported_platforms do %>
                          <.ui_badge variant="ghost" size="xs">{platform}</.ui_badge>
                        <% end %>
                      </div>
                    </div>

                    <div
                      :if={@assignment_preview.unsupported_agents != []}
                      class="mt-3 space-y-2 text-[11px]"
                    >
                      <div class="uppercase tracking-wider text-error">Unsupported Targets</div>
                      <div class="flex flex-wrap gap-1">
                        <%= for agent <- @assignment_preview.unsupported_agents do %>
                          <span class="badge badge-error badge-outline badge-xs">
                            {agent.agent_id} ({agent.platform_label})
                          </span>
                        <% end %>
                      </div>
                    </div>
                  </div>

                  <%= if config_schema_present?(@selected_package.config_schema) do %>
                    <div class="rounded-lg border border-base-200/70 bg-base-100/60 p-3 space-y-3">
                      <div class="text-xs font-semibold text-base-content/70">Configuration</div>
                      <.plugin_config_fields
                        schema={@selected_package.config_schema}
                        params={assignment_params_map(@assignment_form)}
                        base_name="assignment[params]"
                      />
                    </div>

                    <details class="rounded-lg border border-base-200/70 bg-base-100/60 p-3">
                      <summary class="cursor-pointer text-xs font-semibold text-base-content/70">
                        Raw Params (JSON)
                      </summary>
                      <div class="mt-3">
                        <textarea
                          name="assignment[params_raw]"
                          class="textarea textarea-bordered w-full font-mono text-xs min-h-[80px]"
                        ><%= assignment_params_raw(@assignment_form) %></textarea>
                      </div>
                    </details>
                  <% else %>
                    <div>
                      <label class="label"><span class="label-text">Params (JSON)</span></label>
                      <textarea
                        name="assignment[params]"
                        class="textarea textarea-bordered w-full font-mono text-xs min-h-[80px]"
                      ><%= assignment_params_raw(@assignment_form) %></textarea>
                    </div>
                  <% end %>

                  <div>
                    <label class="label"><span class="label-text">Args (one per line)</span></label>
                    <textarea
                      name="assignment[args]"
                      class="textarea textarea-bordered w-full font-mono text-xs min-h-[60px]"
                    ><%= @assignment_form["args"] %></textarea>
                  </div>

                  <div class="flex justify-end">
                    <button
                      type="submit"
                      class="btn btn-primary btn-sm"
                      disabled={
                        not addon_package_assignable?(@selected_package) or not @can_assign_addons or
                          assignment_submit_disabled?(@assignment_form, @assignment_preview)
                      }
                    >
                      Assign
                    </button>
                  </div>
                </form>
                <%= if @selected_package.status != :approved do %>
                  <p class="text-xs text-base-content/60">
                    This add-on must be approved before it can be assigned.
                  </p>
                <% end %>
                <p :if={addon_blob_missing?(@selected_package)} class="text-xs text-error">
                  This add-on cannot be assigned until its missing artifact is re-imported.
                </p>
              </details>
            </div>
          </div>
        <% end %>
      </Shell.settings_chrome>
    </Layouts.app>
    """
  end

  defp list_addon_packages(scope), do: AddonPackages.list(%{limit: 500}, scope: scope)

  defp load_first_party_catalog(socket) do
    case NativeAddonImporter.list_recent_addons(
           %{"repo_url" => socket.assigns.first_party_repo_url},
           first_party_sync_limit()
         ) do
      {:ok, addons} ->
        requested_release_tag =
          if socket.assigns[:first_party_release_selected?] do
            socket.assigns[:first_party_release_tag]
          end

        socket
        |> assign(:first_party_catalog_error, nil)
        |> assign_first_party_catalog_view(addons, requested_release_tag)

      {:error, reason} ->
        release_options = combined_release_options([], socket.assigns.packages)

        socket
        |> assign(:first_party_catalog, [])
        |> assign(:first_party_catalog_all, [])
        |> assign(:first_party_release_options, release_options)
        |> assign(
          :first_party_release_tag,
          selected_first_party_release(release_options, socket.assigns[:first_party_release_tag])
        )
        |> assign(:first_party_catalog_error, format_error(reason))
        |> assign(:first_party_catalog_status, first_party_catalog_status([], socket.assigns.packages))
    end
  end

  defp assign_first_party_catalog_view(socket, addons, requested_release_tag) do
    packages = socket.assigns[:packages] || []
    visible_addons = visible_first_party_addons(addons)
    visible_packages = visible_addon_packages(packages)
    release_options = combined_release_options(visible_addons, visible_packages)
    selected_release_tag = selected_first_party_release(release_options, requested_release_tag)
    visible_release_addons = filter_first_party_addons(visible_addons, selected_release_tag)

    socket
    |> assign(:first_party_catalog_all, addons)
    |> assign(:first_party_release_options, release_options)
    |> assign(:first_party_release_tag, selected_release_tag)
    |> assign(:first_party_catalog, visible_release_addons)
    |> assign(:first_party_catalog_status, first_party_catalog_status(addons, packages))
  end

  defp first_party_release_options(addons) do
    addons
    |> visible_first_party_addons()
    |> Enum.map(& &1.release_tag)
    |> Enum.filter(&official_release_tag?/1)
    |> Enum.uniq()
  end

  defp package_release_options(packages) do
    packages
    |> visible_addon_packages()
    |> Enum.map(& &1.source_release_tag)
    |> Enum.filter(&official_release_tag?/1)
    |> Enum.uniq()
  end

  defp combined_release_options(addons, packages) do
    addons
    |> first_party_release_options()
    |> Kernel.++(package_release_options(packages))
    |> Enum.uniq()
    |> Enum.sort_by(&release_sort_key/1, :desc)
  end

  defp selected_first_party_release([], _requested), do: nil

  defp selected_first_party_release(release_options, requested) do
    if requested in release_options do
      requested
    else
      List.first(release_options)
    end
  end

  defp filter_first_party_addons(_addons, nil), do: []

  defp filter_first_party_addons(addons, release_tag) do
    addons
    |> visible_first_party_addons()
    |> Enum.filter(&(&1.release_tag == release_tag))
  end

  defp first_party_catalog_status(addons, packages) do
    visible_addons = visible_first_party_addons(addons)
    visible_packages = visible_addon_packages(packages)
    import_ready = Enum.count(visible_addons, &Map.get(&1, :import_ready?))
    releases = visible_addons |> combined_release_options(visible_packages) |> length()

    "Loaded #{length(visible_addons)} first-party add-on entry(s), #{import_ready} import-ready, #{length(visible_packages)} imported package(s), from #{releases} release(s)."
  end

  defp first_party_repo_url do
    config = Application.get_env(:serviceradar_web_ng, :native_addon_import, [])
    Keyword.get(config, :repo_url, "https://code.carverauto.dev/carverauto/serviceradar")
  end

  defp first_party_sync_limit do
    config = Application.get_env(:serviceradar_web_ng, :native_addon_import, [])
    Keyword.get(config, :sync_release_limit, 10)
  end

  defp catalog_platforms(addon) do
    addon
    |> Map.get(:artifacts, [])
    |> Enum.map(fn artifact -> "#{artifact["os"]}/#{artifact["arch"]}" end)
    |> Enum.uniq()
    |> Enum.join(", ")
  end

  defp combined_catalog_rows(first_party_addons, packages, release_tag) do
    first_party_addons = visible_first_party_addons(first_party_addons)
    packages = visible_addon_packages(packages)
    package_by_key = Map.new(packages, &{package_catalog_key(&1), &1})

    first_party_rows =
      Enum.map(first_party_addons, fn addon ->
        package = Map.get(package_by_key, addon_catalog_key(addon))

        %{
          addon_id: addon.addon_id,
          name: addon.name,
          version: addon.version,
          release_tag: addon.release_tag,
          platforms: catalog_platforms(addon),
          package: package,
          import_ready: Map.get(addon, :import_ready?, false)
        }
      end)

    first_party_keys = MapSet.new(first_party_addons, &addon_catalog_key/1)

    package_rows =
      packages
      |> Enum.filter(&package_matches_release?(&1, release_tag))
      |> Enum.reject(&(package_catalog_key(&1) in first_party_keys))
      |> Enum.map(fn package ->
        %{
          addon_id: package.addon_id,
          name: package.name,
          version: package.version,
          release_tag: package.source_release_tag,
          platforms: package_platforms(package),
          package: package,
          import_ready: false
        }
      end)

    Enum.sort_by(first_party_rows ++ package_rows, &catalog_row_sort_key/1)
  end

  defp addon_catalog_key(addon), do: {addon.addon_id, addon.version, addon.release_tag}

  defp package_catalog_key(package) do
    {package.addon_id, package.version, package.source_release_tag}
  end

  defp package_matches_release?(_package, nil), do: false
  defp package_matches_release?(package, release_tag), do: package.source_release_tag == release_tag

  defp visible_first_party_addons(addons) do
    Enum.reject(addons, &hidden_catalog_addon_id?(&1.addon_id))
  end

  defp visible_addon_packages(packages) do
    Enum.reject(packages, &hidden_catalog_addon_id?(&1.addon_id))
  end

  defp hidden_catalog_addon_id?(addon_id) do
    inert_sample_addon_id?(addon_id) or RetiredNativeAddons.retired?(addon_id)
  end

  defp inert_sample_addon_id?(addon_id) when is_binary(addon_id) do
    MapSet.member?(@inert_sample_addon_ids, addon_id)
  end

  defp inert_sample_addon_id?(_addon_id), do: false

  defp official_release_tag?(release_tag) when is_binary(release_tag) do
    Regex.match?(@official_release_tag_regex, release_tag)
  end

  defp official_release_tag?(_release_tag), do: false

  defp release_sort_key(release_tag) do
    case Regex.named_captures(@official_release_tag_regex, release_tag) do
      %{"major" => major, "minor" => minor, "patch" => patch} ->
        {String.to_integer(major), String.to_integer(minor), String.to_integer(patch)}

      _ ->
        {-1, -1, -1}
    end
  end

  defp package_platforms(package) do
    package.artifacts
    |> case do
      artifacts when is_map(artifacts) -> Map.keys(artifacts)
      _ -> []
    end
    |> Enum.sort()
    |> Enum.join(", ")
  end

  # Latest version first within each add-on (semver descending; non-semver
  # versions sort after semver ones, tie-broken by raw string) so the default
  # choice at the top is always the newest.
  defp catalog_row_sort_key(row) do
    {row.name |> to_string() |> String.downcase(), row.addon_id, version_desc_key(row.version), to_string(row.version)}
  end

  defp version_desc_key(version) do
    case Version.parse(to_string(version || "")) do
      {:ok, parsed} -> {0, -parsed.major, -parsed.minor, -parsed.patch}
      :error -> {1, 0, 0, 0}
    end
  end

  # --- import state ---------------------------------------------------------

  # A row is importable when the remote entry is import-ready and there is no
  # healthy imported package for it yet (blob-missing packages are re-importable).
  defp catalog_import_state(catalog_rows) do
    importable =
      Enum.count(catalog_rows, fn row ->
        row.import_ready and (is_nil(row.package) or addon_blob_missing?(row.package))
      end)

    imported = Enum.count(catalog_rows, &(not is_nil(&1.package)))

    %{importable: importable, imported: imported, total: length(catalog_rows)}
  end

  defp import_all_label(true, _state), do: "Importing…"

  defp import_all_label(false, %{importable: 0, imported: imported}) when imported > 0 do
    "All #{imported} imported"
  end

  defp import_all_label(false, %{importable: 0}), do: "Import All"
  defp import_all_label(false, %{importable: importable}), do: "Import All (#{importable})"

  defp import_summary_message(summary, release_label) do
    skipped = Map.get(summary, :skipped, 0)
    failed = length(summary.failed)

    parts =
      ["#{summary.imported} imported", "#{skipped} skipped (already imported)"] ++
        if failed > 0, do: ["#{failed} failed"], else: []

    "Import finished for #{release_label}: #{Enum.join(parts, ", ")}."
  end

  # The latest approved package of the same add-on when it is strictly newer
  # than the one being viewed (drives the "open latest" banner so older
  # versions are an explicit drill-in choice, not the default).
  defp newer_approved_package(packages, %{addon_id: addon_id} = current) do
    candidates =
      Enum.filter(packages, fn package ->
        package.addon_id == addon_id and package.status == :approved and
          package.id != current.id and not addon_blob_missing?(package)
      end)

    case AddonFleet.latest_package(candidates) do
      nil ->
        nil

      latest ->
        if AddonFleet.compare_versions(latest.version, current.version) == :gt, do: latest
    end
  end

  defp catalog_row_status(%{package: nil}), do: "not imported"

  defp catalog_row_status(%{package: package}) do
    if addon_blob_missing?(package), do: "blob missing", else: package.status
  end

  defp catalog_row_status_badge(%{package: nil}), do: "badge-ghost"

  defp catalog_row_status_badge(%{package: package}) do
    if addon_blob_missing?(package), do: "badge-error", else: package_status_badge(package.status)
  end

  defp list_assignments_for_package(package_id, scope) do
    AddonAssignments.list(%{addon_package_id: package_id}, scope: scope)
  end

  defp list_profiles_for_package(package_id, scope) do
    AddonProfiles.list(%{addon_package_id: package_id}, scope: scope)
  end

  defp list_agents(scope) do
    Agent
    |> Ash.Query.for_read(:read)
    |> Ash.Query.limit(200)
    |> Ash.Query.sort(name: :asc)
    |> Ash.read!(scope: scope)
    |> AgentRuntimeMetadata.hydrate_agents()
    |> Enum.filter(&active_agent?/1)
  rescue
    _ -> []
  end

  defp active_agent?(%Agent{status: status, last_seen_time: %DateTime{} = last_seen_time})
       when status in [:connected, :degraded, :connecting] do
    DateTime.diff(DateTime.utc_now(), last_seen_time, :minute) <= 30
  end

  defp active_agent?(%Agent{last_seen_time: %DateTime{} = last_seen_time}) do
    DateTime.diff(DateTime.utc_now(), last_seen_time, :minute) <= 30
  end

  defp active_agent?(_agent), do: false

  defp agent_label(agent) do
    name = agent.name || agent.host || agent.uid
    "#{name} (#{agent.uid})"
  end

  defp default_assignment_form do
    %{
      "target_mode" => "agent",
      "cohort" => "connected",
      "agent_uid" => "",
      "agent_ids" => "",
      "params" => "",
      "params_raw" => "",
      "args" => ""
    }
  end

  defp default_profile_form(package \\ nil)

  defp default_profile_form(nil) do
    %{
      "name" => "",
      "target_query" => "",
      "priority" => "100",
      "max_targets" => "10000",
      "params" => "{}",
      "args" => ""
    }
  end

  defp default_profile_form(package) do
    base = default_profile_form(nil)
    %{base | "name" => "#{package.name} profile"}
  end

  defp fetch_agent_uid(form) do
    case String.trim(Map.get(form, "agent_uid") || "") do
      "" -> {:error, :missing_agent}
      uid -> {:ok, uid}
    end
  end

  defp fetch_assignment_agent_uids(%{"target_mode" => "cohort"} = form, package, scope) do
    preview = build_assignment_preview(form, package, scope)

    case preview.compatible_agent_ids do
      [] -> {:error, :empty_cohort}
      agent_uids -> {:ok, agent_uids}
    end
  end

  defp fetch_assignment_agent_uids(form, _package, _scope) do
    with {:ok, agent_uid} <- fetch_agent_uid(form), do: {:ok, [agent_uid]}
  end

  defp create_assignments(agent_uids, package, params, args, scope) do
    Enum.reduce_while(agent_uids, {:ok, 0}, fn agent_uid, {:ok, count} ->
      attrs = %{
        agent_uid: agent_uid,
        addon_package_id: package.id,
        params: params,
        args: args
      }

      # Upsert by (agent_uid, addon_id): re-pushing the same add-on (or upgrading
      # to a newer package of it) must update the existing assignment rather than
      # collide with the one-enabled-per-(agent, add-on) invariant.
      case AddonAssignments.upsert(package.addon_id, attrs, scope: scope) do
        {:ok, _assignment} -> {:cont, {:ok, count + 1}}
        {:error, error} -> {:halt, {:error, error, count}}
      end
    end)
  end

  defp assignment_success_message(1), do: "Add-on assigned to agent."
  defp assignment_success_message(count), do: "Add-on assigned to #{count} agents."

  defp source_label(source) when is_atom(source), do: Atom.to_string(source)
  defp source_label(source) when is_binary(source), do: source
  defp source_label(_source), do: "unknown"

  defp assignment_source_text(assignment, profiles) do
    case source_label(assignment.source) do
      "profile" ->
        case assignment_profile(assignment, profiles) do
          nil -> "profile"
          profile -> "profile: #{profile.name}"
        end

      "manual" ->
        "manual override"

      source ->
        source
    end
  end

  defp assignment_reconcile_status(assignment, profiles) do
    present_text(assignment.profile_reconcile_status) ||
      assignment
      |> assignment_profile(profiles)
      |> profile_reconcile_report()
      |> Map.get(:status)
  end

  defp assignment_reconciled_at(assignment, profiles) do
    assignment.profile_last_reconciled_at ||
      case assignment_profile(assignment, profiles) do
        nil -> nil
        profile -> profile.last_reconciled_at
      end
  end

  defp assignment_reconcile_error(assignment, profiles) do
    present_text(assignment.profile_reconcile_error) ||
      assignment
      |> assignment_profile(profiles)
      |> profile_reconcile_report()
      |> profile_report_last_error()
  end

  defp assignment_profile(assignment, profiles) do
    profile_id = assignment.addon_profile_id

    Enum.find(profiles, fn profile ->
      present_text(profile.id) == present_text(profile_id)
    end)
  end

  defp parse_params(form, config_schema) do
    if config_schema_present?(config_schema) do
      structured = Map.get(form, "params")
      raw = Map.get(form, "params_raw")

      cond do
        is_map(structured) and map_size(structured) > 0 -> {:ok, structured}
        is_binary(raw) and String.trim(raw) != "" -> parse_json_object(raw)
        true -> {:ok, %{}}
      end
    else
      raw = Map.get(form, "params")

      if is_binary(raw) and String.trim(raw) != "" do
        parse_json_object(raw)
      else
        {:ok, %{}}
      end
    end
  end

  defp parse_profile_params(form) do
    raw = Map.get(form, "params")

    if is_binary(raw) and String.trim(raw) != "" do
      parse_json_object(raw)
    else
      {:ok, %{}}
    end
  end

  defp profile_attrs(form, package, params, priority, max_targets, target_query) do
    {:ok,
     %{
       name: present_text(Map.get(form, "name")) || "#{package.name} profile",
       addon_package_id: package.id,
       target_query: target_query,
       params: params,
       args: parse_args(Map.get(form, "args")),
       priority: priority,
       max_targets: max_targets,
       enabled: true
     }}
  end

  defp profile_target_query(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, :missing_target_query}
      query -> {:ok, query}
    end
  end

  defp profile_target_query(_value), do: {:error, :missing_target_query}

  defp parse_positive_integer(value, default) do
    value = if is_nil(value) or value == "", do: Integer.to_string(default), else: to_string(value)

    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> {:ok, parsed}
      _ -> {:error, :invalid_integer}
    end
  end

  defp profile_reconcile_message(summary) when is_map(summary) do
    desired = Map.get(summary, :desired_assignments) || Map.get(summary, "desired_assignments") || 0
    upserted = Map.get(summary, :upserted) || Map.get(summary, "upserted") || 0
    disabled = Map.get(summary, :disabled) || Map.get(summary, "disabled") || 0

    "Profile reconciled: #{desired} desired, #{upserted} changed, #{disabled} disabled."
  end

  defp profile_reconcile_message(_summary), do: "Profile reconciled."

  defp profile_reconcile_report(%{last_reconcile_summary: summary}) when is_map(summary) do
    %{
      status: summary_value(summary, :status),
      matched_rows: summary_value(summary, :matched_rows, 0),
      eligible_agents: summary_value(summary, :eligible_agents, 0),
      desired_assignments: summary_value(summary, :desired_assignments, 0),
      skipped_targets: summary_list(summary, :skipped_targets),
      skip_counts: summary_map(summary, :skip_counts),
      upserted: summary_value(summary, :upserted, 0),
      disabled: summary_value(summary, :disabled, 0),
      last_error: summary_value(summary, :last_error)
    }
  end

  defp profile_reconcile_report(_profile) do
    %{
      status: nil,
      matched_rows: nil,
      eligible_agents: nil,
      desired_assignments: nil,
      skipped_targets: [],
      skip_counts: %{},
      upserted: nil,
      disabled: nil,
      last_error: nil
    }
  end

  defp profile_report_status_badge("failed"), do: "badge-error"
  defp profile_report_status_badge("succeeded"), do: "badge-success"
  defp profile_report_status_badge(_status), do: "badge-ghost"

  defp profile_report_status_label("failed"), do: "failed"
  defp profile_report_status_label("succeeded"), do: "ok"
  defp profile_report_status_label(status) when is_binary(status), do: status
  defp profile_report_status_label(_status), do: "unknown"

  defp profile_report_chips(report) do
    Enum.reject(
      [
        count_chip("matched", report.matched_rows),
        count_chip("eligible", report.eligible_agents),
        count_chip("desired", report.desired_assignments),
        count_chip("skipped", skipped_target_count(report)),
        count_chip("changed", report.upserted),
        count_chip("disabled stale", report.disabled)
      ],
      &is_nil/1
    )
  end

  defp profile_skip_chips(report) do
    report.skip_counts
    |> Enum.sort_by(fn {reason, count} -> {-count, to_string(reason)} end)
    |> Enum.take(4)
    |> Enum.map(fn {reason, count} -> "#{human_reason(reason)} #{count}" end)
  end

  defp profile_report_last_error(%{last_error: error}) when is_binary(error) and error != "" do
    "Last error: #{truncate_error(error)}"
  end

  defp profile_report_last_error(_report), do: nil

  defp skipped_target_count(%{skip_counts: skip_counts}) when map_size(skip_counts) > 0 do
    skip_counts |> Map.values() |> Enum.sum()
  end

  defp skipped_target_count(%{skipped_targets: skipped_targets}) when is_list(skipped_targets) do
    length(skipped_targets)
  end

  defp skipped_target_count(_report), do: 0

  defp count_chip(_label, nil), do: nil
  defp count_chip(label, value) when is_integer(value), do: "#{label} #{value}"
  defp count_chip(label, value) when is_binary(value), do: "#{label} #{value}"
  defp count_chip(_label, _value), do: nil

  defp human_reason(reason) do
    reason
    |> to_string()
    |> String.replace("_", " ")
  end

  defp summary_value(summary, key, default \\ nil) do
    Map.get(summary, key) || Map.get(summary, to_string(key)) || default
  end

  defp summary_map(summary, key) do
    case summary_value(summary, key, %{}) do
      value when is_map(value) -> value
      _ -> %{}
    end
  end

  defp summary_list(summary, key) do
    case summary_value(summary, key, []) do
      value when is_list(value) -> value
      _ -> []
    end
  end

  defp parse_json_object(raw) do
    case Jason.decode(raw) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:ok, _other} -> {:error, {:invalid_params, "expected a JSON object"}}
      {:error, _error} -> {:error, {:invalid_params, "invalid JSON"}}
    end
  end

  defp parse_args(nil), do: []

  defp parse_args(text) when is_binary(text) do
    text
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_args(_text), do: []

  defp parse_selected_capabilities(form) when is_map(form) do
    form
    |> Map.get("approved_capabilities", [])
    |> List.wrap()
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp parse_selected_capabilities(_form), do: []

  defp assignment_params_map(form) do
    case Map.get(form, "params") do
      %{} = map -> map
      _ -> %{}
    end
  end

  defp assignment_params_raw(form) do
    Map.get(form, "params_raw") || raw_string(Map.get(form, "params")) || ""
  end

  defp raw_string(value) when is_binary(value), do: value
  defp raw_string(_value), do: nil

  defp config_schema_present?(schema) when is_map(schema) do
    properties = Map.get(schema, "properties") || Map.get(schema, :properties) || %{}
    is_map(properties) and map_size(properties) > 0
  end

  defp config_schema_present?(_schema), do: false

  defp empty_assignment_preview do
    %{
      cohort: "agent",
      selected_count: 0,
      compatible_count: 0,
      compatible_agent_ids: [],
      unsupported_count: 0,
      unsupported_agent_ids: [],
      unknown_count: 0,
      supported_platforms: [],
      unsupported_agents: [],
      unknown_agent_ids: []
    }
  end

  defp build_assignment_preview(_form, nil, _scope), do: empty_assignment_preview()

  defp build_assignment_preview(form, package, scope) do
    {selected_agents, unknown_agent_ids, selected_count, cohort} =
      assignment_preview_targets(form, scope)

    {compatible_agents, unsupported_agents} =
      Enum.split_with(selected_agents, &addon_supports_agent?(package, &1))

    unsupported = summarize_unsupported_agents(unsupported_agents)

    %{
      cohort: cohort,
      selected_count: selected_count,
      compatible_count: length(compatible_agents),
      compatible_agent_ids: Enum.map(compatible_agents, & &1.uid),
      unsupported_count: length(unsupported),
      unsupported_agent_ids: Enum.map(unsupported, & &1.agent_id),
      unknown_count: length(unknown_agent_ids),
      supported_platforms: addon_supported_platforms(package),
      unsupported_agents: Enum.take(unsupported, 8),
      unknown_agent_ids: Enum.take(unknown_agent_ids, 8)
    }
  end

  defp assignment_preview_targets(%{"target_mode" => "cohort", "cohort" => "custom"} = form, scope) do
    agent_ids = parse_agent_ids(Map.get(form, "agent_ids"))
    agents = list_agents_by_uid(agent_ids, scope)
    agents_by_uid = Map.new(agents, &{&1.uid, &1})

    selected_agents =
      agent_ids
      |> Enum.map(&Map.get(agents_by_uid, &1))
      |> Enum.reject(&is_nil/1)

    unknown_agent_ids = Enum.reject(agent_ids, &Map.has_key?(agents_by_uid, &1))

    {selected_agents, unknown_agent_ids, length(selected_agents) + length(unknown_agent_ids), "custom"}
  end

  defp assignment_preview_targets(%{"target_mode" => "cohort"}, scope) do
    agents = list_agents(scope)
    {agents, [], length(agents), "connected"}
  end

  defp assignment_preview_targets(form, scope) do
    case fetch_agent_uid(form) do
      {:ok, agent_uid} ->
        agents = list_agents_by_uid([agent_uid], scope)
        {agents, if(agents == [], do: [agent_uid], else: []), 1, "agent"}

      {:error, :missing_agent} ->
        {[], [], 0, "agent"}
    end
  end

  defp list_agents_by_uid([], _scope), do: []

  defp list_agents_by_uid(agent_ids, scope) do
    Agent
    |> Ash.Query.for_read(:read, %{})
    |> Ash.Query.filter(uid in ^agent_ids)
    |> Ash.read(scope: scope)
    |> case do
      {:ok, agents} -> AgentRuntimeMetadata.hydrate_agents(agents)
      {:error, _error} -> []
    end
  end

  defp parse_agent_ids(value) when is_binary(value) do
    value
    |> String.split(~r/[\s,]+/, trim: true)
    |> Enum.uniq()
  end

  defp parse_agent_ids(_value), do: []

  defp addon_supports_agent?(package, %Agent{metadata: metadata}) when is_map(metadata) do
    agent_os = metadata_field(metadata, [:os, "os"])
    agent_arch = metadata_field(metadata, [:arch, "arch"])

    platform_allowed_by_requires?(package.requires, agent_os) and
      platform_allowed_by_artifacts?(package.artifacts, agent_os, agent_arch)
  end

  defp addon_supports_agent?(_package, _agent), do: false

  defp platform_allowed_by_requires?(requires, agent_os) when is_map(requires) do
    platforms = Map.get(requires, "platforms") || Map.get(requires, :platforms) || []
    platforms = Enum.map(List.wrap(platforms), &to_string/1)

    platforms == [] or (is_binary(agent_os) and agent_os in platforms)
  end

  defp platform_allowed_by_requires?(_requires, _agent_os), do: true

  defp platform_allowed_by_artifacts?(artifacts, _agent_os, _agent_arch) when artifacts in [nil, %{}], do: true

  defp platform_allowed_by_artifacts?(artifacts, agent_os, agent_arch) when is_map(artifacts) do
    key = platform_label(agent_os, agent_arch)
    is_binary(key) and Map.has_key?(artifacts, key)
  end

  defp platform_allowed_by_artifacts?(_artifacts, _agent_os, _agent_arch), do: true

  defp summarize_unsupported_agents(agents) do
    Enum.map(agents, fn agent ->
      %{
        agent_id: agent.uid,
        platform_label: agent_platform_label(agent) || "unknown platform"
      }
    end)
  end

  defp show_assignment_preview?(preview) do
    preview.selected_count > 0 or preview.supported_platforms != [] or preview.unknown_agent_ids != []
  end

  defp assignment_submit_disabled?(%{"target_mode" => "cohort"}, preview) do
    preview.compatible_count == 0 or preview.unknown_count > 0
  end

  defp assignment_submit_disabled?(_form, _preview), do: false

  defp assignment_preview_scope_text(%{cohort: "custom"}), do: "Current custom cohort"
  defp assignment_preview_scope_text(%{cohort: "connected"}), do: "Current connected cohort"
  defp assignment_preview_scope_text(_preview), do: "Selected agent"

  defp assignment_preview_block_message(preview) do
    cond do
      preview.selected_count == 0 ->
        "Select at least one agent to preview compatibility."

      preview.unknown_count > 0 ->
        "Assignment is blocked until unresolved agent IDs are corrected or removed."

      preview.compatible_count == 0 ->
        "Assignment is blocked until the target includes at least one supported agent."

      preview.unsupported_count > 0 ->
        "Unsupported agents will be skipped; the add-on will target the compatible subset."

      true ->
        nil
    end
  end

  defp addon_supported_platforms(package) do
    package.artifacts
    |> case do
      artifacts when is_map(artifacts) -> Map.keys(artifacts)
      _ -> []
    end
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.sort()
  end

  defp agent_platform_label(%Agent{metadata: metadata}) when is_map(metadata) do
    platform_label(metadata_field(metadata, [:os, "os"]), metadata_field(metadata, [:arch, "arch"]))
  end

  defp agent_platform_label(_agent), do: nil

  defp metadata_field(metadata, keys) when is_map(metadata) do
    Enum.find_value(List.wrap(keys), fn key ->
      case Map.get(metadata, key) do
        nil -> nil
        value -> value
      end
    end)
  end

  defp platform_label(os, arch) do
    case {present_text(os), present_text(arch)} do
      {nil, nil} -> nil
      {os, nil} -> os
      {nil, arch} -> arch
      {os, arch} -> "#{os}/#{arch}"
    end
  end

  defp package_capabilities(nil), do: []

  defp package_capabilities(package) do
    package.capabilities
    |> List.wrap()
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp approved_capabilities_text(package) do
    case package.approved_capabilities || [] do
      [] -> "—"
      capabilities -> Enum.join(capabilities, ", ")
    end
  end

  defp denied_reason_text(%{denied_reason: reason}) when is_binary(reason) and reason != "", do: reason

  defp denied_reason_text(_package), do: "Denied or revoked packages are not eligible for delivery."

  defp addon_package_assignable?(package) do
    package.status == :approved and not addon_blob_missing?(package)
  end

  defp addon_blob_missing?(%{verification_status: "blob_missing"}), do: true
  defp addon_blob_missing?(_package), do: false

  defp verification_status_label(package) do
    if addon_blob_missing?(package), do: "blob missing", else: package.verification_status || "unknown"
  end

  defp verification_status_badge(package) do
    if addon_blob_missing?(package), do: "badge-error", else: "badge-ghost"
  end

  defp package_status_badge(:approved), do: "badge-success"
  defp package_status_badge("approved"), do: "badge-success"
  defp package_status_badge(:staged), do: "badge-warning"
  defp package_status_badge("staged"), do: "badge-warning"
  defp package_status_badge(status) when status in [:denied, :revoked, "denied", "revoked"], do: "badge-error"
  defp package_status_badge(_status), do: "badge-ghost"

  defp approved_by(%{user: %{email: email}}) when is_binary(email), do: email
  defp approved_by(_scope), do: nil

  defp current_path_from_url(url), do: URI.parse(url).path

  defp addons_base_path_from_url(url) do
    path = URI.parse(url).path || ""

    if String.starts_with?(path, "/admin/addons") do
      "/admin/addons"
    else
      "/settings/agents/addons"
    end
  end

  defp format_error(error) when is_binary(error), do: truncate_error(error)
  defp format_error(error) when is_atom(error), do: error |> Atom.to_string() |> truncate_error()
  defp format_error(%Ash.Error.Invalid{} = error), do: error |> Exception.message() |> truncate_error()

  defp format_error(error) do
    error
    |> inspect(limit: 8, printable_limit: 400)
    |> truncate_error()
  end

  defp truncate_error(message) when is_binary(message) do
    if String.length(message) > 500 do
      String.slice(message, 0, 500) <> "..."
    else
      message
    end
  end

  defp present_text(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp present_text(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp present_text(_value), do: nil
end
