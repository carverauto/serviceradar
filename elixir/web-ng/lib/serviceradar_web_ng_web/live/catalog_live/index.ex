defmodule ServiceRadarWebNGWeb.CatalogLive.Index do
  @moduledoc """
  Solution Packs Catalog Gallery LiveView (`/catalog`, `/catalog/:slug`, and
  `/settings/catalog`) (`4.1`, `4.2`, `4.3`, `4.5`).

  LiveView Iron Law compliance:
  - Performs zero database queries in disconnected `mount/3`.
  - Checks `connected?(socket)` before loading catalog data or subscribing to PubSub.
  - Enforces RBAC (`catalog.view`, `catalog.packs.install`, `catalog.packs.export`,
    `catalog.repositories.manage`, `catalog.gitops.sync`) on mount and every mutating event.
  """

  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.CatalogLive.InstallWizardComponents
  import ServiceRadarWebNGWeb.CatalogLive.PackDetailComponents
  import ServiceRadarWebNGWeb.CatalogLive.RepositoryModalComponents

  alias ServiceRadar.Camera.VantagePubSub
  alias ServiceRadar.Catalog.PackArchive
  alias ServiceRadarWebNG.CameraVantageWorkers
  alias ServiceRadarWebNG.Catalog
  alias ServiceRadarWebNG.RBAC

  @view_permission "catalog.view"
  @install_permission "catalog.packs.install"
  @export_permission "catalog.packs.export"
  @manage_repos_permission "catalog.repositories.manage"
  @gitops_sync_permission "catalog.gitops.sync"

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if can_view?(scope) do
      socket =
        socket
        |> assign(:page_title, "Solution Packs Catalog")
        |> assign(:current_path, "/catalog")
        |> assign(:can_install, RBAC.can?(scope, @install_permission))
        |> assign(:can_activate_dashboards, can_activate_dashboards?(scope))
        |> assign(:can_export, RBAC.can?(scope, @export_permission))
        |> assign(:can_manage_repos, RBAC.can?(scope, @manage_repos_permission))
        |> assign(:can_gitops_sync, RBAC.can?(scope, @gitops_sync_permission))
        |> assign(:loading?, not connected?(socket))
        |> assign(:packs, [])
        |> assign(:filtered_packs, [])
        |> assign(:repositories, [])
        |> assign(:credential_options, %{secrets: [], rules: []})
        |> assign(:vantage_worker_summary, CameraVantageWorkers.default_summary())
        |> assign(:vantage_worker_subscribed?, false)
        |> assign(:search, "")
        |> assign(:selected_category, "all")
        |> assign(:selected_source, "all")
        |> assign(:active_tab, "all")
        |> assign(:detail_pack, nil)
        |> assign(:detail_tab, "overview")
        |> assign(:detail_check_slug, nil)
        |> assign(:uninstall_confirm_pack, nil)
        |> assign(:wizard, nil)
        |> assign(:repos_modal_open, false)
        |> assign(:repo_form, default_repo_form())
        |> assign(:editing_repo_id, nil)
        |> assign(:repo_error, nil)
        |> assign(:repo_test_result, nil)
        |> assign(:gitops_push_open, false)
        |> assign(:gitops_push_form, default_push_form())
        |> assign(:gitops_push_result, nil)
        |> assign(:gitops_push_error, nil)
        |> assign(:gitops_pull_open, false)
        |> assign(:gitops_pull_state, default_pull_state())
        |> assign(:import_modal_open, false)
        |> assign(:upload_error, nil)
        |> allow_upload(:pack_bundle,
          accept: :any,
          max_entries: 1,
          max_file_size: PackArchive.max_compressed_bytes_with_dashboards()
        )

      {:ok, socket}
    else
      {:ok,
       socket
       |> put_flash(:error, "Not authorized to access the Solution Packs Catalog")
       |> push_navigate(to: ~p"/dashboard")}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    if connected?(socket) do
      socket =
        socket
        |> maybe_subscribe_vantage_workers()
        |> load_catalog_data()
        |> apply_route_params(params)

      {:noreply, socket}
    else
      {:noreply, assign(socket, :loading?, true)}
    end
  end

  ## Gallery Filtering Events

  @impl true
  def handle_event("search", %{"q" => query}, socket) do
    {:noreply,
     socket
     |> assign(:search, to_string(query || ""))
     |> recompute_filtered_packs()}
  end

  def handle_event("select_category", %{"category" => category}, socket) do
    {:noreply,
     socket
     |> assign(:selected_category, category)
     |> recompute_filtered_packs()}
  end

  def handle_event("select_source", %{"source" => source}, socket) do
    {:noreply,
     socket
     |> assign(:selected_source, source)
     |> recompute_filtered_packs()}
  end

  def handle_event("select_tab", %{"tab" => tab}, socket) when tab in ["all", "available", "installed", "updates"] do
    {:noreply,
     socket
     |> assign(:active_tab, tab)
     |> recompute_filtered_packs()}
  end

  ## Pack Detail Drawer Events

  def handle_event("open_pack_detail", %{"slug" => slug}, socket) do
    case backend().get_pack(slug, scope: socket.assigns.current_scope) do
      {:ok, pack} ->
        first_check_slug =
          case Map.get(pack, "checks", []) do
            [%{"slug" => s} | _] -> s
            _ -> nil
          end

        {:noreply,
         socket
         |> assign(:detail_pack, pack)
         |> assign(:detail_tab, "overview")
         |> assign(:detail_check_slug, first_check_slug)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Unable to load pack: #{format_error(reason)}")}
    end
  end

  def handle_event("close_pack_detail", _params, socket) do
    {:noreply, assign(socket, :detail_pack, nil)}
  end

  def handle_event("select_detail_tab", %{"tab" => tab}, socket) when tab in ["overview", "dag", "resources", "json"] do
    {:noreply, assign(socket, :detail_tab, tab)}
  end

  def handle_event("select_detail_check", %{"slug" => slug}, socket) do
    {:noreply, assign(socket, :detail_check_slug, slug)}
  end

  ## 4-Step Guided Install / Upgrade Wizard Events

  def handle_event("open_install_wizard", %{"slug" => slug}, socket) do
    if socket.assigns.can_install do
      case backend().get_pack(slug, scope: socket.assigns.current_scope) do
        {:ok, pack} ->
          {:noreply, open_wizard_for_pack(socket, pack, nil)}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Unable to open install wizard: #{format_error(reason)}")}
      end
    else
      {:noreply, unauthorized_flash(socket, @install_permission)}
    end
  end

  def handle_event("close_install_wizard", _params, socket) do
    {:noreply, assign(socket, :wizard, nil)}
  end

  def handle_event("wizard_update_config", %{"config" => cfg}, socket) do
    case socket.assigns.wizard do
      nil ->
        {:noreply, socket}

      wizard ->
        merged = Map.merge(wizard.config_values, cfg)
        {:noreply, assign(socket, :wizard, %{wizard | config_values: merged, error: nil})}
    end
  end

  def handle_event("wizard_update_bindings", %{"bindings" => bindings}, socket) do
    case socket.assigns.wizard do
      nil ->
        {:noreply, socket}

      wizard ->
        merged = Map.merge(wizard.credential_bindings, bindings)
        {:noreply, assign(socket, :wizard, %{wizard | credential_bindings: merged, error: nil})}
    end
  end

  def handle_event("wizard_set_decision", %{"key" => key, "decision" => decision}, socket)
      when decision in ["keep_customized", "reset_to_upstream"] do
    case socket.assigns.wizard do
      nil ->
        {:noreply, socket}

      wizard ->
        decisions = Map.put(wizard.decisions, key, decision)
        next_wizard = %{wizard | decisions: decisions, error: nil}
        {:noreply, refresh_wizard_preview(socket, next_wizard)}
    end
  end

  def handle_event("wizard_prev_step", _params, socket) do
    case socket.assigns.wizard do
      %{step: step} = wizard when step > 1 ->
        {:noreply, assign(socket, :wizard, %{wizard | step: step - 1, error: nil})}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("wizard_next_step", _params, socket) do
    case socket.assigns.wizard do
      %{step: 1} = wizard ->
        dep_report =
          case backend().check_dependencies(wizard.pack,
                 scope: socket.assigns.current_scope
               ) do
            {:ok, report} ->
              report

            _ ->
              %{
                ready?: true,
                dependencies: [],
                worker_dependencies: [],
                dashboard_package_dependencies: []
              }
          end

        {:noreply,
         assign(socket, :wizard, %{
           wizard
           | step: 2,
             dependency_report: dep_report,
             error: nil
         })}

      %{step: 2} = wizard ->
        {:noreply, refresh_wizard_preview(socket, %{wizard | step: 3, error: nil})}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("wizard_toggle_activate_dashboards", _params, socket) do
    if socket.assigns.can_install and socket.assigns.can_activate_dashboards do
      case socket.assigns.wizard do
        nil ->
          {:noreply, socket}

        wizard ->
          {:noreply,
           assign(socket, :wizard, %{
             wizard
             | activate_dashboard_packages: not wizard.activate_dashboard_packages,
               error: nil
           })}
      end
    else
      {:noreply, unauthorized_flash(socket, "dashboards.packages.manage")}
    end
  end

  def handle_event("wizard_toggle_install_paused", _params, socket) do
    case socket.assigns.wizard do
      nil ->
        {:noreply, socket}

      wizard ->
        {:noreply,
         assign(socket, :wizard, %{
           wizard
           | install_paused: not wizard.install_paused,
             error: nil
         })}
    end
  end

  def handle_event("wizard_apply_install", _params, socket) do
    if socket.assigns.can_install do
      case socket.assigns.wizard do
        nil ->
          {:noreply, socket}

        wizard ->
          pack_input = wizard.uploaded_files || wizard.pack["slug"]
          params = build_reconcile_params(wizard)

          install_opts = [
            scope: socket.assigns.current_scope,
            activate_dashboard_packages: wizard.activate_dashboard_packages == true,
            install_paused: wizard.install_paused == true
          ]

          case backend().install_pack(pack_input, params, install_opts) do
            {:ok, result} ->
              {:noreply,
               socket
               |> assign(:wizard, %{wizard | step: 4, apply_result: result, error: nil})
               |> load_catalog_data()
               |> put_flash(:info, "Solution Pack \"#{wizard.pack["name"]}\" applied successfully")}

            {:error, reason} ->
              {:noreply, assign(socket, :wizard, %{wizard | error: format_error(reason)})}
          end
      end
    else
      {:noreply, unauthorized_flash(socket, @install_permission)}
    end
  end

  def handle_event("open_uninstall_confirm", %{"slug" => slug}, socket) do
    if socket.assigns.can_install do
      pack = Enum.find(socket.assigns.packs, &(&1["slug"] == slug)) || socket.assigns.detail_pack
      {:noreply, assign(socket, :uninstall_confirm_pack, pack)}
    else
      {:noreply, unauthorized_flash(socket, @install_permission)}
    end
  end

  def handle_event("cancel_uninstall", _params, socket) do
    {:noreply, assign(socket, :uninstall_confirm_pack, nil)}
  end

  def handle_event("confirm_uninstall_pack", %{"slug" => slug}, socket) do
    if socket.assigns.can_install do
      case backend().uninstall_pack(slug, scope: socket.assigns.current_scope) do
        {:ok, _res} ->
          {:noreply,
           socket
           |> assign(:uninstall_confirm_pack, nil)
           |> assign(:detail_pack, nil)
           |> load_catalog_data()
           |> put_flash(:info, "Solution Pack uninstalled (detached resources preserved)")}

        {:error, reason} ->
          {:noreply,
           socket
           |> assign(:uninstall_confirm_pack, nil)
           |> put_flash(:error, "Uninstall failed: #{format_error(reason)}")}
      end
    else
      {:noreply, unauthorized_flash(socket, @install_permission)}
    end
  end

  def handle_event("confirm_detach_pack", %{"slug" => slug}, socket) do
    if socket.assigns.can_install do
      case backend().detach_pack(slug, scope: socket.assigns.current_scope) do
        {:ok, _res} ->
          {:noreply,
           socket
           |> assign(:uninstall_confirm_pack, nil)
           |> assign(:detail_pack, nil)
           |> load_catalog_data()
           |> put_flash(:info, "Solution Pack detached (all resources preserved as managed: false)")}

        {:error, reason} ->
          {:noreply,
           socket
           |> assign(:uninstall_confirm_pack, nil)
           |> put_flash(:error, "Detach failed: #{format_error(reason)}")}
      end
    else
      {:noreply, unauthorized_flash(socket, @install_permission)}
    end
  end

  ## Import .srpack / .json Upload Events

  def handle_event("open_import_modal", _params, socket) do
    if socket.assigns.can_install do
      {:noreply, socket |> assign(:import_modal_open, true) |> assign(:upload_error, nil)}
    else
      {:noreply, unauthorized_flash(socket, @install_permission)}
    end
  end

  def handle_event("close_import_modal", _params, socket) do
    {:noreply, socket |> assign(:import_modal_open, false) |> assign(:upload_error, nil)}
  end

  def handle_event("validate_upload", _params, socket) do
    {:noreply, assign(socket, :upload_error, nil)}
  end

  # The path is the temp file LiveView created for the consumed upload entry.
  # sobelow_skip ["Traversal.FileModule"]
  def handle_event("submit_upload", _params, socket) do
    if socket.assigns.can_install do
      results =
        consume_uploaded_entries(socket, :pack_bundle, fn %{path: path}, entry ->
          bytes = File.read!(path)
          {:ok, parse_uploaded_bundle(bytes, entry.client_name)}
        end)

      case results do
        [{:ok, validated}] ->
          pack_map = validated_to_wizard_pack(validated)

          {:noreply,
           socket
           |> assign(:import_modal_open, false)
           |> assign(:upload_error, nil)
           |> open_wizard_for_pack(pack_map, validated.files)}

        [{:error, reason}] ->
          {:noreply, assign(socket, :upload_error, format_error(reason))}

        [] ->
          {:noreply, assign(socket, :upload_error, "Please select a .srpack, .zip, or .json file")}
      end
    else
      {:noreply, unauthorized_flash(socket, @install_permission)}
    end
  end

  ## Catalog Repositories Modal Events

  def handle_event("open_repositories_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:repos_modal_open, true)
     |> assign(:repo_error, nil)
     |> assign(:repo_test_result, nil)}
  end

  def handle_event("close_repositories_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:repos_modal_open, false)
     |> assign(:editing_repo_id, nil)
     |> assign(:repo_form, default_repo_form())
     |> assign(:repo_error, nil)
     |> assign(:repo_test_result, nil)}
  end

  def handle_event("change_repository_form", %{"repo" => params}, socket) do
    {:noreply, assign(socket, :repo_form, Map.merge(socket.assigns.repo_form, params))}
  end

  def handle_event("edit_repository", %{"id" => id}, socket) do
    if socket.assigns.can_manage_repos do
      case Enum.find(socket.assigns.repositories, &(&1["id"] == id)) do
        nil ->
          {:noreply, socket}

        repo ->
          form = %{
            "name" => repo["name"] || "",
            "mode" => repo["mode"] || "release_catalog",
            "provider_type" => repo["provider_type"] || "github",
            "repo_url" => repo["repo_url"] || "",
            "branch" => repo["branch"] || "main",
            "base_path" => repo["base_path"] || "packs",
            "push_strategy" => repo["push_strategy"] || "pull_request",
            "signing_key_id" => repo["signing_key_id"] || "",
            "signing_public_key" => repo["signing_public_key"] || "",
            "credential_secret_id" => repo["credential_secret_id"] || ""
          }

          {:noreply,
           socket
           |> assign(:editing_repo_id, id)
           |> assign(:repo_form, form)
           |> assign(:repo_error, nil)}
      end
    else
      {:noreply, unauthorized_flash(socket, @manage_repos_permission)}
    end
  end

  def handle_event("cancel_edit_repository", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing_repo_id, nil)
     |> assign(:repo_form, default_repo_form())
     |> assign(:repo_error, nil)}
  end

  def handle_event("save_repository", %{"repo" => params}, socket) do
    if socket.assigns.can_manage_repos do
      scope = socket.assigns.current_scope

      result =
        case socket.assigns.editing_repo_id do
          nil -> backend().create_repository(params, scope: scope)
          id -> backend().update_repository(id, params, scope: scope)
        end

      case result do
        {:ok, _repo} ->
          {:noreply,
           socket
           |> assign(:editing_repo_id, nil)
           |> assign(:repo_form, default_repo_form())
           |> assign(:repo_error, nil)
           |> load_catalog_data()
           |> put_flash(:info, "Catalog repository saved")}

        {:error, reason} ->
          {:noreply, assign(socket, :repo_error, format_error(reason))}
      end
    else
      {:noreply, unauthorized_flash(socket, @manage_repos_permission)}
    end
  end

  def handle_event("toggle_repository", %{"id" => id, "enabled" => enabled_str}, socket) do
    if socket.assigns.can_manage_repos do
      enabled? = enabled_str == "true"

      case backend().set_repository_enabled(id, enabled?, scope: socket.assigns.current_scope) do
        {:ok, _repo} ->
          {:noreply,
           socket
           |> load_catalog_data()
           |> put_flash(:info, if(enabled?, do: "Repository enabled", else: "Repository disabled"))}

        {:error, reason} ->
          {:noreply, assign(socket, :repo_error, format_error(reason))}
      end
    else
      {:noreply, unauthorized_flash(socket, @manage_repos_permission)}
    end
  end

  def handle_event("delete_repository", %{"id" => id}, socket) do
    if socket.assigns.can_manage_repos do
      case backend().delete_repository(id, scope: socket.assigns.current_scope) do
        :ok ->
          {:noreply,
           socket
           |> load_catalog_data()
           |> put_flash(:info, "Catalog repository removed")}

        {:error, reason} ->
          {:noreply, assign(socket, :repo_error, format_error(reason))}
      end
    else
      {:noreply, unauthorized_flash(socket, @manage_repos_permission)}
    end
  end

  def handle_event("test_repository", %{"id" => id}, socket) do
    if socket.assigns.can_manage_repos or socket.assigns.can_gitops_sync do
      case backend().test_repository(id, scope: socket.assigns.current_scope) do
        {:ok, result} ->
          {:noreply,
           socket
           |> assign(:repo_test_result, result)
           |> assign(:repo_error, nil)}

        {:error, reason} ->
          {:noreply,
           socket
           |> assign(:repo_test_result, nil)
           |> assign(:repo_error, "Connection test failed: #{format_error(reason)}")}
      end
    else
      {:noreply, unauthorized_flash(socket, @manage_repos_permission)}
    end
  end

  def handle_event("sync_repository", %{"id" => id}, socket) do
    if socket.assigns.can_manage_repos or socket.assigns.can_gitops_sync do
      case backend().sync_repository(id, scope: socket.assigns.current_scope) do
        {:ok, _summary} ->
          {:noreply,
           socket
           |> load_catalog_data()
           |> put_flash(:info, "Repository sync completed")}

        {:error, reason} ->
          {:noreply, assign(socket, :repo_error, "Sync failed: #{format_error(reason)}")}
      end
    else
      {:noreply, unauthorized_flash(socket, @gitops_sync_permission)}
    end
  end

  ## GitOps Push & Pull Promotion Events

  def handle_event("open_gitops_push", params, socket) do
    if socket.assigns.can_gitops_sync do
      slug = Map.get(params, "slug", "")

      first_gitops_id =
        socket.assigns.repositories
        |> Enum.find(&(&1["mode"] == "gitops_tree"))
        |> case do
          %{"id" => id} -> id
          _ -> ""
        end

      form = %{
        "repository_id" => first_gitops_id,
        "pack_slug" => slug,
        "commit_message" => if(slug == "", do: "chore(packs): sync pack", else: "chore(packs): sync #{slug}")
      }

      {:noreply,
       socket
       |> assign(:gitops_push_open, true)
       |> assign(:gitops_push_form, form)
       |> assign(:gitops_push_result, nil)
       |> assign(:gitops_push_error, nil)}
    else
      {:noreply, unauthorized_flash(socket, @gitops_sync_permission)}
    end
  end

  def handle_event("close_gitops_push", _params, socket) do
    {:noreply, assign(socket, :gitops_push_open, false)}
  end

  def handle_event("change_gitops_push", %{"push" => params}, socket) do
    {:noreply, assign(socket, :gitops_push_form, Map.merge(socket.assigns.gitops_push_form, params))}
  end

  def handle_event("submit_gitops_push", %{"push" => params}, socket) do
    if socket.assigns.can_gitops_sync do
      repo_id = params["repository_id"] || ""
      slug = params["pack_slug"] || ""
      commit_message = params["commit_message"] || "chore(packs): sync #{slug}"
      scope = socket.assigns.current_scope

      with {:ok, payload} <- backend().build_push_payload(slug, %{}, scope: scope),
           {:ok, result} <-
             backend().push_to_gitops(repo_id, payload,
               scope: scope,
               commit_message: commit_message
             ) do
        {:noreply,
         socket
         |> assign(:gitops_push_result, result)
         |> assign(:gitops_push_error, nil)
         |> put_flash(:info, "Solution Pack pushed to GitOps repository")}
      else
        {:error, reason} ->
          {:noreply, assign(socket, :gitops_push_error, format_error(reason))}
      end
    else
      {:noreply, unauthorized_flash(socket, @gitops_sync_permission)}
    end
  end

  def handle_event("open_gitops_pull", %{"id" => repo_id}, socket) do
    if socket.assigns.can_gitops_sync do
      {:noreply,
       socket
       |> assign(:gitops_pull_open, true)
       |> assign(:gitops_pull_state, %{
         repository_id: repo_id,
         form: %{"slug" => "", "ref" => ""},
         preview: nil,
         error: nil
       })}
    else
      {:noreply, unauthorized_flash(socket, @gitops_sync_permission)}
    end
  end

  def handle_event("close_gitops_pull", _params, socket) do
    {:noreply, assign(socket, :gitops_pull_open, false)}
  end

  def handle_event("change_gitops_pull", %{"pull" => params}, socket) do
    state = socket.assigns.gitops_pull_state
    {:noreply, assign(socket, :gitops_pull_state, %{state | form: Map.merge(state.form, params)})}
  end

  def handle_event("preview_gitops_pull", %{"pull" => params}, socket) do
    if socket.assigns.can_gitops_sync do
      state = socket.assigns.gitops_pull_state
      slug = String.trim(params["slug"] || "")

      ref =
        case String.trim(params["ref"] || "") do
          "" -> nil
          val -> val
        end

      opts = [scope: socket.assigns.current_scope, dry_run: true] ++ if(ref, do: [ref: ref], else: [])

      case backend().pull_from_gitops(state.repository_id, slug, opts) do
        {:ok, preview} ->
          {:noreply,
           assign(socket, :gitops_pull_state, %{
             state
             | form: Map.merge(state.form, params),
               preview: preview,
               error: nil
           })}

        {:error, reason} ->
          {:noreply,
           assign(socket, :gitops_pull_state, %{
             state
             | preview: nil,
               error: format_error(reason)
           })}
      end
    else
      {:noreply, unauthorized_flash(socket, @gitops_sync_permission)}
    end
  end

  def handle_event("apply_gitops_pull", _params, socket) do
    if socket.assigns.can_gitops_sync do
      state = socket.assigns.gitops_pull_state
      slug = String.trim(state.form["slug"] || "")

      ref =
        case String.trim(state.form["ref"] || "") do
          "" -> nil
          val -> val
        end

      opts = [scope: socket.assigns.current_scope, dry_run: false] ++ if(ref, do: [ref: ref], else: [])

      case backend().pull_from_gitops(state.repository_id, slug, opts) do
        {:ok, _applied} ->
          {:noreply,
           socket
           |> assign(:gitops_pull_open, false)
           |> load_catalog_data()
           |> put_flash(:info, "GitOps promotion applied for #{slug}")}

        {:error, reason} ->
          {:noreply, assign(socket, :gitops_pull_state, %{state | error: format_error(reason)})}
      end
    else
      {:noreply, unauthorized_flash(socket, @gitops_sync_permission)}
    end
  end

  @impl true
  def handle_info({:vantage_worker_heartbeat, _payload}, socket) do
    if connected?(socket) do
      summary = vantage_workers_backend().summary(socket.assigns.current_scope)
      {:noreply, assign(socket, :vantage_worker_summary, summary)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  ## Render

  @impl true
  def render(assigns) do
    gitops_repos = Enum.filter(assigns.repositories, &(&1["mode"] == "gitops_tree"))
    assigns = assign(assigns, :gitops_repos, gitops_repos)

    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path={@current_path}
      page_title={@page_title}
      shell={:operations}
    >
      <div id="solution-packs-catalog" class="mx-auto max-w-7xl space-y-6 px-4 py-6 sm:px-6 lg:px-8">
        <header class="flex flex-wrap items-start justify-between gap-4">
          <div>
            <h1 class="text-2xl font-semibold tracking-tight text-sr-ink">
              Solution Packs Catalog
            </h1>
            <p class="mt-1 text-sm text-sr-muted">
              Browse, preview, and install secret-free monitoring bundles combining Declarative Checks,
              alert rules, and authored dashboards.
            </p>
          </div>

          <div class="flex flex-wrap items-center gap-2">
            <a
              id="developer-portal-packs-link"
              href={Catalog.developer_portal_url()}
              target="_blank"
              rel="noopener noreferrer"
              class="inline-flex items-center gap-1.5 rounded-sr-control border border-sr-line bg-sr-control px-3 py-1.5 text-xs font-medium text-sr-ink hover:bg-sr-subtle"
            >
              <.icon name="hero-globe-alt" class="size-4 text-sr-brand" /> Developer Portal Catalog
            </a>

            <.ui_button
              :if={@can_install}
              id="open-import-pack-btn"
              type="button"
              size="sm"
              variant="outline"
              phx-click="open_import_modal"
            >
              <.icon name="hero-arrow-up-tray" class="size-4" /> Import .srpack / .json
            </.ui_button>

            <.ui_button
              :if={@can_gitops_sync}
              id="open-gitops-push-btn"
              type="button"
              size="sm"
              variant="outline"
              phx-click="open_gitops_push"
            >
              <.icon name="hero-cloud-arrow-up" class="size-4" /> Push to Git
            </.ui_button>

            <.ui_button
              id="open-repositories-btn"
              type="button"
              size="sm"
              variant="primary"
              phx-click="open_repositories_modal"
            >
              <.icon name="hero-circle-stack" class="size-4" /> Repositories ({length(@repositories)})
            </.ui_button>
          </div>
        </header>

        <section
          id="vantage-worker-health-strip"
          class="rounded-xl border border-sr-line bg-sr-surface px-4 py-3 space-y-2"
        >
          <div class="flex flex-wrap items-center justify-between gap-3">
            <div class="flex flex-wrap items-center gap-2">
              <span class="text-xs font-semibold uppercase tracking-wider text-sr-muted">
                Vantage ML Worker Pool
              </span>
              <.ui_badge
                id="catalog-vantage-routing-badge"
                size="xs"
                variant={vantage_routing_badge_variant(@vantage_worker_summary.routing_mode)}
              >
                {vantage_routing_label(@vantage_worker_summary.routing_mode)}
              </.ui_badge>
              <span class="text-xs text-sr-muted">
                {@vantage_worker_summary.online_count} online · {@vantage_worker_summary.stale_count} stale
              </span>
            </div>

            <div class="flex flex-wrap items-center gap-3 text-xs text-sr-muted">
              <span :if={@vantage_worker_summary.queue_lag.accessible?}>
                Queue:
                <strong class="text-sr-ink">{@vantage_worker_summary.queue_lag.pending_count}</strong>
                pending ·
                <strong class="text-sr-ink">{@vantage_worker_summary.queue_lag.dispatched_count}</strong>
                dispatched
                <span :if={is_integer(@vantage_worker_summary.queue_lag.oldest_pending_age_seconds)}>
                  · oldest {@vantage_worker_summary.queue_lag.oldest_pending_age_seconds}s
                </span>
              </span>
            </div>
          </div>

          <div
            :if={@vantage_worker_summary.workers != []}
            class="flex flex-wrap gap-2 pt-1"
          >
            <div
              :for={worker <- @vantage_worker_summary.workers}
              id={"catalog-worker-#{slugify_id(worker.worker_id)}"}
              class="flex flex-wrap items-center gap-1.5 rounded-lg border border-sr-line bg-sr-subtle px-2.5 py-1 text-xs"
            >
              <span class="font-mono font-medium text-sr-ink">{worker.worker_id}</span>
              <.ui_badge size="xs" variant={if(worker.online?, do: "success", else: "warning")}>
                {if(worker.stale?, do: "stale", else: worker.health)}
              </.ui_badge>
              <span class="font-mono text-[11px] text-sr-muted">
                {Enum.join(worker.capabilities, ", ")} · {worker.architecture} · {worker.model_id}:{worker.model_version} · {worker.active_jobs}/{worker.max_concurrency}
              </span>
            </div>
          </div>
        </section>

        <section class="rounded-xl border border-sr-line bg-sr-surface p-4 space-y-4">
          <div class="flex flex-wrap items-center justify-between gap-3">
            <div class="flex flex-wrap items-center gap-1" role="tablist">
              <button
                :for={
                  {tab_id, label} <- [
                    {"all", "All Packs"},
                    {"available", "Available"},
                    {"installed", "Installed"},
                    {"updates", "Updates Available"}
                  ]
                }
                id={"catalog-tab-#{tab_id}"}
                type="button"
                role="tab"
                aria-selected={@active_tab == tab_id}
                phx-click="select_tab"
                phx-value-tab={tab_id}
                class={[
                  "rounded-sr-control px-3 py-1.5 text-xs font-medium transition-colors",
                  if(@active_tab == tab_id,
                    do: "bg-sr-brand text-white shadow-xs",
                    else: "text-sr-muted hover:bg-sr-subtle hover:text-sr-ink"
                  )
                ]}
              >
                {label}
              </button>
            </div>

            <div class="flex flex-wrap items-center gap-2">
              <form id="catalog-search-form" phx-change="search" class="w-64">
                <input
                  id="catalog-search-input"
                  type="search"
                  name="q"
                  value={@search}
                  placeholder="Search packs, checks, rules..."
                  phx-debounce="150"
                  class={ui_field_class(size: "sm", class: "w-full")}
                />
              </form>

              <form id="catalog-source-form" phx-change="select_source">
                <select
                  id="catalog-source-select"
                  name="source"
                  class={ui_field_class(size: "sm")}
                  aria-label="Filter by catalog source"
                >
                  <option value="all" selected={@selected_source == "all"}>All Sources</option>
                  <option value="builtin" selected={@selected_source == "builtin"}>Built-in</option>
                  <option
                    :for={repo <- @repositories}
                    value={repo["mode"]}
                    selected={@selected_source == repo["mode"]}
                  >
                    {repo["name"]} ({repo["mode"]})
                  </option>
                </select>
              </form>
            </div>
          </div>

          <div class="flex flex-wrap items-center gap-1.5" role="group" aria-label="Category filters">
            <button
              id="category-pill-all"
              type="button"
              phx-click="select_category"
              phx-value-category="all"
              class={[
                "rounded-full border px-3 py-1 text-xs font-medium transition-colors",
                if(@selected_category == "all",
                  do: "border-sr-brand bg-sr-brand/15 text-sr-brand",
                  else: "border-sr-line bg-sr-subtle text-sr-muted hover:text-sr-ink"
                )
              ]}
            >
              All Categories
            </button>
            <button
              :for={cat <- Catalog.categories()}
              id={"category-pill-#{slugify_id(cat)}"}
              type="button"
              phx-click="select_category"
              phx-value-category={cat}
              class={[
                "rounded-full border px-3 py-1 text-xs font-medium transition-colors",
                if(@selected_category == cat,
                  do: "border-sr-brand bg-sr-brand/15 text-sr-brand",
                  else: "border-sr-line bg-sr-subtle text-sr-muted hover:text-sr-ink"
                )
              ]}
            >
              {cat}
            </button>
          </div>
        </section>

        <div
          :if={@loading?}
          id="catalog-loading-state"
          class="rounded-xl border border-sr-line bg-sr-surface p-10 text-center text-sm text-sr-muted"
        >
          Loading Solution Packs catalog...
        </div>

        <div
          :if={!@loading? and @filtered_packs == []}
          id="catalog-empty-state"
          class="rounded-xl border border-sr-line bg-sr-surface p-10 text-center text-sm text-sr-muted"
        >
          No Solution Packs match the current search or filter criteria.
        </div>

        <div
          :if={!@loading? and @filtered_packs != []}
          id="catalog-pack-grid"
          class="grid grid-cols-1 gap-4 md:grid-cols-2 lg:grid-cols-3"
        >
          <article
            :for={pack <- @filtered_packs}
            id={"pack-card-#{pack["slug"]}"}
            data-role="solution-pack-card"
            class="flex flex-col justify-between rounded-xl border border-sr-line bg-sr-surface p-5 shadow-xs transition-colors hover:border-sr-brand/50"
          >
            <div class="space-y-3">
              <div class="flex items-start justify-between gap-3">
                <div class="flex items-center gap-3 min-w-0">
                  <div class="flex size-11 shrink-0 items-center justify-center rounded-lg border border-sr-line bg-sr-subtle p-1.5">
                    <img
                      :if={
                        is_binary(pack["icon"]) and
                          String.starts_with?(pack["icon"], "data:image/svg+xml;base64,")
                      }
                      src={pack["icon"]}
                      alt=""
                      class="size-8 object-contain"
                    />
                    <.icon
                      :if={
                        not (is_binary(pack["icon"]) and
                               String.starts_with?(pack["icon"], "data:image/svg+xml;base64,"))
                      }
                      name="hero-cube-transparent"
                      class="size-6 text-sr-brand"
                    />
                  </div>
                  <div class="min-w-0">
                    <h2 class="truncate text-sm font-semibold text-sr-ink">{pack["name"]}</h2>
                    <p class="truncate font-mono text-[11px] text-sr-muted">{pack["id"]}</p>
                  </div>
                </div>
                <.ui_badge variant="outline" size="xs">v{pack["version"]}</.ui_badge>
              </div>

              <p class="line-clamp-3 text-xs leading-relaxed text-sr-muted">
                {pack["description"]}
              </p>

              <div class="flex flex-wrap items-center gap-1.5">
                <.ui_badge variant="info" size="xs">
                  {source_label(pack["source_type"])}
                </.ui_badge>
                <.ui_badge :if={pack["installed"]} variant="success" size="xs">
                  Installed v{pack["installed_version"] || pack["version"]}
                </.ui_badge>
                <.ui_badge :if={pack["update_available"]} variant="warning" size="xs">
                  Update v{pack["available_version"]}
                </.ui_badge>
                <.ui_badge :for={cat <- pack["categories"] || []} variant="ghost" size="xs">
                  {cat}
                </.ui_badge>
              </div>
            </div>

            <div class="mt-4 border-t border-sr-line pt-3 space-y-3">
              <div data-role="whats-inside-badge" class="text-[11px] font-medium text-sr-muted">
                {get_in(pack, ["counts", "checks"]) || 0} checks
                * {get_in(pack, ["counts", "rules"]) || 0} alert rules
                * {get_in(pack, ["counts", "dashboards"]) || 0} dashboards
                <span :if={(get_in(pack, ["counts", "vantage_pipelines"]) || 0) > 0}>
                  * {get_in(pack, ["counts", "vantage_pipelines"])} vantage pipelines
                </span>
                <span :if={(get_in(pack, ["counts", "dashboard_packages"]) || 0) > 0}>
                  * {get_in(pack, ["counts", "dashboard_packages"])} dashboard modules
                </span>
              </div>

              <div class="flex items-center justify-between gap-2">
                <.ui_button
                  id={"preview-pack-#{pack["slug"]}"}
                  type="button"
                  size="xs"
                  variant="ghost"
                  phx-click="open_pack_detail"
                  phx-value-slug={pack["slug"]}
                >
                  Preview & Docs
                </.ui_button>

                <div class="flex items-center gap-1.5">
                  <.ui_button
                    :if={@can_install and pack["installed"]}
                    id={"uninstall-pack-#{pack["slug"]}"}
                    type="button"
                    size="xs"
                    variant="ghost"
                    phx-click="open_uninstall_confirm"
                    phx-value-slug={pack["slug"]}
                  >
                    Uninstall
                  </.ui_button>

                  <.ui_button
                    :if={@can_install}
                    id={"install-pack-#{pack["slug"]}"}
                    type="button"
                    size="xs"
                    variant="primary"
                    phx-click="open_install_wizard"
                    phx-value-slug={pack["slug"]}
                  >
                    {if(pack["installed"], do: "Upgrade / Configure", else: "Install")}
                  </.ui_button>
                </div>
              </div>
            </div>
          </article>
        </div>
      </div>

      <.pack_detail_drawer
        :if={@detail_pack}
        pack={@detail_pack}
        active_tab={@detail_tab}
        selected_check_slug={@detail_check_slug}
        vantage_worker_summary={@vantage_worker_summary}
        can_install={@can_install}
        can_export={@can_export}
        can_gitops_sync={@can_gitops_sync}
      />

      <.install_wizard_modal
        :if={@wizard}
        wizard={@wizard}
        credential_options={@credential_options}
        can_activate_dashboards={@can_activate_dashboards}
      />

      <div
        :if={@uninstall_confirm_pack}
        id="pack-uninstall-confirm-modal"
        class="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4 backdrop-blur-xs"
        role="dialog"
        aria-modal="true"
        aria-label="Uninstall Solution Pack"
      >
        <div class="w-full max-w-md rounded-xl border border-sr-line bg-sr-surface p-6 shadow-2xl space-y-4">
          <h2 class="text-base font-semibold text-sr-ink">
            Uninstall {@uninstall_confirm_pack["name"]}
          </h2>
          <p class="text-xs text-sr-muted leading-relaxed">
            Removing this Solution Pack cleans up all <code class="font-mono">managed: true</code>
            checks, alert rules, dashboards, Vantage pipelines, and unreferenced dashboard bundles while preserving any
            <code class="font-mono">managed: false</code>
            operator-detached copies.
          </p>
          <div class="flex flex-wrap justify-end gap-2 pt-2">
            <.ui_button type="button" size="sm" variant="ghost" phx-click="cancel_uninstall">
              Cancel
            </.ui_button>
            <.ui_button
              id="confirm-detach-pack-btn"
              type="button"
              size="sm"
              variant="outline"
              phx-click="confirm_detach_pack"
              phx-value-slug={@uninstall_confirm_pack["slug"]}
            >
              Detach Only
            </.ui_button>
            <.ui_button
              id="confirm-uninstall-pack-btn"
              type="button"
              size="sm"
              variant="danger"
              phx-click="confirm_uninstall_pack"
              phx-value-slug={@uninstall_confirm_pack["slug"]}
            >
              Uninstall Pack
            </.ui_button>
          </div>
        </div>
      </div>

      <.repositories_modal
        open={@repos_modal_open}
        repositories={@repositories}
        credential_options={@credential_options}
        repo_form={@repo_form}
        editing_repo_id={@editing_repo_id}
        repo_error={@repo_error}
        test_result={@repo_test_result}
        can_manage_repos={@can_manage_repos}
        can_gitops_sync={@can_gitops_sync}
      />

      <.gitops_push_modal
        open={@gitops_push_open}
        gitops_repos={@gitops_repos}
        push_form={@gitops_push_form}
        push_result={@gitops_push_result}
        push_error={@gitops_push_error}
      />

      <.gitops_pull_drawer
        open={@gitops_pull_open}
        pull_state={@gitops_pull_state}
      />

      <.import_pack_modal
        open={@import_modal_open}
        upload_error={@upload_error}
        uploads={@uploads}
      />
    </Layouts.app>
    """
  end

  ## Private helpers

  defp backend do
    Application.get_env(:serviceradar_web_ng, :catalog_backend, Catalog)
  end

  defp vantage_workers_backend do
    Application.get_env(:serviceradar_web_ng, :catalog_vantage_workers_backend, CameraVantageWorkers)
  end

  defp maybe_subscribe_vantage_workers(%{assigns: %{vantage_worker_subscribed?: true}} = socket), do: socket

  defp maybe_subscribe_vantage_workers(socket) do
    _ = VantagePubSub.subscribe_worker_health()
    assign(socket, :vantage_worker_subscribed?, true)
  end

  defp vantage_routing_badge_variant(:ramp_2), do: "success"
  defp vantage_routing_badge_variant(:mixed), do: "info"
  defp vantage_routing_badge_variant(:ramp_1_fallback), do: "warning"
  defp vantage_routing_badge_variant(:held), do: "error"
  defp vantage_routing_badge_variant(_), do: "ghost"

  defp vantage_routing_label(:ramp_2), do: "Ramp 2: vantage.worker.v1 active"
  defp vantage_routing_label(:mixed), do: "Mixed: Ramp 2 + Ramp 1 fallback"
  defp vantage_routing_label(:ramp_1_fallback), do: "Ramp 1: camera_vlm active"
  defp vantage_routing_label(:held), do: "Held (awaiting worker)"
  defp vantage_routing_label(_), do: "Idle (no active workers)"

  defp can_view?(scope) do
    RBAC.can?(scope, @view_permission) or
      RBAC.can?(scope, @install_permission) or
      RBAC.can?(scope, @export_permission) or
      RBAC.can?(scope, @manage_repos_permission) or
      RBAC.can?(scope, @gitops_sync_permission)
  end

  defp load_catalog_data(socket) do
    scope = socket.assigns.current_scope

    packs =
      case backend().list_packs(scope: scope) do
        {:ok, list} -> list
        _ -> []
      end

    repos =
      case backend().list_repositories(scope: scope) do
        {:ok, list} -> list
        _ -> []
      end

    cred_opts = backend().list_credential_options(scope: scope)
    vantage_summary = vantage_workers_backend().summary(scope)

    socket
    |> assign(:loading?, false)
    |> assign(:packs, packs)
    |> assign(:repositories, repos)
    |> assign(:credential_options, cred_opts)
    |> assign(:vantage_worker_summary, vantage_summary)
    |> recompute_filtered_packs()
  end

  defp apply_route_params(socket, params) do
    socket =
      case Map.get(params, "slug") do
        slug when is_binary(slug) and slug != "" ->
          case backend().get_pack(slug, scope: socket.assigns.current_scope) do
            {:ok, pack} -> assign(socket, :detail_pack, pack)
            _ -> socket
          end

        _ ->
          socket
      end

    if Map.get(params, "modal") == "repositories" do
      assign(socket, :repos_modal_open, true)
    else
      socket
    end
  end

  defp recompute_filtered_packs(socket) do
    q = socket.assigns.search |> String.trim() |> String.downcase()
    cat = socket.assigns.selected_category
    source = socket.assigns.selected_source
    tab = socket.assigns.active_tab

    filtered =
      Enum.filter(socket.assigns.packs, fn pack ->
        tab_match? =
          case tab do
            "available" -> not pack["installed"]
            "installed" -> pack["installed"] == true
            "updates" -> pack["update_available"] == true
            _ -> true
          end

        cat_match? = cat == "all" or cat in List.wrap(pack["categories"])
        source_match? = source == "all" or pack["source_type"] == source

        search_match? =
          q == "" or
            String.contains?(String.downcase(pack["name"] || ""), q) or
            String.contains?(String.downcase(pack["id"] || ""), q) or
            String.contains?(String.downcase(pack["description"] || ""), q) or
            String.contains?(String.downcase(pack["author"] || ""), q)

        tab_match? and cat_match? and source_match? and search_match?
      end)

    assign(socket, :filtered_packs, filtered)
  end

  defp open_wizard_for_pack(socket, pack, uploaded_files) do
    existing_cfg = get_in(pack, ["installed_record", "config_values"]) || %{}

    default_cfg =
      Map.new(pack["config"] || [], fn cfg ->
        val = Map.get(existing_cfg, cfg["key"], cfg["default"])
        {cfg["key"], if(is_nil(val), do: "", else: to_string(val))}
      end)

    assign(socket, :wizard, %{
      pack: pack,
      uploaded_files: uploaded_files,
      step: 1,
      config_values: default_cfg,
      credential_bindings: %{},
      activate_dashboard_packages: false,
      install_paused: false,
      dependency_report: %{
        ready?: true,
        dependencies: [],
        worker_dependencies: [],
        dashboard_package_dependencies: []
      },
      preview_plan: nil,
      decisions: %{},
      apply_result: nil,
      error: nil
    })
  end

  defp refresh_wizard_preview(socket, wizard) do
    pack_input = wizard.uploaded_files || wizard.pack["slug"]
    params = build_reconcile_params(wizard)

    preview_opts = [
      scope: socket.assigns.current_scope,
      activate_dashboard_packages: wizard.activate_dashboard_packages == true,
      install_paused: wizard.install_paused == true
    ]

    case backend().preview_install(pack_input, params, preview_opts) do
      {:ok, plan} ->
        assign(socket, :wizard, %{wizard | preview_plan: plan, error: nil})

      {:error, reason} ->
        assign(socket, :wizard, %{wizard | error: format_error(reason)})
    end
  end

  defp build_reconcile_params(wizard) do
    config =
      Enum.reduce(wizard.pack["config"] || [], %{}, fn cfg, acc ->
        key = cfg["key"]
        raw = Map.get(wizard.config_values, key)
        Map.put(acc, key, coerce_config_value(raw, cfg["type"]))
      end)

    bindings =
      Enum.reduce(wizard.credential_bindings, %{}, fn {slot, val}, acc ->
        case String.split(to_string(val), ":", parts: 2) do
          ["rule", id] when id != "" -> Map.put(acc, slot, %{"credential_rule_id" => id})
          ["secret", id] when id != "" -> Map.put(acc, slot, %{"credential_secret_id" => id})
          _ -> acc
        end
      end)

    base = %{
      "config" => config,
      "credential_bindings" => bindings,
      "decisions" => wizard.decisions
    }

    base =
      if wizard.activate_dashboard_packages == true do
        Map.put(base, "activate_dashboard_packages", true)
      else
        base
      end

    if wizard.install_paused == true do
      Map.put(base, "install_paused", true)
    else
      base
    end
  end

  defp coerce_config_value(nil, _type), do: nil
  defp coerce_config_value("", _type), do: nil

  defp coerce_config_value(val, "integer") when is_binary(val) do
    case Integer.parse(String.trim(val)) do
      {n, ""} -> n
      _ -> val
    end
  end

  defp coerce_config_value(val, "duration_seconds"), do: coerce_config_value(val, "integer")

  defp coerce_config_value(val, "number") when is_binary(val) do
    case Float.parse(String.trim(val)) do
      {n, ""} -> n
      _ -> val
    end
  end

  defp coerce_config_value("true", "boolean"), do: true
  defp coerce_config_value("false", "boolean"), do: false
  defp coerce_config_value(val, _type), do: val

  defp parse_uploaded_bundle(bytes, filename) do
    if String.ends_with?(String.downcase(to_string(filename)), ".json") do
      with {:ok, decoded} <- Jason.decode(bytes),
           version when version in [1, 2, nil] <- Map.get(decoded, "pack_format_version"),
           files when is_map(files) <- Map.get(decoded, "files") do
        backend().validate_pack(files, [])
      else
        _ -> {:error, "Uploaded JSON must contain a pack_format_version: 1 or 2 files map"}
      end
    else
      backend().validate_pack(bytes, [])
    end
  end

  defp validated_to_wizard_pack(validated) do
    manifest = validated.manifest
    resources = manifest["resources"] || %{}

    %{
      "pack_format_version" => Map.get(manifest, "pack_format_version", 1),
      "id" => manifest["id"],
      "slug" => manifest["slug"],
      "name" => manifest["name"],
      "version" => manifest["version"],
      "author" => manifest["author"],
      "description" => manifest["description"],
      "categories" => List.wrap(manifest["categories"]),
      "installed" => false,
      "counts" => %{
        "checks" => length(List.wrap(resources["checks"])),
        "rules" => length(List.wrap(resources["rules"])),
        "dashboards" => length(List.wrap(resources["dashboards"])),
        "vantage_pipelines" => length(List.wrap(resources["vantage_pipelines"])),
        "signal_schemas" => length(List.wrap(resources["signal_schemas"])),
        "dashboard_packages" => length(List.wrap(resources["dashboard_packages"]))
      },
      "config" => List.wrap(manifest["config"]),
      "credential_slots" => List.wrap(manifest["credential_slots"]),
      "plugin_dependencies" => List.wrap(manifest["plugin_dependencies"]),
      "worker_dependencies" => List.wrap(manifest["worker_dependencies"]),
      "dashboard_package_dependencies" => List.wrap(manifest["dashboard_package_dependencies"]),
      "vantage_pipelines" => List.wrap(resources["vantage_pipelines"]),
      "signal_schemas" => List.wrap(resources["signal_schemas"]),
      "dashboard_packages" => List.wrap(resources["dashboard_packages"])
    }
  end

  defp can_activate_dashboards?(scope) do
    RBAC.can?(scope, "dashboards.packages.manage") or
      ((RBAC.can?(scope, "dashboards.packages.publish") or
          RBAC.can?(scope, "cli.dashboard.publish")) and
         (RBAC.can?(scope, "dashboards.packages.enable") or
            RBAC.can?(scope, "cli.dashboard.enable")))
  end

  defp default_repo_form do
    %{
      "name" => "",
      "mode" => "release_catalog",
      "provider_type" => "github",
      "repo_url" => "",
      "branch" => "main",
      "base_path" => "packs",
      "push_strategy" => "pull_request",
      "signing_key_id" => "",
      "signing_public_key" => "",
      "credential_secret_id" => ""
    }
  end

  defp default_push_form do
    %{
      "repository_id" => "",
      "pack_slug" => "",
      "commit_message" => "chore(packs): sync solution pack"
    }
  end

  defp default_pull_state do
    %{
      repository_id: nil,
      form: %{"slug" => "", "ref" => ""},
      preview: nil,
      error: nil
    }
  end

  defp source_label("builtin"), do: "Built-in"
  defp source_label("release_catalog"), do: "Signed Release"
  defp source_label("gitops_tree"), do: "GitOps Tree"
  defp source_label("upload"), do: "Local Upload"
  defp source_label(other), do: to_string(other || "Catalog")

  defp slugify_id(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp unauthorized_flash(socket, permission) do
    put_flash(socket, :error, "Missing required permission: #{permission}")
  end

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(%{message: msg}) when is_binary(msg), do: msg
  defp format_error(%{errors: errs}) when is_list(errs), do: Enum.map_join(errs, "; ", &format_error/1)
  defp format_error(reason), do: inspect(reason)
end
