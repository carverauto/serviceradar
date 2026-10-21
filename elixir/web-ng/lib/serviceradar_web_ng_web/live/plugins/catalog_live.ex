defmodule ServiceRadarWebNGWeb.Plugins.CatalogLive do
  @moduledoc """
  Catalog view of the Wasm plugin pages: plugin repositories, their releases,
  import (one plugin, all of a release, or a staged upload or GitHub package),
  the egress probe, the verification policy and, until it moves to the agent
  page, the per-agent capacity snapshot.

  Nothing is read in the disconnected render. Database reads run once the
  socket connects; repository release indexes are fetched with `start_async/3`,
  never in the LiveView process.
  """

  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.Plugins.Components

  alias Ash.Error.Invalid
  alias ServiceRadar.Plugins.Manifest
  alias ServiceRadar.Plugins.PluginRepository
  alias ServiceRadar.Plugins.RepositoryCredentials
  alias ServiceRadarWebNG.Plugins.Assignments
  alias ServiceRadarWebNG.Plugins.EgressConnectivityCheck
  alias ServiceRadarWebNG.Plugins.FirstPartyImporter
  alias ServiceRadarWebNG.Plugins.FirstPartyReleaseClient
  alias ServiceRadarWebNG.Plugins.ImportFailureMessages
  alias ServiceRadarWebNG.Plugins.Packages
  alias ServiceRadarWebNG.Plugins.Repositories
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.Settings.Shell

  @first_party_catalog_page_size 10
  @official_release_tag_regex ~r/^v(?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+)$/

  # Sentinel release option meaning "every release this repository publishes".
  # A repository that tags per plugin (one release per plugin, the pattern
  # third-party repositories are documented to use) has no single release
  # holding its whole catalog, so selecting one tag would show one plugin and
  # hide the rest.
  @all_releases_tag FirstPartyReleaseClient.admin_all_releases_sentinel()
  # Deliberately not implied by plugins.stage: staging imports from a source the
  # platform already trusts, while this decides which sources are trusted.
  @repository_manage_permission "plugins.repositories.manage"

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if RBAC.can?(scope, "plugins.view") do
      {:ok,
       socket
       |> assign(:can_stage_plugins, RBAC.can?(scope, "plugins.stage"))
       |> assign(:can_manage_repositories, RBAC.can?(scope, @repository_manage_permission))
       |> assign(:page_title, "Plugin catalog")
       |> assign(:current_path, nil)
       |> assign(:plugins_base_path, "/admin/plugins")
       |> assign(:loaded?, false)
       |> assign(:catalog_packages, [])
       |> assign(:first_party_catalog, [])
       |> assign(:first_party_catalog_all, [])
       |> assign(:first_party_catalog_page, 1)
       |> assign(:first_party_catalog_page_size, @first_party_catalog_page_size)
       |> assign(:first_party_catalog_error, nil)
       |> assign(:first_party_catalog_status, nil)
       |> assign(:first_party_catalog_loading?, false)
       |> assign(:first_party_release_options, [])
       |> assign(:first_party_release_tag, nil)
       |> assign(:first_party_release_selected?, false)
       |> assign(:plugin_repositories, [])
       |> assign(:enabled_plugin_repositories, [])
       |> assign(:selected_repository, nil)
       |> assign(:first_party_repo_url, nil)
       |> assign(:show_repository_modal, false)
       |> assign(:repository_form, default_repository_form())
       |> assign(:repository_errors, [])
       |> assign(:editing_repository_id, nil)
       |> assign(:import_running?, false)
       |> assign(:egress_check_running?, false)
       |> assign(:egress_check, nil)
       |> assign(:show_create_modal, false)
       |> assign(:create_form, default_create_form())
       |> assign(:create_errors, [])
       |> assign(:capacity_rows, [])
       |> assign(:capacity_totals, empty_capacity_totals())
       |> assign(:verification_policy, plugin_verification_policy())}
    else
      {:ok,
       socket
       |> put_flash(:error, "You don't have permission to access Plugins.")
       |> redirect(to: ~p"/dashboard")}
    end
  end

  @impl true
  def handle_params(_params, url, socket) do
    socket =
      socket
      |> assign(:current_path, current_path_from_url(url))
      |> assign(:plugins_base_path, plugins_base_path_from_url(url))
      |> assign(:show_create_modal, socket.assigns.live_action == :new)
      |> assign(:create_errors, [])

    if connected?(socket) and not socket.assigns.loaded? do
      {:noreply, load_page(socket)}
    else
      {:noreply, socket}
    end
  end

  defp load_page(socket) do
    scope = socket.assigns.current_scope
    socket = assign_catalog_packages(socket, scope)
    release_options = combined_release_options([], socket.assigns.catalog_packages)

    socket
    |> assign(:loaded?, true)
    |> assign(:first_party_release_options, release_options)
    |> assign(:first_party_release_tag, selected_first_party_release(release_options, nil))
    |> assign_plugin_repositories(scope)
    |> assign_capacity(scope)
    |> load_first_party_catalog()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <Shell.settings_chrome
        current_path={@current_path || @plugins_base_path}
        current_scope={@current_scope}
        active_view={@settings_active_view}
        active_category={@settings_active_category}
        breadcrumbs={@settings_breadcrumbs}
        nav_tree={@settings_nav_tree}
        palette={@settings_palette}
        stats={@settings_stats}
      >
        <.plugins_nav
          active={:catalog}
          base_path={@plugins_base_path}
          can_stage_plugins={@can_stage_plugins}
        >
          <:actions>
            <.ui_button variant="ghost" size="sm" phx-click="refresh">
              <.icon name="hero-arrow-path" class="size-4" /> Refresh
            </.ui_button>
          </:actions>
        </.plugins_nav>

        <% catalog_rows =
          combined_catalog_rows(
            @first_party_catalog,
            repository_packages(@catalog_packages, @selected_repository),
            @first_party_release_tag
          ) %>
        <% import_state = catalog_import_state(catalog_rows) %>

        <.ui_panel id="plugin-catalog">
          <:header>
            <div>
              <div class="text-sm font-semibold">Plugin catalog</div>
              <p class="text-xs text-sr-muted">
                <span :if={@selected_repository}>
                  Signed Wasm plugins discovered from {@selected_repository.name} ({@selected_repository.repo_url}), plus imported packages.
                </span>
                <span :if={is_nil(@selected_repository)}>
                  No enabled plugin repository. Imported packages remain available in their own panel.
                </span>
              </p>
            </div>
            <div class="flex flex-wrap items-center justify-end gap-2">
              <form
                id="select-first-party-repository-form"
                phx-change="select_first_party_repository"
                class="flex w-full min-w-0 items-center gap-2 sm:w-auto"
              >
                <label for="plugin-repository-select" class="sr-only">Catalog repository</label>
                <select
                  id="plugin-repository-select"
                  name="repository_id"
                  class={ui_field_class(size: "sm", class: "w-full sm:w-72")}
                >
                  <option
                    :for={repository <- @enabled_plugin_repositories}
                    value={repository.id}
                    selected={@selected_repository && repository.id == @selected_repository.id}
                  >
                    {repository.name}{if repository.builtin, do: " (built-in)", else: ""}
                  </option>
                  <%!--
                    An action, not a value. `close_repository_modal` restores the
                    prior selection so dismissing the modal cannot leave the
                    dropdown claiming a catalog that is not loaded.
                  --%>
                  <option :if={@can_manage_repositories} value="__add_new__">… Add New</option>
                </select>
              </form>
              <div
                :if={@can_manage_repositories and @selected_repository}
                class="flex items-center gap-1"
              >
                <.ui_icon_button
                  :if={not @selected_repository.builtin}
                  size="sm"
                  title="Edit repository"
                  aria-label="Edit repository"
                  phx-click="open_repository_modal"
                  phx-value-id={@selected_repository.id}
                >
                  <.icon name="hero-pencil-square" class="size-4" />
                </.ui_icon_button>
                <.ui_icon_button
                  size="sm"
                  title={
                    if @selected_repository.enabled,
                      do: "Disable repository",
                      else: "Enable repository"
                  }
                  aria-label={
                    if @selected_repository.enabled,
                      do: "Disable repository",
                      else: "Enable repository"
                  }
                  phx-click="toggle_repository"
                  phx-value-id={@selected_repository.id}
                >
                  <.icon
                    name={
                      if @selected_repository.enabled,
                        do: "hero-pause-circle",
                        else: "hero-play-circle"
                    }
                    class="size-4"
                  />
                </.ui_icon_button>
                <%!--
                  The built-in source is seeded and cannot be edited or removed
                  -- only disabled. Hiding the controls matches what the resource
                  enforces, so the UI cannot offer an action that always fails.
                --%>
                <.ui_icon_button
                  :if={not @selected_repository.builtin}
                  size="sm"
                  title="Remove repository"
                  aria-label="Remove repository"
                  phx-click="delete_repository"
                  phx-value-id={@selected_repository.id}
                  data-confirm={"Remove #{@selected_repository.name}? Packages already imported from it are kept."}
                >
                  <.icon name="hero-trash" class="size-4" />
                </.ui_icon_button>
              </div>
              <form
                :if={@first_party_release_options != []}
                id="select-plugin-release-form"
                phx-change="select_first_party_release"
                class="flex items-center gap-2"
              >
                <select name="release_tag" class={ui_field_class(size: "sm")}>
                  <option
                    :for={release_tag <- @first_party_release_options}
                    value={release_tag}
                    selected={release_tag == @first_party_release_tag}
                  >
                    {release_option_label(release_tag)}
                  </option>
                </select>
              </form>
              <.ui_button variant="ghost" size="sm" phx-click="sync_first_party_catalog">
                <.icon name="hero-arrow-path" class="size-4" /> Sync
              </.ui_button>
              <.ui_button
                variant="ghost"
                size="sm"
                disabled={@egress_check_running?}
                phx-click="test_plugin_egress"
                title="Probe every host plugin sync needs through the egress proxy"
              >
                <span :if={@egress_check_running?} class="sr-ui-spinner sr-ui-spinner-xs"></span>
                <.icon :if={not @egress_check_running?} name="hero-signal" class="size-4" />
                Test egress
              </.ui_button>
              <.ui_button
                :if={@can_stage_plugins}
                variant="primary"
                size="sm"
                disabled={@import_running? or import_state.importable == 0}
                phx-click="import_first_party_catalog"
              >
                <span :if={@import_running?} class="sr-ui-spinner sr-ui-spinner-xs"></span>
                <.icon :if={not @import_running?} name="hero-arrow-down-tray" class="size-4" />
                {import_all_label(@import_running?, import_state)}
              </.ui_button>
            </div>
          </:header>

          <div
            :if={@first_party_catalog_loading?}
            id="plugin-catalog-loading"
            class="flex items-center gap-2 rounded-xl border border-sr-line bg-sr-surface p-3 text-xs text-sr-muted"
          >
            <span class="sr-ui-spinner sr-ui-spinner-xs"></span> Loading the plugin catalog…
          </div>

          <%= if @first_party_catalog_error do %>
            <div class="rounded-xl border border-error/30 bg-error/5 p-3 text-xs text-error">
              {@first_party_catalog_error}
            </div>
          <% end %>

          <%= if @first_party_catalog_status do %>
            <div class="rounded-xl border border-warning/30 bg-warning/5 p-3 text-xs text-sr-muted">
              {@first_party_catalog_status}
            </div>
          <% end %>

          <%= if @selected_repository do %>
            <div class="rounded-xl border border-sr-line bg-sr-surface p-3 text-xs text-sr-muted">
              {last_sync_label(@selected_repository)}
            </div>
          <% end %>

          <%= if @egress_check do %>
            <div class={"rounded-xl border p-3 text-xs " <> if(@egress_check.blocked == 0, do: "border-success/30 bg-success/5", else: "border-error/30 bg-error/5")}>
              <div class="font-semibold text-sr-ink mb-2">
                Egress check: {@egress_check.blocked} of {length(@egress_check.results)} hosts blocked
              </div>
              <ul class="space-y-1">
                <li :for={result <- @egress_check.results} class="flex items-center gap-2">
                  <span class={if result.reachable, do: "text-success", else: "text-error"}>
                    <.icon
                      name={if result.reachable, do: "hero-check-circle", else: "hero-x-circle"}
                      class="size-4"
                    />
                  </span>
                  <span class="font-medium text-sr-ink">{result.host}</span>
                  <span class="text-sr-muted">({result.purpose})</span>
                  <span :if={not result.reachable and result.detail} class="text-error">
                    {result.detail}
                  </span>
                </li>
              </ul>
            </div>
          <% end %>

          <%= cond do %>
            <% catalog_rows == [] and is_nil(@first_party_catalog_error) and
                 not @first_party_catalog_loading? -> %>
              <div class="rounded-xl border border-dashed border-sr-line bg-sr-surface p-6 text-center">
                <div class="text-sm font-semibold text-sr-ink">
                  No plugins found for this release
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
                      <th>Plugin</th>
                      <th>Version</th>
                      <th>Release</th>
                      <th>Status</th>
                      <th>Updated</th>
                      <th></th>
                    </tr>
                  </thead>
                  <tbody>
                    <%= for row <- paginated_items(
                          catalog_rows,
                          @first_party_catalog_page,
                          @first_party_catalog_page_size
                        ) do %>
                      <tr class="hover:bg-sr-subtle/30">
                        <td>
                          <div class="font-medium">{row.name}</div>
                          <div class="text-xs text-sr-muted font-mono">{row.plugin_id}</div>
                        </td>
                        <td class="text-xs">{row.version}</td>
                        <td class="text-xs font-mono">{row.release_tag || "-"}</td>
                        <td>
                          <.ui_badge size="sm" variant={catalog_row_status_variant(row)}>
                            {catalog_row_status(row)}
                          </.ui_badge>
                        </td>
                        <td class="text-xs text-sr-muted">
                          <.user_time
                            id={"admin-plugin-catalog-#{dom_id_segment(row.plugin_id)}-#{dom_id_segment(row.version)}-updated-at"}
                            value={catalog_row_updated_at(row)}
                            timezone={@current_scope.user.timezone || "Etc/UTC"}
                            style={:compact}
                          />
                        </td>
                        <td>
                          <div class="flex gap-1">
                            <.ui_button
                              :if={row.package}
                              variant="ghost"
                              size="xs"
                              navigate={plugins_show_path(@plugins_base_path, row.package.id)}
                            >
                              View
                            </.ui_button>
                            <.ui_button
                              :if={is_nil(row.package) and @can_stage_plugins and row.import_ready}
                              variant="ghost"
                              size="xs"
                              phx-click="import_first_party_plugin"
                              phx-value-release-tag={row.release_tag}
                              phx-value-plugin-id={row.plugin_id}
                              phx-value-version={row.version}
                            >
                              Import
                            </.ui_button>
                          </div>
                        </td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
                <.pagination_controls
                  id_prefix="first-party-catalog"
                  event="first_party_catalog_page"
                  page={@first_party_catalog_page}
                  total_items={length(catalog_rows)}
                  page_size={@first_party_catalog_page_size}
                />
              </div>
            <% true -> %>
              <div class="hidden"></div>
          <% end %>
        </.ui_panel>

        <.ui_panel>
          <:header>
            <div>
              <div class="text-sm font-semibold">Capacity Snapshot</div>
              <p class="text-xs text-sr-muted">
                Aggregate resource requests per agent based on current assignments.
              </p>
            </div>
          </:header>

          <%= if @capacity_rows == [] do %>
            <div class="rounded-xl border border-dashed border-sr-line bg-sr-surface p-8 text-center">
              <div class="text-sm font-semibold text-sr-ink">No agents available</div>
              <p class="mt-1 text-xs text-sr-muted">
                Agents will appear here once they have registered with the platform.
              </p>
            </div>
          <% else %>
            <div class="sr-ui-table-shell">
              <table class={ui_table_class(size: "sm")}>
                <thead>
                  <tr class="text-xs uppercase tracking-wide text-sr-muted">
                    <th>Agent</th>
                    <th>Assignments</th>
                    <th>CPU (ms)</th>
                    <th>Memory (MB)</th>
                    <th>Connections</th>
                  </tr>
                </thead>
                <tbody>
                  <%= for row <- @capacity_rows do %>
                    <tr class="hover:bg-sr-subtle/30">
                      <td>
                        <div class="font-medium">{row.name}</div>
                        <div class="text-xs text-sr-muted font-mono">{row.agent_uid}</div>
                      </td>
                      <td class="text-xs">
                        <.link
                          href={agent_plugins_path(row.agent_uid)}
                          class="text-sr-brand hover:underline font-semibold"
                          title={assigned_plugins_title(row)}
                        >
                          {row.assignments}
                        </.link>
                      </td>
                      <td class="text-xs">{row.cpu_ms}</td>
                      <td class="text-xs">{row.memory_mb}</td>
                      <td class="text-xs">{row.connections}</td>
                    </tr>
                  <% end %>
                </tbody>
                <tfoot>
                  <tr class="text-xs font-semibold text-sr-muted">
                    <td>Total</td>
                    <td>{@capacity_totals.assignments}</td>
                    <td>{@capacity_totals.cpu_ms}</td>
                    <td>{@capacity_totals.memory_mb}</td>
                    <td>{@capacity_totals.connections}</td>
                  </tr>
                </tfoot>
              </table>
            </div>
          <% end %>
        </.ui_panel>

        <.ui_panel>
          <:header>
            <div>
              <div class="text-sm font-semibold">Verification Policy</div>
              <p class="text-xs text-sr-muted">
                Controls how GitHub and uploaded packages are treated before execution.
              </p>
            </div>
          </:header>

          <div class="grid grid-cols-1 md:grid-cols-2 gap-4 text-sm">
            <div class="rounded-xl border border-sr-line p-4 space-y-1">
              <div class="text-xs text-sr-muted">GitHub packages</div>
              <div class="font-semibold">
                <%= if @verification_policy.require_gpg_for_github do %>
                  Require GPG verification
                <% else %>
                  Allow without GPG verification
                <% end %>
              </div>
            </div>
            <div class="rounded-xl border border-sr-line p-4 space-y-1">
              <div class="text-xs text-sr-muted">Uploaded packages</div>
              <div class="font-semibold">
                <%= if @verification_policy.allow_unsigned_uploads do %>
                  Allow unsigned uploads
                <% else %>
                  Require signed uploads
                <% end %>
              </div>
            </div>
          </div>
          <p class="mt-3 text-xs text-sr-muted">
            Adjust with environment variables and restart web-ng to apply changes.
          </p>
        </.ui_panel>
      </Shell.settings_chrome>

      <.create_modal
        :if={@show_create_modal}
        create_form={@create_form}
        create_errors={@create_errors}
      />
      <.repository_modal
        show_repository_modal={@show_repository_modal}
        repository_form={@repository_form}
        repository_errors={@repository_errors}
        editing_repository_id={@editing_repository_id}
        plugin_repositories={@plugin_repositories}
      />
    </Layouts.app>
    """
  end

  @impl true
  def handle_info({:plugin_egress_check, result}, socket) do
    {:noreply,
     socket
     |> assign(:egress_check_running?, false)
     |> assign(:egress_check, result)}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    scope = socket.assigns.current_scope

    {:noreply,
     socket
     |> assign_catalog_packages(scope)
     |> assign_capacity(scope)
     |> assign(:verification_policy, plugin_verification_policy())
     |> assign_first_party_catalog_view(
       socket.assigns.first_party_catalog_all,
       socket.assigns.first_party_release_tag
     )}
  end

  def handle_event("create_change", %{"create" => params}, socket) do
    {:noreply, assign(socket, :create_form, params)}
  end

  def handle_event("close_create_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_create_modal, false)
     |> assign(:create_errors, [])}
  end

  def handle_event("sync_first_party_catalog", _params, socket) do
    {:noreply, load_first_party_catalog(socket)}
  end

  # Read-only probes through the same egress client the import uses; results
  # name blocked hosts so an operator can fix the proxy ACL without logs.
  def handle_event("test_plugin_egress", _params, %{assigns: %{egress_check_running?: true}} = socket) do
    {:noreply, socket}
  end

  def handle_event("test_plugin_egress", _params, socket) do
    socket = assign(socket, :egress_check_running?, true)

    if connected?(socket) do
      parent = self()

      # The probes are sequential HEADs with bounded timeouts; run them off the
      # LiveView process so a slow host cannot stall the page.
      Task.start(fn ->
        result = EgressConnectivityCheck.run()
        send(parent, {:plugin_egress_check, result})
      end)

      {:noreply, socket}
    else
      {:noreply, assign(socket, :egress_check_running?, false)}
    end
  end

  def handle_event("select_first_party_release", %{"release_tag" => release_tag}, socket) do
    {:noreply,
     socket
     |> assign(:first_party_release_selected?, true)
     |> assign_first_party_catalog_view(socket.assigns.first_party_catalog_all, release_tag)}
  end

  # Selecting a repository is a read: anyone who can view plugins may switch the
  # catalog they are looking at. Managing repositories is the gated action.
  def handle_event("select_first_party_repository", %{"repository_id" => "__add_new__"}, socket) do
    if socket.assigns.can_manage_repositories do
      {:noreply,
       socket
       |> assign(:show_repository_modal, true)
       |> assign(:editing_repository_id, nil)
       |> assign(:repository_form, default_repository_form())
       |> assign(:repository_errors, [])}
    else
      {:noreply, put_flash(socket, :error, repository_permission_message())}
    end
  end

  def handle_event("select_first_party_repository", %{"repository_id" => repository_id}, socket) do
    {:noreply,
     socket
     |> assign_plugin_repositories(socket.assigns.current_scope, repository_id)
     |> assign(:first_party_release_selected?, false)
     |> assign(:first_party_release_tag, nil)
     |> assign(:first_party_catalog, [])
     |> assign(:first_party_catalog_all, [])
     |> assign(:first_party_catalog_page, 1)
     |> load_first_party_catalog()}
  end

  def handle_event("select_first_party_repository", _params, socket) do
    {:noreply, put_flash(socket, :error, "Catalog repository is required.")}
  end

  def handle_event("open_repository_modal", _params, %{assigns: %{can_manage_repositories: false}} = socket) do
    {:noreply, put_flash(socket, :error, repository_permission_message())}
  end

  def handle_event("open_repository_modal", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.plugin_repositories, &(&1.id == id)) do
      nil ->
        {:noreply, put_flash(socket, :error, "That repository no longer exists.")}

      repository ->
        {:noreply,
         socket
         |> assign(:show_repository_modal, true)
         |> assign(:editing_repository_id, repository.id)
         |> assign(:repository_form, repository_form_from(repository))
         |> assign(:repository_errors, [])}
    end
  end

  def handle_event("close_repository_modal", _params, socket) do
    # Dismissing returns the dropdown to its prior selection: the `… Add New`
    # option is an action, not a selectable value, so leaving it selected would
    # misreport which catalog is being viewed.
    {:noreply,
     socket
     |> assign(:show_repository_modal, false)
     |> assign(:editing_repository_id, nil)
     |> assign(:repository_errors, [])}
  end

  def handle_event("save_repository", _params, %{assigns: %{can_manage_repositories: false}} = socket) do
    {:noreply, put_flash(socket, :error, repository_permission_message())}
  end

  def handle_event("save_repository", %{"repository" => params}, socket) do
    socket = assign(socket, :repository_form, params)
    scope = socket.assigns.current_scope

    case save_repository(socket.assigns.editing_repository_id, params, scope) do
      {:ok, repository} ->
        {:noreply,
         socket
         |> assign(:show_repository_modal, false)
         |> assign(:editing_repository_id, nil)
         |> assign(:repository_form, default_repository_form())
         |> assign(:repository_errors, [])
         |> put_flash(:info, "Saved plugin repository #{repository.name}")
         |> assign_plugin_repositories(scope, repository.id)
         |> assign(:first_party_catalog, [])
         |> assign(:first_party_catalog_all, [])
         |> assign(:first_party_release_tag, nil)
         |> assign(:first_party_release_selected?, false)
         |> load_first_party_catalog()}

      {:error, errors} ->
        # Modal stays open with field-level errors rather than closing and
        # dropping what was typed.
        {:noreply, assign(socket, :repository_errors, errors)}
    end
  end

  def handle_event("toggle_repository", _params, %{assigns: %{can_manage_repositories: false}} = socket) do
    {:noreply, put_flash(socket, :error, repository_permission_message())}
  end

  def handle_event("toggle_repository", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    with repository when not is_nil(repository) <-
           Enum.find(socket.assigns.plugin_repositories, &(&1.id == id)),
         action = if(repository.enabled, do: :disable, else: :enable),
         {:ok, updated} <- update_repository_state(repository, action, scope) do
      {:noreply,
       socket
       |> put_flash(:info, "#{if updated.enabled, do: "Enabled", else: "Disabled"} #{updated.name}")
       |> assign_plugin_repositories(scope)
       |> load_first_party_catalog()}
    else
      nil -> {:noreply, put_flash(socket, :error, "That repository no longer exists.")}
      {:error, reason} -> {:noreply, put_flash(socket, :error, "Could not update repository: #{format_error(reason)}")}
    end
  end

  def handle_event("delete_repository", _params, %{assigns: %{can_manage_repositories: false}} = socket) do
    {:noreply, put_flash(socket, :error, repository_permission_message())}
  end

  def handle_event("delete_repository", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    with repository when not is_nil(repository) <-
           Enum.find(socket.assigns.plugin_repositories, &(&1.id == id)),
         :ok <- destroy_repository(repository, scope) do
      {:noreply,
       socket
       |> put_flash(:info, "Removed plugin repository #{repository.name}")
       |> assign_plugin_repositories(scope)
       |> assign(:first_party_catalog, [])
       |> assign(:first_party_catalog_all, [])
       |> load_first_party_catalog()}
    else
      nil -> {:noreply, put_flash(socket, :error, "That repository no longer exists.")}
      {:error, reason} -> {:noreply, put_flash(socket, :error, "Could not remove repository: #{format_error(reason)}")}
    end
  end

  def handle_event("clear_repository_token", _params, %{assigns: %{can_manage_repositories: false}} = socket) do
    {:noreply, put_flash(socket, :error, repository_permission_message())}
  end

  def handle_event("clear_repository_token", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    with repository when not is_nil(repository) <-
           Enum.find(socket.assigns.plugin_repositories, &(&1.id == id)),
         {:ok, _repository} <- RepositoryCredentials.clear_token(repository, actor: scope_actor(scope)) do
      {:noreply,
       socket
       |> put_flash(:info, "Removed the access token for #{repository.name}")
       |> assign_plugin_repositories(scope, repository.id)}
    else
      nil -> {:noreply, put_flash(socket, :error, "That repository no longer exists.")}
      {:error, reason} -> {:noreply, put_flash(socket, :error, "Could not clear the token: #{format_error(reason)}")}
    end
  end

  def handle_event("first_party_catalog_page", %{"page" => page}, socket) do
    catalog_row_count =
      socket.assigns.first_party_catalog
      |> combined_catalog_rows(
        repository_packages(socket.assigns.catalog_packages, socket.assigns.selected_repository),
        socket.assigns.first_party_release_tag
      )
      |> length()

    page =
      clamp_page(
        page,
        catalog_row_count,
        socket.assigns.first_party_catalog_page_size
      )

    {:noreply, assign(socket, :first_party_catalog_page, page)}
  end

  def handle_event("import_first_party_catalog", _params, %{assigns: %{can_stage_plugins: false}} = socket) do
    {:noreply, put_flash(socket, :error, "You don't have permission to stage plugin packages.")}
  end

  def handle_event("import_first_party_catalog", _params, %{assigns: %{import_running?: true}} = socket) do
    {:noreply, socket}
  end

  def handle_event("import_first_party_catalog", _params, socket) do
    scope = socket.assigns.current_scope
    repo_url = socket.assigns.first_party_repo_url
    release_tag = socket.assigns.first_party_release_tag
    limit = first_party_sync_limit()

    {:noreply,
     socket
     |> assign(:import_running?, true)
     |> start_async(:import_first_party_catalog, fn ->
       Packages.sync_first_party_plugins(
         scope: scope,
         repo_url: repo_url,
         release_tag: release_tag,
         limit: limit
       )
     end)}
  end

  def handle_event(
        "import_first_party_plugin",
        %{"release-tag" => _release_tag, "plugin-id" => _plugin_id, "version" => _version},
        %{assigns: %{can_stage_plugins: false}} = socket
      ) do
    {:noreply, put_flash(socket, :error, "You don't have permission to stage plugin packages.")}
  end

  def handle_event(
        "import_first_party_plugin",
        %{"release-tag" => release_tag, "plugin-id" => plugin_id, "version" => version},
        socket
      ) do
    scope = socket.assigns.current_scope

    attrs = %{
      source_type: :first_party,
      repo_url: socket.assigns.first_party_repo_url,
      release_tag: release_tag,
      plugin_id: plugin_id,
      version: version
    }

    case Packages.create(attrs, scope: scope) do
      {:ok, package} ->
        {:noreply,
         socket
         |> put_flash(:info, "Imported first-party plugin #{package.name} #{package.version}")
         |> push_navigate(to: plugins_show_path(socket.assigns.plugins_base_path, package.id))}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "First-party import failed: #{format_import_error(reason)}")
         |> load_first_party_catalog()}
    end
  end

  def handle_event("create_package", %{"create" => _params}, %{assigns: %{can_stage_plugins: false}} = socket) do
    {:noreply, put_flash(socket, :error, "You don't have permission to stage plugin packages.")}
  end

  def handle_event("create_package", %{"create" => params}, socket) do
    scope = socket.assigns.current_scope
    socket = assign(socket, :create_form, params)

    source_type = normalize_source_type(params["source_type"])

    case source_type do
      :github ->
        with {:ok, config_schema} <-
               parse_optional_json_map(params["config_schema_json"], "Config schema"),
             {:ok, display_contract} <-
               parse_optional_json_map(params["display_contract_json"], "Display contract"),
             attrs =
               %{
                 source_type: :github,
                 source_repo_url: params["source_repo_url"],
                 source_commit: params["source_commit"],
                 config_schema: config_schema,
                 display_contract: display_contract
               },
             {:ok, package} <- Packages.create(attrs, scope: scope) do
          {:noreply,
           socket
           |> assign(:show_create_modal, false)
           |> assign(:create_form, default_create_form())
           |> assign(:create_errors, [])
           |> put_flash(:info, "Plugin package staged")
           |> push_navigate(to: plugins_show_path(socket.assigns.plugins_base_path, package.id))}
        else
          {:error, :missing_repo_url} ->
            {:noreply,
             socket
             |> assign(:create_errors, ["source repo url is required for GitHub imports"])
             |> put_flash(:error, "GitHub repo URL is required")}

          {:error, :invalid_repo_url} ->
            {:noreply,
             socket
             |> assign(:create_errors, ["invalid GitHub repo url"])
             |> put_flash(:error, "GitHub repo URL is invalid")}

          {:error, :untrusted_repo} ->
            {:noreply,
             socket
             |> assign(:create_errors, [
               "github import is outside the trusted repository boundary"
             ])
             |> put_flash(:error, "GitHub repo is not trusted for authenticated import")}

          {:error, :invalid_ref} ->
            {:noreply,
             socket
             |> assign(:create_errors, ["source commit or ref is invalid"])
             |> put_flash(:error, "GitHub ref is invalid")}

          {:error, :invalid_manifest_path} ->
            {:noreply,
             socket
             |> assign(:create_errors, ["manifest path is invalid"])
             |> put_flash(:error, "Manifest path is invalid")}

          {:error, :invalid_wasm_path} ->
            {:noreply,
             socket
             |> assign(:create_errors, ["wasm path is invalid"])
             |> put_flash(:error, "Wasm path is invalid")}

          {:error, :verification_required} ->
            {:noreply,
             socket
             |> assign(:create_errors, ["gpg verification required by policy"])
             |> put_flash(:error, "GitHub package must be GPG verified")}

          {:error, :payload_too_large} ->
            {:noreply,
             socket
             |> assign(:create_errors, ["wasm blob exceeds maximum upload size"])
             |> put_flash(:error, "Wasm blob too large")}

          {:error, {:invalid_manifest, errors}} ->
            {:noreply,
             socket
             |> assign(:create_errors, errors)
             |> put_flash(:error, "Manifest validation failed")}

          {:error, errors} when is_list(errors) ->
            {:noreply,
             socket
             |> assign(:create_errors, errors)
             |> put_flash(:error, "Manifest validation failed")}

          {:error, {:invalid_json, message}} ->
            {:noreply,
             socket
             |> assign(:create_errors, [message])
             |> put_flash(:error, "Config schema JSON is invalid")}

          {:error, error} ->
            {:noreply, put_flash(socket, :error, "Failed to import GitHub package: #{format_error(error)}")}
        end

      _ ->
        with {:ok, manifest} <- parse_manifest(params["manifest_yaml"]),
             {:ok, config_schema} <-
               parse_optional_json_map(params["config_schema_json"], "Config schema"),
             {:ok, display_contract} <-
               parse_optional_json_map(params["display_contract_json"], "Display contract"),
             attrs =
               build_create_attrs(params,
                 manifest: manifest,
                 config_schema: config_schema,
                 display_contract: display_contract
               ),
             {:ok, package} <- Packages.create(attrs, scope: scope) do
          {:noreply,
           socket
           |> assign(:show_create_modal, false)
           |> assign(:create_form, default_create_form())
           |> assign(:create_errors, [])
           |> put_flash(:info, "Plugin package staged")
           |> push_navigate(to: plugins_show_path(socket.assigns.plugins_base_path, package.id))}
        else
          {:error, {:invalid_manifest, errors}} ->
            {:noreply,
             socket
             |> assign(:create_errors, errors)
             |> put_flash(:error, "Manifest validation failed")}

          {:error, errors} when is_list(errors) ->
            {:noreply,
             socket
             |> assign(:create_errors, errors)
             |> put_flash(:error, "Manifest validation failed")}

          {:error, :invalid_manifest_yaml} ->
            {:noreply,
             socket
             |> assign(:create_errors, ["invalid yaml"])
             |> put_flash(:error, "Manifest YAML is invalid")}

          {:error, {:invalid_json, message}} ->
            {:noreply,
             socket
             |> assign(:create_errors, [message])
             |> put_flash(:error, "Config schema JSON is invalid")}

          {:error, error} ->
            {:noreply, put_flash(socket, :error, "Failed to create package: #{format_error(error)}")}
        end
    end
  end

  @impl true
  def handle_async(:import_first_party_catalog, {:ok, result}, socket) do
    socket = assign(socket, :import_running?, false)

    case result do
      {:ok, summary} ->
        release_label = release_flash_label(socket.assigns.first_party_release_tag)

        {:noreply,
         socket
         |> put_flash(import_summary_flash_kind(summary), import_summary_message(summary, release_label))
         |> assign_catalog_packages(socket.assigns.current_scope)
         |> load_first_party_catalog()}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "First-party catalog import failed: #{format_import_error(reason)}")
         |> load_first_party_catalog()}
    end
  end

  def handle_async(:import_first_party_catalog, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(:import_running?, false)
     |> put_flash(:error, "First-party catalog import failed: #{format_import_error(reason)}")}
  end

  def handle_async(:load_first_party_catalog, {:ok, result}, socket) do
    {:noreply, apply_first_party_catalog(socket, result)}
  end

  def handle_async(:load_first_party_catalog, {:exit, reason}, socket) do
    {:noreply, apply_first_party_catalog(socket, {:error, reason})}
  end

  defp repository_modal(assigns) do
    ~H"""
    <.ui_modal
      :if={@show_repository_modal}
      id="plugin-repository-modal"
      open={true}
      size="lg"
      on_cancel="close_repository_modal"
    >
      <:title>
        {if @editing_repository_id, do: "Edit plugin repository", else: "Add plugin repository"}
      </:title>

      <form id="plugin-repository-form" phx-submit="save_repository" class="space-y-4">
        <div
          :if={@repository_errors != []}
          class="rounded-xl border border-error/30 bg-error/5 p-3 text-xs text-error"
        >
          <ul class="list-disc space-y-1 pl-4">
            <li :for={error <- @repository_errors}>{error}</li>
          </ul>
        </div>

        <div class="grid gap-4 sm:grid-cols-2">
          <label class="block">
            <span class="text-xs font-medium text-sr-ink">Name</span>
            <input
              type="text"
              name="repository[name]"
              value={@repository_form["name"]}
              class={ui_field_class(size: "sm", class: "w-full")}
              placeholder="Acme Plugins"
              required
            />
          </label>

          <label class="block">
            <span class="text-xs font-medium text-sr-ink">Repository URL</span>
            <input
              type="url"
              name="repository[repo_url]"
              value={@repository_form["repo_url"]}
              class={ui_field_class(size: "sm", class: "w-full")}
              placeholder="https://github.com/acme/sr-plugins"
              required
            />
          </label>
        </div>

        <label class="block">
          <span class="text-xs font-medium text-sr-ink">Index asset name</span>
          <input
            type="text"
            name="repository[index_asset_name]"
            value={@repository_form["index_asset_name"]}
            class={ui_field_class(size: "sm", class: "w-full")}
            required
          />
          <span class="mt-1 block text-xs text-sr-muted">
            The release asset holding this repository's plugin index.
          </span>
        </label>

        <div class="grid gap-4 sm:grid-cols-2">
          <label class="block">
            <span class="text-xs font-medium text-sr-ink">Signing key id</span>
            <input
              type="text"
              name="repository[signing_key_id]"
              value={@repository_form["signing_key_id"]}
              class={ui_field_class(size: "sm", class: "w-full")}
              placeholder="acme-v1"
              required
            />
          </label>

          <label class="block">
            <span class="text-xs font-medium text-sr-ink">Signing public key</span>
            <input
              type="text"
              name="repository[signing_public_key]"
              value={@repository_form["signing_public_key"]}
              class={ui_field_class(size: "sm", class: "w-full font-mono")}
              placeholder="base64 ed25519 public key"
              required
            />
          </label>
        </div>

        <p class="text-xs text-sr-muted">
          Bundles from this repository are verified against this key. A repository
          cannot be saved without one: without a trust anchor it could never
          import anything.
        </p>

        <label class="block">
          <span class="text-xs font-medium text-sr-ink">
            Access token <span class="text-sr-muted">(private repositories only)</span>
          </span>
          <input
            type="password"
            name="repository[github_token]"
            value=""
            autocomplete="off"
            class={ui_field_class(size: "sm", class: "w-full")}
            placeholder={
              if @editing_repository_id &&
                   repository_credential_attached?(@plugin_repositories, @editing_repository_id),
                 do: "•••••••• stored — type to replace",
                 else: "ghp_… (stored encrypted)"
            }
          />
          <%!--
            The hint has to differ for a new repository. "Leave blank to keep
            the stored token" is true when editing and actively misleading when
            creating: there is nothing stored, so blank stores nothing, and a
            private repository then fails with a 404 that reads as a missing
            release rather than a missing credential.
          --%>
          <span class="mt-1 block text-xs text-sr-muted">
            A fine-grained token with read-only Contents access to this repository is enough.
            <%= if @editing_repository_id &&
                     repository_credential_attached?(@plugin_repositories, @editing_repository_id) do %>
              Leave blank to keep the stored token.
            <% else %>
              A private repository needs one: without it GitHub answers 404, the same as a missing release.
            <% end %>
          </span>
        </label>

        <div class="flex items-center justify-between gap-2 pt-2">
          <.ui_button
            :if={
              @editing_repository_id &&
                repository_credential_attached?(@plugin_repositories, @editing_repository_id)
            }
            type="button"
            variant="ghost"
            size="sm"
            phx-click="clear_repository_token"
            phx-value-id={@editing_repository_id}
          >
            Remove stored token
          </.ui_button>
          <div class="ml-auto flex items-center gap-2">
            <.ui_button type="button" variant="ghost" size="sm" phx-click="close_repository_modal">
              Cancel
            </.ui_button>
            <.ui_button type="submit" variant="primary" size="sm">
              {if @editing_repository_id, do: "Save", else: "Add repository"}
            </.ui_button>
          </div>
        </div>
      </form>
    </.ui_modal>
    """
  end

  defp repository_credential_attached?(repositories, id) do
    case Enum.find(repositories, &(&1.id == id)) do
      nil -> false
      repository -> not is_nil(repository.credential_secret_id)
    end
  end

  defp create_modal(assigns) do
    ~H"""
    <dialog id="plugin-package-modal-a" class="sr-ui-modal sr-ui-modal-open" phx-hook="DialogTopLayer">
      <div class="sr-ui-modal-box sr-ui-modal-box-lg">
        <form method="dialog">
          <.ui_icon_button
            phx-click="close_create_modal"
            size="sm"
            variant="ghost"
            class="absolute right-2 top-2"
          >
            x
          </.ui_icon_button>
        </form>

        <h3 class="text-lg font-semibold">Stage a Plugin Package</h3>
        <p class="text-xs text-sr-muted mt-1">
          Paste the plugin manifest and optional config schema to start the review.
        </p>

        <%= if @create_errors != [] do %>
          <div class="mt-4 rounded-xl border border-error/30 bg-error/5 p-3 text-xs text-error">
            <div class="font-semibold">Validation errors</div>
            <ul class="mt-1 list-disc list-inside">
              <%= for error <- @create_errors do %>
                <li>{error}</li>
              <% end %>
            </ul>
          </div>
        <% end %>

        <form class="mt-4 space-y-4" phx-submit="create_package" phx-change="create_change">
          <div>
            <label class="flex items-center justify-between gap-2">
              <span class="text-sm font-medium text-sr-ink">Manifest (YAML)</span>
            </label>
            <textarea
              name="create[manifest_yaml]"
              class={ui_field_class(mono: true, class: "w-full min-h-[180px] py-2.5 text-xs")}
              placeholder="id: http-check\nname: HTTP Checker\nversion: 1.0.0\nentrypoint: run_check\noutputs: serviceradar.plugin_result.v1\ncapabilities:\n  - http_request\nresources:\n  requested_cpu_ms: 1000\n  requested_memory_mb: 64"
            ><%= @create_form["manifest_yaml"] %></textarea>
          </div>

          <div>
            <label class="flex items-center justify-between gap-2">
              <span class="text-sm font-medium text-sr-ink">Config Schema (JSON, optional)</span>
            </label>
            <textarea
              name="create[config_schema_json]"
              class={ui_field_class(mono: true, class: "w-full min-h-[140px] py-2.5 text-xs")}
              placeholder='{"type":"object","properties":{"url":{"type":"string"}}}'
            ><%= @create_form["config_schema_json"] %></textarea>
          </div>

          <div>
            <label class="flex items-center justify-between gap-2">
              <span class="text-sm font-medium text-sr-ink">Display Contract (JSON, optional)</span>
            </label>
            <textarea
              name="create[display_contract_json]"
              class={ui_field_class(mono: true, class: "w-full min-h-[140px] py-2.5 text-xs")}
              placeholder='{"schema_version":1,"widgets":["status_badge","stat_card","table","markdown","sparkline"]}'
            ><%= @create_form["display_contract_json"] %></textarea>
          </div>

          <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
            <div>
              <label class="flex items-center justify-between gap-2">
                <span class="text-sm font-medium text-sr-ink">Source Type</span>
              </label>
              <select name="create[source_type]" class={ui_field_class(class: "w-full")}>
                <option value="upload" selected={@create_form["source_type"] == "upload"}>
                  Upload
                </option>
                <option value="github" selected={@create_form["source_type"] == "github"}>
                  GitHub
                </option>
              </select>
            </div>
            <div>
              <label class="flex items-center justify-between gap-2">
                <span class="text-sm font-medium text-sr-ink">Source Repo URL (optional)</span>
              </label>
              <input
                type="text"
                name="create[source_repo_url]"
                value={@create_form["source_repo_url"]}
                class={ui_field_class(class: "w-full")}
                placeholder="https://github.com/org/repo"
              />
            </div>
          </div>

          <div>
            <label class="flex items-center justify-between gap-2">
              <span class="text-sm font-medium text-sr-ink">Source Commit (optional)</span>
            </label>
            <input
              type="text"
              name="create[source_commit]"
              value={@create_form["source_commit"]}
              class={ui_field_class(class: "w-full")}
              placeholder="abc1234"
            />
          </div>

          <div class="flex justify-end gap-2 pt-2">
            <.ui_button type="button" phx-click="close_create_modal" size="sm" variant="neutral">
              Cancel
            </.ui_button>
            <.ui_button type="submit" size="sm" variant="primary">Stage Package</.ui_button>
          </div>
        </form>
      </div>
      <form method="dialog" class="sr-ui-modal-backdrop">
        <button phx-click="close_create_modal">close</button>
      </form>
    </dialog>
    """
  end

  defp assign_catalog_packages(socket, scope) do
    assign(socket, :catalog_packages, Packages.list(%{}, scope: scope))
  end

  defp load_first_party_catalog(%{assigns: %{selected_repository: nil}} = socket) do
    socket
    |> assign(:first_party_catalog_loading?, false)
    |> assign_first_party_catalog_view([], socket.assigns[:first_party_release_tag])
    |> assign(:first_party_catalog_error, nil)
    |> assign(
      :first_party_catalog_status,
      "No enabled plugin repository. Add one, or enable an existing one, to browse a catalog."
    )
  end

  # The repository credentials and the GitHub release index are read in a task,
  # so a slow or unreachable host cannot stall the page. A newer load replaces
  # an older one still running, whose result LiveView then discards.
  defp load_first_party_catalog(socket) do
    repository = socket.assigns.selected_repository
    scope = socket.assigns.current_scope
    limit = first_party_sync_limit()

    socket
    |> assign(:first_party_catalog_loading?, true)
    |> start_async(:load_first_party_catalog, fn ->
      repository
      |> repository_import_attrs(scope)
      |> FirstPartyImporter.list_recent_plugins_with_summary(limit)
    end)
  end

  defp apply_first_party_catalog(socket, result) do
    socket = assign(socket, :first_party_catalog_loading?, false)

    case result do
      {:ok, summary} ->
        requested_release_tag =
          if socket.assigns[:first_party_release_selected?] do
            socket.assigns[:first_party_release_tag]
          end

        socket =
          assign_first_party_catalog_view(
            socket,
            summary.plugins,
            requested_release_tag
          )

        socket
        |> assign(:first_party_catalog_error, nil)
        |> assign(
          :first_party_catalog_status,
          first_party_catalog_status(summary, socket.assigns.first_party_catalog, summary.plugins)
        )

      {:error, reason} ->
        socket
        |> assign(:first_party_catalog, [])
        |> assign(:first_party_catalog_all, [])
        |> assign(:first_party_catalog_page, 1)
        |> assign(
          :first_party_release_options,
          combined_release_options([], socket.assigns.catalog_packages)
        )
        |> assign(
          :first_party_release_tag,
          selected_first_party_release(
            combined_release_options([], socket.assigns.catalog_packages),
            socket.assigns[:first_party_release_tag]
          )
        )
        |> assign(:first_party_catalog_error, format_error(reason))
        |> assign(:first_party_catalog_status, nil)
    end
  end

  defp assign_first_party_catalog_view(socket, plugins, requested_release_tag) do
    packages =
      repository_packages(
        socket.assigns[:catalog_packages] || [],
        socket.assigns[:selected_repository]
      )

    release_options = combined_release_options(plugins, packages)
    selected_release_tag = selected_first_party_release(release_options, requested_release_tag)
    visible_plugins = filter_first_party_plugins(plugins, selected_release_tag)

    socket
    |> assign(:first_party_catalog_all, plugins)
    |> assign(:first_party_release_options, release_options)
    |> assign(:first_party_release_tag, selected_release_tag)
    |> assign(:first_party_catalog, visible_plugins)
    |> assign(:first_party_catalog_page, 1)
  end

  # Every tag the entries actually carry. Filtering these by
  # `official_release_tag?/1` discarded every tag from a repository that names
  # its releases per plugin (`clearpass-policy-manager-v0.1.0`), which left the
  # options list to fall back on an *imported* package's tag from a different
  # repository -- and the catalog then filtered its own entries against that
  # foreign tag and reported "no import-ready plugin entries were found".
  defp first_party_release_options(plugins) do
    plugins
    |> Enum.map(& &1.release_tag)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
  end

  # Imported packages keep the official-tag filter that discovered entries must
  # not have. A discovered entry's tag is a release the repository actually
  # published, so every one belongs in the selector; an imported package's
  # provenance tag can be a one-off dev build (`sha-abc1234`), which would only
  # clutter it.
  defp package_release_options(packages) do
    packages
    |> Enum.map(& &1.source_release_tag)
    |> Enum.filter(&official_release_tag?/1)
    |> Enum.uniq()
  end

  defp combined_release_options(plugins, packages) do
    tags =
      plugins
      |> first_party_release_options()
      |> Kernel.++(package_release_options(packages))
      |> Enum.uniq()

    # Official tags stay newest-first so the first-party default is unchanged;
    # per-plugin tags have no meaningful version order between them, so they
    # follow in a stable alphabetical order.
    {official, other} = Enum.split_with(tags, &official_release_tag?/1)
    sorted = Enum.sort_by(official, &release_sort_key/1, :desc) ++ Enum.sort(other)

    case sorted do
      [] -> []
      [_only] -> sorted
      _ -> [@all_releases_tag | sorted]
    end
  end

  defp selected_first_party_release([], _requested), do: nil

  defp selected_first_party_release(release_options, requested) do
    if requested in release_options do
      requested
    else
      default_release_option(release_options)
    end
  end

  # First-party keeps its old default: the newest official release, which
  # `combined_release_options/2` has already sorted to the front. A repository
  # with no official tag defaults to "all releases" rather than to one arbitrary
  # per-plugin tag, which would present one plugin as the whole catalog.
  defp default_release_option(release_options) do
    Enum.find(release_options, &official_release_tag?/1) || List.first(release_options)
  end

  defp filter_first_party_plugins(_plugins, nil), do: []

  defp filter_first_party_plugins(plugins, @all_releases_tag), do: plugins

  defp filter_first_party_plugins(plugins, release_tag) do
    Enum.filter(plugins, &(&1.release_tag == release_tag))
  end

  defp release_option_label(@all_releases_tag), do: "All releases"
  defp release_option_label(release_tag), do: release_tag

  defp release_flash_label(nil), do: "the selected release"
  defp release_flash_label(@all_releases_tag), do: "all releases"
  defp release_flash_label(release_tag), do: release_tag

  defp first_party_catalog_status(summary, visible_plugins, all_plugins) do
    cond do
      visible_plugins != [] ->
        "Showing #{length(visible_plugins)} first-party plugin entry(s) from #{selected_release_status_label(visible_plugins)}. Loaded #{length(all_plugins)} entry(s) from #{summary.indexed_releases} indexed release(s)."

      summary.indexed_releases == 0 ->
        "Scanned #{summary.scanned_releases} recent GitHub release(s), but none had #{summary.index_asset_name}. Publish the Wasm plugin import index to a release before importing."

      true ->
        "Scanned #{summary.indexed_releases} indexed release(s), but no import-ready plugin entries were found."
    end
  end

  defp selected_release_status_label([]), do: "the selected release"

  defp selected_release_status_label(plugins) do
    case first_party_release_options(plugins) do
      [release_tag] -> "release #{release_tag}"
      [_ | _] -> "all releases"
      [] -> "the selected release"
    end
  end

  defp combined_catalog_rows(first_party_plugins, packages, release_tag) do
    package_by_key = Map.new(packages, &{package_catalog_key(&1), &1})

    first_party_rows =
      Enum.map(first_party_plugins, fn plugin ->
        package = Map.get(package_by_key, plugin_catalog_key(plugin))

        %{
          plugin_id: plugin.plugin_id,
          name: plugin.name,
          version: plugin.version,
          release_tag: plugin.release_tag,
          package: package,
          import_ready: Map.get(plugin, :import_ready?, false)
        }
      end)

    first_party_keys = MapSet.new(first_party_plugins, &plugin_catalog_key/1)

    package_rows =
      packages
      |> Enum.filter(&package_matches_release?(&1, release_tag))
      |> Enum.reject(&(package_catalog_key(&1) in first_party_keys))
      |> Enum.map(fn package ->
        %{
          plugin_id: package.plugin_id,
          name: package.name,
          version: package.version,
          release_tag: package.source_release_tag,
          package: package,
          import_ready: false
        }
      end)

    Enum.sort_by(first_party_rows ++ package_rows, &catalog_row_sort_key/1)
  end

  defp plugin_catalog_key(plugin), do: {plugin.plugin_id, plugin.version, plugin.release_tag}

  defp package_catalog_key(package) do
    {package.plugin_id, package.version, package.source_release_tag}
  end

  # Imported packages are shown alongside discovered entries, but only the ones
  # that came from the repository being browsed. Without this an "All releases"
  # selection matches every package, so a package imported from the built-in
  # repository appears inside a third-party repository's catalog.
  defp repository_packages(packages, nil), do: packages

  defp repository_packages(packages, repository) do
    Enum.filter(packages, &package_from_repository?(&1, repository))
  end

  # A package with no recorded origin cannot be attributed to any repository.
  # It stays visible in the Updates view's package list, which is not scoped.
  defp package_from_repository?(%{source_repo_url: origin}, _repository) when origin in [nil, ""], do: false

  defp package_from_repository?(package, repository) do
    normalize_repo_url(package.source_repo_url) == normalize_repo_url(repository.repo_url)
  end

  defp normalize_repo_url(url) do
    url
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> String.replace_suffix(".git", "")
    |> String.trim_trailing("/")
  end

  defp package_matches_release?(_package, nil), do: false

  defp package_matches_release?(_package, @all_releases_tag), do: true

  defp package_matches_release?(package, release_tag), do: package.source_release_tag == release_tag

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

  defp catalog_row_sort_key(row) do
    {row.name |> to_string() |> String.downcase(), row.plugin_id, row.version}
  end

  defp catalog_row_status(%{package: nil, import_ready: true}), do: "import-ready"
  defp catalog_row_status(%{package: nil}), do: "missing artifact"
  defp catalog_row_status(%{package: package}), do: package.status

  defp catalog_row_status_variant(%{package: nil, import_ready: true}), do: "success"
  defp catalog_row_status_variant(%{package: nil}), do: "ghost"

  defp catalog_row_status_variant(%{package: package}), do: package_status_badge_variant(package.status)

  defp catalog_row_updated_at(%{package: nil}), do: nil
  defp catalog_row_updated_at(%{package: package}), do: package.updated_at || package.inserted_at

  # --- import state ---------------------------------------------------------

  defp catalog_import_state(catalog_rows) do
    importable = Enum.count(catalog_rows, &(is_nil(&1.package) and &1.import_ready))
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
        if failed > 0, do: ["#{failed} failed (#{import_failure_summary(summary.failed)})"], else: []

    "Import finished for #{release_label}: #{Enum.join(parts, ", ")}."
  end

  defp import_summary_flash_kind(%{failed: []}), do: :info
  defp import_summary_flash_kind(_summary), do: :error

  defp import_failure_summary(failures) do
    details =
      failures
      |> Enum.take(3)
      |> Enum.map_join(", ", fn failure ->
        plugin = Map.get(failure, :plugin_id, "unknown plugin")
        version = Map.get(failure, :version)
        reason = safe_import_failure_reason(Map.get(failure, :error))
        label = if is_binary(version), do: "#{plugin} #{version}", else: plugin
        "#{label}: #{reason}"
      end)

    if length(failures) > 3, do: details <> ", …", else: details
  end

  defp safe_import_failure_reason(:invalid_signature), do: "signature verification failed"
  defp safe_import_failure_reason(:untrusted_signer), do: "signer is not trusted"
  defp safe_import_failure_reason(:plugin_not_found), do: "release entry was not found"

  defp safe_import_failure_reason(reason) when is_atom(reason) do
    reason
    |> Atom.to_string()
    |> String.replace("_", " ")
  end

  defp safe_import_failure_reason(reason), do: ImportFailureMessages.reason_to_text(reason)

  # Repository state for the catalog picker. `first_party_repo_url` stays as the
  # assign name the template already uses, but it now comes from the selected
  # repository record rather than config.
  defp assign_plugin_repositories(socket, scope, selected_id \\ nil) do
    repositories = Repositories.list(scope: scope)
    enabled = Enum.filter(repositories, & &1.enabled)

    selected =
      Enum.find(enabled, &(&1.id == selected_id)) ||
        Enum.find(enabled, & &1.is_default) ||
        List.first(enabled)

    socket
    |> assign(:plugin_repositories, repositories)
    |> assign(:enabled_plugin_repositories, enabled)
    |> assign(:selected_repository, selected)
    |> assign(:first_party_repo_url, selected && selected.repo_url)
  end

  defp repository_permission_message, do: "You don't have permission to manage plugin repositories."

  # The last auto-sync run's outcome, straight off the repository record the
  # sync worker stamps: status, counts, and why it failed when it did.
  defp last_sync_label(repository) do
    summary = Map.get(repository, :last_sync_summary) || %{}
    at = repository.last_sync_at

    cond do
      is_nil(at) ->
        "Last sync: never"

      summary["status"] == "failed" ->
        "Last sync: failed - #{summary["error"] || repository.last_sync_error || "unknown reason"}"

      repository.last_sync_error ->
        "Last sync: failed - #{repository.last_sync_error}"

      summary["status"] == "partial" ->
        first = summary["first_error"] || %{}

        "Last sync: failed imports - " <>
          "#{Map.get(summary, "failed_count", 0)} of " <>
          "#{Map.get(summary, "imported", 0) + Map.get(summary, "failed_count", 0)} failed" <>
          first_error_suffix(first)

      true ->
        "Last sync: ok - imported #{Map.get(summary, "imported", 0)}, " <>
          "skipped #{Map.get(summary, "skipped", 0)}"
    end
  end

  defp first_error_suffix(%{"plugin_id" => plugin_id} = first) when is_binary(plugin_id) do
    " (first: #{plugin_id} #{Map.get(first, "version", "")} - #{Map.get(first, "reason", "unknown reason")})"
  end

  defp first_error_suffix(_first), do: ""

  defp scope_actor(%{user: user}) when not is_nil(user), do: user
  defp scope_actor(_scope), do: nil

  defp save_repository(nil, params, scope) do
    attrs = repository_attrs(params)

    with {:ok, repository} <-
           PluginRepository
           |> Ash.Changeset.for_create(:create, attrs, actor: scope_actor(scope))
           |> Ash.create()
           |> normalize_repository_result() do
      apply_repository_token(repository, params, scope)
    end
  end

  defp save_repository(id, params, scope) do
    attrs = repository_attrs(params)
    actor = scope_actor(scope)

    with {:ok, repository} <- fetch_repository(id, actor),
         {:ok, repository} <-
           repository
           |> Ash.Changeset.for_update(:update, attrs, actor: actor)
           |> Ash.update()
           |> normalize_repository_result() do
      apply_repository_token(repository, params, scope)
    end
  end

  # The token field is write-only: an empty value on an edit means "leave the
  # existing token alone", not "clear it". Clearing is its own explicit action,
  # so a save cannot silently drop a credential the operator did not re-type.
  defp apply_repository_token(repository, params, scope) do
    case String.trim(Map.get(params, "github_token") || "") do
      "" ->
        {:ok, repository}

      token ->
        case RepositoryCredentials.put_token(repository, token, actor: scope_actor(scope)) do
          {:ok, repository} -> {:ok, repository}
          {:error, reason} -> {:error, ["access token: #{format_error(reason)}"]}
        end
    end
  end

  defp repository_attrs(params) do
    %{
      name: String.trim(Map.get(params, "name") || ""),
      repo_url: String.trim(Map.get(params, "repo_url") || ""),
      index_asset_name: String.trim(Map.get(params, "index_asset_name") || ""),
      signing_key_id: String.trim(Map.get(params, "signing_key_id") || ""),
      signing_public_key: String.trim(Map.get(params, "signing_public_key") || "")
    }
  end

  defp fetch_repository(id, actor) do
    case PluginRepository.get_by_id(id, actor: actor) do
      {:ok, repository} -> {:ok, repository}
      {:error, reason} -> {:error, [format_error(reason)]}
    end
  end

  defp update_repository_state(repository, action, scope) do
    repository
    |> Ash.Changeset.for_update(action, %{}, actor: scope_actor(scope))
    |> Ash.update()
  end

  defp destroy_repository(repository, scope) do
    case Ash.destroy(repository, actor: scope_actor(scope)) do
      :ok -> :ok
      {:ok, _record} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_repository_result({:ok, repository}), do: {:ok, repository}

  defp normalize_repository_result({:error, %Invalid{errors: errors}}),
    do: {:error, Enum.map(errors, &repository_error_message/1)}

  defp normalize_repository_result({:error, reason}), do: {:error, [format_error(reason)]}

  defp repository_error_message(%{field: field, message: message}) when not is_nil(field), do: "#{field}: #{message}"

  defp repository_error_message(error), do: format_error(error)

  defp default_repository_form do
    %{
      "name" => "",
      "repo_url" => "",
      "index_asset_name" => "serviceradar-wasm-plugin-index.json",
      "signing_key_id" => "",
      "signing_public_key" => "",
      "github_token" => ""
    }
  end

  defp repository_form_from(repository) do
    %{
      "name" => repository.name,
      "repo_url" => repository.repo_url,
      "index_asset_name" => repository.index_asset_name,
      "signing_key_id" => repository.signing_key_id,
      "signing_public_key" => repository.signing_public_key,
      # Never round-trip the token into the form: it is write-only, and the
      # form shows only whether one is attached.
      "github_token" => ""
    }
  end

  defp repository_import_attrs(nil, _scope), do: %{}

  defp repository_import_attrs(repository, scope) do
    case Repositories.import_attrs(repository, scope: scope) do
      {:ok, attrs} -> attrs
      {:error, _reason} -> %{"repo_url" => repository.repo_url}
    end
  end

  defp first_party_sync_limit do
    config = Application.get_env(:serviceradar_web_ng, :first_party_plugin_import, [])

    case Keyword.get(config, :sync_release_limit, 10) do
      limit when is_integer(limit) and limit > 0 -> limit
      _ -> 10
    end
  end

  defp assign_capacity(socket, scope) do
    {rows, totals} =
      try do
        build_capacity_snapshot(scope)
      rescue
        _ -> {[], empty_capacity_totals()}
      end

    socket
    |> assign(:capacity_rows, rows)
    |> assign(:capacity_totals, totals)
  end

  defp build_capacity_snapshot(scope) do
    agents = Assignments.assignable_agents(scope)
    assignments = Assignments.list(%{"limit" => 500}, scope: scope)
    packages = Packages.list(%{"limit" => 500}, scope: scope)
    packages_by_id = Map.new(packages, &{&1.id, &1})

    assignments_by_agent = Enum.group_by(assignments, & &1.agent_uid)

    rows =
      Enum.map(agents, fn agent ->
        agent_assignments = Map.get(assignments_by_agent, agent.uid, [])
        enabled_assignments = Enum.reject(agent_assignments, &(&1.enabled == false))
        resources = aggregate_resources(enabled_assignments, packages_by_id)

        %{
          agent_uid: agent.uid,
          name: agent.name || agent.host || agent.uid,
          assignments: length(enabled_assignments),
          plugins: assignment_plugin_summaries(enabled_assignments, packages_by_id),
          cpu_ms: resources.requested_cpu_ms,
          memory_mb: resources.requested_memory_mb,
          connections: resources.max_open_connections
        }
      end)

    totals = %{
      assignments: Enum.reduce(rows, 0, &(&1.assignments + &2)),
      cpu_ms: Enum.reduce(rows, 0, &(&1.cpu_ms + &2)),
      memory_mb: Enum.reduce(rows, 0, &(&1.memory_mb + &2)),
      connections: Enum.reduce(rows, 0, &(&1.connections + &2))
    }

    {rows, totals}
  end

  defp empty_capacity_totals do
    %{assignments: 0, cpu_ms: 0, memory_mb: 0, connections: 0}
  end

  defp aggregate_resources(assignments, packages_by_id) do
    Enum.reduce(
      assignments,
      %{requested_cpu_ms: 0, requested_memory_mb: 0, max_open_connections: 0},
      fn assignment, acc ->
        if assignment.enabled == false do
          acc
        else
          resources = effective_resources(assignment, packages_by_id)

          %{
            requested_cpu_ms: acc.requested_cpu_ms + resource_value(resources, :requested_cpu_ms),
            requested_memory_mb: acc.requested_memory_mb + resource_value(resources, :requested_memory_mb),
            max_open_connections: acc.max_open_connections + resource_value(resources, :max_open_connections)
          }
        end
      end
    )
  end

  defp assignment_plugin_summaries(assignments, packages_by_id) do
    assignments
    |> Enum.reject(&(&1.enabled == false))
    |> Enum.map(fn assignment ->
      package = packages_by_id[assignment.plugin_package_id]

      %{
        plugin_id: package && package.plugin_id,
        name: package && package.name,
        version: package && package.version,
        interval_seconds: assignment.interval_seconds,
        timeout_seconds: assignment.timeout_seconds
      }
    end)
    |> Enum.reject(&is_nil(&1.plugin_id))
    |> Enum.sort_by(& &1.plugin_id)
  end

  defp assigned_plugins_title(%{plugins: []}), do: "No enabled plugin assignments"

  defp assigned_plugins_title(%{plugins: plugins}) do
    Enum.map_join(plugins, "\n", fn plugin ->
      String.trim("#{plugin.name || plugin.plugin_id} #{plugin.version || ""}")
    end)
  end

  defp assigned_plugins_title(_row), do: "View agent plugin assignments"

  defp agent_plugins_path(agent_uid) when is_binary(agent_uid) do
    "/agents/#{URI.encode(agent_uid)}#plugins"
  end

  defp agent_plugins_path(_agent_uid), do: "/agents"

  defp effective_resources(assignment, packages_by_id) do
    override = normalize_map(assignment.resources_override)

    cond do
      map_present?(override) ->
        override

      package = packages_by_id[assignment.plugin_package_id] ->
        approved = normalize_map(package.approved_resources)

        if map_present?(approved) do
          approved
        else
          normalize_map(
            Map.get(package.manifest || %{}, "resources") ||
              Map.get(package.manifest || %{}, :resources)
          )
        end

      true ->
        %{}
    end
  end

  defp map_present?(map) when is_map(map), do: map_size(map) > 0

  defp normalize_map(nil), do: %{}
  defp normalize_map(map) when is_map(map), do: map
  defp normalize_map(_), do: %{}

  defp resource_value(map, key) do
    value = Map.get(map, key) || Map.get(map, Atom.to_string(key))
    parse_int(value, 0)
  end

  defp build_create_attrs(params, extra) do
    extra = Map.new(extra)

    source_type = normalize_source_type(params["source_type"])
    manifest = Map.get(extra, :manifest) || Map.get(extra, "manifest")
    config_schema = Map.get(extra, :config_schema) || Map.get(extra, "config_schema")
    display_contract = Map.get(extra, :display_contract) || Map.get(extra, "display_contract")

    source_repo_url = params["source_repo_url"] || manifest_source_repo_url(manifest)

    %{
      manifest: manifest,
      config_schema: config_schema,
      display_contract: display_contract,
      source_type: source_type,
      source_repo_url: source_repo_url,
      source_commit: params["source_commit"]
    }
  end

  defp parse_manifest(nil), do: {:error, :invalid_manifest_yaml}

  defp parse_manifest(yaml) when is_binary(yaml) do
    trimmed = String.trim(yaml)

    with true <- trimmed != "" || {:error, :invalid_manifest_yaml},
         {:ok, manifest} <- Manifest.from_yaml(trimmed) do
      {:ok, Map.from_struct(manifest)}
    else
      {:error, errors} when is_list(errors) -> {:error, {:invalid_manifest, errors}}
      _ -> {:error, :invalid_manifest_yaml}
    end
  end

  defp parse_manifest(_), do: {:error, :invalid_manifest_yaml}

  defp normalize_source_type(nil), do: :upload
  defp normalize_source_type(""), do: :upload
  defp normalize_source_type(:upload), do: :upload
  defp normalize_source_type(:github), do: :github
  defp normalize_source_type(:first_party), do: :first_party

  defp normalize_source_type(source_type) when is_binary(source_type) do
    case String.trim(source_type) do
      "github" -> :github
      "first_party" -> :first_party
      "upload" -> :upload
      _ -> :upload
    end
  end

  defp normalize_source_type(_), do: :upload

  defp default_create_form do
    %{
      "manifest_yaml" => "",
      "config_schema_json" => "",
      "display_contract_json" => "",
      "source_type" => "upload",
      "source_repo_url" => "",
      "source_commit" => ""
    }
  end

  defp manifest_source_repo_url(manifest) do
    source = Map.get(manifest || %{}, :source) || Map.get(manifest || %{}, "source") || %{}
    Map.get(source, :repo_url) || Map.get(source, "repo_url")
  end

  defp parse_int(nil, default), do: default
  defp parse_int("", default), do: default

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> default
    end
  end

  defp parse_int(value, _default) when is_integer(value), do: value
  defp parse_int(_value, default), do: default

  # First-party import failures carry transport shapes (proxy rejections, TLS,
  # DNS) that inspect/1 renders as opaque tuples; map them to actionable text.
  defp format_import_error(reason), do: ImportFailureMessages.reason_to_text(reason)
end
