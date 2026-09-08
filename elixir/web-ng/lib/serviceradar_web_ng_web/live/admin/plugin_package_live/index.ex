defmodule ServiceRadarWebNGWeb.Admin.PluginPackageLive.Index do
  @moduledoc """
  LiveView for managing Wasm plugin packages and import review.
  """

  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.PluginConfigForm

  alias Ash.Error.Invalid
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Plugins.IntegrationCatalog
  alias ServiceRadar.Plugins.Manifest
  alias ServiceRadar.Plugins.PluginRepository
  alias ServiceRadar.Plugins.RepositoryCredentials
  alias ServiceRadarWebNG.Observability.ContractRegistry
  alias ServiceRadarWebNG.Plugins.Assignments
  alias ServiceRadarWebNG.Plugins.CredentialCoverage
  alias ServiceRadarWebNG.Plugins.FirstPartyImporter
  alias ServiceRadarWebNG.Plugins.FirstPartyReleaseClient
  alias ServiceRadarWebNG.Plugins.Packages
  alias ServiceRadarWebNG.Plugins.Repositories
  alias ServiceRadarWebNG.Plugins.Storage
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.Settings.Shell

  require Ash.Query
  require Logger

  Module.register_attribute(__MODULE__, :sobelow_skip, accumulate: true)

  @package_page_size 10
  @first_party_catalog_page_size 10
  @official_release_tag_regex ~r/^v(?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+)$/

  # Sentinel release option meaning "every release this repository publishes".
  # A repository that tags per plugin (one release per plugin, the pattern
  # third-party repositories are documented to use) has no single release
  # holding its whole catalog, so selecting one tag would show one plugin and
  # hide the rest.
  @all_releases_tag FirstPartyReleaseClient.admin_all_releases_sentinel()
  @plugin_assignment_manage_permission "settings.plugins.manage"
  @credential_manage_permission "settings.credentials.manage"
  # Deliberately not implied by plugins.stage: staging imports from a source the
  # platform already trusts, while this decides which sources are trusted.
  @repository_manage_permission "plugins.repositories.manage"
  @policy_recovery_poll_delay_ms 2_000
  @policy_recovery_poll_attempt_limit 30
  @legacy_recovery_candidate_page_size 50

  # Capabilities that grant network egress or raw request access from a Wasm
  # plugin. These MUST be explicitly carried into a package's approved
  # capabilities before the host will allow the plugin to use them (the host's
  # first guard is `hasCapability/1`). They are surfaced distinctly in the review
  # UI so an operator does not silently drop one when hand-typing the approved
  # list — omitting a requested sensitive capability denies it.
  @sensitive_capabilities ~w(
    http_request
    websocket_connect
    websocket_send
    websocket_recv
    websocket_close
  )

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if RBAC.can?(scope, "plugins.view") do
      packages = list_packages(%{}, scope)
      release_options = combined_release_options([], packages)
      can_assign_plugins = RBAC.can?(scope, @plugin_assignment_manage_permission)

      can_reconcile_credential_rules =
        can_assign_plugins and RBAC.can?(scope, @credential_manage_permission)

      socket =
        socket
        |> assign(:can_stage_plugins, RBAC.can?(scope, "plugins.stage"))
        |> assign(:can_approve_plugins, RBAC.can?(scope, "plugins.approve"))
        # PluginAssignment mutations (including legacy recovery) are guarded
        # by the core `settings.plugins.manage` policy. Do not advertise a
        # weaker `plugins.assign` browser capability that the server will deny.
        |> assign(:can_assign_plugins, can_assign_plugins)
        |> assign(:can_reconcile_credential_rules, can_reconcile_credential_rules)
        |> assign(:page_title, "Plugins")
        |> assign(:current_path, nil)
        |> assign(:plugins_base_path, "/admin/plugins")
        |> assign(:packages, packages)
        |> assign(:catalog_packages, packages)
        |> assign(:package_page, 1)
        |> assign(:package_page_size, @package_page_size)
        |> assign(:filter_status, nil)
        |> assign(:filter_source_type, nil)
        |> assign(:first_party_catalog, [])
        |> assign(:first_party_catalog_all, [])
        |> assign(:first_party_catalog_page, 1)
        |> assign(:first_party_catalog_page_size, @first_party_catalog_page_size)
        |> assign(:first_party_catalog_error, nil)
        |> assign(:first_party_catalog_status, nil)
        |> assign(:first_party_release_options, release_options)
        |> assign(:first_party_release_tag, selected_first_party_release(release_options, nil))
        |> assign(:first_party_release_selected?, false)
        |> assign(:can_manage_repositories, RBAC.can?(scope, @repository_manage_permission))
        |> assign_plugin_repositories(scope)
        |> assign(:show_repository_modal, false)
        |> assign(:repository_form, default_repository_form())
        |> assign(:repository_errors, [])
        |> assign(:editing_repository_id, nil)
        |> assign(:import_running?, false)
        |> assign(:show_create_modal, false)
        |> assign(:show_details_modal, false)
        |> assign(:create_form, default_create_form())
        |> assign(:create_errors, [])
        |> assign(:selected_package, nil)
        |> assign(:review_form, default_review_form())
        |> assign(:assignment_form, default_assignment_form())
        |> assign(:assignments, [])
        |> assign(:authenticated_partition_preview, nil)
        |> assign(:recovery_confirmation, nil)
        |> assign(:policy_recovery_polls, %{})
        |> assign(:legacy_recovery_candidate_page, 1)
        |> assign(:legacy_recovery_candidate_after_ids, %{1 => nil})
        |> assign(:legacy_recovery_candidates_more?, false)
        |> assign(:credential_fields, [])
        |> assign(:credential_coverage, nil)
        |> assign(:assignment_coverage, %{})
        |> assign(:versions, [])
        |> assign(:agents, list_agents(scope))
        |> assign_capacity(scope)
        |> assign(:verification_policy, plugin_verification_policy())
        |> assign(:upload_url, nil)
        |> assign(:upload_token, nil)
        |> assign(:upload_expires_at, nil)
        |> assign(:download_url, nil)
        |> assign(:download_token, nil)
        |> assign(:download_expires_at, nil)
        |> assign(:blob_present, nil)
        |> assign(:upload_errors, [])
        # Candidate discovery is a database-backed, tenant-scoped query. Keep
        # the disconnected mount free of new database work and load it only
        # after the LiveView socket is connected.
        |> assign(:legacy_recovery_candidates, [])
        |> allow_upload(:wasm_blob,
          accept: ~w(.wasm),
          max_entries: 1,
          max_file_size: Storage.max_upload_bytes()
        )

      if connected?(socket) do
        send(self(), :load_first_party_catalog)
      end

      {:ok, socket}
    else
      {:ok,
       socket
       |> put_flash(:error, "You don't have permission to access Plugins.")
       |> redirect(to: ~p"/dashboard")}
    end
  end

  @impl true
  def handle_params(params, url, socket) do
    base_path = plugins_base_path_from_url(url)

    socket =
      socket
      |> assign(:current_path, current_path_from_url(url))
      |> assign(:plugins_base_path, base_path)

    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:show_create_modal, false)
    |> assign(:show_details_modal, false)
    |> assign(:selected_package, nil)
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:show_create_modal, true)
    |> assign(:create_errors, [])
  end

  defp apply_action(socket, :show, %{"id" => id}) do
    scope = socket.assigns.current_scope

    case Packages.get(id, scope: scope) do
      {:ok, package} ->
        socket
        |> assign(:selected_package, package)
        |> assign(:show_details_modal, true)
        |> assign(:review_form, build_review_form(package))
        |> assign(:assignment_form, default_assignment_form(package))
        |> assign(:assignments, list_plugin_assignments(package.plugin_id, scope))
        |> assign(:authenticated_partition_preview, nil)
        |> assign(:recovery_confirmation, nil)
        |> assign(:policy_recovery_polls, %{})
        |> assign_credential_context(package)
        |> assign(:versions, list_versions(package.plugin_id, scope))
        |> assign(:upload_errors, [])
        |> assign_package_urls(package, scope)

      {:error, :not_found} ->
        socket
        |> put_flash(:error, "Package not found")
        |> push_navigate(to: plugins_index_path(socket))

      {:error, _error} ->
        socket
        |> put_flash(:error, "Failed to load package")
        |> push_navigate(to: plugins_index_path(socket))
    end
  end

  @impl true
  def handle_info(:load_first_party_catalog, socket) do
    {:noreply, load_first_party_catalog(socket)}
  end

  def handle_info(:load_legacy_recovery_candidates, socket) do
    {:noreply, assign_legacy_recovery_candidates(socket, socket.assigns.current_scope)}
  end

  def handle_info({:refresh_policy_recovery, legacy_assignment_id, poll_ref, attempt}, socket) do
    poll = Map.get(socket.assigns.policy_recovery_polls, legacy_assignment_id)

    if current_policy_recovery_poll?(poll, poll_ref, attempt) and
         not is_nil(socket.assigns.selected_package) do
      package = socket.assigns.selected_package
      scope = socket.assigns.current_scope
      assignments = list_plugin_assignments(package.plugin_id, scope)
      state = policy_recovery_state_for_assignment(assignments, legacy_assignment_id)

      socket = assign(socket, :assignments, assignments)

      case state do
        state when state in [:queued, :pending] ->
          {:noreply, schedule_policy_recovery_poll(socket, legacy_assignment_id, poll_ref, attempt)}

        state when is_atom(state) ->
          {:noreply,
           socket
           |> clear_policy_recovery_poll(legacy_assignment_id)
           |> reset_legacy_recovery_candidate_page()
           |> assign_legacy_recovery_candidates(scope)
           |> put_flash(:info, policy_recovery_terminal_message(state))}

        _ ->
          {:noreply,
           socket
           |> clear_policy_recovery_poll(legacy_assignment_id)
           |> put_flash(
             :error,
             "Could not refresh policy reconciliation status. Refresh the page before retrying."
           )}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("open_create_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_create_modal, true)
     |> assign(:create_form, default_create_form())
     |> assign(:create_errors, [])}
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

  def handle_event("close_details_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_details_modal, false)
     |> assign(:selected_package, nil)
     |> assign(:assignments, [])
     |> assign(:assignment_form, default_assignment_form())
     |> assign(:authenticated_partition_preview, nil)
     |> assign(:recovery_confirmation, nil)
     |> assign(:policy_recovery_polls, %{})
     |> assign(:versions, [])
     |> assign(:upload_errors, [])
     |> assign(:upload_url, nil)
     |> assign(:upload_token, nil)
     |> assign(:download_url, nil)
     |> assign(:download_token, nil)
     |> assign(:blob_present, nil)}
  end

  def handle_event("filter", params, socket) do
    scope = socket.assigns.current_scope

    filter_status = Map.get(params, "status", socket.assigns.filter_status)
    filter_source_type = Map.get(params, "source_type", socket.assigns.filter_source_type)

    filters =
      %{}
      |> maybe_put_filter("status", filter_status)
      |> maybe_put_filter("source_type", filter_source_type)

    {:noreply,
     socket
     |> assign(:filter_status, normalize_filter(filter_status))
     |> assign(:filter_source_type, normalize_filter(filter_source_type))
     |> assign(:package_page, 1)
     |> assign(:packages, list_packages(filters, scope))}
  end

  def handle_event("refresh", _params, socket) do
    scope = socket.assigns.current_scope

    {:noreply,
     socket
     |> assign_package_views(scope)
     |> assign(:agents, list_agents(scope))
     |> assign_capacity(scope)
     |> assign(:verification_policy, plugin_verification_policy())
     |> assign_first_party_catalog_view(
       socket.assigns.first_party_catalog_all,
       socket.assigns.first_party_release_tag
     )}
  end

  def handle_event("legacy_recovery_candidate_page", %{"id" => direction}, socket) do
    current_page = socket.assigns.legacy_recovery_candidate_page

    next_page =
      case direction do
        "next" when socket.assigns.legacy_recovery_candidates_more? -> current_page + 1
        "previous" -> max(current_page - 1, 1)
        _ -> current_page
      end

    if Map.has_key?(socket.assigns.legacy_recovery_candidate_after_ids, next_page) do
      {:noreply,
       socket
       |> assign(:legacy_recovery_candidate_page, next_page)
       |> assign_legacy_recovery_candidates(socket.assigns.current_scope)}
    else
      {:noreply, socket}
    end
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

  def handle_event("package_page", %{"page" => page}, socket) do
    page =
      clamp_page(
        page,
        length(socket.assigns.packages),
        socket.assigns.package_page_size
      )

    {:noreply, assign(socket, :package_page, page)}
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
         |> assign_package_views(scope)
         |> load_first_party_catalog()
         |> push_navigate(to: plugins_show_path(socket, package.id))}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "First-party import failed: #{format_error(reason)}")
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
           |> assign_package_views(scope)
           |> assign(:show_create_modal, false)
           |> assign(:create_form, default_create_form())
           |> assign(:create_errors, [])
           |> put_flash(:info, "Plugin package staged")
           |> push_navigate(to: plugins_show_path(socket, package.id))}
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
           |> assign_package_views(scope)
           |> assign(:show_create_modal, false)
           |> assign(:create_form, default_create_form())
           |> assign(:create_errors, [])
           |> put_flash(:info, "Plugin package staged")
           |> push_navigate(to: plugins_show_path(socket, package.id))}
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

  def handle_event("review_change", %{"review" => params}, socket) do
    {:noreply, assign(socket, :review_form, Map.merge(socket.assigns.review_form, params))}
  end

  def handle_event("upload_wasm", _params, %{assigns: %{can_stage_plugins: false}} = socket) do
    {:noreply, put_flash(socket, :error, "You don't have permission to stage plugin packages.")}
  end

  def handle_event("upload_wasm", _params, socket) do
    scope = socket.assigns.current_scope
    package = socket.assigns.selected_package

    cond do
      is_nil(package) ->
        {:noreply, put_flash(socket, :error, "No package selected")}

      socket.assigns.uploads.wasm_blob.entries == [] ->
        {:noreply, put_flash(socket, :error, "Select a .wasm file to upload")}

      true ->
        handle_wasm_upload(socket, package, scope)
    end
  end

  def handle_event("wasm_upload_change", _params, socket) do
    {:noreply, assign(socket, :upload_errors, [])}
  end

  def handle_event("assignment_change", %{"assignment" => params}, socket) do
    form = Map.merge(socket.assigns.assignment_form, params)

    {:noreply,
     socket
     |> assign(:assignment_form, form)
     |> assign_form_coverage(form["agent_uid"])
     |> assign_authenticated_partition_preview(form["agent_uid"])}
  end

  def handle_event("approve_package", %{"review" => _params}, %{assigns: %{can_approve_plugins: false}} = socket) do
    {:noreply, put_flash(socket, :error, "You don't have permission to approve plugin packages.")}
  end

  def handle_event("approve_package", %{"review" => params}, socket) do
    scope = socket.assigns.current_scope
    approved_by = get_actor(socket)

    with {:ok, attrs} <- parse_review_params(params),
         {:ok, package} <-
           Packages.approve(
             socket.assigns.selected_package.id,
             attrs,
             scope: scope,
             approved_by: approved_by
           ) do
      {:noreply,
       socket
       |> assign_package_views(scope)
       |> assign(:selected_package, package)
       |> assign(:review_form, build_review_form(package))
       |> put_flash(:info, "Package approved")}
    else
      {:error, {:invalid_json, message}} ->
        {:noreply, put_flash(socket, :error, message)}

      {:error, :verification_required} ->
        {:noreply, put_flash(socket, :error, "GitHub package must be GPG verified before approval")}

      {:error, :signature_required} ->
        {:noreply, put_flash(socket, :error, "Unsigned uploads are blocked by verification policy")}

      {:error, :trusted_upload_signers_not_configured} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Upload signing keys are not configured for strict verification"
         )}

      {:error, :invalid_signature} ->
        {:noreply, put_flash(socket, :error, "Upload signature verification failed")}

      {:error, :unsupported_signature_algorithm} ->
        {:noreply, put_flash(socket, :error, "Upload signature algorithm is not supported")}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, "Failed to approve: #{format_error(error)}")}
    end
  end

  def handle_event("deny_package", _params, %{assigns: %{can_approve_plugins: false}} = socket) do
    {:noreply, put_flash(socket, :error, "You don't have permission to approve plugin packages.")}
  end

  def handle_event("deny_package", _params, socket) do
    scope = socket.assigns.current_scope
    reason = socket.assigns.review_form["denied_reason"]

    case Packages.deny(socket.assigns.selected_package.id, %{denied_reason: reason}, scope: scope) do
      {:ok, package} ->
        {:noreply,
         socket
         |> assign_package_views(scope)
         |> assign(:selected_package, package)
         |> assign(:review_form, build_review_form(package))
         |> put_flash(:info, "Package denied")}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, "Failed to deny: #{format_error(error)}")}
    end
  end

  def handle_event("revoke_package", _params, %{assigns: %{can_approve_plugins: false}} = socket) do
    {:noreply, put_flash(socket, :error, "You don't have permission to approve plugin packages.")}
  end

  def handle_event("revoke_package", _params, socket) do
    scope = socket.assigns.current_scope
    reason = socket.assigns.review_form["denied_reason"]

    case Packages.revoke(socket.assigns.selected_package.id, %{denied_reason: reason}, scope: scope) do
      {:ok, package} ->
        {:noreply,
         socket
         |> assign_package_views(scope)
         |> assign(:selected_package, package)
         |> assign(:review_form, build_review_form(package))
         |> put_flash(:info, "Package revoked")}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, "Failed to revoke: #{format_error(error)}")}
    end
  end

  def handle_event("noop", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("create_assignment", %{"assignment" => _params}, %{assigns: %{can_assign_plugins: false}} = socket) do
    {:noreply, put_flash(socket, :error, "You don't have permission to assign plugins.")}
  end

  def handle_event("create_assignment", %{"assignment" => params}, socket) do
    if producer_schedule_provisioned?(socket.assigns.selected_package) do
      {:noreply, put_flash(socket, :error, producer_schedule_assignment_message())}
    else
      scope = socket.assigns.current_scope

      case parse_assignment_params(params, socket.assigns.selected_package) do
        {:ok, attrs} ->
          handle_assignment_upsert(socket, scope, attrs)

        {:error, {:invalid_json, message}} ->
          Logger.error("Plugin assignment failed - invalid JSON: #{message}")
          {:noreply, put_flash(socket, :error, message)}

        {:error, error} ->
          Logger.error("Plugin assignment failed: #{inspect(error)}")
          {:noreply, put_flash(socket, :error, "Failed to assign: #{format_error(error)}")}
      end
    end
  end

  def handle_event("delete_assignment", %{"id" => _id}, %{assigns: %{can_assign_plugins: false}} = socket) do
    {:noreply, put_flash(socket, :error, "You don't have permission to assign plugins.")}
  end

  def handle_event("delete_assignment", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    case Assignments.delete(id, scope: scope) do
      {:ok, _assignment} ->
        {:noreply,
         socket
         |> assign(
           :assignments,
           list_plugin_assignments(socket.assigns.selected_package.plugin_id, scope)
         )
         |> assign_credential_context(socket.assigns.selected_package)
         |> put_flash(:info, "Assignment removed")}

      {:error, error} ->
        Logger.error("Plugin assignment deletion failed for #{id}: #{inspect(error)}")
        {:noreply, put_flash(socket, :error, "Failed to remove: #{format_error(error)}")}
    end
  end

  def handle_event("upgrade_assignment", %{"id" => _id}, %{assigns: %{can_assign_plugins: false}} = socket) do
    {:noreply, put_flash(socket, :error, "You don't have permission to assign plugins.")}
  end

  def handle_event("upgrade_assignment", %{"id" => id, "target-package-id" => target_package_id}, socket) do
    upgrade_assignment(socket, id, target_package_id)
  end

  def handle_event("upgrade_assignment", %{"id" => id, "assignment_upgrade" => params}, socket) do
    upgrade_assignment(socket, id, Map.get(params, "target_package_id"))
  end

  def handle_event("request_legacy_recovery", _params, %{assigns: %{can_assign_plugins: false}} = socket) do
    {:noreply, put_flash(socket, :error, "You don't have permission to recover plugin assignments.")}
  end

  def handle_event("request_legacy_recovery", %{"id" => id, "kind" => kind}, socket) do
    case legacy_recovery_confirmation(socket.assigns.assignments, id, kind) do
      {:ok, confirmation} ->
        if legacy_recovery_confirmation_allowed?(socket, confirmation) do
          {:noreply, assign(socket, :recovery_confirmation, confirmation)}
        else
          {:noreply, put_flash(socket, :error, credential_recovery_permission_message())}
        end

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Legacy assignment was not found. Refresh and try again.")}

      {:error, :unsupported_policy_owner} ->
        {:noreply, put_flash(socket, :error, unsupported_policy_owner_message())}

      {:error, :recovery_unavailable} ->
        {:noreply, put_flash(socket, :error, legacy_recovery_unavailable_message())}

      {:error, :not_recoverable} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "This assignment is not an unbound legacy row and cannot be recovered through reapproval."
         )}

      {:error, :kind_mismatch} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "The requested recovery action does not match this assignment."
         )}
    end
  end

  def handle_event("cancel_legacy_recovery", _params, socket) do
    {:noreply, assign(socket, :recovery_confirmation, nil)}
  end

  def handle_event("confirm_legacy_recovery", _params, %{assigns: %{can_assign_plugins: false}} = socket) do
    {:noreply, put_flash(socket, :error, "You don't have permission to recover plugin assignments.")}
  end

  def handle_event("confirm_legacy_recovery", %{"id" => id, "kind" => kind}, socket) do
    confirmation = socket.assigns.recovery_confirmation

    case {
      recovery_confirmation_matches?(confirmation, id, kind),
      legacy_recovery_confirmation_allowed?(socket, confirmation)
    } do
      {true, true} ->
        perform_legacy_recovery(socket, id, kind)

      {true, false} ->
        {:noreply, put_flash(socket, :error, credential_recovery_permission_message())}

      _ ->
        {:noreply, put_flash(socket, :error, "Review this recovery request again before confirming.")}
    end
  end

  def handle_event("restage_package", _params, %{assigns: %{can_approve_plugins: false}} = socket) do
    {:noreply, put_flash(socket, :error, "You don't have permission to approve plugin packages.")}
  end

  def handle_event("restage_package", _params, socket) do
    scope = socket.assigns.current_scope

    case Packages.restage(socket.assigns.selected_package.id, scope: scope) do
      {:ok, package} ->
        {:noreply,
         socket
         |> assign_package_views(scope)
         |> assign(:selected_package, package)
         |> assign(:review_form, build_review_form(package))
         |> put_flash(:info, "Package moved back to staged")}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, "Failed to restage: #{format_error(error)}")}
    end
  end

  def handle_event("delete_package", %{"id" => _id}, %{assigns: %{can_approve_plugins: false}} = socket) do
    {:noreply, put_flash(socket, :error, "You don't have permission to approve plugin packages.")}
  end

  def handle_event("delete_package", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope
    package = socket.assigns.selected_package

    case delete_package_and_assignments(id, package, scope) do
      :ok ->
        {:noreply,
         socket
         |> assign_package_views(scope)
         |> assign_first_party_catalog_view(
           socket.assigns.first_party_catalog_all,
           socket.assigns.first_party_release_tag
         )
         |> assign(:show_details_modal, false)
         |> assign(:selected_package, nil)
         |> assign(:assignments, [])
         |> assign(:assignment_form, default_assignment_form())
         |> assign(:authenticated_partition_preview, nil)
         |> assign(:recovery_confirmation, nil)
         |> assign(:versions, [])
         |> assign(:upload_url, nil)
         |> assign(:upload_token, nil)
         |> assign(:download_url, nil)
         |> assign(:download_token, nil)
         |> assign(:blob_present, nil)
         |> put_flash(:info, "Package deleted")}

      {:error, {:assignment_errors, errors}} ->
        {:noreply, put_flash(socket, :error, "Failed to remove assignments: #{Enum.join(errors, "; ")}")}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, "Failed to delete package: #{format_error(error)}")}
    end
  end

  defp delete_package_and_assignments(id, package, scope) do
    assignment_errors =
      id
      |> list_assignments(scope)
      |> Enum.reduce([], fn assignment, errors ->
        case Assignments.delete(assignment.id, scope: scope) do
          {:ok, _} -> errors
          :ok -> errors
          {:error, error} -> [format_error(error) | errors]
        end
      end)

    case assignment_errors do
      [] ->
        _ = maybe_delete_blob(package)

        case Packages.delete(id, scope: scope) do
          :ok -> :ok
          {:ok, _package} -> :ok
          {:error, error} -> {:error, error}
        end

      errors ->
        {:error, {:assignment_errors, Enum.reverse(errors)}}
    end
  end

  defp handle_assignment_upsert(socket, scope, attrs) do
    case existing_assignment(socket.assigns.assignments, attrs.agent_uid) do
      nil ->
        create_assignment(socket, scope, attrs)

      assignment ->
        cond do
          legacy_unbound_assignment?(assignment) ->
            {:noreply,
             put_flash(
               socket,
               :error,
               "This agent has an unbound legacy assignment. Use its recovery action instead of updating it."
             )}

          assignment_source(assignment) == :policy ->
            {:noreply,
             put_flash(
               socket,
               :error,
               "This agent already has this plugin assigned by policy. Change the policy to move versions."
             )}

          assignment_package_id(assignment) != attrs.plugin_package_id ->
            upgrade_assignment(socket, scope, assignment, attrs)

          true ->
            update_assignment(socket, scope, assignment, attrs)
        end
    end
  end

  defp create_assignment(socket, scope, attrs) do
    case Assignments.create(attrs, scope: scope) do
      {:ok, _assignment} ->
        {:noreply,
         socket
         |> assign(
           :assignments,
           list_plugin_assignments(socket.assigns.selected_package.plugin_id, scope)
         )
         |> assign(:assignment_form, default_assignment_form(socket.assigns.selected_package))
         |> assign(:show_details_modal, false)
         |> assignment_saved_flash("Assignment created", attrs.agent_uid)}

      {:error, error} ->
        Logger.error("Plugin assignment creation failed: #{inspect(error)}")
        {:noreply, put_flash(socket, :error, assignment_create_error_message(error))}
    end
  end

  defp update_assignment(socket, scope, assignment, attrs) do
    update_attrs =
      attrs
      |> Map.delete(:agent_uid)
      |> Map.delete(:plugin_package_id)

    case Assignments.update(assignment.id, update_attrs, scope: scope) do
      {:ok, _assignment} ->
        {:noreply,
         socket
         |> assign(
           :assignments,
           list_plugin_assignments(socket.assigns.selected_package.plugin_id, scope)
         )
         |> assign(:assignment_form, default_assignment_form(socket.assigns.selected_package))
         |> assign(:show_details_modal, false)
         |> assignment_saved_flash("Assignment updated", assignment.agent_uid)}

      {:error, error} ->
        Logger.error("Plugin assignment update failed for #{assignment.id}: #{inspect(error)}")

        {:noreply, put_flash(socket, :error, "Failed to update assignment: #{format_error(error)}")}
    end
  end

  defp upgrade_assignment(socket, scope, assignment, attrs) do
    case Assignments.upgrade(assignment.id, attrs.plugin_package_id, scope: scope, attrs: attrs) do
      {:ok, _assignment} ->
        {:noreply,
         socket
         |> assign(
           :assignments,
           list_plugin_assignments(socket.assigns.selected_package.plugin_id, scope)
         )
         |> assign(:assignment_form, default_assignment_form(socket.assigns.selected_package))
         |> assign(:show_details_modal, false)
         |> assignment_saved_flash("Assignment upgraded", attrs.agent_uid)}

      {:error, error} ->
        Logger.error("Plugin assignment upgrade failed for #{assignment.id}: #{inspect(error)}")

        {:noreply, put_flash(socket, :error, "Failed to upgrade assignment: #{format_error(error)}")}
    end
  end

  defp upgrade_assignment(socket, id, target_package_id) when is_binary(target_package_id) and target_package_id != "" do
    scope = socket.assigns.current_scope

    case Assignments.upgrade(id, target_package_id, scope: scope) do
      {:ok, _assignment} ->
        {:noreply,
         socket
         |> assign(:packages, list_packages(current_filters(socket), scope))
         |> assign(
           :assignments,
           list_plugin_assignments(socket.assigns.selected_package.plugin_id, scope)
         )
         |> assign(:versions, list_versions(socket.assigns.selected_package.plugin_id, scope))
         |> put_flash(:info, "Assignment upgraded")}

      {:error, error} ->
        Logger.error("Plugin assignment upgrade failed for #{id}: #{inspect(error)}")

        {:noreply, put_flash(socket, :error, "Failed to upgrade assignment: #{format_error(error)}")}
    end
  end

  defp upgrade_assignment(socket, _id, _target_package_id) do
    {:noreply, put_flash(socket, :error, "Select a plugin version to upgrade to.")}
  end

  defp perform_legacy_recovery(socket, id, kind) do
    scope = socket.assigns.current_scope

    result =
      case normalize_legacy_recovery_kind(kind) do
        {:ok, :manual} ->
          Assignments.reapprove_legacy_manual(id, %{confirm: true}, scope: scope)

        {:ok, :policy} ->
          Assignments.reconcile_legacy_policy(id, %{confirm: true}, scope: scope)

        :error ->
          {:error, :invalid_recovery_kind}
      end

    case result do
      {:ok, recovery} ->
        package = socket.assigns.selected_package

        socket =
          socket
          |> assign(:assignments, list_plugin_assignments(package.plugin_id, scope))
          |> reset_legacy_recovery_candidate_page()
          |> assign_legacy_recovery_candidates(scope)
          |> assign_credential_context(package)
          |> assign(:recovery_confirmation, nil)
          |> schedule_policy_recovery_poll(id, recovery)

        {:noreply, put_flash(socket, :info, legacy_recovery_success_message(kind, recovery))}

      {:error, error} ->
        package = socket.assigns.selected_package

        socket =
          socket
          |> assign(:assignments, list_plugin_assignments(package.plugin_id, scope))
          |> reset_legacy_recovery_candidate_page()
          |> assign_legacy_recovery_candidates(scope)
          |> assign_credential_context(package)
          |> assign(:recovery_confirmation, nil)

        {:noreply, put_flash(socket, :error, legacy_recovery_failure_message(error))}
    end
  end

  @sobelow_skip ["Traversal.FileModule"]
  defp handle_wasm_upload(socket, package, scope) do
    results =
      consume_uploaded_entries(socket, :wasm_blob, fn %{path: path}, _entry ->
        case File.read(path) do
          {:ok, payload} ->
            {:ok, payload}

          {:error, reason} ->
            Logger.error("plugin wasm upload read failed package_id=#{package.id} path=#{path} reason=#{inspect(reason)}")

            {:error, :read_failed}
        end
      end)

    case results do
      [payload] when is_binary(payload) ->
        upload_wasm_payload(socket, package, scope, payload)

      _ ->
        {:noreply,
         socket
         |> assign(:upload_errors, ["failed to read uploaded file"])
         |> put_flash(:error, "Failed to upload Wasm blob")}
    end
  end

  defp upload_wasm_payload(socket, package, scope, payload) do
    case Packages.upload_blob(package, payload, scope: scope) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign_package_urls(updated, scope)
         |> assign_package_views(scope)
         |> assign(:upload_errors, [])
         |> put_flash(:info, "Wasm blob uploaded")}

      {:error, error} ->
        error_message = format_error(error)

        Logger.error(
          "plugin wasm upload failed package_id=#{package.id} plugin_id=#{package.plugin_id} object_key=#{package.wasm_object_key || Storage.object_key_for(package)} error=#{inspect(error)}"
        )

        {:noreply,
         socket
         |> assign(:upload_errors, [error_message])
         |> put_flash(:error, "Failed to upload Wasm blob: #{error_message}")}
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
         |> assign_package_views(socket.assigns.current_scope)
         |> load_first_party_catalog()}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "First-party catalog import failed: #{format_error(reason)}")
         |> load_first_party_catalog()}
    end
  end

  def handle_async(:import_first_party_catalog, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(:import_running?, false)
     |> put_flash(:error, "First-party catalog import failed: #{format_error(reason)}")}
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
        <div class="flex flex-wrap items-center justify-between gap-4">
          <div>
            <h1 class="text-2xl font-semibold text-sr-ink">Plugins</h1>
            <p class="text-sm text-sr-muted">
              Review and publish Wasm plugin packages before they are distributed to agents.
            </p>
          </div>
          <div class="flex gap-2">
            <.ui_button variant="ghost" size="sm" phx-click="refresh">
              <.icon name="hero-arrow-path" class="size-4" /> Refresh
            </.ui_button>
            <.ui_button
              :if={@can_stage_plugins}
              variant="primary"
              size="sm"
              phx-click="open_create_modal"
            >
              <.icon name="hero-plus" class="size-4" /> New Plugin
            </.ui_button>
          </div>
        </div>

        <.ui_panel id="imported-plugin-packages">
          <:header>
            <div>
              <div class="text-sm font-semibold">Imported packages</div>
              <p class="text-xs text-sr-muted">
                {length(@packages)} package(s) available in this ServiceRadar instance.
              </p>
            </div>
            <form
              id="filter-imported-plugin-packages"
              phx-change="filter"
              class="flex flex-wrap items-center justify-end gap-2"
            >
              <label for="imported-plugin-status-filter" class="sr-only">Package status</label>
              <select
                id="imported-plugin-status-filter"
                name="status"
                class={ui_field_class(size: "sm")}
              >
                <option value="">All statuses</option>
                <option value="staged" selected={@filter_status == "staged"}>Staged</option>
                <option value="approved" selected={@filter_status == "approved"}>Approved</option>
                <option value="denied" selected={@filter_status == "denied"}>Denied</option>
                <option value="revoked" selected={@filter_status == "revoked"}>Revoked</option>
              </select>
              <label for="imported-plugin-source-filter" class="sr-only">Package source</label>
              <select
                id="imported-plugin-source-filter"
                name="source_type"
                class={ui_field_class(size: "sm")}
              >
                <option value="">All sources</option>
                <option value="upload" selected={@filter_source_type == "upload"}>Upload</option>
                <option value="github" selected={@filter_source_type == "github"}>GitHub</option>
                <option value="first_party" selected={@filter_source_type == "first_party"}>
                  First-party
                </option>
              </select>
            </form>
          </:header>

          <%= if @packages == [] do %>
            <div class="rounded-xl border border-dashed border-sr-line bg-sr-surface p-8 text-center">
              <div class="text-sm font-semibold text-sr-ink">No packages found</div>
              <p class="mt-1 text-xs text-sr-muted">
                Stage a plugin package to begin the review workflow.
              </p>
            </div>
          <% else %>
            <div class="sr-ui-table-shell">
              <table class={ui_table_class(size: "sm")}>
                <thead>
                  <tr class="text-xs uppercase tracking-wide text-sr-muted">
                    <th>Plugin</th>
                    <th>Version</th>
                    <th>Status</th>
                    <th>Source</th>
                    <th>Updated</th>
                    <th></th>
                  </tr>
                </thead>
                <tbody>
                  <%= for package <- paginated_items(@packages, @package_page, @package_page_size) do %>
                    <tr
                      id={"imported-plugin-package-#{package.id}"}
                      class="hover:bg-sr-subtle/30"
                    >
                      <td>
                        <div class="font-medium">{package.name}</div>
                        <div class="text-xs text-sr-muted font-mono">{package.plugin_id}</div>
                      </td>
                      <td class="text-xs">{package.version}</td>
                      <td>
                        <.status_badge status={package.status} />
                      </td>
                      <td>
                        <.ui_badge variant="ghost" size="xs">
                          {package.source_type}
                        </.ui_badge>
                      </td>
                      <td class="text-xs text-sr-muted">
                        <.user_time
                          id={"admin-plugin-package-#{package.id}-updated-at"}
                          value={package.updated_at || package.inserted_at}
                          timezone={@current_scope.user.timezone || "Etc/UTC"}
                          style={:compact}
                        />
                      </td>
                      <td>
                        <.ui_button
                          variant="ghost"
                          size="xs"
                          navigate={plugins_show_path(@plugins_base_path, package.id)}
                        >
                          View
                        </.ui_button>
                      </td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
              <.pagination_controls
                id_prefix="plugin-packages"
                event="package_page"
                page={@package_page}
                total_items={length(@packages)}
                page_size={@package_page_size}
              />
            </div>
          <% end %>
        </.ui_panel>

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

          <%= cond do %>
            <% catalog_rows == [] and is_nil(@first_party_catalog_error) -> %>
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

      <.details_modal
        :if={@show_details_modal}
        package={@selected_package}
        can_approve_plugins={@can_approve_plugins}
        review_form={@review_form}
        assignments={@assignments}
        agents={@agents}
        assignment_form={@assignment_form}
        assignment_coverage={@assignment_coverage}
        credential_fields={@credential_fields}
        credential_coverage={@credential_coverage}
        authenticated_partition_preview={@authenticated_partition_preview}
        recovery_confirmation={@recovery_confirmation}
        can_assign_plugins={@can_assign_plugins}
        can_reconcile_credential_rules={@can_reconcile_credential_rules}
        versions={@versions}
        blob_present={@blob_present}
        uploads={@uploads}
        upload_errors={@upload_errors}
        verification_policy={@verification_policy}
        upload_url={@upload_url}
        upload_token={@upload_token}
        upload_expires_at={@upload_expires_at}
        download_url={@download_url}
        download_token={@download_token}
        download_expires_at={@download_expires_at}
        plugins_base_path={@plugins_base_path}
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

  defp details_modal(assigns) do
    ~H"""
    <dialog id="plugin-package-modal-b" class="sr-ui-modal sr-ui-modal-open" phx-hook="DialogTopLayer">
      <div class="sr-ui-modal-box sr-ui-modal-box-lg">
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

        <div class="flex flex-wrap items-start justify-between gap-4">
          <div>
            <h3 class="text-lg font-semibold">{@package.name}</h3>
            <p class="text-xs text-sr-muted font-mono">{@package.plugin_id}</p>
            <p class="text-xs text-sr-muted">Version {@package.version}</p>
          </div>
          <div class="flex items-center gap-2">
            <.status_badge status={@package.status} />
            <.ui_badge variant="ghost" size="xs">{@package.source_type}</.ui_badge>
          </div>
        </div>

        <%= if policy_requires_verification?(@package, @verification_policy) do %>
          <div class="mt-3 rounded-xl border border-warning/30 bg-warning/10 p-3 text-xs text-warning">
            This package is unverified and will be blocked by the current verification policy.
          </div>
        <% end %>

        <div class="mt-4 grid grid-cols-1 lg:grid-cols-2 gap-4">
          <div class="space-y-4">
            <div class="rounded-xl border border-sr-line p-4">
              <div class="text-sm font-semibold">Requested Capabilities</div>
              <div class="mt-2 flex flex-wrap gap-2">
                <%= for cap <- requested_capabilities(@package) do %>
                  <.ui_badge
                    size="xs"
                    variant={if sensitive_capability?(cap), do: "warning", else: "ghost"}
                    title={
                      if sensitive_capability?(cap),
                        do: "Sensitive: grants network egress. Must be explicitly approved.",
                        else: nil
                    }
                  >
                    {cap}<span :if={sensitive_capability?(cap)} aria-hidden="true">&nbsp;⚠</span>
                  </.ui_badge>
                <% end %>
                <%= if requested_capabilities(@package) == [] do %>
                  <span class="text-xs text-sr-muted">None</span>
                <% end %>
              </div>
              <p
                :if={sensitive_requested_capabilities(@package) != []}
                class="mt-2 text-xs text-warning"
              >
                Sensitive (network-egress) capabilities are highlighted. They are only granted if
                they appear in the approved capabilities below — leave the field blank to accept all
                requested capabilities, or list every capability the plugin needs.
              </p>
            </div>

            <div class="rounded-xl border border-sr-line p-4">
              <div class="text-sm font-semibold">Requested Permissions</div>
              <pre class="mt-2 bg-sr-subtle/50 p-3 rounded-lg text-xs font-mono overflow-x-auto max-h-48">
    <%= format_json_value(requested_permissions(@package)) %>
    </pre>
            </div>

            <div class="rounded-xl border border-sr-line p-4">
              <div class="text-sm font-semibold">Requested Resources</div>
              <pre class="mt-2 bg-sr-subtle/50 p-3 rounded-lg text-xs font-mono overflow-x-auto max-h-48">
    <%= format_json_value(requested_resources(@package)) %>
    </pre>
            </div>

            <div class="rounded-xl border border-sr-line p-4">
              <div class="text-sm font-semibold">Northbound Actions</div>
              <div class="mt-3 space-y-3">
                <%= for action <- requested_actions(@package) do %>
                  <div class="rounded-lg border border-sr-line/70 bg-sr-surface/60 p-3">
                    <div class="flex flex-wrap items-start justify-between gap-2">
                      <div>
                        <div class="text-sm font-medium">
                          {action_label(action)}
                        </div>
                        <div class="font-mono text-[11px] text-sr-muted">
                          {action_id(action)} · v{action_version(action)}
                        </div>
                      </div>
                      <div class="flex flex-wrap gap-1">
                        <%= for scope <- action_scopes(action) do %>
                          <.ui_badge size="xs" variant="ghost">{scope}</.ui_badge>
                        <% end %>
                      </div>
                    </div>
                    <p :if={action_description(action)} class="mt-2 text-xs text-sr-muted">
                      {action_description(action)}
                    </p>
                    <div class="mt-2 flex flex-wrap gap-x-4 gap-y-1 text-[11px] text-sr-muted">
                      <span>Safety: {action_safety(action)}</span>
                      <span>Timeout: {action_timeout(action)}s</span>
                      <span>
                        Confirmation: {if action_requires_confirmation?(action),
                          do: "required",
                          else: "not required"}
                      </span>
                    </div>
                  </div>
                <% end %>
                <%= if requested_actions(@package) == [] do %>
                  <span class="text-xs text-sr-muted">None</span>
                <% end %>
              </div>
            </div>
          </div>

          <div class="space-y-4">
            <div class="rounded-xl border border-sr-line p-4">
              <div class="text-sm font-semibold">Manifest</div>
              <pre class="mt-2 bg-sr-subtle/50 p-3 rounded-lg text-xs font-mono overflow-x-auto max-h-64">
    <%= format_json_value(@package.manifest) %>
    </pre>
            </div>

            <div class="rounded-xl border border-sr-line p-4">
              <div class="text-sm font-semibold">Config Schema</div>
              <pre class="mt-2 bg-sr-subtle/50 p-3 rounded-lg text-xs font-mono overflow-x-auto max-h-48">
    <%= format_json_value(@package.config_schema) %>
    </pre>
            </div>

            <div class="rounded-xl border border-sr-line p-4">
              <div class="text-sm font-semibold">Display Contract</div>
              <pre class="mt-2 bg-sr-subtle/50 p-3 rounded-lg text-xs font-mono overflow-x-auto max-h-48">
    <%= format_json_value(@package.display_contract) %>
    </pre>
            </div>

            <div class="rounded-xl border border-sr-line p-4 space-y-2">
              <div class="text-sm font-semibold">Runtime Display Contracts</div>
              <p class="text-xs text-sr-muted">
                Contracts this package ships, resolved at runtime by the UI. A package needs no
                web-ng release to render its own signals; a contract listed as refused renders
                through the generic view instead.
              </p>
              <div :if={@package.display_contracts == %{}} class="text-xs text-sr-muted">
                This package ships no display contracts.
              </div>
              <div
                :for={key <- Enum.sort(Map.keys(@package.display_contracts))}
                class="text-xs font-mono"
              >
                {key}
              </div>
              <div
                :for={diagnostic <- display_contract_diagnostics(@package)}
                class="text-xs text-warning"
              >
                {diagnostic.source}: {diagnostic.reason}
              </div>
            </div>

            <div class="rounded-xl border border-sr-line p-4 space-y-2">
              <div class="text-sm font-semibold">Integrity & Verification</div>
              <div class="text-xs text-sr-muted">Content hash</div>
              <div class="text-xs font-mono">{format_hash(@package.content_hash)}</div>
              <div class="text-xs text-sr-muted mt-2">Blob stored</div>
              <div class="text-xs">{blob_status(@blob_present)}</div>
              <div class="text-xs text-sr-muted mt-2">GPG verification</div>
              <div class="text-xs">
                <%= if @package.gpg_verified_at do %>
                  Verified
                  <.user_time
                    id={"admin-plugin-package-#{@package.id}-gpg-verified-at"}
                    value={@package.gpg_verified_at}
                    timezone={@current_scope.user.timezone || "Etc/UTC"}
                    style={:compact}
                  />{gpg_key_suffix(@package.gpg_key_id)}
                <% else %>
                  {gpg_status(@package.gpg_key_id)}
                <% end %>
              </div>
              <div class="text-xs text-sr-muted mt-2">Signature metadata</div>
              <div class="text-xs font-mono">{signature_status(@package.signature)}</div>
            </div>

            <div
              :if={@package.source_type == :first_party}
              class="rounded-xl border border-sr-line p-4 space-y-2"
            >
              <div class="text-sm font-semibold">First-party Provenance</div>
              <div class="text-xs text-sr-muted">Release</div>
              <div class="text-xs font-mono">{@package.source_release_tag}</div>
              <div class="text-xs text-sr-muted mt-2">OCI reference</div>
              <div class="text-xs font-mono break-all">{@package.source_oci_ref}</div>
              <div class="text-xs text-sr-muted mt-2">OCI digest</div>
              <div class="text-xs font-mono break-all">{@package.source_oci_digest}</div>
              <div class="text-xs text-sr-muted mt-2">Bundle digest</div>
              <div class="text-xs font-mono break-all">{@package.source_bundle_digest}</div>
              <div class="text-xs text-sr-muted mt-2">Verification</div>
              <div class="text-xs">{@package.verification_status || "unknown"}</div>
            </div>

            <div class="rounded-xl border border-sr-line p-4 space-y-3">
              <div class="text-sm font-semibold">Upload Wasm Blob</div>
              <p class="text-xs text-sr-muted">
                Upload the compiled `.wasm` binary to complete this package.
              </p>

              <.form
                for={%{}}
                phx-change="wasm_upload_change"
                phx-submit="upload_wasm"
                class="space-y-3"
              >
                <.live_file_input
                  upload={@uploads.wasm_blob}
                  class={
                    ui_field_class(
                      class:
                        "w-full file:mr-3 file:rounded-sr-control file:border-0 file:bg-sr-subtle file:px-3 file:py-1.5 file:text-sm file:font-semibold file:text-sr-ink"
                    )
                  }
                  phx-change="wasm_upload_change"
                />

                <%= for entry <- @uploads.wasm_blob.entries do %>
                  <div class="flex items-center gap-2 text-xs">
                    <.icon name="hero-document-text" class="size-4 text-sr-brand" />
                    <span>{entry.client_name}</span>
                    <span class="text-sr-muted">
                      ({Float.round(entry.client_size / 1024, 1)} KB)
                    </span>
                    <%= for err <- upload_errors(@uploads.wasm_blob, entry) do %>
                      <span class="text-error text-xs">{wasm_upload_error(err)}</span>
                    <% end %>
                  </div>
                <% end %>

                <div class="flex justify-end">
                  <.ui_button
                    type="submit"
                    disabled={@uploads.wasm_blob.entries == []}
                    size="sm"
                    variant="primary"
                  >
                    Upload Wasm
                  </.ui_button>
                </div>
              </.form>

              <%= if @upload_errors != [] do %>
                <div class="rounded-lg border border-error/40 bg-error/5 p-2 text-xs text-error">
                  <%= for error <- @upload_errors do %>
                    <div>{error}</div>
                  <% end %>
                </div>
              <% end %>
            </div>

            <div class="rounded-xl border border-sr-line p-4 space-y-2">
              <div class="text-sm font-semibold">Wasm Package Requests</div>
              <div class="text-xs text-sr-muted">
                Upload endpoint expires
                <.user_time
                  id="admin-plugin-upload-endpoint-expires-at"
                  value={@upload_expires_at}
                  timezone={@current_scope.user.timezone || "Etc/UTC"}
                  style={:compact}
                />
              </div>
              <pre class="bg-sr-subtle/50 p-3 rounded-lg text-xs font-mono overflow-x-auto">
    <%= @upload_url %>
    </pre>
              <div class="text-xs text-sr-muted">
                Upload token
              </div>
              <pre class="bg-sr-subtle/50 p-3 rounded-lg text-xs font-mono overflow-x-auto">
    <%= @upload_token %>
    </pre>
              <div class="text-xs text-sr-muted">
                Download endpoint expires
                <.user_time
                  id="admin-plugin-download-endpoint-expires-at"
                  value={@download_expires_at}
                  timezone={@current_scope.user.timezone || "Etc/UTC"}
                  style={:compact}
                />
              </div>
              <pre class="bg-sr-subtle/50 p-3 rounded-lg text-xs font-mono overflow-x-auto">
    <%= @download_url %>
    </pre>
              <div class="text-xs text-sr-muted">
                Download token
              </div>
              <pre class="bg-sr-subtle/50 p-3 rounded-lg text-xs font-mono overflow-x-auto">
    <%= @download_token %>
    </pre>
              <div class="text-xs text-sr-muted">
                Example download
              </div>
              <pre class="bg-sr-subtle/50 p-3 rounded-lg text-xs font-mono overflow-x-auto">
    <%= if @download_url && @download_token do %>curl -fsSL -X POST -H "x-serviceradar-plugin-token: <%= @download_token %>" "<%= @download_url %>" -o plugin.wasm<% end %>
    </pre>
            </div>

            <div class="rounded-xl border border-sr-line p-4">
              <div class="text-sm font-semibold">Version History</div>
              <%= if @versions == [] do %>
                <p class="mt-2 text-xs text-sr-muted">No other versions found.</p>
              <% else %>
                <div class="mt-2 space-y-2">
                  <%= for version <- @versions do %>
                    <div class="flex items-center justify-between text-xs">
                      <div>
                        <span class="font-medium">{version.version}</span>
                        <span class="text-sr-muted">• {version.status}</span>
                        <%= if version.id == @package.id do %>
                          <.ui_badge size="xs" variant="ghost" class="ml-2">current</.ui_badge>
                        <% end %>
                      </div>
                      <.link
                        navigate={plugins_show_path(@plugins_base_path, version.id)}
                        class="text-sr-brand hover:underline"
                      >
                        View
                      </.link>
                    </div>
                  <% end %>
                </div>
              <% end %>
            </div>
          </div>
        </div>

        <div class="mt-6 grid grid-cols-1 lg:grid-cols-2 gap-4">
          <div class="rounded-xl border border-sr-line p-4 space-y-3">
            <div class="text-sm font-semibold">Assignments</div>
            <%= if @recovery_confirmation do %>
              <div
                id="legacy-recovery-confirmation"
                role="alert"
                class={
                  ui_alert_class(variant: "warning", class: "alert-vertical sm:alert-horizontal")
                }
              >
                <div>
                  <div class="font-semibold">{legacy_confirmation_title(@recovery_confirmation)}</div>
                  <p class="mt-1 text-xs">
                    {legacy_confirmation_message(@recovery_confirmation)}
                  </p>
                </div>
                <div class="flex shrink-0 flex-wrap gap-2">
                  <.ui_button
                    id="confirm-legacy-recovery"
                    type="button"
                    phx-click="confirm_legacy_recovery"
                    phx-value-id={@recovery_confirmation.id}
                    phx-value-kind={@recovery_confirmation.kind}
                    size="sm"
                    variant="warning"
                  >
                    {legacy_confirmation_action_label(@recovery_confirmation)}
                  </.ui_button>
                  <.ui_button
                    id="cancel-legacy-recovery"
                    type="button"
                    phx-click="cancel_legacy_recovery"
                    size="sm"
                    variant="ghost"
                  >
                    Cancel
                  </.ui_button>
                </div>
              </div>
            <% end %>
            <%= if @assignments == [] do %>
              <p class="text-xs text-sr-muted">No agents assigned yet.</p>
            <% else %>
              <div class="space-y-2">
                <%= for assignment <- @assignments do %>
                  <% current_package = package_for_assignment(assignment, @versions) %>
                  <% upgrade_target = latest_upgrade_target(assignment, @versions) %>
                  <% approved_targets = approved_version_targets(assignment, @versions) %>
                  <% latest_approved? =
                    latest_approved_assignment_version?(assignment, @versions) %>
                  <% legacy_kind = legacy_recovery_kind_for_display(assignment) %>
                  <% legacy_compatibility = legacy_recovery_compatibility_message(assignment) %>
                  <% legacy_partition_context = legacy_authenticated_partition_message(assignment) %>
                  <% manual_recovery = legacy_manual_recovery_status(assignment) %>
                  <% manual_legacy_state = legacy_manual_presentation_state(assignment) %>
                  <% policy_recovery = legacy_policy_recovery_status(assignment) %>
                  <% credential_rule_recovery? = legacy_credential_rule_recovery?(assignment) %>
                  <div
                    id={"assignment-#{assignment.id}"}
                    class="rounded-lg border border-sr-line/70 bg-sr-surface/60 p-3 text-xs"
                  >
                    <div class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
                      <div>
                        <div class="font-medium flex flex-wrap items-center gap-2">
                          {assignment.agent_uid}
                          <%= if assignment.enabled == false do %>
                            <.ui_badge size="xs" variant="ghost">disabled</.ui_badge>
                          <% end %>
                          <%= if assignment.source == :policy do %>
                            <.ui_badge size="xs" variant="ghost">policy</.ui_badge>
                          <% end %>
                          <%= if legacy_kind == :manual and manual_legacy_state == :completed do %>
                            <.ui_badge size="xs" variant="success">legacy recovered</.ui_badge>
                          <% else %>
                            <%= if legacy_kind do %>
                              <.ui_badge size="xs" variant="warning">legacy unbound</.ui_badge>
                            <% end %>
                          <% end %>
                          <%= if uncovered_assignment?(@assignment_coverage, assignment.id) do %>
                            <.ui_badge
                              size="xs"
                              variant="warning"
                              title={coverage_badge_title(@assignment_coverage, assignment.id)}
                            >
                              no credential rule coverage
                            </.ui_badge>
                          <% end %>
                        </div>
                        <div class="text-sr-muted">
                          every {assignment.interval_seconds}s, timeout {assignment.timeout_seconds}s
                        </div>
                        <div
                          id={"assignment-version-#{assignment.id}"}
                          class="text-sr-muted"
                        >
                          version {package_version(current_package)}
                          <%= if upgrade_target do %>
                            <span>-> newer {upgrade_target.version}</span>
                          <% else %>
                            <%= if latest_approved? do %>
                              <span class="text-success">· latest approved</span>
                            <% end %>
                          <% end %>
                        </div>
                      </div>
                      <div class="flex flex-wrap items-center gap-2">
                        <%= if legacy_kind == :manual and manual_legacy_state == :actionable do %>
                          <.ui_button
                            id={"request-manual-reapproval-#{assignment.id}"}
                            type="button"
                            phx-click="request_legacy_recovery"
                            phx-value-id={assignment.id}
                            phx-value-kind="manual"
                            disabled={
                              not manual_recovery_action_enabled?(
                                @can_assign_plugins,
                                manual_recovery
                              )
                            }
                            size="xs"
                            variant="warning"
                          >
                            {manual_recovery_action_label(manual_recovery)}
                          </.ui_button>
                        <% end %>
                        <%= if legacy_kind == :policy do %>
                          <.ui_button
                            id={"request-policy-reconciliation-#{assignment.id}"}
                            type="button"
                            phx-click="request_legacy_recovery"
                            phx-value-id={assignment.id}
                            phx-value-kind="policy"
                            disabled={
                              not policy_recovery_action_enabled?(
                                @can_assign_plugins,
                                @can_reconcile_credential_rules,
                                credential_rule_recovery?,
                                policy_recovery
                              )
                            }
                            size="xs"
                            variant="warning"
                          >
                            {policy_recovery_action_label(
                              @can_reconcile_credential_rules,
                              credential_rule_recovery?,
                              policy_recovery
                            )}
                          </.ui_button>
                        <% end %>
                        <%= if is_nil(legacy_kind) and assignment.source == :policy do %>
                          <span class="text-[11px] text-sr-muted">managed by policy</span>
                        <% end %>
                        <%= if is_nil(legacy_kind) and assignment.source != :policy do %>
                          <%= if upgrade_target do %>
                            <.ui_button
                              id={"upgrade-assignment-#{assignment.id}"}
                              type="button"
                              phx-click="upgrade_assignment"
                              phx-value-id={assignment.id}
                              phx-value-target-package-id={upgrade_target.id}
                              data-confirm={"Upgrade this assignment to #{upgrade_target.version}?"}
                              size="xs"
                              variant="primary"
                            >
                              Upgrade
                            </.ui_button>
                          <% end %>
                          <%= if approved_targets != [] do %>
                            <form
                              id={"assignment-version-form-#{assignment.id}"}
                              phx-submit="upgrade_assignment"
                              phx-value-id={assignment.id}
                              class="flex items-center gap-1"
                            >
                              <select
                                id={"assignment-version-select-#{assignment.id}"}
                                name="assignment_upgrade[target_package_id]"
                                aria-label={"Change version for #{assignment.agent_uid}"}
                                required
                                class={
                                  ui_field_class(size: "xs", class: "w-auto min-w-[4.75rem] shrink-0")
                                }
                              >
                                <option value="" selected disabled>Change version</option>
                                <%= for target <- approved_targets do %>
                                  <option value={target.id}>
                                    {assignment_version_option_label(target, current_package)}
                                  </option>
                                <% end %>
                              </select>
                              <.ui_button
                                id={"apply-assignment-version-#{assignment.id}"}
                                type="submit"
                                size="xs"
                                variant="ghost"
                              >
                                Apply
                              </.ui_button>
                            </form>
                          <% end %>
                        <% end %>
                        <%= if is_nil(legacy_kind) do %>
                          <.ui_button
                            type="button"
                            phx-click="delete_assignment"
                            phx-value-id={assignment.id}
                            data-confirm="Remove this assignment?"
                            size="xs"
                            variant="ghost"
                          >
                            Remove
                          </.ui_button>
                        <% end %>
                      </div>
                    </div>
                    <%= if legacy_kind == :manual and manual_legacy_state != :actionable do %>
                      <div
                        id={"legacy-assignment-recovery-#{assignment.id}"}
                        role="status"
                        class={[
                          "mt-3 rounded-md border px-3 py-2 text-xs",
                          manual_legacy_state == :completed &&
                            "border-success/30 bg-success/5 text-sr-muted",
                          manual_legacy_state != :completed &&
                            "border-sr-line bg-sr-subtle/30 text-sr-muted"
                        ]}
                      >
                        <div class="font-medium">
                          {legacy_manual_presentation_title(manual_legacy_state)}
                        </div>
                        <p class="mt-1">
                          {legacy_manual_presentation_message(manual_legacy_state)}
                        </p>
                      </div>
                    <% else %>
                      <%= if legacy_kind do %>
                        <div
                          id={"legacy-assignment-recovery-#{assignment.id}"}
                          role="status"
                          class={ui_alert_class(variant: "warning", class: "alert-vertical mt-3")}
                        >
                          <div>
                            <div class="font-semibold">{legacy_recovery_label(legacy_kind)}</div>
                            <p class="mt-1 text-xs">{legacy_recovery_message(legacy_kind)}</p>
                            <p
                              :if={legacy_kind == :policy and legacy_recovery_owner_label(assignment)}
                              class="mt-1 text-xs"
                            >
                              Owner: {legacy_recovery_owner_label(assignment)}
                            </p>
                            <p :if={legacy_compatibility} class="mt-1 text-xs">
                              {legacy_compatibility}
                            </p>
                            <p :if={legacy_partition_context} class="mt-1 text-xs">
                              {legacy_partition_context}
                            </p>
                            <p
                              :if={
                                legacy_kind == :manual and
                                  legacy_manual_recovery_message(manual_recovery)
                              }
                              class="mt-1 text-xs font-medium"
                            >
                              {legacy_manual_recovery_message(manual_recovery)}
                            </p>
                            <p
                              :if={
                                legacy_kind == :policy and
                                  legacy_policy_recovery_message(policy_recovery)
                              }
                              class="mt-1 text-xs font-medium"
                            >
                              {legacy_policy_recovery_message(policy_recovery)}
                            </p>
                            <p
                              :if={
                                legacy_kind == :policy and credential_rule_recovery? and
                                  not @can_reconcile_credential_rules
                              }
                              class="mt-1 text-xs"
                            >
                              You also need credential-management permission to reconcile this credential rule.
                            </p>
                          </div>
                        </div>
                      <% end %>
                    <% end %>
                  </div>
                <% end %>
              </div>
            <% end %>
          </div>

          <div class="rounded-xl border border-sr-line p-4 space-y-3">
            <div class="text-sm font-semibold">Assign to Agent</div>
            <.credential_rule_assignment_banner
              :if={
                producer_schedule_provisioned?(@package) or
                  (is_list(@credential_fields) and @credential_fields != [])
              }
              plugin_id={@package.plugin_id}
              coverage={@credential_coverage}
              producer_schedule?={producer_schedule_provisioned?(@package)}
            />
            <form
              :if={!producer_schedule_provisioned?(@package)}
              phx-submit="create_assignment"
              phx-change="assignment_change"
              class="space-y-3"
            >
              <div>
                <label class="flex items-center justify-between gap-2">
                  <span class="text-sm font-medium text-sr-ink">Agent</span>
                </label>
                <select name="assignment[agent_uid]" class={ui_field_class(class: "w-full")}>
                  <option value="">Select an agent</option>
                  <%= for agent <- @agents do %>
                    <option value={agent.uid} selected={@assignment_form["agent_uid"] == agent.uid}>
                      {agent_label(agent)}
                    </option>
                  <% end %>
                </select>
              </div>
              <%= if @authenticated_partition_preview do %>
                <div
                  id="authenticated-partition-preview"
                  role="status"
                  class={
                    ui_alert_class(
                      variant:
                        if(@authenticated_partition_preview.state == :available,
                          do: "info",
                          else: "warning"
                        ),
                      class: "flex-col"
                    )
                  }
                >
                  <%= if @authenticated_partition_preview.state == :available do %>
                    <div>
                      <div class="font-semibold">
                        Authenticated partition: {@authenticated_partition_preview.partition_id}
                      </div>
                      <p class="mt-1 text-xs">
                        Derived from this agent's current live mTLS control session. It is informational
                        only and will be resolved again when you save.
                      </p>
                    </div>
                  <% else %>
                    <div>
                      <div class="font-semibold">Authenticated partition: unavailable</div>
                      <p class="mt-1 text-xs">
                        {authenticated_partition_preview_message(@authenticated_partition_preview)}
                      </p>
                    </div>
                  <% end %>
                </div>
              <% end %>
              <div class="grid grid-cols-1 md:grid-cols-2 gap-3">
                <div>
                  <label class="flex items-center justify-between gap-2">
                    <span class="text-sm font-medium text-sr-ink">Interval (seconds)</span>
                  </label>
                  <input
                    type="number"
                    min={assignment_interval_min(@package)}
                    name="assignment[interval_seconds]"
                    value={@assignment_form["interval_seconds"]}
                    class={ui_field_class(class: "w-full")}
                  />
                </div>
                <div>
                  <label class="flex items-center justify-between gap-2">
                    <span class="text-sm font-medium text-sr-ink">Timeout (seconds)</span>
                  </label>
                  <input
                    type="number"
                    min={assignment_timeout_min(@package)}
                    name="assignment[timeout_seconds]"
                    value={@assignment_form["timeout_seconds"]}
                    class={ui_field_class(class: "w-full")}
                  />
                </div>
              </div>
              <%= if config_schema_present?(@package.config_schema) do %>
                <div class="rounded-lg border border-sr-line/70 bg-sr-surface/60 p-3 space-y-3">
                  <div class="text-xs font-semibold text-sr-muted">Configuration</div>
                  <.plugin_config_fields
                    schema={@package.config_schema}
                    params={assignment_params_map(@assignment_form)}
                    base_name="assignment[params]"
                    credential_coverage={@credential_coverage}
                  />
                </div>

                <details class="rounded-lg border border-sr-line/70 bg-sr-surface/60 p-3">
                  <summary class="cursor-pointer text-xs font-semibold text-sr-muted">
                    Raw Params (JSON)
                  </summary>
                  <div class="mt-3">
                    <textarea
                      name="assignment[params_raw]"
                      class={ui_field_class(mono: true, class: "w-full min-h-[80px] py-2.5 text-xs")}
                    ><%= assignment_params_raw(@assignment_form) %></textarea>
                  </div>
                </details>
              <% else %>
                <div class="grid grid-cols-1 md:grid-cols-2 gap-3">
                  <div>
                    <label class="flex items-center justify-between gap-2">
                      <span class="text-sm font-medium text-sr-ink">Params (JSON)</span>
                    </label>
                    <textarea
                      name="assignment[params]"
                      class={ui_field_class(mono: true, class: "w-full min-h-[80px] py-2.5 text-xs")}
                    ><%= assignment_params_raw(@assignment_form) %></textarea>
                  </div>
                  <div>
                    <label class="flex items-center justify-between gap-2">
                      <span class="text-sm font-medium text-sr-ink">Permissions Override (JSON)</span>
                    </label>
                    <textarea
                      name="assignment[permissions_override]"
                      class={ui_field_class(mono: true, class: "w-full min-h-[80px] py-2.5 text-xs")}
                    ><%= @assignment_form["permissions_override"] %></textarea>
                  </div>
                </div>
              <% end %>
              <%= if config_schema_present?(@package.config_schema) do %>
                <div>
                  <label class="flex items-center justify-between gap-2">
                    <span class="text-sm font-medium text-sr-ink">Permissions Override (JSON)</span>
                  </label>
                  <textarea
                    name="assignment[permissions_override]"
                    class={ui_field_class(mono: true, class: "w-full min-h-[80px] py-2.5 text-xs")}
                  ><%= @assignment_form["permissions_override"] %></textarea>
                </div>
              <% end %>
              <div>
                <label class="flex items-center justify-between gap-2">
                  <span class="text-sm font-medium text-sr-ink">Resources Override (JSON)</span>
                </label>
                <textarea
                  name="assignment[resources_override]"
                  class={ui_field_class(mono: true, class: "w-full min-h-[80px] py-2.5 text-xs")}
                ><%= @assignment_form["resources_override"] %></textarea>
              </div>
              <div class="flex justify-end">
                <.ui_button
                  type="submit"
                  disabled={
                    assignment_submit_disabled?(
                      @package,
                      @blob_present,
                      @authenticated_partition_preview
                    )
                  }
                  size="sm"
                  variant="primary"
                >
                  Assign
                </.ui_button>
              </div>
            </form>
            <%= if not producer_schedule_provisioned?(@package) and @package.status != :approved do %>
              <p class="text-xs text-sr-muted">
                Approve the package before assigning it to agents.
              </p>
            <% end %>
            <%= if not producer_schedule_provisioned?(@package) and @package.status == :approved and
                    not blob_present?(@blob_present) do %>
              <p class="text-xs text-warning">
                Upload the Wasm blob before assigning this package.
              </p>
            <% end %>
          </div>
        </div>

        <form
          class="mt-6 space-y-4"
          phx-submit={review_submit_action(@package)}
          phx-change="review_change"
        >
          <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
            <div>
              <label class="flex items-center justify-between gap-2">
                <span class="text-sm font-medium text-sr-ink">
                  Approved Capabilities (comma separated)
                </span>
              </label>
              <input
                type="text"
                name="review[approved_capabilities]"
                value={@review_form["approved_capabilities"]}
                class={ui_field_class(class: "w-full")}
                placeholder="Leave blank to accept requested capabilities"
              />
              <p class="mt-1 text-xs text-sr-muted">
                Blank grants every requested capability (including sensitive ones). If you list
                capabilities explicitly, include each sensitive capability the plugin needs (for
                example <code class="font-mono">http_request</code>) — anything omitted is denied.
              </p>
            </div>
            <div>
              <label class="flex items-center justify-between gap-2">
                <span class="text-sm font-medium text-sr-ink">Reason (for deny/revoke)</span>
              </label>
              <input
                type="text"
                name="review[denied_reason]"
                value={@review_form["denied_reason"]}
                class={ui_field_class(class: "w-full")}
                placeholder="Optional"
              />
            </div>
          </div>

          <div class="grid grid-cols-1 lg:grid-cols-2 gap-4">
            <div>
              <label class="flex items-center justify-between gap-2">
                <span class="text-sm font-medium text-sr-ink">Approved Permissions (JSON)</span>
              </label>
              <textarea
                name="review[approved_permissions]"
                class={ui_field_class(mono: true, class: "w-full min-h-[120px] py-2.5 text-xs")}
                placeholder="Leave blank to accept requested permissions"
              ><%= @review_form["approved_permissions"] %></textarea>
            </div>
            <div>
              <label class="flex items-center justify-between gap-2">
                <span class="text-sm font-medium text-sr-ink">Approved Resources (JSON)</span>
              </label>
              <textarea
                name="review[approved_resources]"
                class={ui_field_class(mono: true, class: "w-full min-h-[120px] py-2.5 text-xs")}
                placeholder="Leave blank to accept requested resources"
              ><%= @review_form["approved_resources"] %></textarea>
            </div>
          </div>

          <div class="flex flex-wrap justify-end gap-2 pt-2">
            <%= if @package.status == :staged do %>
              <.ui_button type="submit" disabled={!@can_approve_plugins} size="sm" variant="primary">
                Approve
              </.ui_button>
              <.ui_button
                type="button"
                phx-click="deny_package"
                phx-value-id={@package.id}
                disabled={!@can_approve_plugins}
                size="sm"
                variant="outline"
              >
                Deny
              </.ui_button>
              <p :if={!@can_approve_plugins} class="w-full text-right text-xs text-sr-muted">
                You do not have permission to approve or deny plugin packages.
              </p>
            <% end %>

            <%= if @package.status == :approved do %>
              <.ui_button
                type="button"
                phx-click="revoke_package"
                phx-value-id={@package.id}
                size="sm"
                variant="outline"
              >
                Revoke
              </.ui_button>
            <% end %>

            <%= if @package.status in [:denied, :revoked] do %>
              <.ui_button
                type="button"
                phx-click="restage_package"
                phx-value-id={@package.id}
                size="sm"
                variant="outline"
              >
                Move to Staged
              </.ui_button>
            <% end %>

            <.ui_button
              type="button"
              phx-click="delete_package"
              phx-value-id={@package.id}
              data-confirm="Delete this package and remove all assignments?"
              size="sm"
              variant="outline"
            >
              Delete Package
            </.ui_button>

            <.ui_button type="button" phx-click="close_details_modal" size="sm" variant="neutral">
              Close
            </.ui_button>
          </div>
        </form>
      </div>
      <form method="dialog" class="sr-ui-modal-backdrop">
        <button phx-click="close_details_modal">close</button>
      </form>
    </dialog>
    """
  end

  defp review_submit_action(package) do
    case package.status do
      :staged -> "approve_package"
      _ -> "noop"
    end
  end

  defp list_packages(filters, scope) do
    Packages.list(filters, scope: scope)
  end

  defp assign_package_views(socket, scope) do
    catalog_packages = list_packages(%{}, scope)
    filters = current_filters(socket)

    packages =
      if map_size(filters) == 0 do
        catalog_packages
      else
        list_packages(filters, scope)
      end

    socket
    |> assign(:catalog_packages, catalog_packages)
    |> assign(:packages, packages)
  end

  defp list_assignments(package_id, scope) do
    Assignments.list(%{"plugin_package_id" => package_id}, scope: scope)
  end

  defp list_plugin_assignments(plugin_id, scope) do
    plugin_id
    |> then(&Assignments.list(%{"plugin_id" => &1}, scope: scope))
    |> Enum.reject(&legacy_unbound_assignment?/1)
  end

  defp assign_legacy_recovery_candidates(socket, scope) do
    page = socket.assigns.legacy_recovery_candidate_page
    after_id = Map.get(socket.assigns.legacy_recovery_candidate_after_ids, page)

    {candidates, more?, next_after_id} =
      if socket.assigns.can_assign_plugins,
        do: list_legacy_recovery_candidates(scope, after_id),
        else: {[], false, nil}

    after_ids =
      socket.assigns.legacy_recovery_candidate_after_ids
      |> Map.put(page, after_id)
      |> update_legacy_recovery_candidate_after_ids(page, more?, next_after_id)

    socket
    |> assign(:legacy_recovery_candidates, candidates)
    |> assign(:legacy_recovery_candidates_more?, more?)
    |> assign(:legacy_recovery_candidate_after_ids, after_ids)
  end

  defp list_legacy_recovery_candidates(scope, after_id) do
    case Assignments.list_legacy(
           scope: scope,
           limit: @legacy_recovery_candidate_page_size + 1,
           after_id: after_id
         ) do
      {:ok, candidates} ->
        {page_candidates, overflow} = Enum.split(candidates, @legacy_recovery_candidate_page_size)

        actionable_candidates =
          page_candidates
          |> Enum.map(&enrich_legacy_recovery_candidate(&1, scope))
          |> Enum.filter(&legacy_recovery_candidate_actionable?/1)

        {actionable_candidates, overflow != [], legacy_recovery_candidate_after_id(page_candidates)}

      {:error, _reason} ->
        {[], false, nil}
    end
  end

  defp legacy_recovery_candidate_after_id([]), do: nil

  defp legacy_recovery_candidate_after_id(candidates) do
    candidates
    |> List.last()
    |> assignment_value(:legacy_assignment_id)
  end

  defp update_legacy_recovery_candidate_after_ids(after_ids, page, true, next_after_id) when is_binary(next_after_id) do
    Map.put(after_ids, page + 1, next_after_id)
  end

  defp update_legacy_recovery_candidate_after_ids(after_ids, page, _more?, _next_after_id) do
    Map.delete(after_ids, page + 1)
  end

  defp reset_legacy_recovery_candidate_page(socket) do
    socket
    |> assign(:legacy_recovery_candidate_page, 1)
    |> assign(:legacy_recovery_candidate_after_ids, %{1 => nil})
    |> assign(:legacy_recovery_candidates_more?, false)
  end

  defp enrich_legacy_recovery_candidate(candidate, scope) do
    case Assignments.legacy_detail(candidate.legacy_assignment_id, scope: scope) do
      {:ok, detail} -> Map.put(candidate, :recovery, detail)
      {:error, _reason} -> candidate
    end
  end

  # Quarantined rows deliberately remain disabled and partition-unbound as
  # historical evidence, even after their replacement succeeds. Keep them out
  # of the actionable candidate count once the safe, redacted terminal state
  # proves that no operator action remains.
  defp legacy_recovery_candidate_actionable?(candidate) do
    case legacy_recovery_kind_for_display(candidate) do
      :manual -> legacy_manual_presentation_state(candidate) == :actionable
      :policy -> policy_recovery_state(legacy_policy_recovery_status(candidate)) != :reconciled
      # Unsupported historical owners and unavailable projections remain visible
      # in package detail, but are not recovery actions or candidate work.
      :unsupported_policy_owner -> false
      :recovery_unavailable -> false
      _ -> false
    end
  end

  defp schedule_policy_recovery_poll(socket, legacy_assignment_id, recovery) when is_map(recovery) do
    case legacy_recovery_result_state(recovery) do
      state when state in [:queued, :pending] ->
        schedule_policy_recovery_poll(socket, legacy_assignment_id, make_ref(), 0)

      _ ->
        socket
    end
  end

  defp schedule_policy_recovery_poll(socket, _legacy_assignment_id, _recovery), do: socket

  defp schedule_policy_recovery_poll(socket, legacy_assignment_id, poll_ref, attempt)
       when is_binary(legacy_assignment_id) and is_reference(poll_ref) and is_integer(attempt) and
              attempt < @policy_recovery_poll_attempt_limit do
    next_attempt = attempt + 1

    if connected?(socket) do
      Process.send_after(
        self(),
        {:refresh_policy_recovery, legacy_assignment_id, poll_ref, next_attempt},
        @policy_recovery_poll_delay_ms
      )
    end

    polls =
      Map.put(socket.assigns.policy_recovery_polls, legacy_assignment_id, %{
        ref: poll_ref,
        attempt: next_attempt
      })

    assign(socket, :policy_recovery_polls, polls)
  end

  defp schedule_policy_recovery_poll(socket, legacy_assignment_id, _poll_ref, _attempt) do
    clear_policy_recovery_poll(socket, legacy_assignment_id)
  end

  defp clear_policy_recovery_poll(socket, legacy_assignment_id) do
    assign(
      socket,
      :policy_recovery_polls,
      Map.delete(socket.assigns.policy_recovery_polls, legacy_assignment_id)
    )
  end

  defp current_policy_recovery_poll?(%{ref: poll_ref, attempt: attempt}, poll_ref, attempt), do: true

  defp current_policy_recovery_poll?(_poll, _poll_ref, _attempt), do: false

  defp policy_recovery_state_for_assignment(assignments, legacy_assignment_id) do
    assignments
    |> Enum.find(&(assignment_id(&1) == legacy_assignment_id))
    |> legacy_policy_recovery_status()
    |> value_from_map(:state)
  end

  defp list_versions(plugin_id, scope) do
    Packages.list(%{"plugin_id" => plugin_id}, scope: scope)
  end

  defp list_agents(scope) do
    Agent
    |> Ash.Query.for_read(:read)
    |> Ash.Query.limit(200)
    |> Ash.Query.sort(name: :asc)
    |> Ash.read!(scope: scope)
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

  defp load_first_party_catalog(%{assigns: %{selected_repository: nil}} = socket) do
    socket
    |> assign_first_party_catalog_view([], socket.assigns[:first_party_release_tag])
    |> assign(:first_party_catalog_error, nil)
    |> assign(
      :first_party_catalog_status,
      "No enabled plugin repository. Add one, or enable an existing one, to browse a catalog."
    )
  end

  defp load_first_party_catalog(socket) do
    case FirstPartyImporter.list_recent_plugins_with_summary(
           repository_import_attrs(socket.assigns.selected_repository, socket.assigns.current_scope),
           first_party_sync_limit()
         ) do
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
  # It stays visible in the "Imported packages" list above, which is not scoped.
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

  defp safe_import_failure_reason(_reason), do: "import was rejected"

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

  attr(:id_prefix, :string, required: true)
  attr(:event, :string, required: true)
  attr(:page, :integer, required: true)
  attr(:total_items, :integer, required: true)
  attr(:page_size, :integer, required: true)

  defp pagination_controls(assigns) do
    page_count = page_count(assigns.total_items, assigns.page_size)
    {first_item, last_item} = page_range(assigns.total_items, assigns.page, assigns.page_size)

    assigns =
      assign(assigns,
        page_count: page_count,
        first_item: first_item,
        last_item: last_item
      )

    ~H"""
    <div
      :if={@total_items > 0}
      class="flex flex-wrap items-center justify-between gap-3 border-t border-sr-line px-4 py-3 text-xs text-sr-muted"
    >
      <span>
        Showing {@first_item}-{@last_item} of {@total_items}
      </span>
      <div class={ui_join_class()}>
        <.ui_button
          id={"#{@id_prefix}-prev-page"}
          type="button"
          phx-click={@event}
          phx-value-page={@page - 1}
          disabled={@page <= 1}
          size="xs"
          variant="neutral"
        >
          Previous
        </.ui_button>
        <.ui_button type="button" disabled size="xs" variant="ghost">
          Page {@page} of {@page_count}
        </.ui_button>
        <.ui_button
          id={"#{@id_prefix}-next-page"}
          type="button"
          phx-click={@event}
          phx-value-page={@page + 1}
          disabled={@page >= @page_count}
          size="xs"
          variant="neutral"
        >
          Next
        </.ui_button>
      </div>
    </div>
    """
  end

  defp paginated_items(items, page, page_size) when is_list(items) do
    page = clamp_page(page, length(items), page_size)

    items
    |> Enum.drop((page - 1) * page_size)
    |> Enum.take(page_size)
  end

  defp page_count(total_items, page_size) when is_integer(total_items) and total_items > 0,
    do: max(1, ceil(total_items / page_size))

  defp page_count(_total_items, _page_size), do: 1

  defp page_range(total_items, page, page_size) when total_items > 0 do
    page = clamp_page(page, total_items, page_size)
    first_item = (page - 1) * page_size + 1
    last_item = min(page * page_size, total_items)

    {first_item, last_item}
  end

  defp page_range(_total_items, _page, _page_size), do: {0, 0}

  defp clamp_page(page, total_items, page_size) do
    page =
      case page do
        page when is_integer(page) -> page
        page when is_binary(page) -> page |> Integer.parse() |> parsed_page()
        _ -> 1
      end

    page
    |> max(1)
    |> min(page_count(total_items, page_size))
  end

  defp parsed_page({page, _rest}), do: page
  defp parsed_page(:error), do: 1

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
    agents = list_agents(scope)
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

  defp current_path_from_url(nil), do: nil

  defp current_path_from_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{path: path} when is_binary(path) -> path
      _ -> nil
    end
  end

  defp plugins_base_path_from_url(url) do
    path = current_path_from_url(url) || ""

    if String.starts_with?(path, "/settings/agents/plugins") do
      "/settings/agents/plugins"
    else
      "/admin/plugins"
    end
  end

  defp plugins_index_path(socket) do
    socket.assigns[:plugins_base_path] || "/admin/plugins"
  end

  defp plugins_show_path(socket, id) when is_map(socket) do
    plugins_index_path(socket) <> "/#{id}"
  end

  defp plugins_show_path(base_path, id) when is_binary(base_path) do
    base_path <> "/#{id}"
  end

  defp plugin_verification_policy do
    config = Application.get_env(:serviceradar_web_ng, :plugin_verification, [])

    %{
      require_gpg_for_github: Keyword.get(config, :require_gpg_for_github, false),
      allow_unsigned_uploads: Keyword.get(config, :allow_unsigned_uploads, true)
    }
  end

  defp policy_requires_verification?(package, policy) do
    source =
      case package.source_type do
        value when is_atom(value) -> Atom.to_string(value)
        value when is_binary(value) -> value
        _ -> ""
      end

    policy.require_gpg_for_github && source == "github" && is_nil(package.gpg_verified_at)
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

  defp current_filters(socket) do
    %{}
    |> maybe_put_filter("status", socket.assigns.filter_status)
    |> maybe_put_filter("source_type", socket.assigns.filter_source_type)
  end

  defp assign_package_urls(socket, package, scope) do
    case ensure_object_key(package, scope) do
      {:ok, package} ->
        {upload_token, upload_expires_at} =
          Storage.sign_token(
            :upload,
            package.id,
            package.wasm_object_key,
            Storage.upload_ttl_seconds()
          )

        {download_token, download_expires_at} =
          Storage.sign_token(
            :download,
            package.id,
            package.wasm_object_key,
            Storage.download_ttl_seconds()
          )

        socket
        |> assign(:selected_package, package)
        |> assign(:upload_url, Storage.upload_url(package.id))
        |> assign(:upload_token, upload_token)
        |> assign(:upload_expires_at, upload_expires_at)
        |> assign(:download_url, Storage.download_url(package.id))
        |> assign(:download_token, download_token)
        |> assign(:download_expires_at, download_expires_at)
        |> assign(:blob_present, Storage.blob_exists?(package.wasm_object_key))

      {:error, _error} ->
        socket
        |> assign(:upload_url, nil)
        |> assign(:upload_token, nil)
        |> assign(:download_url, nil)
        |> assign(:download_token, nil)
        |> assign(:blob_present, nil)
    end
  end

  defp ensure_object_key(package, scope) do
    if package.wasm_object_key in [nil, ""] do
      object_key = Storage.object_key_for(package)

      package
      |> Ash.Changeset.for_update(:update, %{wasm_object_key: object_key})
      |> Ash.update(scope: scope)
    else
      {:ok, package}
    end
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

  defp parse_optional_json_map(json, label) do
    parse_optional_json_map_impl(json, label)
  end

  defp parse_optional_json_map_impl(nil, _label), do: {:ok, %{}}
  defp parse_optional_json_map_impl("", _label), do: {:ok, %{}}

  defp parse_optional_json_map_impl(%{} = value, _label), do: {:ok, value}

  defp parse_optional_json_map_impl(json, label) when is_binary(json) do
    trimmed = String.trim(json)

    if trimmed == "" do
      {:ok, %{}}
    else
      case Jason.decode(trimmed) do
        {:ok, value} when is_map(value) -> {:ok, value}
        {:ok, _} -> {:error, {:invalid_json, "#{label} must be a JSON object"}}
        {:error, reason} -> {:error, {:invalid_json, Exception.message(reason)}}
      end
    end
  end

  defp parse_optional_json_map_impl(_value, label), do: {:error, {:invalid_json, "#{label} must be JSON"}}

  defp config_schema_present?(schema) when is_map(schema) do
    schema = stringify_keys(schema)
    properties = Map.get(schema, "properties", %{})
    map_size(properties) > 0
  end

  defp config_schema_present?(_), do: false

  defp assignment_params_map(form) when is_map(form) do
    params = Map.get(form, "params", %{})

    cond do
      is_map(params) -> stringify_keys(params)
      is_binary(params) -> parse_json_string(params)
      true -> %{}
    end
  end

  defp assignment_params_map(_), do: %{}

  defp assignment_params_raw(form) when is_map(form) do
    params_raw = Map.get(form, "params_raw", "")
    params = Map.get(form, "params", "")

    cond do
      is_binary(params_raw) and String.trim(params_raw) != "" -> params_raw
      is_binary(params) -> params
      is_map(params) -> Jason.encode!(params)
      true -> ""
    end
  end

  defp assignment_params_raw(_), do: ""

  defp parse_json_string(value) when is_binary(value) do
    case Jason.decode(String.trim(value)) do
      {:ok, %{} = map} -> map
      _ -> %{}
    end
  end

  defp parse_json_string(_), do: %{}

  defp stringify_keys(%{} = map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp parse_assignment_params(params, package) do
    agent_uid = params["agent_uid"]
    timing = assignment_timing_defaults(package)

    interval_seconds =
      params["interval_seconds"]
      |> parse_int(timing.interval_seconds)
      |> clamp_int(timing.min_interval_seconds, timing.max_interval_seconds)

    timeout_seconds =
      params["timeout_seconds"]
      |> parse_int(timing.timeout_seconds)
      |> max(timing.min_timeout_seconds)

    # Prefer structured params (from config fields) over raw JSON
    # Only use params_raw if params["params"] is empty/nil
    params_source = resolve_params_source(params)
    config_schema = package.config_schema

    with true <-
           (is_binary(agent_uid) and String.trim(agent_uid) != "") ||
             {:error, "agent_uid required"},
         {:ok, parsed_params} <-
           parse_optional_json_map(params_source, "Params"),
         {:ok, permissions_override} <-
           parse_optional_json_map(params["permissions_override"], "Permissions override"),
         {:ok, resources_override} <-
           parse_optional_json_map(params["resources_override"], "Resources override") do
      # Normalize params using the config schema to convert string values to proper types
      normalized_params = normalize_assignment_params(parsed_params, config_schema)

      {:ok,
       %{
         agent_uid: String.trim(agent_uid),
         plugin_package_id: package.id,
         interval_seconds: interval_seconds,
         timeout_seconds: timeout_seconds,
         params: normalized_params,
         permissions_override: permissions_override,
         resources_override: resources_override
       }}
    else
      {:error, {:invalid_json, message}} -> {:error, {:invalid_json, message}}
      {:error, message} -> {:error, message}
      _ -> {:error, "invalid assignment"}
    end
  end

  # Prefer structured params from config fields over raw JSON textarea
  defp resolve_params_source(params) do
    structured_params = params["params"]
    raw_params = params["params_raw"]

    cond do
      # If structured params is a non-empty map, use it (config fields were filled)
      is_map(structured_params) and map_size(structured_params) > 0 ->
        structured_params

      # If raw params has content, use it
      is_binary(raw_params) and String.trim(raw_params) != "" ->
        raw_params

      # Fall back to structured params (might be empty map or nil)
      true ->
        structured_params
    end
  end

  defp normalize_assignment_params(params, config_schema) when is_map(params) and is_map(config_schema) do
    alias ServiceRadar.Plugins.ConfigSchema

    schema = stringify_keys(config_schema)
    required_fields = Map.get(schema, "required", [])

    # Remove empty strings only for non-required fields
    # Required fields with empty strings should fail validation with a clear error
    cleaned_params =
      params
      |> Enum.reject(fn {k, v} -> v == "" and k not in required_fields end)
      |> Map.new()

    if map_size(schema) > 0 do
      ConfigSchema.normalize_params(schema, cleaned_params)
    else
      cleaned_params
    end
  end

  defp normalize_assignment_params(params, _config_schema) when is_map(params), do: params

  defp parse_review_params(params) do
    approved_capabilities = parse_list(params["approved_capabilities"])

    with {:ok, approved_permissions} <-
           parse_optional_json_map(params["approved_permissions"], "Approved permissions"),
         {:ok, approved_resources} <-
           parse_optional_json_map(params["approved_resources"], "Approved resources") do
      {:ok,
       %{
         approved_capabilities: approved_capabilities,
         approved_permissions: approved_permissions,
         approved_resources: approved_resources
       }}
    end
  end

  defp parse_list(nil), do: []
  defp parse_list(""), do: []

  defp parse_list(value) when is_binary(value) do
    value
    |> String.split([",", "\n"], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_list(list) when is_list(list), do: list
  defp parse_list(_), do: []

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

  defp default_review_form do
    %{
      "approved_capabilities" => "",
      "approved_permissions" => "",
      "approved_resources" => "",
      "denied_reason" => ""
    }
  end

  defp build_review_form(package) do
    %{
      "approved_capabilities" => format_list_value(package.approved_capabilities),
      "approved_permissions" => format_json_value(package.approved_permissions),
      "approved_resources" => format_json_value(package.approved_resources),
      "denied_reason" => package.denied_reason || ""
    }
  end

  defp requested_capabilities(package) do
    Map.get(package.manifest || %{}, "capabilities") ||
      Map.get(package.manifest || %{}, :capabilities) || []
  end

  defp sensitive_capability?(capability) when is_binary(capability) do
    capability in @sensitive_capabilities
  end

  defp sensitive_capability?(_capability), do: false

  defp sensitive_requested_capabilities(package) do
    package
    |> requested_capabilities()
    |> Enum.filter(&sensitive_capability?/1)
  end

  defp requested_permissions(package) do
    Map.get(package.manifest || %{}, "permissions") ||
      Map.get(package.manifest || %{}, :permissions) || %{}
  end

  defp requested_resources(package) do
    Map.get(package.manifest || %{}, "resources") || Map.get(package.manifest || %{}, :resources) ||
      %{}
  end

  defp requested_actions(package) do
    case Map.get(package.manifest || %{}, "actions") || Map.get(package.manifest || %{}, :actions) do
      actions when is_list(actions) -> actions
      _ -> []
    end
  end

  defp action_id(action), do: action_value(action, "action_id") || "unknown"
  defp action_label(action), do: action_value(action, "label") || action_id(action)
  defp action_version(action), do: action_value(action, "version") || "1.0.0"
  defp action_description(action), do: action_value(action, "description")
  defp action_safety(action), do: action_value(action, "safety_classification") || "standard"
  defp action_timeout(action), do: action_value(action, "timeout_seconds") || 60

  defp action_requires_confirmation?(action) do
    action_value(action, "requires_confirmation") in [true, "true", 1, "1"]
  end

  defp action_scopes(action) do
    case action_value(action, "scopes") do
      scopes when is_list(scopes) -> Enum.map(scopes, &to_string/1)
      _ -> []
    end
  end

  defp action_value(action, key) when is_map(action) do
    Map.get(action, key) || Map.get(action, action_atom_key(key))
  end

  defp action_value(_action, _key), do: nil

  defp action_atom_key("action_id"), do: :action_id
  defp action_atom_key("label"), do: :label
  defp action_atom_key("version"), do: :version
  defp action_atom_key("description"), do: :description
  defp action_atom_key("safety_classification"), do: :safety_classification
  defp action_atom_key("timeout_seconds"), do: :timeout_seconds
  defp action_atom_key("requires_confirmation"), do: :requires_confirmation
  defp action_atom_key("scopes"), do: :scopes
  defp action_atom_key(_key), do: nil

  @fallback_assignment_interval_seconds 60
  @fallback_assignment_timeout_seconds 10
  @fallback_assignment_interval_min 5
  @fallback_assignment_timeout_min 1

  defp default_assignment_form(package \\ nil) do
    timing = assignment_timing_defaults(package)

    %{
      "agent_uid" => "",
      "interval_seconds" => Integer.to_string(timing.interval_seconds),
      "timeout_seconds" => Integer.to_string(timing.timeout_seconds),
      "params" => "",
      "params_raw" => "",
      "permissions_override" => "",
      "resources_override" => ""
    }
  end

  defp assignment_interval_min(package), do: assignment_timing_defaults(package).min_interval_seconds

  defp assignment_timeout_min(package), do: assignment_timing_defaults(package).min_timeout_seconds

  defp assignment_timing_defaults(package) do
    schedule = first_producer_schedule(package)

    %{
      interval_seconds:
        positive_int(
          schedule_get(schedule, "default_cadence_seconds"),
          @fallback_assignment_interval_seconds
        ),
      timeout_seconds:
        positive_int(
          schedule_get(schedule, "timeout_seconds"),
          @fallback_assignment_timeout_seconds
        ),
      min_interval_seconds:
        positive_int(
          schedule_get(schedule, "min_cadence_seconds"),
          @fallback_assignment_interval_min
        ),
      max_interval_seconds: positive_int(schedule_get(schedule, "max_cadence_seconds"), nil),
      min_timeout_seconds: @fallback_assignment_timeout_min
    }
  end

  defp first_producer_schedule(%{producer_schedules: [schedule | _]}) when is_map(schedule), do: schedule

  defp first_producer_schedule(%{"producer_schedules" => [schedule | _]}) when is_map(schedule), do: schedule

  defp first_producer_schedule(_package), do: nil

  defp producer_schedule_provisioned?(package), do: match?(%{}, first_producer_schedule(package))

  defp producer_schedule_assignment_message do
    "This plugin is assigned from a credential rule under Settings → Networks → Credentials. Pick the agent as the rule Scope Value; do not assign it here."
  end

  defp schedule_get(nil, _key), do: nil

  defp schedule_get(schedule, key) when is_map(schedule) do
    Map.get(schedule, key) || Map.get(schedule, schedule_atom_key(key))
  end

  defp schedule_atom_key("default_cadence_seconds"), do: :default_cadence_seconds
  defp schedule_atom_key("timeout_seconds"), do: :timeout_seconds
  defp schedule_atom_key("min_cadence_seconds"), do: :min_cadence_seconds
  defp schedule_atom_key("max_cadence_seconds"), do: :max_cadence_seconds
  defp schedule_atom_key(_key), do: nil

  defp positive_int(value, _fallback) when is_integer(value) and value > 0, do: value

  defp positive_int(value, fallback) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> int
      _ -> fallback
    end
  end

  defp positive_int(_value, fallback), do: fallback

  defp clamp_int(value, low, high) when is_integer(low) and is_integer(high) and high >= low do
    value |> Kernel.max(low) |> Kernel.min(high)
  end

  defp clamp_int(value, low, _high) when is_integer(low), do: Kernel.max(value, low)
  defp clamp_int(value, _low, _high), do: value

  defp agent_label(agent) do
    name = agent.name || agent.host || agent.uid
    "#{name} (#{agent.uid})"
  end

  defp existing_assignment(assignments, agent_uid) when is_list(assignments) and is_binary(agent_uid) do
    Enum.find(assignments, fn assignment ->
      assignment.agent_uid == agent_uid and not legacy_unbound_assignment?(assignment)
    end)
  end

  defp existing_assignment(_assignments, _agent_uid), do: nil

  # Partition recovery deliberately derives all identity data from the current
  # authenticated control session. The preview makes that provenance visible,
  # but it is never submitted as assignment input and the recovery command
  # resolves it again immediately before it creates a replacement.
  defp assign_authenticated_partition_preview(socket, agent_uid) do
    case trim_or_nil(agent_uid) do
      nil ->
        assign(socket, :authenticated_partition_preview, nil)

      agent_uid ->
        scope = socket.assigns.current_scope

        preview =
          case Assignments.authenticated_partition_preview(agent_uid, scope: scope) do
            {:ok, preview} -> normalize_authenticated_partition_preview(agent_uid, preview)
            {:error, reason} -> unavailable_partition_preview(agent_uid, reason)
            _other -> unavailable_partition_preview(agent_uid, :unavailable)
          end

        assign(socket, :authenticated_partition_preview, preview)
    end
  rescue
    _exception ->
      # A preview must fail closed. In particular, do not fall back to an
      # agent record, a default partition, or a value from an earlier form.
      assign(
        socket,
        :authenticated_partition_preview,
        unavailable_partition_preview(agent_uid, :unavailable)
      )
  end

  defp normalize_authenticated_partition_preview(agent_uid, preview) when is_map(preview) do
    partition_id = value_from_map(preview, :partition_id)

    if is_binary(partition_id) and String.trim(partition_id) != "" do
      %{
        agent_uid: agent_uid,
        state: :available,
        partition_id: String.trim(partition_id)
      }
    else
      unavailable_partition_preview(agent_uid, value_from_map(preview, :reason) || :unavailable)
    end
  end

  defp normalize_authenticated_partition_preview(agent_uid, _preview),
    do: unavailable_partition_preview(agent_uid, :unavailable)

  defp unavailable_partition_preview(agent_uid, reason) do
    %{
      agent_uid: agent_uid,
      state: :unavailable,
      reason: normalize_partition_preview_reason(reason)
    }
  end

  defp normalize_partition_preview_reason(reason)
       when reason in [
              :agent_offline,
              :authenticated_agent_partition_unavailable,
              :authenticated_agent_partition_mismatch,
              :forbidden,
              :not_found
            ], do: reason

  defp normalize_partition_preview_reason(_reason), do: :unavailable

  defp authenticated_partition_preview_message(%{reason: :agent_offline}),
    do: "No live authenticated control session is available for this agent."

  defp authenticated_partition_preview_message(%{reason: :authenticated_agent_partition_unavailable}),
    do: "The live control session did not provide a trustworthy partition."

  defp authenticated_partition_preview_message(%{reason: :authenticated_agent_partition_mismatch}),
    do: "The live control-session identity does not match the selected agent."

  defp authenticated_partition_preview_message(%{reason: :forbidden}),
    do: "You are not authorized to inspect this agent's live control session."

  defp authenticated_partition_preview_message(%{reason: :not_found}),
    do: "The selected agent is no longer available in your current scope."

  defp authenticated_partition_preview_message(_preview),
    do: "The authenticated partition is unavailable. No saved or default partition will be used."

  defp assignment_submit_disabled?(package, blob_present, preview) do
    package.status != :approved or not blob_present?(blob_present) or
      not match?(%{state: :available}, preview)
  end

  defp legacy_recovery_confirmation(assignments, id, requested_kind) when is_list(assignments) do
    with assignment when not is_nil(assignment) <-
           Enum.find(assignments, &(assignment_id(&1) == id)),
         {:ok, kind} <- legacy_recovery_kind(assignment),
         {:ok, ^kind} <- normalize_legacy_recovery_kind(requested_kind) do
      {:ok,
       %{
         id: assignment_id(assignment),
         kind: kind,
         agent_uid: assignment_value(assignment, :agent_uid),
         owner_label: legacy_recovery_owner_label(assignment),
         credential_rule_recovery?: legacy_credential_rule_recovery?(assignment)
       }}
    else
      nil -> {:error, :not_found}
      {:error, :unsupported_policy_owner} -> {:error, :unsupported_policy_owner}
      {:error, :recovery_unavailable} -> {:error, :recovery_unavailable}
      :error -> {:error, :not_recoverable}
      {:error, _reason} -> {:error, :kind_mismatch}
    end
  end

  defp legacy_recovery_confirmation(_assignments, _id, _requested_kind), do: {:error, :not_found}

  defp recovery_confirmation_matches?(confirmation, id, kind) when is_map(confirmation) do
    case normalize_legacy_recovery_kind(kind) do
      {:ok, normalized_kind} ->
        value_from_map(confirmation, :id) == id and
          value_from_map(confirmation, :kind) == normalized_kind

      :error ->
        false
    end
  end

  defp recovery_confirmation_matches?(_confirmation, _id, _kind), do: false

  defp legacy_recovery_confirmation_allowed?(socket, confirmation) do
    not (value_from_map(confirmation, :kind) == :policy and
           value_from_map(confirmation, :credential_rule_recovery?) == true and
           not socket.assigns.can_reconcile_credential_rules)
  end

  defp credential_recovery_permission_message,
    do: "You need credential-management permission to reconcile this credential rule."

  defp legacy_unbound_assignment?(assignment) do
    assignment_value(assignment, :enabled) == false and
      blank_partition?(assignment_value(assignment, :partition_id))
  end

  defp legacy_recovery_kind(assignment) do
    if legacy_unbound_assignment?(assignment) do
      case core_legacy_recovery_kind(assignment) do
        :manual_reapproval ->
          {:ok, :manual}

        :policy_reconciliation ->
          {:ok, :policy}

        :unsupported_policy_owner ->
          {:error, :unsupported_policy_owner}

        :not_recoverable ->
          {:error, :recovery_unavailable}

        nil ->
          {:error, :recovery_unavailable}
      end
    else
      :error
    end
  end

  defp legacy_recovery_kind_for_display(assignment) do
    if legacy_unbound_assignment?(assignment) do
      case core_legacy_recovery_kind(assignment) do
        :manual_reapproval ->
          :manual

        :policy_reconciliation ->
          :policy

        :unsupported_policy_owner ->
          :unsupported_policy_owner

        _ ->
          :recovery_unavailable
      end
    end
  end

  # The core recovery read model owns this classification. In particular, a
  # legacy `source = :policy` value alone does not prove that its historical
  # owner is a current plugin policy or credential rule. A missing detail fails
  # closed: the UI renders a non-actionable warning instead of deriving an
  # action from legacy source text.
  defp core_legacy_recovery_kind(assignment) do
    projected_kind =
      assignment
      |> legacy_recovery_details()
      |> value_from_map(:recovery_kind)

    projected_kind = projected_kind || assignment_value(assignment, :recovery_kind)

    case projected_kind do
      kind when kind in [:manual_reapproval, "manual_reapproval"] ->
        :manual_reapproval

      kind when kind in [:policy_reconciliation, "policy_reconciliation"] ->
        :policy_reconciliation

      kind when kind in [:unsupported_policy_owner, "unsupported_policy_owner"] ->
        :unsupported_policy_owner

      kind when kind in [:not_recoverable, "not_recoverable"] ->
        :not_recoverable

      _ ->
        nil
    end
  end

  defp legacy_recovery_label(:manual), do: "Unbound legacy manual assignment"
  defp legacy_recovery_label(:policy), do: "Unbound legacy policy assignment"
  defp legacy_recovery_label(:unsupported_policy_owner), do: "Unbound legacy policy assignment"
  defp legacy_recovery_label(:recovery_unavailable), do: "Unbound legacy assignment"
  defp legacy_recovery_label(_kind), do: "Unbound legacy assignment"

  defp legacy_recovery_message(:manual),
    do:
      "This historical row has no trustworthy partition. Reapproval creates a new partition-bound assignment from the live mTLS session; this row remains disabled for audit history."

  defp legacy_recovery_message(:policy),
    do:
      "This historical row has no trustworthy partition. It cannot be cloned or edited here; reconciliation re-evaluates the current authoritative policy or credential rule."

  defp legacy_recovery_message(:unsupported_policy_owner), do: unsupported_policy_owner_message()

  defp legacy_recovery_message(:recovery_unavailable), do: legacy_recovery_unavailable_message()

  defp legacy_recovery_message(_kind),
    do: "This historical row has no trustworthy partition and requires explicit recovery review."

  defp unsupported_policy_owner_message do
    "This historical policy assignment cannot be reconciled because its owner is not a supported current plugin target policy or credential rule. It remains disabled for audit history; recreate it from a supported current policy or credential rule."
  end

  defp legacy_recovery_unavailable_message do
    "Recovery details are unavailable, so this historical row remains disabled. Refresh before taking any recovery action."
  end

  defp legacy_policy_recovery_status(assignment) do
    assignment
    |> legacy_recovery_details()
    |> value_from_map(:policy_recovery)
  end

  defp legacy_manual_recovery_status(assignment) do
    assignment
    |> legacy_recovery_details()
    |> value_from_map(:manual_recovery)
  end

  defp legacy_credential_rule_recovery?(assignment) do
    assignment
    |> legacy_recovery_details()
    |> value_from_map(:owner)
    |> value_from_map(:kind)
    |> case do
      kind when kind in [:credential_rule, "credential_rule"] -> true
      _ -> false
    end
  end

  defp policy_recovery_action_enabled?(
         can_assign_plugins,
         can_reconcile_credential_rules,
         credential_rule_recovery?,
         policy_recovery
       ) do
    can_assign_plugins and
      (not credential_rule_recovery? or can_reconcile_credential_rules) and
      not policy_recovery_active?(policy_recovery) and
      policy_recovery_state(policy_recovery) != :reconciled
  end

  defp manual_recovery_action_enabled?(can_assign_plugins, manual_recovery) do
    can_assign_plugins and manual_recovery_state(manual_recovery) != :reapproved
  end

  defp legacy_manual_presentation_state(assignment) do
    if manual_recovery_state(legacy_manual_recovery_status(assignment)) == :reapproved do
      :completed
    else
      case {legacy_config_compatibility_state(assignment), legacy_authenticated_partition_state(assignment)} do
        {:compatible, :available} ->
          :actionable

        {:incompatible, _partition_state} ->
          :incompatible

        {:unavailable, _partition_state} ->
          :package_unavailable

        {_config_state, partition_state} when partition_state in [:mismatch, :unavailable] ->
          :identity_unavailable

        _ ->
          :unavailable
      end
    end
  end

  defp legacy_manual_presentation_title(:completed), do: "Recovered legacy record"
  defp legacy_manual_presentation_title(:incompatible), do: "Inactive legacy record"
  defp legacy_manual_presentation_title(:package_unavailable), do: "Inactive legacy record"
  defp legacy_manual_presentation_title(:identity_unavailable), do: "Legacy record waiting for agent connection"
  defp legacy_manual_presentation_title(_state), do: "Inactive legacy record"

  defp legacy_manual_presentation_message(:completed) do
    "A current partition-bound replacement is active. This disabled audit record does not affect the agent."
  end

  defp legacy_manual_presentation_message(:incompatible) do
    "Its old configuration cannot be migrated safely. This record is disabled and does not affect the agent. Create a new assignment with the current form only if this add-on is still needed."
  end

  defp legacy_manual_presentation_message(:package_unavailable) do
    "Its package is not currently approved, so it cannot be migrated. This record is disabled and does not affect the agent."
  end

  defp legacy_manual_presentation_message(:identity_unavailable) do
    "This record is disabled and does not affect the agent. Reconnect the agent and refresh before attempting recovery."
  end

  defp legacy_manual_presentation_message(_state) do
    "This record is disabled and does not affect the agent. No recovery action is currently available."
  end

  defp manual_recovery_action_label(manual_recovery) do
    case manual_recovery_state(manual_recovery) do
      :reapproved -> "Reapproved"
      _ -> "Reapprove"
    end
  end

  defp policy_recovery_action_label(can_reconcile_credential_rules, true, _policy_recovery)
       when not can_reconcile_credential_rules, do: "Credential permission required"

  defp policy_recovery_action_label(_can_reconcile_credential_rules, _credential_rule_recovery?, policy_recovery) do
    case policy_recovery_state(policy_recovery) do
      :queued ->
        "Reconciliation queued"

      :pending ->
        "Reconciling"

      :reconciled ->
        "Reconciled"

      state
      when state in [
             :no_longer_eligible,
             :owner_not_authoritative,
             :identity_unavailable,
             :identity_changed,
             :package_unapproved,
             :schema_invalid,
             :conflict,
             :denied,
             :failed
           ] ->
        "Retry reconciliation"

      _ ->
        "Reconcile policy"
    end
  end

  defp legacy_policy_recovery_message(nil), do: nil

  defp legacy_policy_recovery_message(policy_recovery) do
    case policy_recovery_state(policy_recovery) do
      :queued ->
        "Policy reconciliation is queued. This row will refresh while the current source is re-evaluated."

      :pending ->
        "Policy reconciliation is running against the current source and live mTLS identity."

      :reconciled ->
        replacement_count = value_from_map(policy_recovery, :replacement_count) || 0

        "Policy reconciliation completed: #{replacement_count} current assignment#{plural_suffix(replacement_count)} restored."

      :no_longer_eligible ->
        "Policy reconciliation completed without a replacement because this target is no longer eligible. Review the current policy and target."

      :owner_not_authoritative ->
        "Policy reconciliation could not run because the historical policy or credential rule is no longer authoritative."

      :identity_unavailable ->
        "Policy reconciliation is waiting for trustworthy live partition evidence. Reconnect the target agent, then retry."

      :identity_changed ->
        "Policy reconciliation stopped because the target's live identity changed. Verify the agent and retry."

      :package_unapproved ->
        "Policy reconciliation stopped because the package is not currently approved. Review and approve the package before retrying."

      :schema_invalid ->
        "Policy reconciliation stopped because the current policy configuration no longer validates. Review the current policy before retrying."

      :conflict ->
        "Policy reconciliation found an enabled assignment for this target and partition. Review the current assignment before retrying."

      :denied ->
        "Policy reconciliation was denied after current authorization was rechecked. Confirm your permissions and retry."

      :failed ->
        "Policy reconciliation did not complete. Review the current source and retry."

      :unavailable ->
        "Policy reconciliation status is temporarily unavailable. Refresh this page before retrying."

      _ ->
        nil
    end
  end

  defp legacy_manual_recovery_message(manual_recovery) do
    case manual_recovery_state(manual_recovery) do
      :reapproved ->
        "Manual reapproval completed. Its partition-bound replacement remains in effect; this historical row stays disabled."

      _ ->
        nil
    end
  end

  defp manual_recovery_state(manual_recovery) when is_map(manual_recovery) do
    case value_from_map(manual_recovery, :state) do
      state when state in [:reapproved, "reapproved"] -> :reapproved
      _ -> nil
    end
  end

  defp manual_recovery_state(_manual_recovery), do: nil

  defp policy_recovery_active?(policy_recovery), do: policy_recovery_state(policy_recovery) in [:queued, :pending]

  defp policy_recovery_state(policy_recovery) when is_map(policy_recovery) do
    case value_from_map(policy_recovery, :state) do
      state when state in [:queued, "queued"] ->
        :queued

      state when state in [:pending, "pending"] ->
        :pending

      state when state in [:reconciled, "reconciled"] ->
        :reconciled

      state when state in [:no_longer_eligible, "no_longer_eligible"] ->
        :no_longer_eligible

      state when state in [:owner_not_authoritative, "owner_not_authoritative"] ->
        :owner_not_authoritative

      state when state in [:identity_unavailable, "identity_unavailable"] ->
        :identity_unavailable

      state when state in [:identity_changed, "identity_changed"] ->
        :identity_changed

      state when state in [:package_unapproved, "package_unapproved"] ->
        :package_unapproved

      state when state in [:schema_invalid, "schema_invalid"] ->
        :schema_invalid

      state when state in [:conflict, "conflict"] ->
        :conflict

      state when state in [:denied, "denied"] ->
        :denied

      state when state in [:failed, "failed"] ->
        :failed

      state when state in [:unavailable, "unavailable"] ->
        :unavailable

      _ ->
        nil
    end
  end

  defp policy_recovery_state(_policy_recovery), do: nil

  defp policy_recovery_terminal_message(:reconciled),
    do: "Policy reconciliation completed. The recovered assignment now reflects the current authoritative policy."

  defp policy_recovery_terminal_message(:no_longer_eligible),
    do: "Policy reconciliation completed without a replacement because the target is no longer eligible."

  defp policy_recovery_terminal_message(state) do
    legacy_policy_recovery_message(%{state: state}) ||
      "Policy reconciliation finished. Review the recovery status before retrying."
  end

  defp plural_suffix(1), do: ""
  defp plural_suffix(_count), do: "s"

  defp legacy_confirmation_title(%{kind: :manual}), do: "Confirm manual reapproval"
  defp legacy_confirmation_title(%{kind: :policy}), do: "Confirm policy reconciliation"
  defp legacy_confirmation_title(_confirmation), do: "Confirm legacy recovery"

  defp legacy_confirmation_message(%{kind: :manual, agent_uid: agent_uid}) do
    "Reapprove the legacy manual assignment for #{agent_uid}? The server will resolve current mTLS evidence again and retain the historical row disabled."
  end

  defp legacy_confirmation_message(%{kind: :policy, agent_uid: agent_uid} = confirmation) do
    owner = Map.get(confirmation, :owner_label)
    owner_text = if is_binary(owner) and owner != "", do: " for #{owner}", else: ""

    "Request reconciliation for #{agent_uid}#{owner_text}? The current source, target eligibility, and live mTLS evidence will be re-evaluated."
  end

  defp legacy_confirmation_message(_confirmation),
    do: "The server will validate this recovery against current authorization and live identity evidence."

  defp legacy_confirmation_action_label(%{kind: :manual}), do: "Confirm reapproval"
  defp legacy_confirmation_action_label(%{kind: :policy}), do: "Request reconciliation"
  defp legacy_confirmation_action_label(_confirmation), do: "Confirm recovery"

  defp normalize_legacy_recovery_kind(:manual), do: {:ok, :manual}
  defp normalize_legacy_recovery_kind("manual"), do: {:ok, :manual}
  defp normalize_legacy_recovery_kind(:policy), do: {:ok, :policy}
  defp normalize_legacy_recovery_kind("policy"), do: {:ok, :policy}
  defp normalize_legacy_recovery_kind(_kind), do: :error

  defp assignment_source(assignment) do
    case assignment_value(assignment, :source) do
      :manual -> :manual
      "manual" -> :manual
      :policy -> :policy
      "policy" -> :policy
      _ -> nil
    end
  end

  defp assignment_package_id(assignment), do: assignment_value(assignment, :plugin_package_id)
  defp assignment_id(assignment), do: assignment_value(assignment, :id)

  defp assignment_value(assignment, key) when is_map(assignment), do: value_from_map(assignment, key)

  defp assignment_value(_assignment, _key), do: nil

  defp value_from_map(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp value_from_map(_map, _key), do: nil

  defp blank_partition?(partition_id), do: not (is_binary(partition_id) and String.trim(partition_id) != "")

  defp legacy_recovery_details(assignment) do
    case assignment_value(assignment, :recovery) do
      details when is_map(details) -> details
      _ -> %{}
    end
  end

  defp legacy_recovery_owner_label(assignment) do
    owner = assignment |> legacy_recovery_details() |> value_from_map(:owner)
    fallback_id = assignment_value(assignment, :policy_id)

    cond do
      is_map(owner) and is_binary(value_from_map(owner, :label)) and
          value_from_map(owner, :label) != "" ->
        value_from_map(owner, :label)

      is_map(owner) and is_binary(value_from_map(owner, :id)) and value_from_map(owner, :id) != "" ->
        legacy_owner_kind_label(value_from_map(owner, :kind)) <> " " <> value_from_map(owner, :id)

      is_binary(fallback_id) and fallback_id != "" ->
        "Policy #{fallback_id}"

      true ->
        nil
    end
  end

  defp legacy_owner_kind_label(:credential_rule), do: "Credential rule"
  defp legacy_owner_kind_label("credential_rule"), do: "Credential rule"
  defp legacy_owner_kind_label(:policy), do: "Policy"
  defp legacy_owner_kind_label("policy"), do: "Policy"
  defp legacy_owner_kind_label(_kind), do: "Owner"

  defp legacy_recovery_compatibility_message(assignment) do
    compatibility =
      assignment |> legacy_recovery_details() |> value_from_map(:config_compatibility)

    case {value_from_map(compatibility, :state), value_from_map(compatibility, :reason)} do
      {state, _reason} when state in [:compatible, "compatible"] ->
        "Configuration: compatible with the current package schema."

      {state, _reason} when state in [:incompatible, "incompatible"] ->
        "Configuration: the current package schema no longer accepts this historical configuration."

      {state, _reason} when state in [:unavailable, "unavailable"] ->
        "Configuration: the package is unavailable or no longer approved, so recovery cannot proceed."

      _ ->
        nil
    end
  end

  defp legacy_config_compatibility_state(assignment) do
    compatibility =
      assignment |> legacy_recovery_details() |> value_from_map(:config_compatibility)

    case value_from_map(compatibility, :state) do
      state when state in [:compatible, "compatible"] -> :compatible
      state when state in [:incompatible, "incompatible"] -> :incompatible
      state when state in [:unavailable, "unavailable"] -> :unavailable
      _state -> nil
    end
  end

  defp legacy_authenticated_partition_state(assignment) do
    partition =
      assignment |> legacy_recovery_details() |> value_from_map(:authenticated_partition)

    case value_from_map(partition, :state) do
      state when state in [:available, "available"] -> :available
      state when state in [:mismatch, "mismatch"] -> :mismatch
      state when state in [:unavailable, "unavailable"] -> :unavailable
      _state -> nil
    end
  end

  defp legacy_authenticated_partition_message(assignment) do
    partition =
      assignment |> legacy_recovery_details() |> value_from_map(:authenticated_partition)

    state = value_from_map(partition, :state)
    partition_id = value_from_map(partition, :partition_id)

    cond do
      state in [:available, "available"] and is_binary(partition_id) and
          String.trim(partition_id) != "" ->
        "Current authenticated partition: #{String.trim(partition_id)}. It will be resolved again when recovery runs."

      state in [:mismatch, "mismatch"] ->
        "Current authenticated partition: unavailable because the live control-session identity does not match this agent. Reconnect the agent and try again."

      state in [:unavailable, "unavailable"] ->
        "Current authenticated partition: unavailable. Reconnect the agent and try again."

      true ->
        nil
    end
  end

  defp legacy_recovery_success_message(kind, recovery) do
    case {normalize_legacy_recovery_kind(kind), legacy_recovery_result_state(recovery)} do
      {{:ok, :manual}, :already_reapproved} ->
        "This legacy manual assignment was already reapproved. Its partition-bound replacement remains in effect."

      {{:ok, :manual}, _state} ->
        "Legacy manual assignment reapproved. A new partition-bound assignment was created; the historical row remains disabled."

      {{:ok, :policy}, state} when state in [:queued, :pending] ->
        "Policy reconciliation queued. Its status will refresh here while the current policy or credential rule re-evaluates this target."

      {{:ok, :policy}, :already_reconciled} ->
        "This legacy policy assignment was already reconciled."

      {{:ok, :policy}, _state} ->
        "Policy reconciliation completed. Any replacement reflects the current authoritative policy, not the historical row."

      _ ->
        "Legacy assignment recovery completed."
    end
  end

  defp legacy_recovery_result_state(recovery) when is_map(recovery) do
    value_from_map(recovery, :state) || value_from_map(recovery, :status)
  end

  defp legacy_recovery_result_state(_recovery), do: nil

  defp legacy_recovery_error_message(:recovery_confirmation_required), do: "Explicit confirmation is required."

  defp legacy_recovery_error_message(:legacy_assignment_not_manual),
    do: "This row is policy-owned and must be reconciled by its authoritative policy."

  defp legacy_recovery_error_message(:legacy_assignment_not_policy),
    do: "This row is manually owned and must be reapproved instead."

  defp legacy_recovery_error_message(:legacy_assignment_not_unbound),
    do: "This row is no longer an unbound legacy assignment. Refresh and review its current state."

  defp legacy_recovery_error_message(:authenticated_agent_partition_unavailable),
    do: "The selected agent has no trustworthy live partition evidence."

  defp legacy_recovery_error_message(reason)
       when reason in [:authenticated_agent_partition_mismatch, :authenticated_agent_partition_changed],
       do: "The live control-session identity no longer matches the selected agent."

  defp legacy_recovery_error_message(:agent_offline), do: "The selected agent is offline. Reconnect it and try again."

  defp legacy_recovery_error_message(reason)
       when reason in [:active_assignment_conflict, :bound_manual_assignment_conflict],
       do: "An enabled assignment already owns this agent and plugin in the resolved partition."

  defp legacy_recovery_error_message(reason)
       when reason in [:package_not_approved, :plugin_package_not_approved, :plugin_package_not_found],
       do: "The package is no longer approved for assignment."

  defp legacy_recovery_error_message(reason)
       when reason in [:policy_owner_unavailable, :owner_not_found, :owner_not_authoritative],
       do: "The historical policy or credential rule is no longer authoritative."

  defp legacy_recovery_error_message(:policy_reconciliation_forbidden),
    do: "You are not authorized to reconcile the owning policy or credential rule."

  defp legacy_recovery_error_message(:unsupported_policy_owner), do: unsupported_policy_owner_message()

  defp legacy_recovery_error_message(:forbidden), do: "You are not authorized to recover this assignment."

  defp legacy_recovery_error_message(reason)
       when reason in [
              :authorization_denied,
              :initiating_actor_required,
              :initiating_principal_required,
              :current_authority_denied,
              :current_permission_denied,
              :principal_disabled,
              :principal_not_found,
              :principal_owner_changed,
              :service_principal_write_scope_required
            ], do: "You are not authorized to recover this assignment."

  defp legacy_recovery_error_message(reason)
       when reason in [:legacy_partition_reapproval_required, :legacy_assignment_not_unbound, :not_legacy_unbound],
       do: "This historical row must remain disabled. Use its explicit recovery action instead."

  defp legacy_recovery_error_message({:rejected, :not_legacy_unbound}),
    do: "This historical row must remain disabled. Use its explicit recovery action instead."

  defp legacy_recovery_error_message({:rejected, :policy_assignment_requires_reconciliation}),
    do: "This row is policy-owned and must be reconciled by its authoritative policy."

  defp legacy_recovery_error_message(:policy_assignment_requires_reconciliation),
    do: "This row is policy-owned and must be reconciled by its authoritative policy."

  defp legacy_recovery_error_message(:params_not_recoverable),
    do: "The historical configuration no longer satisfies the current package schema."

  defp legacy_recovery_error_message(:schema_invalid),
    do: "The historical configuration no longer satisfies the current package schema."

  defp legacy_recovery_error_message({:configuration_incompatible, _errors}),
    do: "The historical configuration no longer satisfies the current package schema."

  defp legacy_recovery_error_message({:schema_invalid, :params_not_recoverable}),
    do: "The historical configuration no longer satisfies the current package schema."

  defp legacy_recovery_error_message({:active_assignment_conflict, _assignment_id}),
    do: "An enabled assignment already owns this agent and plugin in the resolved partition."

  defp legacy_recovery_error_message(_error),
    do: "The server rejected recovery without creating or modifying an assignment."

  defp legacy_recovery_failure_message(error) do
    "Recovery was not completed. No live assignment was changed. #{legacy_recovery_error_message(error)}"
  end

  attr :plugin_id, :string, required: true
  attr :coverage, :map, default: nil
  attr :producer_schedule?, :boolean, default: false

  defp credential_rule_assignment_banner(assigns) do
    provider =
      case assigns.coverage do
        %{provider: provider} when is_binary(provider) and provider != "" -> provider
        _ -> credential_rule_provider(assigns.plugin_id)
      end

    assigns =
      assigns
      |> assign(:provider, provider)
      |> assign(:new_rule_path, credential_rule_new_path(provider))

    ~H"""
    <div class={[
      "rounded-lg p-3 text-sm space-y-2",
      if(@producer_schedule?,
        do: "border border-warning/30 bg-warning/10",
        else: "border border-info/20 bg-info/10"
      )
    ]}>
      <%= if @producer_schedule? do %>
        <div class="font-semibold">Do not assign this plugin here</div>
        <p class="text-xs text-sr-ink/80">
          This scheduled inventory plugin runs from a credential rule, not from this form.
          Create a <span class="font-mono">{@provider}</span>
          username/password credential and rule under <span class="font-medium">Settings → Networks → Credentials</span>.
          The rule's Scope Value is the agent that executes the Wasm module; saving
          the rule creates the assignment.
        </p>
      <% else %>
        <div class="font-semibold">Create a credential rule first</div>
        <p class="text-xs text-sr-ink/80">
          Passwords, API keys, and controller logins belong in <span class="font-medium">Settings → Networks → Credentials</span>,
          not on this assignment. Create a <span class="font-mono">{@provider}</span>
          rule, attach the secret, then assign this plugin to an agent that rule covers.
        </p>
        <p :if={match?(%{state: :uncovered}, @coverage)} class="text-xs text-warning">
          No enabled {@provider} rule covers the selected agent yet. The plugin will
          fail at runtime until one does.
        </p>
      <% end %>
      <.link navigate={@new_rule_path} class="link link-primary text-xs">
        Open the {@provider} credential rule form
      </.link>
    </div>
    """
  end

  defp credential_rule_provider(plugin_id) do
    case IntegrationCatalog.consumer_for_plugin_id(plugin_id) do
      {:ok, {profile, _consumer}} -> profile["provider"] || "matching"
      _ -> "matching"
    end
  end

  defp credential_rule_new_path(provider) when is_binary(provider) and provider != "matching" do
    ~p"/settings/networks/credentials/new?provider=#{provider}"
  end

  defp credential_rule_new_path(_provider), do: ~p"/settings/networks/credentials"

  # -- Credential-rule coverage (x-serviceradar-credential-materialized) -------
  #
  # PluginAssignment has no metadata column to persist a coverage flag, so the
  # warning is derived dynamically on every view: per-assignment badges in the
  # Assignments list, live status in the assignment form, and a loud flash on
  # save. It disappears on its own once a matching rule is enabled.

  defp assign_credential_context(socket, package) do
    fields = CredentialCoverage.materialized_fields(package.config_schema)

    socket
    |> assign(:credential_fields, fields)
    |> assign(:credential_coverage, nil)
    |> assign(
      :assignment_coverage,
      assignment_coverage(fields, package.plugin_id, socket.assigns.assignments)
    )
  end

  defp assignment_coverage([], _plugin_id, _assignments), do: %{}

  defp assignment_coverage(_fields, plugin_id, assignments) do
    Map.new(assignments, fn assignment ->
      case CredentialCoverage.coverage(plugin_id, assignment.agent_uid) do
        {:ok, coverage} -> {assignment.id, coverage}
        _ -> {assignment.id, nil}
      end
    end)
  end

  defp assign_form_coverage(socket, agent_uid) do
    package = socket.assigns.selected_package

    coverage =
      with true <- socket.assigns.credential_fields != [],
           %{plugin_id: plugin_id} when is_binary(plugin_id) <- package,
           trimmed when is_binary(trimmed) and trimmed != "" <- trim_or_nil(agent_uid),
           {:ok, coverage} <- CredentialCoverage.coverage(plugin_id, trimmed) do
        coverage
      else
        _ -> nil
      end

    assign(socket, :credential_coverage, coverage)
  end

  defp assignment_saved_flash(socket, base_message, agent_uid) do
    case saved_coverage_warning(socket, agent_uid) do
      nil -> put_flash(socket, :info, base_message)
      warning -> put_flash(socket, :error, base_message <> ". Warning: " <> warning)
    end
  end

  defp saved_coverage_warning(socket, agent_uid) do
    with true <- socket.assigns.credential_fields != [],
         %{plugin_id: plugin_id} when is_binary(plugin_id) <- socket.assigns.selected_package,
         trimmed when is_binary(trimmed) and trimmed != "" <- trim_or_nil(agent_uid),
         {:ok, coverage} <- CredentialCoverage.coverage(plugin_id, trimmed) do
      CredentialCoverage.warning_message(coverage, trimmed)
    else
      _ -> nil
    end
  end

  defp trim_or_nil(value) when is_binary(value), do: String.trim(value)
  defp trim_or_nil(_value), do: nil

  defp uncovered_assignment?(coverage_map, assignment_id) do
    match?(%{state: :uncovered}, Map.get(coverage_map || %{}, assignment_id))
  end

  defp coverage_badge_title(coverage_map, assignment_id) do
    case Map.get(coverage_map || %{}, assignment_id) do
      %{provider: provider, purpose: purpose} ->
        "No enabled #{provider} #{purpose} credential rule covers this agent"

      _ ->
        nil
    end
  end

  defp manifest_source_repo_url(manifest) do
    source = Map.get(manifest || %{}, :source) || Map.get(manifest || %{}, "source") || %{}
    Map.get(source, :repo_url) || Map.get(source, "repo_url")
  end

  defp maybe_put_filter(filters, _key, nil), do: filters
  defp maybe_put_filter(filters, _key, ""), do: filters

  defp maybe_put_filter(filters, key, value) do
    Map.put(filters, key, value)
  end

  defp normalize_filter(nil), do: nil
  defp normalize_filter(""), do: nil
  defp normalize_filter(value) when is_binary(value), do: value
  defp normalize_filter(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_filter(_), do: nil

  defp format_list_value(nil), do: ""
  defp format_list_value([]), do: ""
  defp format_list_value(list) when is_list(list), do: Enum.join(list, ", ")
  defp format_list_value(value) when is_binary(value), do: value
  defp format_list_value(_), do: ""

  defp format_json_value(nil), do: ""
  defp format_json_value(""), do: ""
  defp format_json_value(value) when is_map(value), do: Jason.encode!(value, pretty: true)
  defp format_json_value(value) when is_binary(value), do: value
  defp format_json_value(_), do: ""

  # 3.5.3: a refused contract must be diagnosable from the package that shipped
  # it, not merely absent from the pages it would have rendered. Read from the
  # runtime index rather than re-validated here, so what is shown is exactly what
  # the renderer decided.
  defp display_contract_diagnostics(package) do
    producer_id = Map.get(package, :plugin_id) || Map.get(package, :addon_id)
    version = Map.get(package, :version)

    runtime =
      Enum.filter(ContractRegistry.diagnostics(), fn diagnostic ->
        diagnostic.package == producer_id and diagnostic.version == version
      end)

    runtime ++ import_display_contract_diagnostics(package)
  end

  # Contracts the bundle shipped and the importer refused. They were never
  # stored, so the runtime index cannot report them; the importer recorded the
  # reasons here instead.
  defp import_display_contract_diagnostics(package) do
    package
    |> Map.get(:source_metadata)
    |> case do
      %{} = metadata -> Map.get(metadata, "display_contract_errors") || []
      _other -> []
    end
    |> List.wrap()
    |> Enum.map(fn reason -> %{source: "at import", reason: to_string(reason)} end)
  end

  defp format_hash(nil), do: "—"
  defp format_hash(""), do: "—"
  defp format_hash(value) when is_binary(value), do: value
  defp format_hash(_), do: "—"

  defp wasm_upload_error(:too_large) do
    "File is too large (max #{format_bytes(Storage.max_upload_bytes())})"
  end

  defp wasm_upload_error(:not_accepted), do: "Invalid file type (only .wasm allowed)"
  defp wasm_upload_error(:too_many_files), do: "Only one file allowed"
  defp wasm_upload_error(:read_failed), do: "Failed to read uploaded file"
  defp wasm_upload_error(error), do: inspect(error)

  defp format_bytes(bytes) when is_integer(bytes) and bytes > 0 do
    mb = Float.round(bytes / 1_048_576, 1)
    "#{mb}MB"
  end

  defp format_bytes(_), do: "0MB"

  defp blob_status(true), do: "Stored"
  defp blob_status(false), do: "Missing"
  defp blob_status(nil), do: "Unknown"
  defp blob_status(_), do: "Unknown"

  defp blob_present?(true), do: true
  defp blob_present?(_), do: false

  defp gpg_status(nil), do: "Not verified"
  defp gpg_status(key_id) when is_binary(key_id), do: "Unverified (key #{key_id})"
  defp gpg_status(_key_id), do: "Unknown"

  defp gpg_key_suffix(key_id) when is_binary(key_id) and key_id != "", do: " (#{key_id})"
  defp gpg_key_suffix(_key_id), do: ""

  defp signature_status(nil), do: "none"
  defp signature_status(%{} = signature) when map_size(signature) == 0, do: "none"
  defp signature_status(%{}), do: "present"
  defp signature_status(_), do: "unknown"

  defp maybe_delete_blob(nil), do: :ok

  defp maybe_delete_blob(package) do
    key =
      case package do
        %{wasm_object_key: value} -> value
        _ -> nil
      end

    if is_binary(key) and String.trim(key) != "" do
      Storage.delete_blob(key)
    else
      :ok
    end
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

  defp status_badge(assigns) do
    status = if is_atom(assigns.status), do: Atom.to_string(assigns.status), else: assigns.status

    variant =
      case status do
        "staged" -> "warning"
        "approved" -> "success"
        "denied" -> "error"
        "revoked" -> "ghost"
        _ -> "ghost"
      end

    assigns = assigns |> assign(:variant, variant) |> assign(:status_str, status)

    ~H"""
    <.ui_badge variant={@variant} size="xs">{@status_str}</.ui_badge>
    """
  end

  defp package_status_badge_variant(:approved), do: "success"
  defp package_status_badge_variant("approved"), do: "success"
  defp package_status_badge_variant(:staged), do: "warning"
  defp package_status_badge_variant("staged"), do: "warning"

  defp package_status_badge_variant(status) when status in [:denied, :revoked, "denied", "revoked"], do: "error"

  defp package_status_badge_variant(_status), do: "ghost"

  defp dom_id_segment(value) do
    value
    |> to_string()
    |> String.replace(~r/[^A-Za-z0-9_-]/u, "-")
  end

  defp package_for_assignment(assignment, versions) do
    Enum.find(versions, &(&1.id == assignment.plugin_package_id))
  end

  defp package_version(nil), do: "unknown"
  defp package_version(package), do: package.version || "unknown"

  defp latest_upgrade_target(assignment, versions) do
    case package_for_assignment(assignment, versions) do
      nil ->
        nil

      current_package ->
        assignment
        |> approved_version_targets(versions)
        |> Enum.filter(&(compare_package_versions(&1, current_package) == :gt))
        |> List.last()
    end
  end

  defp approved_version_targets(assignment, versions) do
    versions
    |> Enum.filter(&approved_upgrade_target?(&1, assignment))
    |> Enum.sort(&version_before_or_equal?/2)
  end

  defp latest_approved_assignment_version?(assignment, versions) do
    current_package = package_for_assignment(assignment, versions)

    latest_package =
      versions
      |> Enum.filter(&approved_plugin_version?(&1, assignment.plugin_id))
      |> Enum.sort(&version_before_or_equal?/2)
      |> List.last()

    not is_nil(current_package) and not is_nil(latest_package) and
      current_package.id == latest_package.id
  end

  defp approved_upgrade_target?(package, assignment) do
    approved_plugin_version?(package, assignment.plugin_id) and
      package.id != assignment.plugin_package_id
  end

  defp approved_plugin_version?(package, plugin_id) do
    package.status in [:approved, "approved"] and package.plugin_id == plugin_id
  end

  defp assignment_version_option_label(target, current_package) do
    relation =
      case compare_package_versions(target, current_package) do
        :lt -> "rollback"
        :gt -> "newer"
        :eq -> "current"
      end

    "#{target.version} (#{relation})"
  end

  defp compare_package_versions(_left, nil), do: :eq

  defp compare_package_versions(left, right) do
    case {Version.parse(left.version || ""), Version.parse(right.version || "")} do
      {{:ok, left_version}, {:ok, right_version}} ->
        Version.compare(left_version, right_version)

      _ ->
        cond do
          (left.version || "") < (right.version || "") -> :lt
          (left.version || "") > (right.version || "") -> :gt
          true -> :eq
        end
    end
  end

  defp version_before_or_equal?(left, right) do
    compare_package_versions(left, right) != :gt
  end

  defp get_actor(socket) do
    case socket.assigns.current_scope.user do
      nil -> "system"
      user -> user.email
    end
  end

  defp assignment_create_error_message(error) do
    message = format_error(error)

    if String.contains?(message, "plugin is already enabled for this agent") or
         String.contains?(message, "plugin is already assigned to this agent by policy") do
      "This agent already has this plugin enabled. Use the existing assignment's upgrade or version selector instead."
    else
      "Failed to assign: #{message}"
    end
  end

  defp format_error(error) when is_binary(error), do: error
  defp format_error(:policy_owned_assignment), do: "assignment is managed by policy"
  defp format_error(:target_package_not_approved), do: "target plugin version is not approved"
  defp format_error(:plugin_id_mismatch), do: "target package is for a different plugin"
  defp format_error(:already_on_target_version), do: "assignment is already on that version"
  defp format_error(error) when is_atom(error), do: Atom.to_string(error)
  defp format_error(%Invalid{} = error), do: Exception.message(error)
  defp format_error(error), do: inspect(error)
end
