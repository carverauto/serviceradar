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

  alias Ash.Error.Invalid
  alias ServiceRadar.AgentRuntimeMetadata
  alias ServiceRadar.Edge.EdgeSite
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Plugins.ConfigSchema
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
       |> assign(:edge_sites, list_edge_sites(scope))
       |> assign(:cohort_options, @cohort_options)
       |> assign(:show_details_modal, false)
       |> assign(:selected_package, nil)
       |> assign(:newer_approved_package, nil)
       |> assign(:import_running?, false)
       |> assign(:sync_running?, false)
       |> assign(:first_party_catalog_synced_at, nil)
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
        |> assign(:assignment_form, default_assignment_form(package))
        |> assign(
          :assignment_preview,
          build_assignment_preview(default_assignment_form(package), package, scope)
        )
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

  def handle_async(:sync_first_party_catalog, {:ok, result}, socket) do
    socket = assign(socket, :sync_running?, false)

    case result do
      {:ok, summary} ->
        socket = apply_first_party_catalog_summary(socket, summary)

        {:noreply, put_flash(socket, :info, catalog_sync_flash(socket, summary))}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:first_party_catalog_error, format_error(reason))
         |> put_flash(:error, "Catalog sync failed: #{format_error(reason)}")}
    end
  end

  def handle_async(:sync_first_party_catalog, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(:sync_running?, false)
     |> put_flash(:error, "Catalog sync failed: #{format_error(reason)}")}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    packages = list_addon_packages(socket.assigns.current_scope)

    {:noreply,
     socket
     |> assign(:packages, packages)
     |> assign_first_party_catalog_view(socket.assigns.first_party_catalog_all, socket.assigns.first_party_release_tag)}
  end

  def handle_event("sync_first_party_catalog", _params, %{assigns: %{sync_running?: true}} = socket) do
    {:noreply, socket}
  end

  def handle_event("sync_first_party_catalog", _params, socket) do
    repo_url = socket.assigns.first_party_repo_url
    limit = first_party_sync_limit()

    {:noreply,
     socket
     |> assign(:sync_running?, true)
     |> start_async(:sync_first_party_catalog, fn ->
       NativeAddonImporter.list_recent_addons_with_summary(%{"repo_url" => repo_url}, limit)
     end)}
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
    scope = socket.assigns.current_scope

    {:noreply,
     socket
     |> assign(:import_running?, true)
     |> start_async(:import_first_party_catalog, fn ->
       AddonPackages.sync_first_party_addons(
         repo_url: repo_url,
         release_tag: release_tag,
         limit: limit,
         scope: scope
       )
     end)}
  end

  def handle_event("import_first_party_addon", _params, %{assigns: %{can_review_addons: false}} = socket) do
    {:noreply, put_flash(socket, :error, "You don't have permission to import add-ons.")}
  end

  def handle_event("import_first_party_addon", params, socket) do
    addon =
      Enum.find(socket.assigns.first_party_catalog_all, fn addon ->
        addon.release_tag == params["release_tag"] and addon.addon_id == params["addon_id"] and
          addon.version == params["version"]
      end)

    case addon do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "First-party add-on is no longer present in the selected release")
         |> load_first_party_catalog()}

      addon ->
        import_catalog_addon(socket, addon, replace: params["replace"] == "true")
    end
  end

  def handle_event("view_package", %{"id" => id}, socket) do
    {:noreply, push_patch(socket, to: socket.assigns.addons_base_path <> "/" <> id)}
  end

  def handle_event("close_details", _params, socket) do
    {:noreply, push_patch(socket, to: socket.assigns.addons_base_path)}
  end

  def handle_event("assignment_change", %{"assignment" => form}, socket) do
    form = Map.merge(default_assignment_form(socket.assigns.selected_package), form)

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
    form = Map.merge(default_assignment_form(package), form)

    with {:ok, agent_uids} <- fetch_assignment_agent_uids(form, package, scope),
         {:ok, params} <- parse_params(form, package.config_schema) do
      case create_assignments(
             agent_uids,
             package,
             params,
             parse_args(Map.get(form, "args")),
             Map.get(form, "edge_site_id"),
             update_policy_attrs(form),
             scope
           ) do
        {:ok, count} ->
          {:noreply,
           socket
           |> put_flash(:info, assignment_success_message(count))
           |> assign(:assignments, list_assignments_for_package(package.id, scope))
           |> assign(:assignment_form, default_assignment_form(package))
           |> assign(
             :assignment_preview,
             build_assignment_preview(default_assignment_form(package), package, scope)
           )}

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
    submitted_form = form
    form = Map.merge(default_profile_form(package), form)

    with {:ok, params} <- parse_profile_params(submitted_form, package.config_schema),
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

      {:error, {:invalid_target_entity, entity}} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Add-on profiles must target agents (in:agents), not #{entity}."
         )}

      {:error, :invalid_integer} ->
        {:noreply, put_flash(socket, :error, "Priority and max targets must be positive integers.")}
    end
  end

  def handle_event("reconcile_profile", _params, %{assigns: %{can_assign_addons: false}} = socket) do
    {:noreply, put_flash(socket, :error, "You don't have permission to assign add-ons.")}
  end

  def handle_event("delete_profile", _params, %{assigns: %{can_assign_addons: false}} = socket) do
    {:noreply, put_flash(socket, :error, "You don't have permission to assign add-ons.")}
  end

  def handle_event("delete_profile", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope
    package = socket.assigns.selected_package

    case AddonProfiles.delete(id, scope: scope) do
      {:ok, _profile} ->
        {:noreply,
         socket
         |> put_flash(:info, "Add-on profile removed.")
         |> assign(:addon_profiles, list_profiles_for_package(package.id, scope))
         |> assign(:assignments, list_assignments_for_package(package.id, scope))}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, "Failed to remove profile: #{format_error(error)}")}
    end
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

  def handle_event("set_assignment_update_policy", %{"id" => id, "policy" => policy}, socket) do
    attrs = update_policy_only_attrs(policy)

    case AddonAssignments.update(id, attrs, scope: socket.assigns.current_scope) do
      {:ok, _} ->
        package = socket.assigns.selected_package

        {:noreply,
         socket
         |> put_flash(:info, "Assignment update policy changed.")
         |> assign(:assignments, list_assignments_for_package(package.id, socket.assigns.current_scope))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not change update policy: #{format_error(reason)}")}
    end
  end

  def handle_event("set_profile_update_policy", %{"id" => id, "policy" => policy}, socket) do
    attrs = update_policy_only_attrs(policy)

    case AddonProfiles.update(id, attrs, scope: socket.assigns.current_scope) do
      {:ok, _} ->
        package = socket.assigns.selected_package

        {:noreply,
         socket
         |> put_flash(:info, "Profile update policy changed.")
         |> assign(:addon_profiles, list_profiles_for_package(package.id, socket.assigns.current_scope))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not change update policy: #{format_error(reason)}")}
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
            <h1 class="text-2xl font-semibold text-sr-ink">Add-ons</h1>
            <p class="text-sm text-sr-muted">
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
                <p class="text-xs text-sr-muted">
                  Signed first-party add-ons and imported packages by release.
                </p>
              </div>
              <div class="flex flex-wrap items-center gap-2">
                <form
                  :if={@first_party_release_options != []}
                  id="select-addon-release-form"
                  phx-change="select_first_party_release"
                >
                  <select name="release_tag" class={ui_field_class(size: "sm")}>
                    <%= for release_tag <- @first_party_release_options do %>
                      <option value={release_tag} selected={release_tag == @first_party_release_tag}>
                        {release_tag}
                      </option>
                    <% end %>
                  </select>
                </form>
                <.ui_button
                  variant="ghost"
                  size="sm"
                  disabled={@sync_running? or @import_running?}
                  phx-click="sync_first_party_catalog"
                  title="Re-fetch the first-party catalog from the registry. This does not import add-ons."
                >
                  <span :if={@sync_running?} class="sr-ui-spinner sr-ui-spinner-xs"></span>
                  <.icon :if={not @sync_running?} name="hero-arrow-path" class="size-4" />
                  {if @sync_running?, do: "Syncing…", else: "Sync"}
                </.ui_button>
                <.ui_button
                  :if={@can_review_addons}
                  variant="primary"
                  size="sm"
                  disabled={@import_running? or @sync_running? or import_state.importable == 0}
                  phx-click="import_first_party_catalog"
                >
                  <span :if={@import_running?} class="sr-ui-spinner sr-ui-spinner-xs"></span>
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
            <div class="mb-3 text-xs text-sr-muted">
              <%= if @first_party_catalog_status.synced_at do %>
                Last refresh
                <.user_time
                  id="admin-addon-catalog-last-refresh-at"
                  value={@first_party_catalog_status.synced_at}
                  timezone={@current_scope.user.timezone || "Etc/UTC"}
                  style={:compact}
                />.
              <% end %>
              {@first_party_catalog_status.summary}
            </div>
          <% end %>

          <div
            :if={import_state.replaceable > 0}
            class={ui_alert_class(variant: "warning", class: "mb-3 text-sm")}
          >
            {import_state.replaceable}
            {if import_state.replaceable == 1, do: "add-on is", else: "add-ons are"} already imported at this version from an earlier release, with a
            different build. Import All will not overwrite them. Use Replace on
            those rows if you want this release's binaries.
          </div>

          <%= cond do %>
            <% catalog_rows == [] and is_nil(@first_party_catalog_error) -> %>
              <div class="rounded-xl border border-dashed border-sr-line bg-sr-surface p-6 text-center">
                <div class="text-sm font-semibold text-sr-ink">
                  No add-ons found for this release
                </div>
                <p class="mt-1 text-xs text-sr-muted">
                  Choose another release or sync the first-party catalog.
                </p>
              </div>
            <% catalog_rows != [] -> %>
              <div class="sr-ui-table-shell">
                <table class={ui_table_class(size: "sm")}>
                  <thead>
                    <tr class="text-xs uppercase tracking-wide text-sr-muted">
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
                      <tr class="hover:bg-sr-subtle/30">
                        <td>
                          <div class="font-medium">{row.name}</div>
                          <div class="text-xs text-sr-muted font-mono">{row.addon_id}</div>
                        </td>
                        <td class="text-xs">{row.version}</td>
                        <td class="text-xs font-mono">{row.release_tag || "—"}</td>
                        <td class="text-xs">{row.platforms}</td>
                        <td>
                          <.ui_badge size="sm" variant={catalog_row_status_variant(row)}>
                            {catalog_row_status(row)}
                          </.ui_badge>
                        </td>
                        <td class="text-right">
                          <.ui_button
                            :if={row.package || row.version_package}
                            variant="ghost"
                            size="sm"
                            phx-click="view_package"
                            phx-value-id={(row.package || row.version_package).id}
                          >
                            View
                          </.ui_button>
                          <.ui_button
                            :if={replaceable_catalog_row?(row) and @can_review_addons}
                            variant="ghost"
                            size="sm"
                            phx-click="import_first_party_addon"
                            phx-value-addon_id={row.addon_id}
                            phx-value-version={row.version}
                            phx-value-release_tag={row.release_tag}
                            phx-value-replace="true"
                            data-confirm={"Replace #{row.addon_id} #{row.version} with the #{row.release_tag} build? The package will go back to staged and must be approved again."}
                          >
                            Replace
                          </.ui_button>
                          <.ui_button
                            :if={
                              is_nil(row.package) and is_nil(row.version_package) and
                                @can_review_addons and row.import_ready
                            }
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
          <.ui_modal
            id="addon-package-details-modal"
            size="xl"
            on_cancel="close_details"
            box_class="max-h-[90vh] overflow-y-auto"
          >
            <:title>
              <div>
                <div>{@selected_package.name}</div>
                <div class="text-xs font-mono font-normal text-sr-muted">
                  {@selected_package.addon_id} · v{@selected_package.version}
                </div>
              </div>
            </:title>

            <dl class="grid grid-cols-2 gap-2 text-xs">
              <div>
                <dt class="text-sr-muted">Delivery</dt>
                <dd>{@selected_package.delivery}</dd>
              </div>
              <div>
                <dt class="text-sr-muted">Supervision</dt>
                <dd>{@selected_package.supervision}</dd>
              </div>
              <div class="col-span-2">
                <dt class="text-sr-muted">Capabilities</dt>
                <dd>{Enum.join(@selected_package.capabilities || [], ", ")}</dd>
              </div>
              <div class="col-span-2">
                <dt class="text-sr-muted">Approved capabilities</dt>
                <dd>{approved_capabilities_text(@selected_package)}</dd>
              </div>
            </dl>

            <div class="grid gap-3 md:grid-cols-2">
              <div class="rounded-xl border border-sr-line p-4 space-y-2">
                <div class="text-sm font-semibold">Manifest & delivery</div>
                <dl class="grid grid-cols-2 gap-2 text-xs">
                  <div>
                    <dt class="text-sr-muted">Kind</dt>
                    <dd>{@selected_package.kind}</dd>
                  </div>
                  <div>
                    <dt class="text-sr-muted">Binary</dt>
                    <dd class="font-mono">{@selected_package.binary || "—"}</dd>
                  </div>
                  <div class="col-span-2">
                    <dt class="text-sr-muted">Install path</dt>
                    <dd class="font-mono break-all">{@selected_package.install_path}</dd>
                  </div>
                  <div class="col-span-2">
                    <dt class="text-sr-muted">Supported artifacts</dt>
                    <dd class="flex flex-wrap gap-1">
                      <%= for platform <- addon_supported_platforms(@selected_package) do %>
                        <.ui_badge size="xs" variant="ghost" class="font-mono">
                          {platform}
                        </.ui_badge>
                      <% end %>
                      <span
                        :if={addon_supported_platforms(@selected_package) == []}
                        class="text-sr-muted"
                      >
                        No per-architecture artifact gate
                      </span>
                    </dd>
                  </div>
                </dl>
              </div>

              <div class="rounded-xl border border-sr-line p-4 space-y-2">
                <div class="text-sm font-semibold">Provenance</div>
                <dl class="space-y-2 text-xs">
                  <div>
                    <dt class="text-sr-muted">Source</dt>
                    <dd>{@selected_package.source_type}</dd>
                  </div>
                  <div>
                    <dt class="text-sr-muted">Release</dt>
                    <dd class="font-mono">{@selected_package.source_release_tag || "—"}</dd>
                  </div>
                  <div>
                    <dt class="text-sr-muted">OCI reference</dt>
                    <dd class="font-mono break-all">{@selected_package.source_oci_ref || "—"}</dd>
                  </div>
                  <div>
                    <dt class="text-sr-muted">Digest</dt>
                    <dd class="font-mono break-all">
                      {@selected_package.source_oci_digest || "—"}
                    </dd>
                  </div>
                  <div>
                    <dt class="text-sr-muted">Verification</dt>
                    <dd>
                      <.ui_badge
                        size="xs"
                        variant={verification_status_variant(@selected_package)}
                      >
                        {verification_status_label(@selected_package)}
                      </.ui_badge>
                    </dd>
                  </div>
                  <div :if={present_text(@selected_package.verification_error)} class="col-span-2">
                    <dt class="text-sr-muted">Verification error</dt>
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
              <p class="text-xs text-sr-muted">
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
                    <label class="inline-flex items-center gap-2 rounded-lg border border-sr-line px-3 py-2 text-xs">
                      <input
                        type="checkbox"
                        name="review[approved_capabilities][]"
                        value={cap}
                        checked
                        class={ui_checkbox_class(size: "xs")}
                      />
                      <span class="font-mono">{cap}</span>
                    </label>
                  <% end %>
                  <span
                    :if={package_capabilities(@selected_package) == []}
                    class="text-xs text-sr-muted"
                  >
                    This package declares no capabilities.
                  </span>
                </div>
                <div class="flex flex-wrap justify-end gap-2">
                  <.ui_button :if={@can_review_addons} type="submit" size="sm" variant="primary">
                    Approve
                  </.ui_button>
                </div>
              </form>

              <form
                id={"deny-addon-#{@selected_package.id}"}
                phx-submit="deny_package"
                phx-value-id={@selected_package.id}
                class="space-y-2"
              >
                <label class="flex items-center justify-between gap-2">
                  <span class="text-sm font-medium text-sr-ink">Deny reason</span>
                </label>
                <textarea
                  name="review[denied_reason]"
                  class={ui_field_class(class: "w-full min-h-[64px] py-2.5 text-sm")}
                  placeholder="Reason this package should not be assigned"
                ></textarea>
                <div class="flex justify-end">
                  <.ui_button :if={@can_review_addons} type="submit" size="sm" variant="danger">
                    Deny
                  </.ui_button>
                </div>
              </form>
            </div>

            <div
              :if={@selected_package.status in [:denied, :revoked]}
              class="rounded-xl border border-error/30 bg-error/5 p-4 text-sm"
            >
              <div class="font-semibold">Not assignable</div>
              <p class="mt-1 text-xs text-sr-muted">
                {denied_reason_text(@selected_package)}
              </p>
            </div>

            <div class="rounded-xl border border-sr-line p-4 space-y-2">
              <div class="text-sm font-semibold">Current assignments</div>
              <%= if @assignments == [] do %>
                <p class="text-xs text-sr-muted">Not assigned to any agent yet.</p>
              <% else %>
                <ul class="divide-y divide-sr-line">
                  <%= for assignment <- @assignments do %>
                    <li class="flex items-center justify-between gap-2 py-2">
                      <div class="min-w-0">
                        <div class="text-xs font-mono">{assignment.agent_uid}</div>
                        <div class="mt-1 flex flex-wrap gap-1">
                          <.ui_badge size="xs" variant="ghost">
                            {assignment_source_text(assignment, @addon_profiles)}
                          </.ui_badge>
                          <.ui_badge
                            :if={assignment_reconcile_status(assignment, @addon_profiles)}
                            size="xs"
                            variant={
                              profile_report_status_variant(
                                assignment_reconcile_status(assignment, @addon_profiles)
                              )
                            }
                          >
                            {profile_report_status_label(
                              assignment_reconcile_status(assignment, @addon_profiles)
                            )}
                          </.ui_badge>
                          <.ui_badge
                            :if={assignment_reconciled_at(assignment, @addon_profiles)}
                            size="xs"
                            variant="ghost"
                          >
                            reconciled
                          </.ui_badge>
                          <.ui_badge size="xs" variant="info">
                            {update_policy_label(assignment.update_policy)}
                          </.ui_badge>
                        </div>
                        <div
                          :if={assignment_reconcile_error(assignment, @addon_profiles)}
                          class="mt-1 truncate text-[11px] text-error"
                        >
                          {assignment_reconcile_error(assignment, @addon_profiles)}
                        </div>
                      </div>
                      <div class="flex items-center gap-2">
                        <.ui_badge
                          size="sm"
                          variant={if(assignment.enabled, do: "success", else: "ghost")}
                        >
                          {if assignment.enabled, do: "enabled", else: "disabled"}
                        </.ui_badge>
                        <.ui_button
                          :if={@can_assign_addons}
                          type="button"
                          phx-click="set_assignment_update_policy"
                          phx-value-id={assignment.id}
                          phx-value-policy={next_update_policy(assignment.update_policy)}
                          size="xs"
                          variant="ghost"
                        >
                          {update_policy_action_label(assignment.update_policy)}
                        </.ui_button>
                        <.ui_button
                          :if={@can_assign_addons}
                          type="button"
                          phx-click="delete_assignment"
                          phx-value-id={assignment.id}
                          data-confirm="Remove this add-on assignment?"
                          size="xs"
                          variant="ghost"
                        >
                          Remove
                        </.ui_button>
                      </div>
                    </li>
                  <% end %>
                </ul>
              <% end %>
            </div>

            <div class="rounded-xl border border-sr-line p-4 space-y-3">
              <div class="flex items-center justify-between gap-3">
                <div>
                  <div class="text-sm font-semibold">Profile assignment</div>
                  <p class="text-xs text-sr-muted">
                    Target agents with SRQL starting at <span class="font-mono">in:agents</span>. Add filters to
                    narrow the set (for example <span class="font-mono">in:agents hostname:dusk*</span>).
                    Device queries are not valid here.
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
                <p class="text-xs text-sr-muted">No profiles for this add-on package.</p>
              <% else %>
                <ul class="divide-y divide-sr-line">
                  <%= for profile <- @addon_profiles do %>
                    <% report = profile_reconcile_report(profile) %>
                    <li class="flex items-center justify-between gap-3 py-2">
                      <div class="min-w-0">
                        <div class="truncate text-xs font-semibold">{profile.name}</div>
                        <div class="truncate font-mono text-[11px] text-sr-muted">
                          {profile.target_query}
                        </div>
                        <div class="mt-1 flex flex-wrap gap-1">
                          <.ui_badge size="xs" variant="ghost">
                            priority {profile.priority}
                          </.ui_badge>
                          <.ui_badge
                            size="xs"
                            variant={if(profile.enabled, do: "success", else: "ghost")}
                          >
                            {if profile.enabled, do: "enabled", else: "disabled"}
                          </.ui_badge>
                          <.ui_badge
                            :if={profile.last_reconciled_at}
                            size="xs"
                            variant="ghost"
                          >
                            reconciled
                          </.ui_badge>
                          <.ui_badge size="xs" variant="info">
                            {update_policy_label(profile.update_policy)}
                          </.ui_badge>
                          <.ui_badge
                            :if={report.status}
                            size="xs"
                            variant={profile_report_status_variant(report.status)}
                          >
                            {profile_report_status_label(report.status)}
                          </.ui_badge>
                          <.ui_badge
                            :for={chip <- profile_report_chips(report)}
                            size="xs"
                            variant="ghost"
                          >
                            {chip}
                          </.ui_badge>
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
                            class="rounded bg-sr-subtle px-1.5 py-0.5 text-[10px] text-sr-muted"
                          >
                            {chip}
                          </span>
                        </div>
                      </div>
                      <div class="flex items-center gap-2">
                        <.ui_button
                          :if={@can_assign_addons}
                          type="button"
                          phx-click="reconcile_profile"
                          phx-value-id={profile.id}
                          disabled={not addon_package_assignable?(@selected_package)}
                          size="xs"
                          variant="ghost"
                        >
                          Reconcile
                        </.ui_button>
                        <.ui_button
                          :if={@can_assign_addons}
                          type="button"
                          phx-click="set_profile_update_policy"
                          phx-value-id={profile.id}
                          phx-value-policy={next_update_policy(profile.update_policy)}
                          size="xs"
                          variant="ghost"
                        >
                          {update_policy_action_label(profile.update_policy)}
                        </.ui_button>
                        <.ui_button
                          :if={@can_assign_addons}
                          type="button"
                          phx-click="delete_profile"
                          phx-value-id={profile.id}
                          data-confirm="Remove this add-on profile and its agent assignments?"
                          size="xs"
                          variant="ghost"
                        >
                          Remove
                        </.ui_button>
                      </div>
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
                  <label class="flex items-center justify-between gap-2">
                    <span class="text-sm font-medium text-sr-ink">Profile Name</span>
                  </label>
                  <input
                    name="profile[name]"
                    class={ui_field_class(class: "w-full")}
                    value={@profile_form["name"]}
                  />
                </div>
                <div>
                  <label class="flex items-center justify-between gap-2">
                    <span class="text-sm font-medium text-sr-ink">SRQL Target Query</span>
                  </label>
                  <input
                    name="profile[target_query]"
                    class={ui_field_class(mono: true, class: "w-full text-xs")}
                    value={@profile_form["target_query"]}
                    placeholder="in:agents"
                  />
                  <p class="mt-1 text-xs text-sr-muted">
                    Must start from <span class="font-mono">in:agents</span>.
                    <span class="font-mono">in:devices</span>
                    cannot assign add-ons.
                  </p>
                </div>
                <.update_policy_fields prefix="profile" form={@profile_form} />
                <div
                  :if={
                    config_schema_present?(flat_config_form_schema(@selected_package.config_schema))
                  }
                  id="addon-profile-configuration"
                  class="space-y-3 rounded-lg border border-sr-line/70 bg-sr-surface/60 p-3"
                >
                  <div class="text-xs font-semibold text-sr-muted">Configuration</div>
                  <.plugin_config_fields
                    schema={flat_config_form_schema(@selected_package.config_schema)}
                    params={config_params_map(@profile_form)}
                    base_name="profile[params]"
                  />
                </div>
                <details
                  id="addon-advanced-profile-options"
                  phx-hook="DetailsState"
                  class="rounded border border-sr-line bg-sr-subtle/30"
                >
                  <summary class="cursor-pointer px-3 py-2 text-xs font-semibold uppercase text-sr-muted">
                    Advanced Profile Options
                  </summary>
                  <div class="space-y-3 border-t border-sr-line p-3">
                    <div class="grid gap-3 md:grid-cols-2">
                      <div>
                        <label class="flex items-center justify-between gap-2">
                          <span class="text-sm font-medium text-sr-ink">Priority</span>
                        </label>
                        <input
                          name="profile[priority]"
                          class={ui_field_class(class: "w-full")}
                          value={@profile_form["priority"]}
                        />
                      </div>
                      <div>
                        <label class="flex items-center justify-between gap-2">
                          <span class="text-sm font-medium text-sr-ink">Max Targets</span>
                        </label>
                        <input
                          name="profile[max_targets]"
                          class={ui_field_class(class: "w-full")}
                          value={@profile_form["max_targets"]}
                        />
                      </div>
                    </div>
                    <div>
                      <label class="flex items-center justify-between gap-2">
                        <span class="text-sm font-medium text-sr-ink">Args (one per line)</span>
                      </label>
                      <textarea
                        name="profile[args]"
                        class={
                          ui_field_class(mono: true, class: "w-full min-h-[42px] py-2.5 text-xs")
                        }
                      ><%= @profile_form["args"] %></textarea>
                    </div>
                    <div>
                      <label class="flex items-center justify-between gap-2">
                        <span class="text-sm font-medium text-sr-ink">
                          {if config_schema_present?(@selected_package.config_schema),
                            do: "Raw Params (JSON)",
                            else: "Params (JSON)"}
                        </span>
                      </label>
                      <textarea
                        name={
                          if config_schema_present?(@selected_package.config_schema),
                            do: "profile[params_raw]",
                            else: "profile[params]"
                        }
                        class={
                          ui_field_class(mono: true, class: "w-full min-h-[70px] py-2.5 text-xs")
                        }
                      ><%= assignment_params_raw(@profile_form) %></textarea>
                    </div>
                  </div>
                </details>
                <div class="flex justify-end">
                  <.ui_button
                    type="submit"
                    disabled={
                      not addon_package_assignable?(@selected_package) or not @can_assign_addons
                    }
                    size="sm"
                    variant="primary"
                  >
                    Create Profile
                  </.ui_button>
                </div>
              </form>
            </div>

            <details
              id="advanced-manual-assignment-override"
              phx-hook="DetailsState"
              class="rounded-xl border border-sr-line p-4"
            >
              <summary class="cursor-pointer">
                <div class="inline-flex flex-col gap-1 align-middle">
                  <span class="text-sm font-semibold">Advanced Manual Assignment Override</span>
                  <span class="text-xs text-sr-muted">
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
                    <label class="flex items-center justify-between gap-2">
                      <span class="text-sm font-medium text-sr-ink">Target</span>
                    </label>
                    <select name="assignment[target_mode]" class={ui_field_class(class: "w-full")}>
                      <option value="agent" selected={@assignment_form["target_mode"] == "agent"}>
                        Single agent
                      </option>
                      <option value="cohort" selected={@assignment_form["target_mode"] == "cohort"}>
                        Cohort
                      </option>
                    </select>
                  </div>
                  <div :if={@assignment_form["target_mode"] == "cohort"}>
                    <label class="flex items-center justify-between gap-2">
                      <span class="text-sm font-medium text-sr-ink">Cohort</span>
                    </label>
                    <select name="assignment[cohort]" class={ui_field_class(class: "w-full")}>
                      <%= for {label, value} <- @cohort_options do %>
                        <option value={value} selected={@assignment_form["cohort"] == value}>
                          {label}
                        </option>
                      <% end %>
                    </select>
                  </div>
                  <div :if={@assignment_form["target_mode"] != "cohort"} class="md:col-span-2">
                    <label class="flex items-center justify-between gap-2">
                      <span class="text-sm font-medium text-sr-ink">Agent</span>
                    </label>
                    <select name="assignment[agent_uid]" class={ui_field_class(class: "w-full")}>
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
                  <div :if={@assignment_form["target_mode"] != "cohort"} class="md:col-span-2">
                    <label class="label">
                      <span class="label-text">Direct JetStream edge site (optional)</span>
                    </label>
                    <select name="assignment[edge_site_id]" class="select select-bordered w-full">
                      <option value="" selected={@assignment_form["edge_site_id"] == ""}>
                        Gateway relay / no edge NATS
                      </option>
                      <%= for site <- @edge_sites do %>
                        <option
                          value={site.id}
                          selected={@assignment_form["edge_site_id"] == site.id}
                        >
                          {edge_site_option_label(site)}
                        </option>
                      <% end %>
                    </select>
                    <p class="label">
                      Required only when configuration sets <code>output.backend</code>
                      to <code>jetstream</code>. The selected leaf must be active and connected;
                      mTLS paths remain add-on-owned.
                    </p>
                  </div>
                </div>

                <div :if={
                  @assignment_form["target_mode"] == "cohort" and
                    @assignment_form["cohort"] == "custom"
                }>
                  <label class="flex items-center justify-between gap-2">
                    <span class="text-sm font-medium text-sr-ink">Custom Agent IDs</span>
                  </label>
                  <textarea
                    name="assignment[agent_ids]"
                    class={ui_field_class(mono: true, class: "w-full min-h-[80px] py-2.5 text-xs")}
                    placeholder="agent-1, agent-2 or one per line"
                  ><%= @assignment_form["agent_ids"] %></textarea>
                </div>

                <.update_policy_fields prefix="assignment" form={@assignment_form} />

                <div
                  :if={show_assignment_preview?(@assignment_preview)}
                  id="addon-compatibility-preview"
                  class="rounded-lg border border-sr-line bg-sr-subtle/30 px-4 py-3 text-sm"
                >
                  <div class="flex flex-wrap items-center justify-between gap-3">
                    <div class="font-semibold text-sr-ink">Compatibility Preview</div>
                    <div class="text-xs text-sr-muted">
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
                    <div class="text-[11px] uppercase tracking-wider text-sr-muted">
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
                        <.ui_badge size="xs" variant="error">
                          {agent.agent_id} ({agent.platform_label})
                        </.ui_badge>
                      <% end %>
                    </div>
                  </div>
                </div>

                <%= if config_schema_present?(@selected_package.config_schema) do %>
                  <div class="rounded-lg border border-sr-line/70 bg-sr-surface/60 p-3 space-y-3">
                    <div class="text-xs font-semibold text-sr-muted">Configuration</div>
                    <.plugin_config_fields
                      schema={@selected_package.config_schema}
                      params={config_params_map(@assignment_form)}
                      base_name="assignment[params]"
                    />
                  </div>

                  <details
                    id="addon-assignment-raw-params"
                    phx-hook="DetailsState"
                    class="rounded-lg border border-sr-line/70 bg-sr-surface/60 p-3"
                  >
                    <summary class="cursor-pointer text-xs font-semibold text-sr-muted">
                      Raw Params (JSON)
                    </summary>
                    <div class="mt-3">
                      <textarea
                        name="assignment[params_raw]"
                        class={
                          ui_field_class(mono: true, class: "w-full min-h-[80px] py-2.5 text-xs")
                        }
                      ><%= assignment_params_raw(@assignment_form) %></textarea>
                    </div>
                  </details>
                <% else %>
                  <div>
                    <label class="flex items-center justify-between gap-2">
                      <span class="text-sm font-medium text-sr-ink">Params (JSON)</span>
                    </label>
                    <textarea
                      name="assignment[params]"
                      class={ui_field_class(mono: true, class: "w-full min-h-[80px] py-2.5 text-xs")}
                    ><%= assignment_params_raw(@assignment_form) %></textarea>
                  </div>
                <% end %>

                <div>
                  <label class="flex items-center justify-between gap-2">
                    <span class="text-sm font-medium text-sr-ink">Args (one per line)</span>
                  </label>
                  <textarea
                    name="assignment[args]"
                    class={ui_field_class(mono: true, class: "w-full min-h-[60px] py-2.5 text-xs")}
                  ><%= @assignment_form["args"] %></textarea>
                </div>

                <div class="flex justify-end">
                  <.ui_button
                    type="submit"
                    disabled={
                      not addon_package_assignable?(@selected_package) or not @can_assign_addons or
                        assignment_submit_disabled?(@assignment_form, @assignment_preview)
                    }
                    size="sm"
                    variant="primary"
                  >
                    Assign
                  </.ui_button>
                </div>
              </form>
              <%= if @selected_package.status != :approved do %>
                <p class="text-xs text-sr-muted">
                  This add-on must be approved before it can be assigned.
                </p>
              <% end %>
              <p :if={addon_blob_missing?(@selected_package)} class="text-xs text-error">
                This add-on cannot be assigned until its missing artifact is re-imported.
              </p>
            </details>
          </.ui_modal>
        <% end %>
      </Shell.settings_chrome>
    </Layouts.app>
    """
  end

  attr :prefix, :string, required: true
  attr :form, :map, required: true

  defp update_policy_fields(assigns) do
    ~H"""
    <div class="rounded-lg border border-info/20 bg-info/5 p-3 space-y-3">
      <div>
        <label class="flex items-center justify-between gap-2">
          <span class="text-sm font-medium text-sr-ink">Updates</span>
        </label>
        <select name={"#{@prefix}[update_policy]"} class={ui_field_class(class: "w-full")}>
          <option
            value="track_latest_approved"
            selected={@form["update_policy"] == "track_latest_approved"}
          >
            Automatically track latest approved (recommended)
          </option>
          <option value="manual_pin" selected={@form["update_policy"] == "manual_pin"}>
            Pin this version
          </option>
        </select>
        <p class="mt-1 text-xs text-sr-muted">
          Tracked packages roll out automatically through a canary and health-gated batches.
          Approval never widens the capability grant.
        </p>
      </div>

      <div :if={@form["update_policy"] == "track_latest_approved"} class="grid gap-3 sm:grid-cols-3">
        <.rollout_number prefix={@prefix} form={@form} field="canary_size" label="Canary" min="1" />
        <.rollout_number prefix={@prefix} form={@form} field="batch_size" label="Batch size" min="1" />
        <.rollout_number
          prefix={@prefix}
          form={@form}
          field="max_parallel"
          label="Max parallel"
          min="1"
        />
        <.rollout_number
          prefix={@prefix}
          form={@form}
          field="soak_seconds"
          label="Soak (seconds)"
          min="0"
        />
        <.rollout_number
          prefix={@prefix}
          form={@form}
          field="health_timeout_seconds"
          label="Health timeout (seconds)"
          min="30"
        />
        <.rollout_number
          prefix={@prefix}
          form={@form}
          field="tolerated_failures"
          label="Failure tolerance"
          min="0"
        />
      </div>
    </div>
    """
  end

  attr :prefix, :string, required: true
  attr :form, :map, required: true
  attr :field, :string, required: true
  attr :label, :string, required: true
  attr :min, :string, required: true

  defp rollout_number(assigns) do
    ~H"""
    <div>
      <label class="flex items-center justify-between gap-2">
        <span class="text-xs font-medium text-sr-ink">{@label}</span>
      </label>
      <input
        type="number"
        min={@min}
        name={"#{@prefix}[#{@field}]"}
        value={@form[@field]}
        class={ui_field_class(size: "sm", class: "w-full")}
      />
    </div>
    """
  end

  defp import_catalog_addon(socket, addon, opts) do
    if RetiredNativeAddons.retired?(addon.addon_id) do
      {:noreply, put_flash(socket, :error, "This add-on is retired: #{RetiredNativeAddons.reason(addon.addon_id)}")}
    else
      case AddonPackages.import_first_party_addon(
             addon,
             Keyword.merge([scope: socket.assigns.current_scope], opts)
           ) do
        {:ok, package, :imported} ->
          {:noreply,
           socket
           |> put_flash(
             :info,
             if(opts[:replace],
               do:
                 "Replaced #{package.name} #{package.version} with this release. Approve it again before agents use the new build.",
               else: "Imported first-party add-on #{package.name} #{package.version}"
             )
           )
           |> assign(:packages, list_addon_packages(socket.assigns.current_scope))
           |> load_first_party_catalog()}

        {:ok, package, :skipped} ->
          {:noreply,
           socket
           |> put_flash(:info, "First-party add-on #{package.name} #{package.version} is already current")
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

  defp list_addon_packages(scope), do: AddonPackages.list(%{limit: 500}, scope: scope)

  defp load_first_party_catalog(socket) do
    case NativeAddonImporter.list_recent_addons_with_summary(
           %{"repo_url" => socket.assigns.first_party_repo_url},
           first_party_sync_limit()
         ) do
      {:ok, summary} ->
        apply_first_party_catalog_summary(socket, summary)

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
        |> assign(
          :first_party_catalog_status,
          first_party_catalog_status([], socket.assigns.packages, socket.assigns[:first_party_catalog_synced_at])
        )
    end
  end

  defp apply_first_party_catalog_summary(socket, summary) when is_map(summary) do
    requested_release_tag =
      if socket.assigns[:first_party_release_selected?] do
        socket.assigns[:first_party_release_tag]
      end

    socket
    |> assign(:first_party_catalog_error, nil)
    |> assign(:first_party_catalog_synced_at, DateTime.utc_now())
    |> assign_first_party_catalog_view(Map.get(summary, :addons, []), requested_release_tag)
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
    |> assign(
      :first_party_catalog_status,
      first_party_catalog_status(addons, packages, socket.assigns[:first_party_catalog_synced_at])
    )
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

  defp first_party_catalog_status(addons, packages, synced_at) do
    visible_addons = visible_first_party_addons(addons)
    visible_packages = visible_addon_packages(packages)
    import_ready = Enum.count(visible_addons, &Map.get(&1, :import_ready?))
    releases = visible_addons |> combined_release_options(visible_packages) |> length()

    summary =
      "Loaded #{length(visible_addons)} first-party add-on entry(s), #{import_ready} import-ready, #{length(visible_packages)} imported package(s), from #{releases} release(s)."

    %{synced_at: normalize_catalog_sync_time(synced_at), summary: summary}
  end

  defp catalog_sync_flash(socket, summary) do
    release = socket.assigns.first_party_release_tag
    rows = combined_catalog_rows(socket.assigns.first_party_catalog, socket.assigns.packages, release)
    state = catalog_import_state(rows)
    scanned = Map.get(summary, :scanned_releases, 0)
    indexed = Map.get(summary, :indexed_releases, 0)

    release_part =
      cond do
        is_binary(release) and release != "" and state.importable > 0 ->
          "Selected #{release}: #{state.total} add-ons, #{state.importable} not imported."

        is_binary(release) and release != "" ->
          "Selected #{release}: #{state.total} add-ons, none waiting to import."

        true ->
          "No official release is selected."
      end

    "Catalog refreshed from the registry (#{scanned} release(s) scanned, #{indexed} with add-on indexes). #{release_part} Nothing was imported."
  end

  defp normalize_catalog_sync_time(%DateTime{} = value), do: value
  defp normalize_catalog_sync_time(%NaiveDateTime{} = value), do: DateTime.from_naive!(value, "Etc/UTC")
  defp normalize_catalog_sync_time(_), do: nil

  defp first_party_repo_url do
    config = Application.get_env(:serviceradar_web_ng, :native_addon_import, [])
    Keyword.get(config, :repo_url, "https://github.com/carverauto/serviceradar")
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
    package_by_version = Map.new(packages, &{{&1.addon_id, &1.version}, &1})

    first_party_rows =
      Enum.map(first_party_addons, fn addon ->
        package = Map.get(package_by_key, addon_catalog_key(addon))

        version_package =
          if is_nil(package), do: Map.get(package_by_version, {addon.addon_id, addon.version})

        %{
          addon_id: addon.addon_id,
          name: addon.name,
          version: addon.version,
          release_tag: addon.release_tag,
          platforms: catalog_platforms(addon),
          package: package,
          version_package: version_package,
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
          version_package: nil,
          import_ready: false
        }
      end)

    Enum.sort_by(first_party_rows ++ package_rows, &catalog_row_sort_key/1)
  end

  # Release tags and OCI manifest envelopes are discovery provenance, not package
  # identity. The same signed bundle may be listed by multiple ServiceRadar
  # releases under different OCI refs/digests. Match the bundle digest exactly as
  # NativeAddonImporter does before falling back to the legacy OCI identity.
  defp addon_catalog_key(addon) do
    catalog_identity(
      addon.addon_id,
      addon.version,
      Map.get(addon, :bundle_digest),
      addon.oci_ref,
      addon.oci_digest
    )
  end

  defp package_catalog_key(package) do
    catalog_identity(
      package.addon_id,
      package.version,
      package_bundle_digest(package),
      package.source_oci_ref,
      package.source_oci_digest
    )
  end

  defp catalog_identity(addon_id, version, bundle_digest, oci_ref, oci_digest) do
    base = {normalize_catalog_value(addon_id), normalize_catalog_value(version)}

    case normalize_catalog_digest(bundle_digest) do
      digest when is_binary(digest) -> {base, :bundle, digest}
      nil -> {base, :oci, normalize_catalog_value(oci_ref), normalize_catalog_digest(oci_digest)}
    end
  end

  defp package_bundle_digest(%{source_metadata: metadata}) when is_map(metadata) do
    Map.get(metadata, "bundle_digest", Map.get(metadata, :bundle_digest))
  end

  defp package_bundle_digest(_package), do: nil

  defp normalize_catalog_digest(value) do
    case normalize_catalog_value(value) do
      value when is_binary(value) -> String.downcase(value)
      nil -> nil
    end
  end

  defp normalize_catalog_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp normalize_catalog_value(value) when is_atom(value), do: value |> Atom.to_string() |> normalize_catalog_value()

  defp normalize_catalog_value(_value), do: nil

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
        row.import_ready and is_nil(row.version_package) and
          (is_nil(row.package) or addon_blob_missing?(row.package))
      end)

    replaceable = Enum.count(catalog_rows, &replaceable_catalog_row?/1)
    imported = Enum.count(catalog_rows, &(not is_nil(&1.package)))

    %{
      importable: importable,
      replaceable: replaceable,
      imported: imported,
      total: length(catalog_rows)
    }
  end

  defp replaceable_catalog_row?(row) do
    row.import_ready and is_nil(row.package) and not is_nil(row.version_package)
  end

  defp import_all_label(true, _state), do: "Importing…"

  defp import_all_label(false, %{importable: 0, imported: imported}) when imported > 0 do
    "All #{imported} imported"
  end

  defp import_all_label(false, %{importable: 0}), do: "Import All"
  defp import_all_label(false, %{importable: importable}), do: "Import All (#{importable})"

  defp import_summary_message(summary, release_label) do
    skipped = Map.get(summary, :skipped, 0)
    failed = List.wrap(summary.failed)

    parts =
      ["#{summary.imported} imported", "#{skipped} skipped (already imported)"] ++
        if failed == [], do: [], else: ["#{length(failed)} failed"]

    message = "Import finished for #{release_label}: #{Enum.join(parts, ", ")}."

    case failed_import_details(failed) do
      nil -> message
      details -> "#{message} #{details}"
    end
  end

  defp failed_import_details([]), do: nil

  defp failed_import_details(failed) do
    failed
    |> Enum.map(fn item ->
      addon = Map.get(item, :addon_id) || Map.get(item, "addon_id") || "unknown"
      "#{addon}: #{format_error(Map.get(item, :error) || Map.get(item, "error"))}"
    end)
    |> Enum.take(5)
    |> Enum.join("; ")
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

  defp catalog_row_status(%{package: nil, version_package: %{}}), do: "older build imported"

  defp catalog_row_status(%{package: nil}), do: "not imported"

  defp catalog_row_status(%{package: package}) do
    if addon_blob_missing?(package), do: "blob missing", else: package.status
  end

  defp catalog_row_status_variant(%{package: nil, version_package: %{}}), do: "warning"

  defp catalog_row_status_variant(%{package: nil}), do: "ghost"

  defp catalog_row_status_variant(%{package: package}) do
    if addon_blob_missing?(package),
      do: "error",
      else: package_status_badge_variant(package.status)
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

  defp list_edge_sites(scope) do
    EdgeSite
    |> Ash.Query.for_read(:read)
    |> Ash.Query.sort(name: :asc)
    |> Ash.read!(scope: scope)
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

  defp edge_site_status_label(%EdgeSite{status: status}), do: to_string(status)
  defp edge_site_status_label(_site), do: "unknown"

  defp edge_site_option_label(site) do
    "#{site.name} (#{site.slug}) · #{edge_site_status_label(site)}"
  end

  defp maybe_put_edge_site_id(attrs, edge_site_id) do
    case String.trim(edge_site_id || "") do
      "" -> Map.put(attrs, :edge_site_id, nil)
      edge_site_id -> Map.put(attrs, :edge_site_id, edge_site_id)
    end
  end

  defp default_assignment_form(package \\ nil) do
    %{
      "target_mode" => "agent",
      "cohort" => "connected",
      "agent_uid" => "",
      "agent_ids" => "",
      "edge_site_id" => "",
      "params" => "",
      "params_raw" => "",
      "args" => "",
      "update_policy" => default_update_policy(package),
      "canary_size" => "1",
      "batch_size" => "10",
      "max_parallel" => "10",
      "soak_seconds" => "300",
      "health_timeout_seconds" => "900",
      "tolerated_failures" => "0"
    }
  end

  defp default_profile_form(package \\ nil)

  defp default_profile_form(nil) do
    %{
      "name" => "",
      "target_query" => "in:agents",
      "priority" => "100",
      "max_targets" => "10000",
      "params" => "{}",
      "args" => "",
      "update_policy" => "manual_pin",
      "canary_size" => "1",
      "batch_size" => "10",
      "max_parallel" => "10",
      "soak_seconds" => "300",
      "health_timeout_seconds" => "900",
      "tolerated_failures" => "0"
    }
  end

  defp default_profile_form(package) do
    base = default_profile_form(nil)

    params =
      if config_schema_present?(package.config_schema) do
        default_profile_config_params(package)
      else
        base["params"]
      end

    %{
      base
      | "name" => "#{package.name} profile",
        "params" => params,
        "update_policy" => default_update_policy(package)
    }
  end

  defp default_profile_config_params(package) do
    schema = package.config_schema
    defaults = ConfigSchema.normalize_params(schema, %{})
    properties = Map.get(schema, "properties") || Map.get(schema, :properties) || %{}
    enabled = Map.get(properties, "enabled") || Map.get(properties, :enabled) || %{}

    # A netprobe profile is the operator's opt-in to host visibility and immediately
    # materializes enabled assignments. Keep its runtime master switch aligned with that
    # lifecycle default instead of silently persisting the schema-level false default.
    if package.addon_id == "netprobe" and
         (Map.get(enabled, "type") == "boolean" or Map.get(enabled, :type) == "boolean") do
      Map.put(defaults, "enabled", true)
    else
      defaults
    end
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

  defp create_assignments(agent_uids, package, params, args, edge_site_id, policy_attrs, scope) do
    Enum.reduce_while(agent_uids, {:ok, 0}, fn agent_uid, {:ok, count} ->
      attrs =
        policy_attrs
        |> Map.merge(%{
          agent_uid: agent_uid,
          addon_package_id: package.id,
          params: params,
          args: args
        })
        |> maybe_put_edge_site_id(edge_site_id)

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

  defp update_policy_label(:track_latest_approved), do: "automatic updates"
  defp update_policy_label("track_latest_approved"), do: "automatic updates"
  defp update_policy_label(_), do: "version pinned"

  defp next_update_policy(:track_latest_approved), do: "manual_pin"
  defp next_update_policy("track_latest_approved"), do: "manual_pin"
  defp next_update_policy(_), do: "track_latest_approved"

  defp update_policy_action_label(:track_latest_approved), do: "Pin"
  defp update_policy_action_label("track_latest_approved"), do: "Pin"
  defp update_policy_action_label(_), do: "Enable auto-update"

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

  defp parse_profile_params(form, config_schema) do
    if config_schema_present?(config_schema) do
      structured = submitted_flat_config_params(form, config_schema)

      raw = Map.get(form, "params_raw")

      with {:ok, raw_params} <- parse_optional_json_object(raw) do
        {:ok, Map.merge(raw_params, structured)}
      end
    else
      parse_params(form, config_schema)
    end
  end

  defp parse_optional_json_object(raw) when is_binary(raw) do
    if String.trim(raw) == "", do: {:ok, %{}}, else: parse_json_object(raw)
  end

  defp parse_optional_json_object(_raw), do: {:ok, %{}}

  defp submitted_flat_config_params(form, config_schema) do
    allowed_names =
      config_schema
      |> flat_config_form_schema()
      |> Map.get("properties", %{})
      |> Map.keys()
      |> MapSet.new(&to_string/1)

    case Map.get(form, "params") do
      %{} = params ->
        Enum.reduce(params, %{}, fn {name, value}, submitted ->
          name = to_string(name)

          if MapSet.member?(allowed_names, name) do
            Map.put(submitted, name, value)
          else
            submitted
          end
        end)

      _ ->
        %{}
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
       enabled: true,
       update_policy: update_policy(Map.get(form, "update_policy")),
       explicit_version_pin: Map.get(form, "update_policy") == "manual_pin",
       rollout_policy: rollout_policy_attrs(form)
     }}
  end

  defp update_policy_attrs(form) do
    policy = update_policy(Map.get(form, "update_policy"))

    %{
      update_policy: policy,
      explicit_version_pin: policy == :manual_pin,
      rollout_policy: rollout_policy_attrs(form)
    }
  end

  defp update_policy_only_attrs(value) do
    policy = update_policy(value)
    %{update_policy: policy, explicit_version_pin: policy == :manual_pin}
  end

  defp update_policy("track_latest_approved"), do: :track_latest_approved
  defp update_policy(_), do: :manual_pin

  defp rollout_policy_attrs(form) do
    %{
      "canary_size" => parse_rollout_integer(form, "canary_size", 1),
      "batch_size" => parse_rollout_integer(form, "batch_size", 10),
      "max_parallel" => parse_rollout_integer(form, "max_parallel", 10),
      "soak_seconds" => parse_rollout_integer(form, "soak_seconds", 300),
      "health_timeout_seconds" => parse_rollout_integer(form, "health_timeout_seconds", 900),
      "tolerated_failures" => parse_rollout_integer(form, "tolerated_failures", 0)
    }
  end

  defp parse_rollout_integer(form, key, default) do
    case Integer.parse(to_string(Map.get(form, key, default))) do
      {value, ""} -> value
      _ -> default
    end
  end

  defp default_update_policy(%{
         source_type: :first_party,
         status: :approved,
         verification_status: "verified",
         verification_error: nil
       }), do: "track_latest_approved"

  defp default_update_policy(_), do: "manual_pin"

  defp profile_target_query(value) when is_binary(value) do
    query = ServiceRadar.SRQLQuery.ensure_target(value, :agents)

    case ServiceRadar.SRQLAst.entity(query, "agents") do
      "agents" -> {:ok, query}
      entity -> {:error, {:invalid_target_entity, entity}}
    end
  end

  defp profile_target_query(nil), do: {:ok, "in:agents"}
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

  defp profile_report_status_variant("failed"), do: "error"
  defp profile_report_status_variant("succeeded"), do: "success"
  defp profile_report_status_variant(_status), do: "ghost"

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

  defp config_params_map(form) do
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

  # The shared config component handles flat scalar fields and string lists. Complex
  # object/array fields stay in the raw JSON editor so their structure is preserved.
  defp flat_config_form_schema(schema) when is_map(schema) do
    properties = Map.get(schema, "properties") || Map.get(schema, :properties) || %{}

    flat_properties =
      Map.filter(properties, fn {_name, property} -> flat_config_property?(property) end)

    schema
    |> Map.delete(:properties)
    |> Map.put("properties", flat_properties)
  end

  defp flat_config_form_schema(_schema), do: %{}

  defp flat_config_property?(property) when is_map(property) do
    type = Map.get(property, "type") || Map.get(property, :type)
    enum = Map.get(property, "enum") || Map.get(property, :enum)
    items = Map.get(property, "items") || Map.get(property, :items) || %{}
    item_type = Map.get(items, "type") || Map.get(items, :type)

    type in ["boolean", "string", "integer", "number"] or
      (type == "array" and item_type == "string") or (is_list(enum) and enum != [])
  end

  defp flat_config_property?(_property), do: false

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

  defp verification_status_variant(package) do
    if addon_blob_missing?(package), do: "error", else: "ghost"
  end

  defp package_status_badge_variant(:approved), do: "success"
  defp package_status_badge_variant("approved"), do: "success"
  defp package_status_badge_variant(:staged), do: "warning"
  defp package_status_badge_variant("staged"), do: "warning"

  defp package_status_badge_variant(status) when status in [:denied, :revoked, "denied", "revoked"], do: "error"

  defp package_status_badge_variant(_status), do: "ghost"

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

  defp format_error(%Invalid{errors: errors} = error) when is_list(errors) and errors != [] do
    messages =
      errors
      |> Enum.map(&ash_error_message/1)
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.uniq()

    case messages do
      [] -> error |> Exception.message() |> strip_ash_breadcrumbs() |> truncate_error()
      _ -> messages |> Enum.join("; ") |> truncate_error()
    end
  end

  defp format_error(%Invalid{} = error) do
    error |> Exception.message() |> strip_ash_breadcrumbs() |> truncate_error()
  end

  defp format_error({:native_addon_version_source_conflict, details}) when is_map(details) do
    addon = Map.get(details, :addon_id) || "addon"
    version = Map.get(details, :version) || "unknown"

    truncate_error(
      "#{addon} #{version} is already imported from an earlier release that " <>
        "rebuilt the same version. Use Replace on that catalog row to take this " <>
        "release's build; Import All will not overwrite it."
    )
  end

  defp format_error(error) do
    error
    |> inspect(limit: 8, printable_limit: 400)
    |> truncate_error()
  end

  defp ash_error_message(%{message: message}) when is_binary(message), do: String.trim(message)
  defp ash_error_message(error), do: error |> Exception.message() |> strip_ash_breadcrumbs()

  defp strip_ash_breadcrumbs(message) when is_binary(message) do
    message
    |> String.replace(~r/Bread Crumbs:.*?(?=\n\n|\z)/s, "")
    |> String.replace(~r/\n?Invalid value provided for \w+:\s*/i, "")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
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
