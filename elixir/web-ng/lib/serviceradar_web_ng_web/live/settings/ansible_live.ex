defmodule ServiceRadarWebNGWeb.Settings.AnsibleLive do
  @moduledoc """
  Settings page for the Ansible integration.

  Manages Ansible controllers and playbook repositories.

  Permission: `ansible.controllers.manage` (admin role by default).
  """

  use ServiceRadarWebNGWeb, :live_view

  use Permit.Phoenix.LiveView,
    authorization_module: ServiceRadarWebNGWeb.Authorization,
    resource_module: ServiceRadar.Automation.Ansible.Controller

  alias Ash.Error.Invalid
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Automation.Ansible.Controller
  alias ServiceRadar.Automation.Ansible.PlaybookRepository
  alias ServiceRadar.Credentials.NetworkCredentialSecret
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.Settings.Shell

  require Ash.Query
  require Logger

  @awx_credential_provider "awx"

  @controller_permission "ansible.controllers.manage"
  @repository_permission "ansible.repositories.manage"
  @settings_permissions [@controller_permission, @repository_permission]

  @tabs [
    {:controllers, "Controllers"},
    {:repositories, "Repositories"}
  ]

  @impl true
  def event_mapping do
    Map.merge(Permit.Phoenix.LiveView.default_event_mapping(), %{
      # Permit has one resource module for this LiveView (Controller), while
      # the page manages two independently-authorized resources. Treat Permit
      # as the baseline page-read gate; every handler below refreshes and checks
      # the permission for its actual resource before using the system actor.
      "new_controller" => :read,
      "edit_controller" => :read,
      "save_controller" => :read,
      "delete_controller" => :read,
      "cancel_controller_form" => :read,
      "validate_controller" => :read,
      "new_repository" => :read,
      "edit_repository" => :read,
      "save_repository" => :read,
      "delete_repository" => :read,
      "cancel_repository_form" => :read,
      "validate_repository" => :read,
      "select_tab" => :read
    })
  end

  @impl true
  def skip_preload do
    [:index, :read]
  end

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    socket = assign_static_state(socket, scope)

    if connected?(socket) do
      load_connected_state(socket, scope)
    else
      {:ok, socket}
    end
  end

  @impl true
  def handle_event("select_tab", %{"tab" => tab}, socket) do
    case to_atom_tab(tab) do
      :controllers ->
        with_current_permission(socket, @controller_permission, fn socket ->
          {:noreply, activate_controllers_tab(socket)}
        end)

      :repositories ->
        with_current_permission(socket, @repository_permission, fn socket ->
          {:noreply, activate_repositories_tab(socket)}
        end)

      nil ->
        with_current_settings_permission(socket, fn socket -> {:noreply, socket} end)
    end
  end

  def handle_event("new_controller", _params, socket) do
    with_current_permission(socket, @controller_permission, fn socket ->
      {:noreply,
       socket
       |> assign(:show_controller_form, true)
       |> assign(:editing_controller_id, nil)
       |> assign(:pending_controller_tokens, empty_pending_controller_tokens())
       |> assign(:controller_form, to_form(default_controller_form(), as: :controller))}
    end)
  end

  def handle_event("edit_controller", %{"id" => id}, socket) do
    with_current_permission(socket, @controller_permission, fn socket ->
      case Controller.get_by_id(id, actor: actor()) do
        {:ok, ctrl} ->
          {:noreply,
           socket
           |> assign(:show_controller_form, true)
           |> assign(:editing_controller_id, ctrl.id)
           |> assign(:pending_controller_tokens, empty_pending_controller_tokens())
           |> assign(:controller_form, to_form(controller_form_from(ctrl), as: :controller))}

        _ ->
          {:noreply, put_flash(socket, :error, "Controller not found.")}
      end
    end)
  end

  def handle_event("cancel_controller_form", _params, socket) do
    with_current_permission(socket, @controller_permission, fn socket ->
      {:noreply,
       socket
       |> assign(:show_controller_form, false)
       |> assign(:pending_controller_tokens, empty_pending_controller_tokens())}
    end)
  end

  def handle_event("validate_controller", %{"controller" => params}, socket) do
    with_current_permission(socket, @controller_permission, fn socket ->
      {:noreply,
       socket
       |> remember_pending_controller_tokens(params)
       |> assign(
         :controller_form,
         to_form(sanitize_controller_form_params(params), as: :controller)
       )}
    end)
  end

  def handle_event("save_controller", %{"controller" => params}, socket) do
    with_current_permission(socket, @controller_permission, fn socket ->
      params = merge_pending_controller_tokens(params, socket.assigns.pending_controller_tokens)

      case socket.assigns.editing_controller_id do
        nil -> create_controller(socket, params)
        id -> update_controller(socket, id, params)
      end
    end)
  end

  def handle_event("delete_controller", %{"id" => id}, socket) do
    with_current_permission(socket, @controller_permission, fn socket ->
      case Controller.get_by_id(id, actor: actor()) do
        {:ok, ctrl} ->
          case Ash.destroy(ctrl, actor: actor()) do
            :ok ->
              {:noreply,
               socket
               |> put_flash(:info, "Controller \"#{ctrl.name}\" deleted.")
               |> stream_delete(:controllers, ctrl)
               |> update(:controller_count, &max(&1 - 1, 0))}

            {:error, reason} ->
              Logger.warning("delete controller failed", reason: inspect(reason))
              {:noreply, put_flash(socket, :error, "Could not delete controller.")}
          end

        _ ->
          {:noreply, put_flash(socket, :error, "Controller not found.")}
      end
    end)
  end

  ## Repository CRUD ----------------------------------------------------------

  def handle_event("new_repository", _params, socket) do
    with_current_permission(socket, @repository_permission, fn socket ->
      {:noreply,
       socket
       |> assign(:show_repository_form, true)
       |> assign(:editing_repository_id, nil)
       |> assign(:repository_form, to_form(default_repository_form(), as: :repository))}
    end)
  end

  def handle_event("edit_repository", %{"id" => id}, socket) do
    with_current_permission(socket, @repository_permission, fn socket ->
      case PlaybookRepository.get_by_id(id, actor: actor()) do
        {:ok, repo} ->
          {:noreply,
           socket
           |> assign(:show_repository_form, true)
           |> assign(:editing_repository_id, repo.id)
           |> assign(:repository_form, to_form(repository_form_from(repo), as: :repository))}

        _ ->
          {:noreply, put_flash(socket, :error, "Repository not found.")}
      end
    end)
  end

  def handle_event("cancel_repository_form", _params, socket) do
    with_current_permission(socket, @repository_permission, fn socket ->
      {:noreply, assign(socket, :show_repository_form, false)}
    end)
  end

  def handle_event("validate_repository", %{"repository" => params}, socket) do
    with_current_permission(socket, @repository_permission, fn socket ->
      {:noreply, assign(socket, :repository_form, to_form(params, as: :repository))}
    end)
  end

  def handle_event("save_repository", %{"repository" => params}, socket) do
    with_current_permission(socket, @repository_permission, fn socket ->
      case socket.assigns.editing_repository_id do
        nil -> create_repository(socket, params)
        id -> update_repository(socket, id, params)
      end
    end)
  end

  def handle_event("delete_repository", %{"id" => id}, socket) do
    with_current_permission(socket, @repository_permission, fn socket ->
      case PlaybookRepository.get_by_id(id, actor: actor()) do
        {:ok, repo} ->
          case Ash.destroy(repo, actor: actor()) do
            :ok ->
              {:noreply,
               socket
               |> put_flash(:info, "Repository \"#{repo.name}\" deleted.")
               |> stream_delete(:repositories, repo)
               |> update(:repository_count, &max(&1 - 1, 0))}

            {:error, reason} ->
              Logger.warning("delete repository failed", reason: inspect(reason))
              {:noreply, put_flash(socket, :error, "Could not delete repository.")}
          end

        _ ->
          {:noreply, put_flash(socket, :error, "Repository not found.")}
      end
    end)
  end

  defp assign_static_state(socket, scope) do
    socket
    |> assign(:page_title, "Ansible Settings")
    |> assign(:current_path, "/settings/ansible")
    |> assign(:settings_loaded, false)
    |> assign_access(
      cached_permission?(scope, @controller_permission),
      cached_permission?(scope, @repository_permission)
    )
    |> assign(:awx_credential_secrets, [])
    |> assign(:show_controller_form, false)
    |> assign(:editing_controller_id, nil)
    |> assign(:pending_controller_tokens, empty_pending_controller_tokens())
    |> assign(:controller_form, to_form(default_controller_form(), as: :controller))
    |> stream(:controllers, [], reset: true)
    |> assign(:controller_count, 0)
    |> assign(:show_repository_form, false)
    |> assign(:editing_repository_id, nil)
    |> assign(:repository_form, to_form(default_repository_form(), as: :repository))
    |> stream(:repositories, [], reset: true)
    |> assign(:repository_count, 0)
  end

  defp load_connected_state(socket, scope) do
    case RBAC.authorize_current_any(scope, @settings_permissions) do
      {:ok, current_scope} ->
        can_manage_controllers = RBAC.can?(current_scope, @controller_permission)
        can_manage_repositories = RBAC.can?(current_scope, @repository_permission)

        {controllers, awx_secrets} =
          if can_manage_controllers do
            {list_controllers(), list_awx_secrets()}
          else
            {[], []}
          end

        repositories =
          if can_manage_repositories do
            list_repositories()
          else
            []
          end

        {:ok,
         socket
         |> assign(:current_scope, current_scope)
         |> assign_access(can_manage_controllers, can_manage_repositories)
         |> assign(:settings_loaded, true)
         |> assign(:awx_credential_secrets, awx_secrets)
         |> stream(:controllers, controllers, reset: true)
         |> assign(:controller_count, length(controllers))
         |> stream(:repositories, repositories, reset: true)
         |> assign(:repository_count, length(repositories))}

      {:error, :permission_revoked} ->
        {:ok,
         socket
         |> put_flash(:error, "You don't have permission to manage Ansible settings.")
         |> push_navigate(to: ~p"/dashboard")}
    end
  end

  defp with_current_permission(socket, permission, callback) do
    case RBAC.authorize_current(socket.assigns.current_scope, [permission]) do
      {:ok, current_scope} ->
        callback.(refresh_access(socket, current_scope))

      {:error, :permission_revoked} ->
        deny_event(socket)
    end
  end

  defp with_current_settings_permission(socket, callback) do
    case RBAC.authorize_current_any(socket.assigns.current_scope, @settings_permissions) do
      {:ok, current_scope} ->
        callback.(refresh_access(socket, current_scope))

      {:error, :permission_revoked} ->
        deny_event(socket)
    end
  end

  # Stream inserts are cleared after rendering, including those for hidden panels.
  # Reset the revealed panel's stream and count from the same fresh collection.
  # Regression coverage: AnsibleLiveTest's "listing timestamps" tests.
  defp activate_controllers_tab(socket) do
    controllers = list_controllers()

    socket
    |> assign(:active_tab, :controllers)
    |> stream(:controllers, controllers, reset: true)
    |> assign(:controller_count, length(controllers))
  end

  defp activate_repositories_tab(socket) do
    repositories = list_repositories()

    socket
    |> assign(:active_tab, :repositories)
    |> stream(:repositories, repositories, reset: true)
    |> assign(:repository_count, length(repositories))
  end

  defp refresh_access(socket, current_scope) do
    socket
    |> assign(:current_scope, current_scope)
    |> assign_access(
      RBAC.can?(current_scope, @controller_permission),
      RBAC.can?(current_scope, @repository_permission)
    )
  end

  defp deny_event(socket) do
    {:noreply,
     put_flash(
       socket,
       :error,
       "Your Ansible settings permissions changed. Refresh the page and try again."
     )}
  end

  defp assign_access(socket, can_manage_controllers, can_manage_repositories) do
    tabs =
      Enum.filter(@tabs, fn
        {:controllers, _label} -> can_manage_controllers
        {:repositories, _label} -> can_manage_repositories
      end)

    active_tab =
      if Enum.any?(tabs, fn {key, _label} -> key == socket.assigns[:active_tab] end) do
        socket.assigns.active_tab
      else
        case tabs do
          [{key, _label} | _rest] -> key
          [] -> nil
        end
      end

    socket
    |> assign(:tabs, tabs)
    |> assign(:active_tab, active_tab)
    |> assign(:can_manage_ansible_controllers, can_manage_controllers)
    |> assign(:can_manage_ansible_repositories, can_manage_repositories)
  end

  defp cached_permission?(%{permissions: %MapSet{} = permissions}, permission) do
    MapSet.member?(permissions, permission)
  end

  defp cached_permission?(_scope, _permission), do: false

  # Function components do not inherit socket assigns. Resolve the timezone at
  # the LiveView boundary and pass it explicitly to both timestamp panels.
  defp user_timezone(%{user: %{timezone: timezone}}) when is_binary(timezone) and timezone != "", do: timezone

  defp user_timezone(_current_scope), do: "Etc/UTC"

  ## Render --------------------------------------------------------------------

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
        <header class="space-y-1">
          <h1 class="text-2xl font-semibold">Ansible</h1>
          <p class="text-sm text-sr-muted">
            AWX/AAP controllers and git playbook repositories.
          </p>
        </header>

        <div role="tablist" class="sr-ui-tabs border-b border-sr-line">
          <button
            :for={{key, label} <- @tabs}
            type="button"
            role="tab"
            phx-click="select_tab"
            phx-value-tab={key}
            class={["sr-ui-tab", @active_tab == key && "sr-ui-tab-active"]}
          >
            {label}
          </button>
        </div>

        <p :if={!@settings_loaded} class="text-sm text-sr-muted">Loading Ansible settings…</p>

        <section
          :if={
            @settings_loaded and @can_manage_ansible_controllers and
              @active_tab == :controllers
          }
          class="space-y-4"
        >
          <.controllers_panel
            controllers={@streams.controllers}
            controller_count={@controller_count}
            show_form={@show_controller_form}
            form={@controller_form}
            editing_id={@editing_controller_id}
            awx_secrets={@awx_credential_secrets}
            timezone={user_timezone(@current_scope)}
          />
        </section>

        <section
          :if={
            @settings_loaded and @can_manage_ansible_repositories and
              @active_tab == :repositories
          }
          class="space-y-4"
        >
          <.repositories_panel
            repositories={@streams.repositories}
            repository_count={@repository_count}
            show_form={@show_repository_form}
            form={@repository_form}
            editing_id={@editing_repository_id}
            timezone={user_timezone(@current_scope)}
          />
        </section>
      </Shell.settings_chrome>
    </Layouts.app>
    """
  end

  attr(:controllers, :any, required: true)
  attr(:controller_count, :integer, required: true)
  attr(:show_form, :boolean, required: true)
  attr(:form, :any, required: true)
  attr(:editing_id, :string, default: nil)
  attr(:awx_secrets, :any, default: [])
  attr(:timezone, :string, required: true)

  defp controllers_panel(assigns) do
    ~H"""
    <div class="flex items-center justify-between">
      <p class="text-sm text-sr-muted">
        <span class="font-medium">{@controller_count}</span>
        registered controller{if @controller_count == 1, do: "", else: "s"}.
      </p>
      <.ui_button type="button" phx-click="new_controller" size="sm" variant="primary">
        + Add controller
      </.ui_button>
    </div>

    <div
      :if={@controller_count == 0 and !@show_form}
      class="rounded-lg border border-dashed border-sr-line p-8 text-center text-sm text-sr-muted"
    >
      <p>No AWX/AAP controllers registered yet.</p>
      <p class="mt-2">Click <strong>Add controller</strong> to register your first.</p>
    </div>

    <.controller_form
      :if={@show_form}
      form={@form}
      editing_id={@editing_id}
      awx_secrets={@awx_secrets}
    />

    <div
      :if={@controller_count > 0}
      class="overflow-x-auto rounded-lg border border-sr-line bg-sr-surface"
    >
      <table class={ui_table_class(zebra: true)}>
        <thead>
          <tr>
            <th>Name</th>
            <th>Base URL</th>
            <th>Agent</th>
            <th>Health</th>
            <th class="w-28">Actions</th>
          </tr>
        </thead>
        <tbody id="ansible-controllers" phx-update="stream">
          <tr :for={{id, ctrl} <- @controllers} id={id}>
            <td>
              <div class="font-medium">{ctrl.name}</div>
              <div :if={ctrl.description} class="text-xs text-sr-muted">
                {ctrl.description}
              </div>
            </td>
            <td><code class="text-xs">{ctrl.base_url}</code></td>
            <td><code class="text-xs">{ctrl.agent_id}</code></td>
            <td>
              <.ui_badge size="sm" variant={health_badge_variant(ctrl.status)}>
                {ctrl.status}
              </.ui_badge>
              <div :if={ctrl.last_health_at} class="text-xs text-sr-muted mt-1">
                <.user_time
                  id={"settings-ansible-controller-#{ctrl.id}-last-health-at"}
                  value={ctrl.last_health_at}
                  timezone={@timezone}
                  style={:compact}
                />
              </div>
            </td>
            <td>
              <div class="flex gap-1">
                <.ui_button
                  type="button"
                  phx-click="edit_controller"
                  phx-value-id={ctrl.id}
                  size="xs"
                  variant="neutral"
                >
                  Edit
                </.ui_button>
                <.ui_button
                  type="button"
                  phx-click="delete_controller"
                  phx-value-id={ctrl.id}
                  data-confirm={"Delete controller '#{ctrl.name}'? This cannot be undone."}
                  size="xs"
                  variant="outline"
                >
                  Delete
                </.ui_button>
              </div>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  attr(:form, :any, required: true)
  attr(:editing_id, :string, default: nil)
  attr(:awx_secrets, :any, default: [])

  defp controller_form(assigns) do
    assigns =
      assigns
      |> assign(
        :selected_sync_secret_id,
        controller_form_secret_id(assigns.form, :sync_credential_secret_id)
      )
      |> assign(
        :selected_execution_secret_id,
        controller_form_secret_id(assigns.form, :execution_credential_secret_id)
      )
      |> assign(
        :selected_callback_secret_id,
        controller_form_secret_id(assigns.form, :callback_credential_secret_id)
      )

    ~H"""
    <div class="rounded-lg border border-sr-line bg-sr-subtle/60 p-4">
      <h2 class="text-lg font-medium mb-3">
        {if @editing_id, do: "Edit controller", else: "Add controller"}
      </h2>

      <.form
        for={@form}
        id="ansible-controller-form"
        phx-change="validate_controller"
        phx-submit="save_controller"
        class="space-y-3"
      >
        <div class="grid grid-cols-1 md:grid-cols-2 gap-3">
          <div class="flex flex-col gap-1.5">
            <label class="flex items-center justify-between gap-2">
              <span class="text-sm font-medium text-sr-ink">Name</span>
            </label>
            <input
              type="text"
              name="controller[name]"
              value={Phoenix.HTML.Form.input_value(@form, :name)}
              required
              class={ui_field_class(size: "sm")}
              placeholder="Production AWX"
            />
          </div>

          <div class="flex flex-col gap-1.5">
            <label class="flex items-center justify-between gap-2">
              <span class="text-sm font-medium text-sr-ink">Agent ID</span>
            </label>
            <input
              type="text"
              name="controller[agent_id]"
              value={Phoenix.HTML.Form.input_value(@form, :agent_id)}
              required
              class={ui_field_class(size: "sm")}
              placeholder="agent-edge-01"
            />
          </div>

          <div class="flex flex-col gap-1.5 md:col-span-2">
            <label class="flex items-center justify-between gap-2">
              <span class="text-sm font-medium text-sr-ink">Description</span>
            </label>
            <input
              type="text"
              name="controller[description]"
              value={Phoenix.HTML.Form.input_value(@form, :description)}
              class={ui_field_class(size: "sm")}
            />
          </div>

          <div class="flex flex-col gap-1.5 md:col-span-2">
            <label class="flex items-center justify-between gap-2">
              <span class="text-sm font-medium text-sr-ink">Base URL</span>
            </label>
            <input
              type="url"
              name="controller[base_url]"
              value={Phoenix.HTML.Form.input_value(@form, :base_url)}
              required
              class={ui_field_class(size: "sm")}
              placeholder="https://awx.internal.example.com"
            />
          </div>

          <div
            role="alert"
            class={ui_alert_class(variant: "info", class: "alert-soft md:col-span-2 text-sm")}
          >
            Use separate least-privilege AWX principals for sync, execution, and callback
            credential lifecycle. Callback may deliberately reuse execution, but it never
            falls back automatically.
          </div>

          <fieldset class="fieldset rounded-sr-surface border border-sr-line p-3 md:col-span-2">
            <legend class="fieldset-legend">Sync credential</legend>
            <label class="flex items-center justify-between gap-2">
              <span class="text-sm font-medium text-sr-ink">
                {if @editing_id, do: "New sync API token", else: "Sync API token"}
              </span>
              <span class="text-xs text-sr-muted">
                {if @editing_id,
                  do: "Leave blank to keep the selected encrypted sync token.",
                  else: "Used only for health, catalog, and inventory reads."}
              </span>
            </label>
            <input
              type="password"
              id="controller-sync-awx-api-token"
              name="controller[sync_awx_api_token]"
              value=""
              phx-update="ignore"
              class={ui_field_class(size: "sm", mono: true)}
              autocomplete="off"
              placeholder={if @editing_id, do: "Paste only to rotate sync", else: "Paste sync token"}
            />

            <label class="flex items-center justify-between gap-2">
              <span class="text-sm font-medium text-sr-ink">Existing sync credential secret</span>
              <span class="text-xs text-sr-muted">
                Provision AWX tokens in Settings → Credentials → New Secret → AWX API Token.
              </span>
            </label>
            <select
              id="controller-sync-credential-secret-id"
              name="controller[sync_credential_secret_id]"
              class={ui_field_class(size: "sm")}
            >
              <option value="" selected={@selected_sync_secret_id in [nil, ""]}>
                — none / paste a token above —
              </option>
              <option
                :for={secret <- @awx_secrets}
                value={secret.id}
                selected={to_string(secret.id) == @selected_sync_secret_id}
              >
                {secret.name}
              </option>
              <option
                :if={@selected_sync_secret_id not in ["" | Enum.map(@awx_secrets, &to_string(&1.id))]}
                value={@selected_sync_secret_id}
                selected={true}
              >
                {@selected_sync_secret_id} (current)
              </option>
            </select>
            <input
              type="hidden"
              name="controller[credential_secret_id]"
              value={@selected_sync_secret_id}
            />
          </fieldset>

          <fieldset class="fieldset rounded-sr-surface border border-sr-line p-3 md:col-span-2">
            <legend class="fieldset-legend">Execution credential</legend>
            <label class="flex items-center justify-between gap-2">
              <span class="text-sm font-medium text-sr-ink">AWX execution token</span>
              <span class="text-xs text-sr-muted">
                {if @editing_id,
                  do: "Leave blank to keep the selected encrypted execution token.",
                  else: "Used to launch, observe, and cancel jobs."}
              </span>
            </label>
            <input
              type="password"
              id="controller-execution-awx-api-token"
              name="controller[execution_awx_api_token]"
              value=""
              phx-update="ignore"
              class={ui_field_class(size: "sm", mono: true)}
              autocomplete="off"
              placeholder={
                if @editing_id, do: "Paste only to rotate execution", else: "Paste execution token"
              }
            />

            <label class="flex items-center justify-between gap-2">
              <span class="text-sm font-medium text-sr-ink">Existing execution credential</span>
            </label>
            <select
              id="controller-execution-credential-secret-id"
              name="controller[execution_credential_secret_id]"
              class={ui_field_class(size: "sm")}
            >
              <option value="" selected={@selected_execution_secret_id in [nil, ""]}>
                — none / launching and job polling disabled —
              </option>
              <option
                :for={secret <- @awx_secrets}
                value={secret.id}
                selected={to_string(secret.id) == @selected_execution_secret_id}
              >
                {secret.name}
              </option>
              <option
                :if={
                  @selected_execution_secret_id not in [
                    "" | Enum.map(@awx_secrets, &to_string(&1.id))
                  ]
                }
                value={@selected_execution_secret_id}
                selected={true}
              >
                {@selected_execution_secret_id} (current)
              </option>
            </select>
            <p class="flex items-center justify-between gap-2">
              Requires only the exact inventory/template/credential use and job lifecycle roles.
            </p>
          </fieldset>

          <fieldset class="fieldset rounded-sr-surface border border-sr-line p-3 md:col-span-2">
            <legend class="fieldset-legend">Callback credential lifecycle</legend>
            <label class="flex items-center justify-between gap-2">
              <span class="text-sm font-medium text-sr-ink">AWX callback token</span>
              <span class="text-xs text-sr-muted">
                {if @editing_id,
                  do: "Leave blank to keep the selected encrypted callback token.",
                  else: "Creates, fetches, and deletes reviewed ephemeral credentials."}
              </span>
            </label>
            <input
              type="password"
              id="controller-callback-awx-api-token"
              name="controller[callback_awx_api_token]"
              value=""
              phx-update="ignore"
              class={ui_field_class(size: "sm", mono: true)}
              autocomplete="off"
              placeholder={
                if @editing_id, do: "Paste only to rotate callback", else: "Paste callback token"
              }
            />

            <label class="flex items-center justify-between gap-2">
              <span class="text-sm font-medium text-sr-ink">Existing callback credential</span>
            </label>
            <select
              id="controller-callback-credential-secret-id"
              name="controller[callback_credential_secret_id]"
              class={ui_field_class(size: "sm")}
            >
              <option value="" selected={@selected_callback_secret_id in [nil, ""]}>
                — none / callback-enabled playbooks disabled —
              </option>
              <option
                :for={secret <- @awx_secrets}
                value={secret.id}
                selected={to_string(secret.id) == @selected_callback_secret_id}
              >
                {secret.name}
              </option>
              <option
                :if={
                  @selected_callback_secret_id not in ["" | Enum.map(@awx_secrets, &to_string(&1.id))]
                }
                value={@selected_callback_secret_id}
                selected={true}
              >
                {@selected_callback_secret_id} (current)
              </option>
            </select>
            <p class="flex items-center justify-between gap-2">
              Use a principal limited to Credential Admin in a dedicated empty AWX organization.
              Selecting the same secret as execution is supported when intentionally reviewed.
            </p>
          </fieldset>

          <div class="flex flex-col gap-1.5">
            <label class="flex items-center justify-between gap-2">
              <span class="text-sm font-medium text-sr-ink">Inventory sync (s)</span>
            </label>
            <input
              type="number"
              name="controller[inventory_sync_interval_seconds]"
              value={Phoenix.HTML.Form.input_value(@form, :inventory_sync_interval_seconds) || 300}
              min="30"
              class={ui_field_class(size: "sm")}
            />
          </div>

          <div class="flex flex-col gap-1.5">
            <label class="flex items-center justify-between gap-2">
              <span class="text-sm font-medium text-sr-ink">Catalog sync (s)</span>
            </label>
            <input
              type="number"
              name="controller[catalog_sync_interval_seconds]"
              value={Phoenix.HTML.Form.input_value(@form, :catalog_sync_interval_seconds) || 600}
              min="60"
              class={ui_field_class(size: "sm")}
            />
          </div>
        </div>

        <div class="flex justify-end gap-2 pt-2">
          <.ui_button
            type="button"
            phx-click="cancel_controller_form"
            size="sm"
            variant="ghost"
          >
            Cancel
          </.ui_button>
          <.ui_button type="submit" size="sm" variant="primary">
            {if @editing_id, do: "Save changes", else: "Create controller"}
          </.ui_button>
        </div>
      </.form>
    </div>
    """
  end

  ## Repository panel + form --------------------------------------------------

  attr(:repositories, :any, required: true)
  attr(:repository_count, :integer, required: true)
  attr(:show_form, :boolean, required: true)
  attr(:form, :any, required: true)
  attr(:editing_id, :string, default: nil)
  attr(:timezone, :string, required: true)

  defp repositories_panel(assigns) do
    ~H"""
    <div class="flex items-center justify-between">
      <p class="text-sm text-sr-muted">
        <span class="font-medium">{@repository_count}</span>
        registered git repositor{if @repository_count == 1, do: "y", else: "ies"}.
      </p>
      <.ui_button type="button" phx-click="new_repository" size="sm" variant="primary">
        + Add repository
      </.ui_button>
    </div>

    <div
      :if={@repository_count == 0 and !@show_form}
      class="rounded-lg border border-dashed border-sr-line p-8 text-center text-sm text-sr-muted"
    >
      <p>No playbook repositories registered yet.</p>
      <p class="mt-2">Click <strong>Add repository</strong> to register your first.</p>
    </div>

    <.repository_form :if={@show_form} form={@form} editing_id={@editing_id} />

    <div
      :if={@repository_count > 0}
      class="overflow-x-auto rounded-lg border border-sr-line bg-sr-surface"
    >
      <table class={ui_table_class(zebra: true)}>
        <thead>
          <tr>
            <th>Name</th>
            <th>Git URL</th>
            <th>Ref</th>
            <th>Last sync</th>
            <th class="w-28">Actions</th>
          </tr>
        </thead>
        <tbody id="ansible-repositories" phx-update="stream">
          <tr :for={{id, repo} <- @repositories} id={id}>
            <td>
              <div class="font-medium">{repo.name}</div>
              <div :if={repo.description} class="text-xs text-sr-muted">
                {repo.description}
              </div>
            </td>
            <td><code class="text-xs">{repo.git_url}</code></td>
            <td><code class="text-xs">{repo.git_ref}</code></td>
            <td>
              <.ui_badge size="sm" variant={sync_badge_variant(repo.last_sync_status)}>
                {repo.last_sync_status}
              </.ui_badge>
              <div :if={repo.last_sync_at} class="text-xs text-sr-muted mt-1">
                <.user_time
                  id={"settings-ansible-repository-#{repo.id}-last-sync-at"}
                  value={repo.last_sync_at}
                  timezone={@timezone}
                  style={:compact}
                />
              </div>
              <div :if={repo.last_sync_summary} class="text-xs text-sr-muted mt-1">
                {repo.last_sync_summary}
              </div>
            </td>
            <td>
              <div class="flex gap-1">
                <.ui_button
                  type="button"
                  phx-click="edit_repository"
                  phx-value-id={repo.id}
                  size="xs"
                  variant="neutral"
                >
                  Edit
                </.ui_button>
                <.ui_button
                  type="button"
                  phx-click="delete_repository"
                  phx-value-id={repo.id}
                  data-confirm={"Delete repository '#{repo.name}'? Playbooks sourced from it will be removed too."}
                  size="xs"
                  variant="outline"
                >
                  Delete
                </.ui_button>
              </div>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  attr(:form, :any, required: true)
  attr(:editing_id, :string, default: nil)

  defp repository_form(assigns) do
    ~H"""
    <div class="rounded-lg border border-sr-line bg-sr-subtle/60 p-4">
      <h2 class="text-lg font-medium mb-3">
        {if @editing_id, do: "Edit repository", else: "Add repository"}
      </h2>

      <.form
        for={@form}
        id="ansible-repository-form"
        phx-change="validate_repository"
        phx-submit="save_repository"
        class="space-y-3"
      >
        <div class="grid grid-cols-1 md:grid-cols-2 gap-3">
          <div class="flex flex-col gap-1.5">
            <label class="flex items-center justify-between gap-2">
              <span class="text-sm font-medium text-sr-ink">Name</span>
            </label>
            <input
              type="text"
              name="repository[name]"
              value={Phoenix.HTML.Form.input_value(@form, :name)}
              required
              class={ui_field_class(size: "sm")}
              placeholder="ops-playbooks"
            />
          </div>

          <div class="flex flex-col gap-1.5">
            <label class="flex items-center justify-between gap-2">
              <span class="text-sm font-medium text-sr-ink">Ref</span>
            </label>
            <input
              type="text"
              name="repository[git_ref]"
              value={Phoenix.HTML.Form.input_value(@form, :git_ref)}
              required
              class={ui_field_class(size: "sm")}
              placeholder="main"
            />
          </div>

          <div class="flex flex-col gap-1.5 md:col-span-2">
            <label class="flex items-center justify-between gap-2">
              <span class="text-sm font-medium text-sr-ink">Description</span>
            </label>
            <input
              type="text"
              name="repository[description]"
              value={Phoenix.HTML.Form.input_value(@form, :description)}
              class={ui_field_class(size: "sm")}
            />
          </div>

          <div class="flex flex-col gap-1.5 md:col-span-2">
            <label class="flex items-center justify-between gap-2">
              <span class="text-sm font-medium text-sr-ink">Git URL (HTTPS)</span>
            </label>
            <input
              type="url"
              name="repository[git_url]"
              value={Phoenix.HTML.Form.input_value(@form, :git_url)}
              required
              class={ui_field_class(size: "sm", mono: true)}
              placeholder="https://github.com/example/playbooks.git"
            />
          </div>

          <div class="flex flex-col gap-1.5 md:col-span-2">
            <label class="flex items-center justify-between gap-2">
              <span class="text-sm font-medium text-sr-ink">Deploy token secret ID</span>
              <span class="text-xs text-sr-muted">
                Optional. Required for private repos. UUID from Settings → Credentials.
              </span>
            </label>
            <input
              type="text"
              name="repository[credential_secret_id]"
              value={Phoenix.HTML.Form.input_value(@form, :credential_secret_id)}
              class={ui_field_class(size: "sm", mono: true)}
              placeholder="(public repo — leave blank)"
            />
          </div>

          <div class="flex flex-col gap-1.5">
            <label class="flex items-center justify-between gap-2">
              <span class="text-sm font-medium text-sr-ink">Sync interval (s)</span>
            </label>
            <input
              type="number"
              name="repository[sync_interval_seconds]"
              value={Phoenix.HTML.Form.input_value(@form, :sync_interval_seconds) || 600}
              min="60"
              class={ui_field_class(size: "sm")}
            />
          </div>
        </div>

        <div class="flex justify-end gap-2 pt-2">
          <.ui_button
            type="button"
            phx-click="cancel_repository_form"
            size="sm"
            variant="ghost"
          >
            Cancel
          </.ui_button>
          <.ui_button type="submit" size="sm" variant="primary">
            {if @editing_id, do: "Save changes", else: "Create repository"}
          </.ui_button>
        </div>
      </.form>
    </div>
    """
  end

  ## Helpers -------------------------------------------------------------------

  defp create_controller(socket, params) do
    case create_controller_with_secret(params) do
      {:ok, ctrl} ->
        {:noreply,
         socket
         |> put_flash(:info, "Controller \"#{ctrl.name}\" created.")
         |> assign(:show_controller_form, false)
         |> assign(:pending_controller_tokens, empty_pending_controller_tokens())
         |> assign(:awx_credential_secrets, list_awx_secrets())
         |> stream_insert(:controllers, ctrl)
         |> update(:controller_count, &(&1 + 1))}

      {:error, error} ->
        Logger.info("Controller create failed", error: format_controller_error(error))

        {:noreply,
         socket
         |> assign(
           :controller_form,
           to_form(sanitize_controller_form_params(params), as: :controller)
         )
         |> put_flash(:error, format_controller_error(error))}
    end
  end

  defp update_controller(socket, id, params) do
    with {:ok, ctrl} <- Controller.get_by_id(id, actor: actor()),
         {:ok, updated} <- update_controller_with_secret(ctrl, params) do
      {:noreply,
       socket
       |> put_flash(:info, "Controller \"#{updated.name}\" updated.")
       |> assign(:show_controller_form, false)
       |> assign(:pending_controller_tokens, empty_pending_controller_tokens())
       |> assign(:awx_credential_secrets, list_awx_secrets())
       |> stream_insert(:controllers, updated)}
    else
      {:error, error} ->
        Logger.info("Controller update failed", error: format_controller_error(error))

        {:noreply,
         socket
         |> assign(
           :controller_form,
           to_form(sanitize_controller_form_params(params), as: :controller)
         )
         |> put_flash(:error, format_controller_error(error))}
    end
  end

  defp create_controller_with_secret(params) do
    [NetworkCredentialSecret, Controller]
    |> Ash.transaction(fn ->
      with {:ok, credentials} <- resolve_controller_credentials(params, %{}),
           {:ok, ctrl} <-
             Controller.create_controller(controller_attrs(params, credentials),
               actor: actor()
             ) do
        ctrl
      else
        {:error, reason} -> Ash.DataLayer.rollback([NetworkCredentialSecret, Controller], reason)
      end
    end)
    |> normalize_transaction_result()
  end

  defp update_controller_with_secret(%Controller{} = ctrl, params) do
    [NetworkCredentialSecret, Controller]
    |> Ash.transaction(fn ->
      with {:ok, credentials} <-
             resolve_controller_credentials(params, controller_credentials(ctrl)),
           {:ok, updated} <-
             Controller.update_controller(ctrl, controller_attrs(params, credentials), actor: actor()) do
        updated
      else
        {:error, reason} -> Ash.DataLayer.rollback([NetworkCredentialSecret, Controller], reason)
      end
    end)
    |> normalize_transaction_result()
  end

  defp resolve_controller_credentials(params, existing) do
    sync_token =
      nilify_blank(params["sync_awx_api_token"]) || nilify_blank(params["awx_api_token"])

    with {:ok, sync_secret_id} <- resolve_sync_credential(params, existing, sync_token),
         {:ok, execution_secret_id} <-
           resolve_optional_credential(params, "execution_credential_secret_id", existing),
         {:ok, callback_secret_id} <-
           resolve_optional_credential(params, "callback_credential_secret_id", existing) do
      {:ok,
       %{
         sync: sync_secret_id,
         execution: execution_secret_id,
         callback: callback_secret_id
       }}
    end
  end

  defp resolve_sync_credential(params, _existing, token) when is_binary(token) do
    create_awx_token_secret(params, token, "sync")
  end

  defp resolve_sync_credential(params, existing, nil) do
    selected =
      cond do
        Map.has_key?(params, "sync_credential_secret_id") ->
          nilify_blank(params["sync_credential_secret_id"])

        Map.has_key?(params, "credential_secret_id") ->
          nilify_blank(params["credential_secret_id"])

        true ->
          Map.get(existing, :sync)
      end

    case selected do
      nil -> {:error, {:missing_awx_credential, :sync}}
      secret_id -> validate_credential_secret_id(secret_id, :sync)
    end
  end

  defp resolve_optional_credential(params, param, existing) do
    purpose = optional_credential_purpose(param)

    # A pasted token wins over the select, the same precedence sync already uses:
    # you only paste when you mean to set or rotate, and the select still holds
    # whatever was bound before. Without this branch these two purposes could
    # only be set by pasting a secret UUID, which is the copy-a-UUID step this
    # change exists to remove -- and the reason execution and callback were
    # routinely left unset while sync was configured.
    case nilify_blank(params[optional_credential_token_param(param)]) do
      token when is_binary(token) ->
        create_awx_token_secret(params, token, to_string(purpose))

      nil ->
        resolve_optional_credential_selection(params, param, existing, purpose)
    end
  end

  defp resolve_optional_credential_selection(params, param, existing, purpose) do
    if Map.has_key?(params, param) do
      case nilify_blank(params[param]) do
        nil -> {:ok, nil}
        secret_id -> validate_credential_secret_id(secret_id, purpose)
      end
    else
      {:ok, Map.get(existing, purpose)}
    end
  end

  defp optional_credential_purpose("execution_credential_secret_id"), do: :execution
  defp optional_credential_purpose("callback_credential_secret_id"), do: :callback

  defp optional_credential_token_param("execution_credential_secret_id"), do: "execution_awx_api_token"

  defp optional_credential_token_param("callback_credential_secret_id"), do: "callback_awx_api_token"

  defp create_awx_token_secret(params, token, purpose) do
    case NetworkCredentialSecret.create_secret(
           %{
             name: awx_token_secret_name(params["name"], purpose),
             description:
               "AWX #{purpose} OAuth2 token for Ansible controller #{nonempty_string(params["name"], "unnamed")}",
             provider: @awx_credential_provider,
             credential_kind: :api_token,
             secret_payload: token,
             last_rotated_at: DateTime.utc_now(),
             metadata: %{
               "source" => "ansible_controller_form",
               "credential_purpose" => purpose,
               "controller_name" => nonempty_string(params["name"], nil),
               "base_url" => nonempty_string(params["base_url"], nil)
             }
           },
           actor: actor()
         ) do
      {:ok, secret} -> {:ok, secret.id}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_credential_secret_id(secret_id, purpose) do
    case Ecto.UUID.cast(secret_id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, {:invalid_credential_secret_id, purpose}}
    end
  end

  defp controller_attrs(params, credentials) do
    %{
      name: params["name"],
      description: nilify_blank(params["description"]),
      base_url: params["base_url"],
      agent_id: params["agent_id"],
      credential_secret_id: credentials.sync,
      sync_credential_secret_id: credentials.sync,
      execution_credential_secret_id: credentials.execution,
      callback_credential_secret_id: credentials.callback,
      inventory_sync_interval_seconds: to_int(params["inventory_sync_interval_seconds"]) || 300,
      catalog_sync_interval_seconds: to_int(params["catalog_sync_interval_seconds"]) || 600
    }
  end

  defp default_controller_form do
    %{
      "name" => "",
      "description" => "",
      "base_url" => "",
      "agent_id" => "",
      "sync_awx_api_token" => "",
      "credential_secret_id" => "",
      "sync_credential_secret_id" => "",
      "execution_credential_secret_id" => "",
      "callback_credential_secret_id" => "",
      "inventory_sync_interval_seconds" => "300",
      "catalog_sync_interval_seconds" => "600"
    }
  end

  defp controller_form_from(%Controller{} = ctrl) do
    %{
      "name" => ctrl.name,
      "description" => ctrl.description || "",
      "base_url" => ctrl.base_url,
      "agent_id" => ctrl.agent_id,
      "sync_awx_api_token" => "",
      "credential_secret_id" => ctrl.sync_credential_secret_id || ctrl.credential_secret_id,
      "sync_credential_secret_id" => ctrl.sync_credential_secret_id || ctrl.credential_secret_id,
      "execution_credential_secret_id" => ctrl.execution_credential_secret_id,
      "callback_credential_secret_id" => ctrl.callback_credential_secret_id,
      "inventory_sync_interval_seconds" => to_string(ctrl.inventory_sync_interval_seconds),
      "catalog_sync_interval_seconds" => to_string(ctrl.catalog_sync_interval_seconds)
    }
  end

  defp list_controllers do
    case Ash.read(Controller, action: :read, actor: actor()) do
      {:ok, rows} -> rows
      {:error, error} -> log_list_failure("controllers", error)
    end
  end

  # DB-backed AWX bearer tokens, provisioned from Settings → Credentials
  # (New Secret → AWX API Token). The controller form references one of these
  # by name; no token is baked into config and nothing is RPC-seeded.
  defp list_awx_secrets do
    case NetworkCredentialSecret.list_by_provider(@awx_credential_provider, actor: actor()) do
      {:ok, rows} -> Enum.sort_by(rows, & &1.name)
      {:error, error} -> log_list_failure("awx credential secrets", error)
    end
  end

  defp controller_credentials(%Controller{} = controller) do
    %{
      sync: controller.sync_credential_secret_id || controller.credential_secret_id,
      execution: controller.execution_credential_secret_id,
      callback: controller.callback_credential_secret_id
    }
  end

  defp controller_form_secret_id(form, field) do
    form
    |> Phoenix.HTML.Form.input_value(field)
    |> case do
      nil -> ""
      value -> to_string(value)
    end
  end

  defp list_repositories do
    case Ash.read(PlaybookRepository, action: :read, actor: actor()) do
      {:ok, rows} -> rows
      {:error, error} -> log_list_failure("repositories", error)
    end
  end

  # A failed read used to collapse silently into an empty list, making a
  # read/policy error indistinguishable from "nothing registered yet" in the
  # UI. Keep the empty-list fallback (the page must still render) but say why.
  defp log_list_failure(what, error) do
    Logger.warning("Ansible settings: failed to list #{what}", error: inspect(error))
    []
  end

  defp create_repository(socket, params) do
    attrs = repository_attrs(params)

    case PlaybookRepository.create_repository(attrs, actor: actor()) do
      {:ok, repo} ->
        {:noreply,
         socket
         |> put_flash(:info, "Repository \"#{repo.name}\" created.")
         |> assign(:show_repository_form, false)
         |> stream_insert(:repositories, repo)
         |> update(:repository_count, &(&1 + 1))}

      {:error, error} ->
        Logger.info("Repository create failed", error: inspect(error))

        {:noreply,
         socket
         |> assign(:repository_form, to_form(params, as: :repository))
         |> put_flash(:error, format_ash_error(error))}
    end
  end

  defp update_repository(socket, id, params) do
    with {:ok, repo} <- PlaybookRepository.get_by_id(id, actor: actor()),
         {:ok, updated} <-
           PlaybookRepository.update_repository(repo, repository_attrs(params), actor: actor()) do
      {:noreply,
       socket
       |> put_flash(:info, "Repository \"#{updated.name}\" updated.")
       |> assign(:show_repository_form, false)
       |> stream_insert(:repositories, updated)}
    else
      {:error, error} ->
        Logger.info("Repository update failed", error: inspect(error))

        {:noreply,
         socket
         |> assign(:repository_form, to_form(params, as: :repository))
         |> put_flash(:error, format_ash_error(error))}
    end
  end

  defp repository_attrs(params) do
    %{
      name: params["name"],
      description: nilify_blank(params["description"]),
      git_url: params["git_url"],
      git_ref: nilify_blank(params["git_ref"]) || "main",
      credential_secret_id: nilify_blank(params["credential_secret_id"]),
      sync_interval_seconds: to_int(params["sync_interval_seconds"]) || 600
    }
  end

  defp default_repository_form do
    %{
      "name" => "",
      "description" => "",
      "git_url" => "",
      "git_ref" => "main",
      "credential_secret_id" => "",
      "sync_interval_seconds" => "600"
    }
  end

  defp repository_form_from(%PlaybookRepository{} = repo) do
    %{
      "name" => repo.name,
      "description" => repo.description || "",
      "git_url" => repo.git_url,
      "git_ref" => repo.git_ref,
      "credential_secret_id" => repo.credential_secret_id || "",
      "sync_interval_seconds" => to_string(repo.sync_interval_seconds)
    }
  end

  defp sync_badge_variant(:ok), do: "success"
  defp sync_badge_variant(:error), do: "error"
  defp sync_badge_variant(:pending), do: "ghost"
  defp sync_badge_variant(_), do: "ghost"

  defp actor, do: SystemActor.system(:ansible_settings_live)

  defp nilify_blank(nil), do: nil
  defp nilify_blank(""), do: nil
  defp nilify_blank(s) when is_binary(s), do: s

  defp to_int(nil), do: nil
  defp to_int(""), do: nil

  defp to_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp to_int(n) when is_integer(n), do: n
  defp to_int(_), do: nil

  defp health_badge_variant(:ok), do: "success"
  defp health_badge_variant(:degraded), do: "warning"
  defp health_badge_variant(:unreachable), do: "error"
  defp health_badge_variant(:unauthorized), do: "error"
  defp health_badge_variant(_), do: "ghost"

  defp to_atom_tab(tab) when is_binary(tab) do
    case tab do
      "controllers" -> :controllers
      "repositories" -> :repositories
      _ -> nil
    end
  end

  defp to_atom_tab(_), do: nil

  defp format_ash_error(%Invalid{errors: errs}) do
    errs
    |> Enum.map_join("; ", &format_ash_error_detail/1)
    |> String.slice(0, 240)
  end

  defp format_ash_error(other), do: String.slice(inspect(other), 0, 240)

  defp format_ash_error_detail(%{field: field, message: message}) when not is_nil(field) and is_binary(message) do
    "#{field} #{message}"
  end

  defp format_ash_error_detail(%{message: message}) when is_binary(message), do: message
  defp format_ash_error_detail(_other), do: "invalid input"

  defp format_controller_error({:missing_awx_credential, :sync}),
    do: "Enter a sync AWX API token or select an existing sync credential."

  defp format_controller_error(missing_awx_credential: :sync),
    do: format_controller_error({:missing_awx_credential, :sync})

  defp format_controller_error({:invalid_credential_secret_id, purpose}),
    do: "The #{purpose} credential secret ID must be a UUID."

  defp format_controller_error(%{value: value})
       when value in [{:missing_awx_credential, :sync}, [missing_awx_credential: :sync]] do
    format_controller_error(value)
  end

  defp format_controller_error(%{errors: [error | _]}), do: format_controller_error(error)

  defp format_controller_error(other), do: format_ash_error(other)

  defp normalize_transaction_result({:ok, value}), do: {:ok, value}
  defp normalize_transaction_result({:error, reason}), do: {:error, reason}
  defp normalize_transaction_result({:error, reason, _stacktrace}), do: {:error, reason}

  defp sanitize_controller_form_params(params) do
    params
    |> Map.put("awx_api_token", "")
    |> Map.put("sync_awx_api_token", "")
    |> Map.put("execution_awx_api_token", "")
    |> Map.put("callback_awx_api_token", "")
  end

  defp empty_pending_controller_tokens do
    %{sync: nil, execution: nil, callback: nil}
  end

  defp remember_pending_controller_tokens(socket, params) do
    pending = socket.assigns.pending_controller_tokens

    assign(socket, :pending_controller_tokens, %{
      sync:
        pending_token(
          params["sync_awx_api_token"] || params["awx_api_token"],
          pending.sync
        ),
      execution: pending_token(params["execution_awx_api_token"], pending.execution),
      callback: pending_token(params["callback_awx_api_token"], pending.callback)
    })
  end

  # A later phx-change that omits the ignored password input must not forget
  # a token the operator already pasted. An explicit blank value does clear it.
  defp pending_token(value, previous) do
    case value do
      nil -> previous
      token -> nilify_blank(token)
    end
  end

  defp merge_pending_controller_tokens(params, pending) do
    params
    |> Map.put(
      "sync_awx_api_token",
      nilify_blank(params["sync_awx_api_token"]) || pending.sync
    )
    |> Map.put(
      "execution_awx_api_token",
      nilify_blank(params["execution_awx_api_token"]) || pending.execution
    )
    |> Map.put(
      "callback_awx_api_token",
      nilify_blank(params["callback_awx_api_token"]) || pending.callback
    )
  end

  defp awx_token_secret_name(name, purpose) do
    base =
      name
      |> nonempty_string("AWX controller")
      |> String.slice(0, 80)

    "AWX #{purpose} token - #{base} - #{System.unique_integer([:positive])}"
  end

  defp nonempty_string(value, fallback) when is_binary(value) do
    case String.trim(value) do
      "" -> fallback
      trimmed -> trimmed
    end
  end

  defp nonempty_string(_value, fallback), do: fallback
end
