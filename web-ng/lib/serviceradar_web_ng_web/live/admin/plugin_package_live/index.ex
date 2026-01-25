defmodule ServiceRadarWebNGWeb.Admin.PluginPackageLive.Index do
  @moduledoc """
  LiveView for managing Wasm plugin packages and import review.
  """

  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.SettingsComponents

  require Ash.Query

  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Plugins.Manifest
  alias ServiceRadarWebNG.Plugins.Assignments
  alias ServiceRadarWebNG.Plugins.Packages
  alias ServiceRadarWebNG.Plugins.Storage

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    socket =
      socket
      |> assign(:page_title, "Plugins")
      |> assign(:packages, list_packages(%{}, scope))
      |> assign(:filter_status, nil)
      |> assign(:filter_source_type, nil)
      |> assign(:show_create_modal, false)
      |> assign(:show_details_modal, false)
      |> assign(:create_form, default_create_form())
      |> assign(:create_errors, [])
      |> assign(:selected_package, nil)
      |> assign(:review_form, default_review_form())
      |> assign(:assignment_form, default_assignment_form())
      |> assign(:assignments, [])
      |> assign(:versions, [])
      |> assign(:agents, list_agents(scope))
      |> assign_capacity(scope)
      |> assign(:verification_policy, plugin_verification_policy())
      |> assign(:upload_url, nil)
      |> assign(:upload_expires_at, nil)
      |> assign(:download_url, nil)
      |> assign(:download_expires_at, nil)
      |> assign(:blob_present, nil)
      |> assign(:upload_errors, [])
      |> allow_upload(:wasm_blob,
        accept: ~w(.wasm),
        max_entries: 1,
        max_file_size: Storage.max_upload_bytes()
      )

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
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
        |> assign(:assignment_form, default_assignment_form())
        |> assign(:assignments, list_assignments(package.id, scope))
        |> assign(:versions, list_versions(package.plugin_id, scope))
        |> assign(:upload_errors, [])
        |> assign_package_urls(package, scope)

      {:error, :not_found} ->
        socket
        |> put_flash(:error, "Package not found")
        |> push_navigate(to: ~p"/admin/plugins")

      {:error, _error} ->
        socket
        |> put_flash(:error, "Failed to load package")
        |> push_navigate(to: ~p"/admin/plugins")
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
     |> assign(:versions, [])
     |> assign(:upload_errors, [])
     |> assign(:upload_url, nil)
     |> assign(:download_url, nil)
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
     |> assign(:packages, list_packages(filters, scope))}
  end

  def handle_event("refresh", _params, socket) do
    scope = socket.assigns.current_scope

    {:noreply,
     socket
     |> assign(:packages, list_packages(current_filters(socket), scope))
     |> assign(:agents, list_agents(scope))
     |> assign_capacity(scope)
     |> assign(:verification_policy, plugin_verification_policy())}
  end

  def handle_event("create_package", %{"create" => params}, socket) do
    scope = socket.assigns.current_scope
    socket = assign(socket, :create_form, params)

    source_type = normalize_source_type(params["source_type"])

    case source_type do
      :github ->
        with {:ok, config_schema} <- parse_optional_json_map(params["config_schema_json"]),
             attrs <-
               %{
                 source_type: :github,
                 source_repo_url: params["source_repo_url"],
                 source_commit: params["source_commit"],
                 config_schema: config_schema
               },
             {:ok, package} <- Packages.create(attrs, scope: scope) do
          {:noreply,
           socket
           |> assign(:packages, list_packages(current_filters(socket), scope))
           |> assign(:show_create_modal, false)
           |> assign(:create_form, default_create_form())
           |> assign(:create_errors, [])
           |> put_flash(:info, "Plugin package staged")
           |> push_navigate(to: ~p"/admin/plugins/#{package.id}")}
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
            {:noreply,
             socket
             |> put_flash(:error, "Failed to import GitHub package: #{format_error(error)}")}
        end

      _ ->
        with {:ok, manifest} <- parse_manifest(params["manifest_yaml"]),
             {:ok, config_schema} <- parse_optional_json_map(params["config_schema_json"]),
             attrs <-
               build_create_attrs(params,
                 manifest: manifest,
                 config_schema: config_schema
               ),
             {:ok, package} <- Packages.create(attrs, scope: scope) do
          {:noreply,
           socket
           |> assign(:packages, list_packages(current_filters(socket), scope))
           |> assign(:show_create_modal, false)
           |> assign(:create_form, default_create_form())
           |> assign(:create_errors, [])
           |> put_flash(:info, "Plugin package staged")
           |> push_navigate(to: ~p"/admin/plugins/#{package.id}")}
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
            {:noreply,
             socket
             |> put_flash(:error, "Failed to create package: #{format_error(error)}")}
        end
    end
  end

  def handle_event("review_change", %{"review" => params}, socket) do
    {:noreply, assign(socket, :review_form, Map.merge(socket.assigns.review_form, params))}
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
    {:noreply,
     assign(socket, :assignment_form, Map.merge(socket.assigns.assignment_form, params))}
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
       |> assign(:packages, list_packages(current_filters(socket), scope))
       |> assign(:selected_package, package)
       |> assign(:review_form, build_review_form(package))
       |> put_flash(:info, "Package approved")}
    else
      {:error, {:invalid_json, message}} ->
        {:noreply, socket |> put_flash(:error, message)}

      {:error, :verification_required} ->
        {:noreply,
         socket |> put_flash(:error, "GitHub package must be GPG verified before approval")}

      {:error, :signature_required} ->
        {:noreply,
         socket |> put_flash(:error, "Unsigned uploads are blocked by verification policy")}

      {:error, error} ->
        {:noreply, socket |> put_flash(:error, "Failed to approve: #{format_error(error)}")}
    end
  end

  def handle_event("deny_package", _params, socket) do
    scope = socket.assigns.current_scope
    reason = socket.assigns.review_form["denied_reason"]

    case Packages.deny(socket.assigns.selected_package.id, %{denied_reason: reason}, scope: scope) do
      {:ok, package} ->
        {:noreply,
         socket
         |> assign(:packages, list_packages(current_filters(socket), scope))
         |> assign(:selected_package, package)
         |> assign(:review_form, build_review_form(package))
         |> put_flash(:info, "Package denied")}

      {:error, error} ->
        {:noreply, socket |> put_flash(:error, "Failed to deny: #{format_error(error)}")}
    end
  end

  def handle_event("revoke_package", _params, socket) do
    scope = socket.assigns.current_scope
    reason = socket.assigns.review_form["denied_reason"]

    case Packages.revoke(socket.assigns.selected_package.id, %{denied_reason: reason},
           scope: scope
         ) do
      {:ok, package} ->
        {:noreply,
         socket
         |> assign(:packages, list_packages(current_filters(socket), scope))
         |> assign(:selected_package, package)
         |> assign(:review_form, build_review_form(package))
         |> put_flash(:info, "Package revoked")}

      {:error, error} ->
        {:noreply, socket |> put_flash(:error, "Failed to revoke: #{format_error(error)}")}
    end
  end

  def handle_event("noop", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("create_assignment", %{"assignment" => params}, socket) do
    scope = socket.assigns.current_scope

    case parse_assignment_params(params, socket.assigns.selected_package.id) do
      {:ok, attrs} ->
        handle_assignment_upsert(socket, scope, attrs)

      {:error, {:invalid_json, message}} ->
        {:noreply, socket |> put_flash(:error, message)}

      {:error, error} ->
        {:noreply, socket |> put_flash(:error, "Failed to assign: #{format_error(error)}")}
    end
  end

  def handle_event("delete_assignment", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    case Assignments.delete(id, scope: scope) do
      {:ok, _assignment} ->
        {:noreply,
         socket
         |> assign(:assignments, list_assignments(socket.assigns.selected_package.id, scope))
         |> put_flash(:info, "Assignment removed")}

      {:error, error} ->
        {:noreply, socket |> put_flash(:error, "Failed to remove: #{format_error(error)}")}
    end
  end

  def handle_event("restage_package", _params, socket) do
    scope = socket.assigns.current_scope

    case Packages.restage(socket.assigns.selected_package.id, scope: scope) do
      {:ok, package} ->
        {:noreply,
         socket
         |> assign(:packages, list_packages(current_filters(socket), scope))
         |> assign(:selected_package, package)
         |> assign(:review_form, build_review_form(package))
         |> put_flash(:info, "Package moved back to staged")}

      {:error, error} ->
        {:noreply, socket |> put_flash(:error, "Failed to restage: #{format_error(error)}")}
    end
  end

  def handle_event("delete_package", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    assignments = list_assignments(id, scope)

    assignment_errors =
      assignments
      |> Enum.map(fn assignment ->
        case Assignments.delete(assignment.id, scope: scope) do
          :ok -> nil
          {:ok, _} -> nil
          {:error, error} -> format_error(error)
        end
      end)
      |> Enum.reject(&is_nil/1)

    if assignment_errors != [] do
      {:noreply,
       socket
       |> put_flash(:error, "Failed to remove assignments: #{Enum.join(assignment_errors, "; ")}")}
    else
      package = socket.assigns.selected_package
      _ = maybe_delete_blob(package)

      case Packages.delete(id, scope: scope) do
        {:ok, _package} ->
          {:noreply,
           socket
           |> assign(:packages, list_packages(current_filters(socket), scope))
           |> assign(:show_details_modal, false)
           |> assign(:selected_package, nil)
           |> assign(:assignments, [])
           |> assign(:assignment_form, default_assignment_form())
           |> assign(:versions, [])
           |> assign(:upload_url, nil)
           |> assign(:download_url, nil)
           |> assign(:blob_present, nil)
           |> put_flash(:info, "Package deleted")}

        {:error, error} ->
          {:noreply,
           socket |> put_flash(:error, "Failed to delete package: #{format_error(error)}")}
      end
    end
  end

  defp handle_assignment_upsert(socket, scope, attrs) do
    case existing_assignment(socket.assigns.assignments, attrs.agent_uid) do
      nil ->
        create_assignment(socket, scope, attrs)

      assignment ->
        update_assignment(socket, scope, assignment, attrs)
    end
  end

  defp create_assignment(socket, scope, attrs) do
    case Assignments.create(attrs, scope: scope) do
      {:ok, _assignment} ->
        {:noreply,
         socket
         |> assign(:assignments, list_assignments(socket.assigns.selected_package.id, scope))
         |> assign(:assignment_form, default_assignment_form())
         |> put_flash(:info, "Assignment created")}

      {:error, {:invalid_json, message}} ->
        {:noreply, socket |> put_flash(:error, message)}

      {:error, error} ->
        {:noreply, socket |> put_flash(:error, "Failed to assign: #{format_error(error)}")}
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
         |> assign(:assignments, list_assignments(socket.assigns.selected_package.id, scope))
         |> assign(:assignment_form, default_assignment_form())
         |> put_flash(:info, "Assignment updated")}

      {:error, {:invalid_json, message}} ->
        {:noreply, socket |> put_flash(:error, message)}

      {:error, error} ->
        {:noreply,
         socket |> put_flash(:error, "Failed to update assignment: #{format_error(error)}")}
    end
  end

  defp handle_wasm_upload(socket, package, scope) do
    results =
      consume_uploaded_entries(socket, :wasm_blob, fn %{path: path}, _entry ->
        case File.read(path) do
          {:ok, payload} -> {:ok, payload}
          {:error, _reason} -> {:error, :read_failed}
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
         |> assign(:packages, list_packages(current_filters(socket), scope))
         |> assign(:upload_errors, [])
         |> put_flash(:info, "Wasm blob uploaded")}

      {:error, error} ->
        {:noreply,
         socket
         |> assign(:upload_errors, [format_error(error)])
         |> put_flash(:error, "Failed to upload Wasm blob")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.settings_shell current_path="/admin/plugins">
        <.settings_nav current_path="/admin/plugins" />
        <.edge_nav current_path="/admin/plugins" class="mt-2" />

        <div class="flex flex-wrap items-center justify-between gap-4">
          <div>
            <h1 class="text-2xl font-semibold text-base-content">Plugins</h1>
            <p class="text-sm text-base-content/60">
              Review and publish Wasm plugin packages before they are distributed to agents.
            </p>
          </div>
          <div class="flex gap-2">
            <.ui_button variant="ghost" size="sm" phx-click="refresh">
              <.icon name="hero-arrow-path" class="size-4" /> Refresh
            </.ui_button>
            <.ui_button variant="primary" size="sm" phx-click="open_create_modal">
              <.icon name="hero-plus" class="size-4" /> New Plugin
            </.ui_button>
          </div>
        </div>

        <.ui_panel>
          <:header>
            <div>
              <div class="text-sm font-semibold">Capacity Snapshot</div>
              <p class="text-xs text-base-content/60">
                Aggregate resource requests per agent based on current assignments.
              </p>
            </div>
          </:header>

          <%= if @capacity_rows == [] do %>
            <div class="rounded-xl border border-dashed border-base-200 bg-base-100 p-8 text-center">
              <div class="text-sm font-semibold text-base-content">No agents available</div>
              <p class="mt-1 text-xs text-base-content/60">
                Agents will appear here once they have registered with the platform.
              </p>
            </div>
          <% else %>
            <div class="overflow-x-auto">
              <table class="table table-sm">
                <thead>
                  <tr class="text-xs uppercase tracking-wide text-base-content/60">
                    <th>Agent</th>
                    <th>Assignments</th>
                    <th>CPU (ms)</th>
                    <th>Memory (MB)</th>
                    <th>Connections</th>
                  </tr>
                </thead>
                <tbody>
                  <%= for row <- @capacity_rows do %>
                    <tr class="hover:bg-base-200/30">
                      <td>
                        <div class="font-medium">{row.name}</div>
                        <div class="text-xs text-base-content/60 font-mono">{row.agent_uid}</div>
                      </td>
                      <td class="text-xs">{row.assignments}</td>
                      <td class="text-xs">{row.cpu_ms}</td>
                      <td class="text-xs">{row.memory_mb}</td>
                      <td class="text-xs">{row.connections}</td>
                    </tr>
                  <% end %>
                </tbody>
                <tfoot>
                  <tr class="text-xs font-semibold text-base-content/70">
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
              <p class="text-xs text-base-content/60">
                Controls how GitHub and uploaded packages are treated before execution.
              </p>
            </div>
          </:header>

          <div class="grid grid-cols-1 md:grid-cols-2 gap-4 text-sm">
            <div class="rounded-xl border border-base-200 p-4 space-y-1">
              <div class="text-xs text-base-content/60">GitHub packages</div>
              <div class="font-semibold">
                <%= if @verification_policy.require_gpg_for_github do %>
                  Require GPG verification
                <% else %>
                  Allow without GPG verification
                <% end %>
              </div>
            </div>
            <div class="rounded-xl border border-base-200 p-4 space-y-1">
              <div class="text-xs text-base-content/60">Uploaded packages</div>
              <div class="font-semibold">
                <%= if @verification_policy.allow_unsigned_uploads do %>
                  Allow unsigned uploads
                <% else %>
                  Require signed uploads
                <% end %>
              </div>
            </div>
          </div>
          <p class="mt-3 text-xs text-base-content/60">
            Adjust with environment variables and restart web-ng to apply changes.
          </p>
        </.ui_panel>

        <.ui_panel>
          <:header>
            <div>
              <div class="text-sm font-semibold">Plugin Packages</div>
              <p class="text-xs text-base-content/60">
                {@packages |> length()} package(s)
              </p>
            </div>
            <div class="flex gap-2">
              <select name="status" class="select select-sm select-bordered" phx-change="filter">
                <option value="">All Statuses</option>
                <option value="staged" selected={@filter_status == "staged"}>Staged</option>
                <option value="approved" selected={@filter_status == "approved"}>Approved</option>
                <option value="denied" selected={@filter_status == "denied"}>Denied</option>
                <option value="revoked" selected={@filter_status == "revoked"}>Revoked</option>
              </select>
              <select name="source_type" class="select select-sm select-bordered" phx-change="filter">
                <option value="">All Sources</option>
                <option value="upload" selected={@filter_source_type == "upload"}>Upload</option>
                <option value="github" selected={@filter_source_type == "github"}>GitHub</option>
              </select>
            </div>
          </:header>

          <div class="overflow-x-auto">
            <%= if @packages == [] do %>
              <div class="rounded-xl border border-dashed border-base-200 bg-base-100 p-8 text-center">
                <div class="text-sm font-semibold text-base-content">No packages found</div>
                <p class="mt-1 text-xs text-base-content/60">
                  Stage a plugin package to begin the review workflow.
                </p>
              </div>
            <% else %>
              <table class="table table-sm">
                <thead>
                  <tr class="text-xs uppercase tracking-wide text-base-content/60">
                    <th>Plugin</th>
                    <th>Version</th>
                    <th>Status</th>
                    <th>Source</th>
                    <th>Updated</th>
                    <th></th>
                  </tr>
                </thead>
                <tbody>
                  <%= for package <- @packages do %>
                    <tr class="hover:bg-base-200/30">
                      <td>
                        <div class="font-medium">{package.name}</div>
                        <div class="text-xs text-base-content/60 font-mono">
                          {package.plugin_id}
                        </div>
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
                      <td class="text-xs text-base-content/70">
                        {format_datetime(package.updated_at || package.inserted_at)}
                      </td>
                      <td>
                        <div class="flex gap-1">
                          <.ui_button
                            variant="ghost"
                            size="xs"
                            navigate={~p"/admin/plugins/#{package.id}"}
                          >
                            View
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
        create_form={@create_form}
        create_errors={@create_errors}
      />

      <.details_modal
        :if={@show_details_modal}
        package={@selected_package}
        review_form={@review_form}
        assignments={@assignments}
        agents={@agents}
        assignment_form={@assignment_form}
        versions={@versions}
        blob_present={@blob_present}
        uploads={@uploads}
        upload_errors={@upload_errors}
        verification_policy={@verification_policy}
        upload_url={@upload_url}
        upload_expires_at={@upload_expires_at}
        download_url={@download_url}
        download_expires_at={@download_expires_at}
      />
    </Layouts.app>
    """
  end

  defp create_modal(assigns) do
    ~H"""
    <dialog class="modal modal-open">
      <div class="modal-box max-w-3xl">
        <form method="dialog">
          <button
            class="btn btn-sm btn-circle btn-ghost absolute right-2 top-2"
            phx-click="close_create_modal"
          >
            x
          </button>
        </form>

        <h3 class="text-lg font-semibold">Stage a Plugin Package</h3>
        <p class="text-xs text-base-content/60 mt-1">
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
            <label class="label">
              <span class="label-text">Manifest (YAML)</span>
            </label>
            <textarea
              name="create[manifest_yaml]"
              class="textarea textarea-bordered w-full font-mono text-xs min-h-[180px]"
              placeholder="id: http-check\nname: HTTP Checker\nversion: 1.0.0\nentrypoint: run_check\noutputs: serviceradar.plugin_result.v1\ncapabilities:\n  - http_request\nresources:\n  requested_cpu_ms: 1000\n  requested_memory_mb: 64"
            ><%= @create_form["manifest_yaml"] %></textarea>
          </div>

          <div>
            <label class="label">
              <span class="label-text">Config Schema (JSON, optional)</span>
            </label>
            <textarea
              name="create[config_schema_json]"
              class="textarea textarea-bordered w-full font-mono text-xs min-h-[140px]"
              placeholder='{"type":"object","properties":{"url":{"type":"string"}}}'
            ><%= @create_form["config_schema_json"] %></textarea>
          </div>

          <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
            <div>
              <label class="label">
                <span class="label-text">Source Type</span>
              </label>
              <select name="create[source_type]" class="select select-bordered w-full">
                <option value="upload" selected={@create_form["source_type"] == "upload"}>
                  Upload
                </option>
                <option value="github" selected={@create_form["source_type"] == "github"}>
                  GitHub
                </option>
              </select>
            </div>
            <div>
              <label class="label">
                <span class="label-text">Source Repo URL (optional)</span>
              </label>
              <input
                type="text"
                name="create[source_repo_url]"
                value={@create_form["source_repo_url"]}
                class="input input-bordered w-full"
                placeholder="https://github.com/org/repo"
              />
            </div>
          </div>

          <div>
            <label class="label">
              <span class="label-text">Source Commit (optional)</span>
            </label>
            <input
              type="text"
              name="create[source_commit]"
              value={@create_form["source_commit"]}
              class="input input-bordered w-full"
              placeholder="abc1234"
            />
          </div>

          <div class="flex justify-end gap-2 pt-2">
            <button type="button" class="btn" phx-click="close_create_modal">
              Cancel
            </button>
            <button type="submit" class="btn btn-primary">Stage Package</button>
          </div>
        </form>
      </div>
      <form method="dialog" class="modal-backdrop">
        <button phx-click="close_create_modal">close</button>
      </form>
    </dialog>
    """
  end

  defp details_modal(assigns) do
    ~H"""
    <dialog class="modal modal-open">
      <div class="modal-box max-w-4xl">
        <form method="dialog">
          <button
            class="btn btn-sm btn-circle btn-ghost absolute right-2 top-2"
            phx-click="close_details_modal"
          >
            x
          </button>
        </form>

        <div class="flex flex-wrap items-start justify-between gap-4">
          <div>
            <h3 class="text-lg font-semibold">{@package.name}</h3>
            <p class="text-xs text-base-content/60 font-mono">{@package.plugin_id}</p>
            <p class="text-xs text-base-content/60">Version {@package.version}</p>
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
            <div class="rounded-xl border border-base-200 p-4">
              <div class="text-sm font-semibold">Requested Capabilities</div>
              <div class="mt-2 flex flex-wrap gap-2">
                <%= for cap <- requested_capabilities(@package) do %>
                  <.ui_badge size="xs" variant="ghost">{cap}</.ui_badge>
                <% end %>
                <%= if requested_capabilities(@package) == [] do %>
                  <span class="text-xs text-base-content/50">None</span>
                <% end %>
              </div>
            </div>

            <div class="rounded-xl border border-base-200 p-4">
              <div class="text-sm font-semibold">Requested Permissions</div>
              <pre class="mt-2 bg-base-200/50 p-3 rounded-lg text-xs font-mono overflow-x-auto max-h-48">
    <%= format_json_value(requested_permissions(@package)) %>
    </pre>
            </div>

            <div class="rounded-xl border border-base-200 p-4">
              <div class="text-sm font-semibold">Requested Resources</div>
              <pre class="mt-2 bg-base-200/50 p-3 rounded-lg text-xs font-mono overflow-x-auto max-h-48">
    <%= format_json_value(requested_resources(@package)) %>
    </pre>
            </div>
          </div>

          <div class="space-y-4">
            <div class="rounded-xl border border-base-200 p-4">
              <div class="text-sm font-semibold">Manifest</div>
              <pre class="mt-2 bg-base-200/50 p-3 rounded-lg text-xs font-mono overflow-x-auto max-h-64">
    <%= format_json_value(@package.manifest) %>
    </pre>
            </div>

            <div class="rounded-xl border border-base-200 p-4">
              <div class="text-sm font-semibold">Config Schema</div>
              <pre class="mt-2 bg-base-200/50 p-3 rounded-lg text-xs font-mono overflow-x-auto max-h-48">
    <%= format_json_value(@package.config_schema) %>
    </pre>
            </div>

            <div class="rounded-xl border border-base-200 p-4 space-y-2">
              <div class="text-sm font-semibold">Integrity & Verification</div>
              <div class="text-xs text-base-content/60">Content hash</div>
              <div class="text-xs font-mono">{format_hash(@package.content_hash)}</div>
              <div class="text-xs text-base-content/60 mt-2">Blob stored</div>
              <div class="text-xs">{blob_status(@blob_present)}</div>
              <div class="text-xs text-base-content/60 mt-2">GPG verification</div>
              <div class="text-xs">{gpg_status(@package.gpg_verified_at, @package.gpg_key_id)}</div>
              <div class="text-xs text-base-content/60 mt-2">Signature metadata</div>
              <div class="text-xs font-mono">{signature_status(@package.signature)}</div>
            </div>

            <div class="rounded-xl border border-base-200 p-4 space-y-3">
              <div class="text-sm font-semibold">Upload Wasm Blob</div>
              <p class="text-xs text-base-content/60">
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
                  class="file-input file-input-bordered w-full"
                  phx-change="wasm_upload_change"
                />

                <%= for entry <- @uploads.wasm_blob.entries do %>
                  <div class="flex items-center gap-2 text-xs">
                    <.icon name="hero-document-text" class="size-4 text-primary" />
                    <span>{entry.client_name}</span>
                    <span class="text-base-content/50">
                      ({Float.round(entry.client_size / 1024, 1)} KB)
                    </span>
                    <%= for err <- upload_errors(@uploads.wasm_blob, entry) do %>
                      <span class="text-error text-xs">{wasm_upload_error(err)}</span>
                    <% end %>
                  </div>
                <% end %>

                <div class="flex justify-end">
                  <button
                    type="submit"
                    class="btn btn-primary btn-sm"
                    disabled={@uploads.wasm_blob.entries == []}
                  >
                    Upload Wasm
                  </button>
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

            <div class="rounded-xl border border-base-200 p-4 space-y-2">
              <div class="text-sm font-semibold">Wasm Package URLs</div>
              <div class="text-xs text-base-content/60">
                Upload URL expires {format_datetime(@upload_expires_at)}
              </div>
              <pre class="bg-base-200/50 p-3 rounded-lg text-xs font-mono overflow-x-auto">
    <%= @upload_url %>
    </pre>
              <div class="text-xs text-base-content/60">
                Download URL expires {format_datetime(@download_expires_at)}
              </div>
              <pre class="bg-base-200/50 p-3 rounded-lg text-xs font-mono overflow-x-auto">
    <%= @download_url %>
    </pre>
            </div>

            <div class="rounded-xl border border-base-200 p-4">
              <div class="text-sm font-semibold">Version History</div>
              <%= if @versions == [] do %>
                <p class="mt-2 text-xs text-base-content/60">No other versions found.</p>
              <% else %>
                <div class="mt-2 space-y-2">
                  <%= for version <- @versions do %>
                    <div class="flex items-center justify-between text-xs">
                      <div>
                        <span class="font-medium">{version.version}</span>
                        <span class="text-base-content/60">• {version.status}</span>
                        <%= if version.id == @package.id do %>
                          <.ui_badge size="xs" variant="ghost" class="ml-2">current</.ui_badge>
                        <% end %>
                      </div>
                      <.link navigate={~p"/admin/plugins/#{version.id}"} class="link link-primary">
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
          <div class="rounded-xl border border-base-200 p-4 space-y-3">
            <div class="text-sm font-semibold">Assignments</div>
            <%= if @assignments == [] do %>
              <p class="text-xs text-base-content/60">No agents assigned yet.</p>
            <% else %>
              <div class="space-y-2">
                <%= for assignment <- @assignments do %>
                  <div class="flex items-center justify-between rounded-lg border border-base-200/70 bg-base-100/60 p-2 text-xs">
                    <div>
                      <div class="font-medium flex items-center gap-2">
                        {assignment.agent_uid}
                        <%= if assignment.enabled == false do %>
                          <.ui_badge size="xs" variant="ghost">disabled</.ui_badge>
                        <% end %>
                      </div>
                      <div class="text-base-content/60">
                        every {assignment.interval_seconds}s, timeout {assignment.timeout_seconds}s
                      </div>
                    </div>
                    <button
                      type="button"
                      class="btn btn-ghost btn-xs"
                      phx-click="delete_assignment"
                      phx-value-id={assignment.id}
                      data-confirm="Remove this assignment?"
                    >
                      Remove
                    </button>
                  </div>
                <% end %>
              </div>
            <% end %>
          </div>

          <div class="rounded-xl border border-base-200 p-4 space-y-3">
            <div class="text-sm font-semibold">Assign to Agent</div>
            <form phx-submit="create_assignment" phx-change="assignment_change" class="space-y-3">
              <div>
                <label class="label">
                  <span class="label-text">Agent</span>
                </label>
                <select name="assignment[agent_uid]" class="select select-bordered w-full">
                  <option value="">Select an agent</option>
                  <%= for agent <- @agents do %>
                    <option value={agent.uid} selected={@assignment_form["agent_uid"] == agent.uid}>
                      {agent_label(agent)}
                    </option>
                  <% end %>
                </select>
              </div>
              <div class="grid grid-cols-1 md:grid-cols-2 gap-3">
                <div>
                  <label class="label">
                    <span class="label-text">Interval (seconds)</span>
                  </label>
                  <input
                    type="number"
                    min="5"
                    name="assignment[interval_seconds]"
                    value={@assignment_form["interval_seconds"]}
                    class="input input-bordered w-full"
                  />
                </div>
                <div>
                  <label class="label">
                    <span class="label-text">Timeout (seconds)</span>
                  </label>
                  <input
                    type="number"
                    min="1"
                    name="assignment[timeout_seconds]"
                    value={@assignment_form["timeout_seconds"]}
                    class="input input-bordered w-full"
                  />
                </div>
              </div>
              <div class="grid grid-cols-1 md:grid-cols-2 gap-3">
                <div>
                  <label class="label">
                    <span class="label-text">Params (JSON)</span>
                  </label>
                  <textarea
                    name="assignment[params]"
                    class="textarea textarea-bordered w-full font-mono text-xs min-h-[80px]"
                  ><%= @assignment_form["params"] %></textarea>
                </div>
                <div>
                  <label class="label">
                    <span class="label-text">Permissions Override (JSON)</span>
                  </label>
                  <textarea
                    name="assignment[permissions_override]"
                    class="textarea textarea-bordered w-full font-mono text-xs min-h-[80px]"
                  ><%= @assignment_form["permissions_override"] %></textarea>
                </div>
              </div>
              <div>
                <label class="label">
                  <span class="label-text">Resources Override (JSON)</span>
                </label>
                <textarea
                  name="assignment[resources_override]"
                  class="textarea textarea-bordered w-full font-mono text-xs min-h-[80px]"
                ><%= @assignment_form["resources_override"] %></textarea>
              </div>
              <div class="flex justify-end">
                <button
                  type="submit"
                  class="btn btn-primary btn-sm"
                  disabled={@package.status != :approved or not blob_present?(@blob_present)}
                >
                  Assign
                </button>
              </div>
            </form>
            <%= if @package.status != :approved do %>
              <p class="text-xs text-base-content/60">
                Approve the package before assigning it to agents.
              </p>
            <% end %>
            <%= if @package.status == :approved and not blob_present?(@blob_present) do %>
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
              <label class="label">
                <span class="label-text">Approved Capabilities (comma separated)</span>
              </label>
              <input
                type="text"
                name="review[approved_capabilities]"
                value={@review_form["approved_capabilities"]}
                class="input input-bordered w-full"
                placeholder="Leave blank to accept requested capabilities"
              />
            </div>
            <div>
              <label class="label">
                <span class="label-text">Reason (for deny/revoke)</span>
              </label>
              <input
                type="text"
                name="review[denied_reason]"
                value={@review_form["denied_reason"]}
                class="input input-bordered w-full"
                placeholder="Optional"
              />
            </div>
          </div>

          <div class="grid grid-cols-1 lg:grid-cols-2 gap-4">
            <div>
              <label class="label">
                <span class="label-text">Approved Permissions (JSON)</span>
              </label>
              <textarea
                name="review[approved_permissions]"
                class="textarea textarea-bordered w-full font-mono text-xs min-h-[120px]"
                placeholder="Leave blank to accept requested permissions"
              ><%= @review_form["approved_permissions"] %></textarea>
            </div>
            <div>
              <label class="label">
                <span class="label-text">Approved Resources (JSON)</span>
              </label>
              <textarea
                name="review[approved_resources]"
                class="textarea textarea-bordered w-full font-mono text-xs min-h-[120px]"
                placeholder="Leave blank to accept requested resources"
              ><%= @review_form["approved_resources"] %></textarea>
            </div>
          </div>

          <div class="flex flex-wrap justify-end gap-2 pt-2">
            <%= if @package.status == :staged do %>
              <button type="submit" class="btn btn-primary">Approve</button>
              <button
                type="button"
                class="btn btn-outline btn-error"
                phx-click="deny_package"
                phx-value-id={@package.id}
              >
                Deny
              </button>
            <% end %>

            <%= if @package.status == :approved do %>
              <button
                type="button"
                class="btn btn-outline btn-warning"
                phx-click="revoke_package"
                phx-value-id={@package.id}
              >
                Revoke
              </button>
            <% end %>

            <%= if @package.status in [:denied, :revoked] do %>
              <button
                type="button"
                class="btn btn-outline"
                phx-click="restage_package"
                phx-value-id={@package.id}
              >
                Move to Staged
              </button>
            <% end %>

            <button
              type="button"
              class="btn btn-outline btn-error"
              phx-click="delete_package"
              phx-value-id={@package.id}
              data-confirm="Delete this package and remove all assignments?"
            >
              Delete Package
            </button>

            <button type="button" class="btn" phx-click="close_details_modal">Close</button>
          </div>
        </form>
      </div>
      <form method="dialog" class="modal-backdrop">
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

  defp list_assignments(package_id, scope) do
    Assignments.list(%{"plugin_package_id" => package_id}, scope: scope)
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
  rescue
    _ -> []
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
            requested_memory_mb:
              acc.requested_memory_mb + resource_value(resources, :requested_memory_mb),
            max_open_connections:
              acc.max_open_connections + resource_value(resources, :max_open_connections)
          }
        end
      end
    )
  end

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
  defp map_present?(_), do: false

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
        |> assign(:upload_url, Storage.upload_url(package.id, upload_token))
        |> assign(:upload_expires_at, upload_expires_at)
        |> assign(:download_url, Storage.download_url(package.id, download_token))
        |> assign(:download_expires_at, download_expires_at)
        |> assign(:blob_present, Storage.blob_exists?(package.wasm_object_key))

      {:error, _error} ->
        socket
        |> assign(:upload_url, nil)
        |> assign(:download_url, nil)
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
    extra =
      case extra do
        value when is_map(value) -> value
        value when is_list(value) -> Map.new(value)
        _ -> %{}
      end

    source_type = normalize_source_type(params["source_type"])
    manifest = Map.get(extra, :manifest) || Map.get(extra, "manifest")
    config_schema = Map.get(extra, :config_schema) || Map.get(extra, "config_schema")

    source_repo_url = params["source_repo_url"] || manifest_source_repo_url(manifest)

    %{
      manifest: manifest,
      config_schema: config_schema,
      source_type: source_type,
      source_repo_url: source_repo_url,
      source_commit: params["source_commit"]
    }
  end

  defp parse_manifest(nil), do: {:error, :invalid_manifest_yaml}

  defp parse_manifest(yaml) when is_binary(yaml) do
    trimmed = String.trim(yaml || "")

    with true <- trimmed != "" || {:error, :invalid_manifest_yaml},
         {:ok, manifest} <- Manifest.from_yaml(trimmed) do
      {:ok, Map.from_struct(manifest)}
    else
      {:error, errors} when is_list(errors) -> {:error, {:invalid_manifest, errors}}
      _ -> {:error, :invalid_manifest_yaml}
    end
  end

  defp parse_manifest(_), do: {:error, :invalid_manifest_yaml}

  defp parse_optional_json_map(nil), do: {:ok, %{}}
  defp parse_optional_json_map(""), do: {:ok, %{}}

  defp parse_optional_json_map(json) when is_binary(json) do
    trimmed = String.trim(json)

    if trimmed == "" do
      {:ok, %{}}
    else
      case Jason.decode(trimmed) do
        {:ok, value} when is_map(value) -> {:ok, value}
        {:ok, _} -> {:error, {:invalid_json, "Config schema must be a JSON object"}}
        {:error, reason} -> {:error, {:invalid_json, Exception.message(reason)}}
      end
    end
  end

  defp parse_optional_json_map(_), do: {:error, {:invalid_json, "Config schema must be JSON"}}

  defp parse_assignment_params(params, package_id) do
    agent_uid = params["agent_uid"]
    interval_seconds = parse_int(params["interval_seconds"], 60)
    timeout_seconds = parse_int(params["timeout_seconds"], 10)

    with true <-
           (is_binary(agent_uid) and String.trim(agent_uid) != "") ||
             {:error, "agent_uid required"},
         {:ok, parsed_params} <- parse_optional_json_map(params["params"]),
         {:ok, permissions_override} <- parse_optional_json_map(params["permissions_override"]),
         {:ok, resources_override} <- parse_optional_json_map(params["resources_override"]) do
      {:ok,
       %{
         agent_uid: String.trim(agent_uid),
         plugin_package_id: package_id,
         interval_seconds: interval_seconds,
         timeout_seconds: timeout_seconds,
         params: parsed_params,
         permissions_override: permissions_override,
         resources_override: resources_override
       }}
    else
      {:error, {:invalid_json, message}} -> {:error, {:invalid_json, message}}
      {:error, message} -> {:error, message}
      _ -> {:error, "invalid assignment"}
    end
  end

  defp parse_review_params(params) do
    approved_capabilities = parse_list(params["approved_capabilities"])

    with {:ok, approved_permissions} <- parse_optional_json_map(params["approved_permissions"]),
         {:ok, approved_resources} <- parse_optional_json_map(params["approved_resources"]) do
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

  defp normalize_source_type(source_type) when is_binary(source_type) do
    case String.trim(source_type) do
      "github" -> :github
      "upload" -> :upload
      _ -> :upload
    end
  end

  defp normalize_source_type(_), do: :upload

  defp default_create_form do
    %{
      "manifest_yaml" => "",
      "config_schema_json" => "",
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

  defp requested_permissions(package) do
    Map.get(package.manifest || %{}, "permissions") ||
      Map.get(package.manifest || %{}, :permissions) || %{}
  end

  defp requested_resources(package) do
    Map.get(package.manifest || %{}, "resources") || Map.get(package.manifest || %{}, :resources) ||
      %{}
  end

  defp default_assignment_form do
    %{
      "agent_uid" => "",
      "interval_seconds" => "60",
      "timeout_seconds" => "10",
      "params" => "",
      "permissions_override" => "",
      "resources_override" => ""
    }
  end

  defp agent_label(agent) do
    name = agent.name || agent.host || agent.uid
    "#{name} (#{agent.uid})"
  end

  defp existing_assignment(assignments, agent_uid)
       when is_list(assignments) and is_binary(agent_uid) do
    Enum.find(assignments, fn assignment ->
      assignment.agent_uid == agent_uid
    end)
  end

  defp existing_assignment(_assignments, _agent_uid), do: nil

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

  defp gpg_status(nil, nil), do: "Not verified"
  defp gpg_status(nil, key_id) when is_binary(key_id), do: "Unverified (key #{key_id})"

  defp gpg_status(%DateTime{} = dt, key_id) do
    key = if is_binary(key_id) and key_id != "", do: " (#{key_id})", else: ""
    "Verified #{Calendar.strftime(dt, "%Y-%m-%d %H:%M")}#{key}"
  end

  defp gpg_status(%NaiveDateTime{} = dt, key_id) do
    dt
    |> DateTime.from_naive!("Etc/UTC")
    |> gpg_status(key_id)
  end

  defp gpg_status(_value, _key_id), do: "Unknown"

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

  defp format_datetime(nil), do: "-"

  defp format_datetime(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  end

  defp format_datetime(%NaiveDateTime{} = dt) do
    dt
    |> DateTime.from_naive!("Etc/UTC")
    |> format_datetime()
  end

  defp get_actor(socket) do
    case socket.assigns.current_scope.user do
      nil -> "system"
      user -> user.email
    end
  end

  defp format_error(error) when is_binary(error), do: error
  defp format_error(%Ash.Error.Invalid{} = error), do: Exception.message(error)
  defp format_error(error), do: inspect(error)
end
