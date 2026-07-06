defmodule ServiceRadarWebNGWeb.Settings.AnsibleLive do
  @moduledoc """
  Settings page for the Ansible integration.

  v1 scope (this commit): Controllers tab — list/add/edit/delete
  `AnsibleController` records, including base_url, agent_id, the
  credential broker secret reference, and the three sync intervals
  (inventory_sync, catalog_sync, run_pulse). Other tabs (Repositories,
  Schedules, Unmatched AWX Hosts, Retention) render placeholder
  "coming soon" panels — they slot in cleanly as their backing
  workers + LiveView surfaces are added.

  Permission: `ansible.controllers.manage` (admin role by default).
  """

  use ServiceRadarWebNGWeb, :live_view

  use Permit.Phoenix.LiveView,
    authorization_module: ServiceRadarWebNGWeb.Authorization,
    resource_module: ServiceRadar.Automation.Ansible.Controller

  alias Ash.Error.Invalid
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Automation.Ansible.Controller
  alias ServiceRadar.Automation.Ansible.Playbook
  alias ServiceRadar.Automation.Ansible.PlaybookRepository
  alias ServiceRadar.Automation.Ansible.PlaybookSchedule
  alias ServiceRadar.Automation.Ansible.RetentionWorker
  alias ServiceRadar.Automation.Ansible.ScheduleEvaluatorWorker
  alias ServiceRadar.Credentials.NetworkCredentialSecret
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.Settings.Shell

  require Ash.Query
  require Logger

  @awx_credential_provider "awx"

  @tabs [
    {:controllers, "Controllers"},
    {:repositories, "Repositories"},
    {:schedules, "Schedules"},
    {:retention, "Retention"}
  ]

  @impl true
  def event_mapping do
    Map.merge(Permit.Phoenix.LiveView.default_event_mapping(), %{
      "new_controller" => :create,
      "edit_controller" => :update,
      "save_controller" => :update,
      "delete_controller" => :delete,
      "new_repository" => :create,
      "edit_repository" => :update,
      "save_repository" => :update,
      "delete_repository" => :delete,
      "new_schedule" => :create,
      "edit_schedule" => :update,
      "save_schedule" => :update,
      "delete_schedule" => :delete,
      "toggle_schedule" => :update,
      "cancel_form" => :read,
      "validate_controller" => :read,
      "validate_repository" => :read,
      "validate_schedule" => :read,
      "select_tab" => :read
    })
  end

  @impl true
  def skip_preload do
    [:index, :read, :create, :update, :delete]
  end

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if RBAC.can?(scope, "ansible.controllers.manage") or
         RBAC.can?(scope, "ansible.repositories.manage") or
         RBAC.can?(scope, "ansible.schedules.manage") do
      controllers = list_controllers()
      repositories = list_repositories()
      schedules = list_schedules()
      playbooks = launchable_playbooks()

      {:ok,
       socket
       |> assign(:page_title, "Ansible Settings")
       |> assign(:current_path, "/settings/ansible")
       |> assign(:tabs, @tabs)
       |> assign(:active_tab, :controllers)
       |> assign(:awx_credential_secrets, list_awx_secrets())
       |> assign(:show_controller_form, false)
       |> assign(:editing_controller_id, nil)
       |> assign(:controller_form, to_form(default_controller_form(), as: :controller))
       |> stream(:controllers, controllers, reset: true)
       |> assign(:controller_count, length(controllers))
       |> assign(:show_repository_form, false)
       |> assign(:editing_repository_id, nil)
       |> assign(:repository_form, to_form(default_repository_form(), as: :repository))
       |> stream(:repositories, repositories, reset: true)
       |> assign(:repository_count, length(repositories))
       |> assign(:show_schedule_form, false)
       |> assign(:editing_schedule_id, nil)
       |> assign(:schedule_form, to_form(default_schedule_form(), as: :schedule))
       |> assign(:playbooks, playbooks)
       |> stream(:schedules, schedules, reset: true)
       |> assign(:schedule_count, length(schedules))
       |> assign(:retention_config, retention_config())}
    else
      {:ok,
       socket
       |> put_flash(:error, "You don't have permission to manage Ansible settings.")
       |> push_navigate(to: ~p"/dashboard")}
    end
  end

  @impl true
  def handle_event("select_tab", %{"tab" => tab}, socket) do
    case to_atom_tab(tab) do
      nil ->
        {:noreply, socket}

      atom ->
        {:noreply, assign(socket, :active_tab, atom)}
    end
  end

  def handle_event("new_controller", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_controller_form, true)
     |> assign(:editing_controller_id, nil)
     |> assign(:controller_form, to_form(default_controller_form(), as: :controller))}
  end

  def handle_event("edit_controller", %{"id" => id}, socket) do
    case Controller.get_by_id(id, actor: actor()) do
      {:ok, ctrl} ->
        {:noreply,
         socket
         |> assign(:show_controller_form, true)
         |> assign(:editing_controller_id, ctrl.id)
         |> assign(:controller_form, to_form(controller_form_from(ctrl), as: :controller))}

      _ ->
        {:noreply, put_flash(socket, :error, "Controller not found.")}
    end
  end

  def handle_event("cancel_form", _params, socket) do
    {:noreply, assign(socket, :show_controller_form, false)}
  end

  def handle_event("validate_controller", %{"controller" => params}, socket) do
    {:noreply, assign(socket, :controller_form, to_form(params, as: :controller))}
  end

  def handle_event("save_controller", %{"controller" => params}, socket) do
    case socket.assigns.editing_controller_id do
      nil -> create_controller(socket, params)
      id -> update_controller(socket, id, params)
    end
  end

  def handle_event("delete_controller", %{"id" => id}, socket) do
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
  end

  ## Repository CRUD ----------------------------------------------------------

  def handle_event("new_repository", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_repository_form, true)
     |> assign(:editing_repository_id, nil)
     |> assign(:repository_form, to_form(default_repository_form(), as: :repository))}
  end

  def handle_event("edit_repository", %{"id" => id}, socket) do
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
  end

  def handle_event("validate_repository", %{"repository" => params}, socket) do
    {:noreply, assign(socket, :repository_form, to_form(params, as: :repository))}
  end

  def handle_event("save_repository", %{"repository" => params}, socket) do
    case socket.assigns.editing_repository_id do
      nil -> create_repository(socket, params)
      id -> update_repository(socket, id, params)
    end
  end

  def handle_event("delete_repository", %{"id" => id}, socket) do
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
  end

  ## Schedule CRUD ------------------------------------------------------------

  def handle_event("new_schedule", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_schedule_form, true)
     |> assign(:editing_schedule_id, nil)
     |> assign(:schedule_form, to_form(default_schedule_form(), as: :schedule))}
  end

  def handle_event("edit_schedule", %{"id" => id}, socket) do
    case PlaybookSchedule.get_by_id(id, actor: actor()) do
      {:ok, sched} ->
        {:noreply,
         socket
         |> assign(:show_schedule_form, true)
         |> assign(:editing_schedule_id, sched.id)
         |> assign(:schedule_form, to_form(schedule_form_from(sched), as: :schedule))}

      _ ->
        {:noreply, put_flash(socket, :error, "Schedule not found.")}
    end
  end

  def handle_event("validate_schedule", %{"schedule" => params}, socket) do
    {:noreply, assign(socket, :schedule_form, to_form(params, as: :schedule))}
  end

  def handle_event("save_schedule", %{"schedule" => params}, socket) do
    case socket.assigns.editing_schedule_id do
      nil -> create_schedule(socket, params)
      id -> update_schedule(socket, id, params)
    end
  end

  def handle_event("toggle_schedule", %{"id" => id}, socket) do
    with {:ok, sched} <- PlaybookSchedule.get_by_id(id, actor: actor()),
         {:ok, updated} <- toggle_enabled(sched) do
      msg = if updated.enabled, do: "enabled", else: "disabled"

      {:noreply,
       socket
       |> put_flash(:info, "Schedule \"#{updated.name}\" #{msg}.")
       |> stream_insert(:schedules, updated)}
    else
      _ -> {:noreply, put_flash(socket, :error, "Could not toggle schedule.")}
    end
  end

  def handle_event("delete_schedule", %{"id" => id}, socket) do
    case PlaybookSchedule.get_by_id(id, actor: actor()) do
      {:ok, sched} ->
        case Ash.destroy(sched, actor: actor()) do
          :ok ->
            {:noreply,
             socket
             |> put_flash(:info, "Schedule \"#{sched.name}\" deleted.")
             |> stream_delete(:schedules, sched)
             |> update(:schedule_count, &max(&1 - 1, 0))}

          {:error, reason} ->
            Logger.warning("delete schedule failed", reason: inspect(reason))
            {:noreply, put_flash(socket, :error, "Could not delete schedule.")}
        end

      _ ->
        {:noreply, put_flash(socket, :error, "Schedule not found.")}
    end
  end

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
          <p class="text-sm text-base-content/70">
            AWX/AAP controllers, git playbook repositories, schedules, and retention.
          </p>
        </header>

        <div role="tablist" class="tabs tabs-bordered">
          <button
            :for={{key, label} <- @tabs}
            type="button"
            role="tab"
            phx-click="select_tab"
            phx-value-tab={key}
            class={["tab", @active_tab == key && "tab-active"]}
          >
            {label}
          </button>
        </div>

        <section :if={@active_tab == :controllers} class="space-y-4">
          <.controllers_panel
            controllers={@streams.controllers}
            controller_count={@controller_count}
            show_form={@show_controller_form}
            form={@controller_form}
            editing_id={@editing_controller_id}
            awx_secrets={@awx_credential_secrets}
          />
        </section>

        <section :if={@active_tab == :repositories} class="space-y-4">
          <.repositories_panel
            repositories={@streams.repositories}
            repository_count={@repository_count}
            show_form={@show_repository_form}
            form={@repository_form}
            editing_id={@editing_repository_id}
          />
        </section>

        <section :if={@active_tab == :schedules} class="space-y-4">
          <.schedules_panel
            schedules={@streams.schedules}
            schedule_count={@schedule_count}
            show_form={@show_schedule_form}
            form={@schedule_form}
            editing_id={@editing_schedule_id}
            playbooks={@playbooks}
          />
        </section>

        <section :if={@active_tab == :retention} class="space-y-4">
          <.retention_panel config={@retention_config} />
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

  defp controllers_panel(assigns) do
    ~H"""
    <div class="flex items-center justify-between">
      <p class="text-sm text-base-content/70">
        <span class="font-medium">{@controller_count}</span>
        registered controller{if @controller_count == 1, do: "", else: "s"}.
      </p>
      <button type="button" phx-click="new_controller" class="btn btn-sm btn-primary">
        + Add controller
      </button>
    </div>

    <div
      :if={@controller_count == 0 and !@show_form}
      class="rounded-lg border border-dashed border-base-300 p-8 text-center text-sm text-base-content/70"
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
      class="overflow-x-auto rounded-lg border border-base-300 bg-base-100"
    >
      <table class="table table-zebra">
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
              <div :if={ctrl.description} class="text-xs text-base-content/60">
                {ctrl.description}
              </div>
            </td>
            <td><code class="text-xs">{ctrl.base_url}</code></td>
            <td><code class="text-xs">{ctrl.agent_id}</code></td>
            <td>
              <span class={["badge", health_badge_class(ctrl.status)]}>
                {ctrl.status}
              </span>
              <div :if={ctrl.last_health_at} class="text-xs text-base-content/60 mt-1">
                {Calendar.strftime(ctrl.last_health_at, "%Y-%m-%d %H:%M:%S UTC")}
              </div>
            </td>
            <td>
              <div class="flex gap-1">
                <button
                  type="button"
                  class="btn btn-xs"
                  phx-click="edit_controller"
                  phx-value-id={ctrl.id}
                >
                  Edit
                </button>
                <button
                  type="button"
                  class="btn btn-xs btn-error btn-outline"
                  phx-click="delete_controller"
                  phx-value-id={ctrl.id}
                  data-confirm={"Delete controller '#{ctrl.name}'? This cannot be undone."}
                >
                  Delete
                </button>
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
    assigns = assign(assigns, :selected_secret_id, controller_form_secret_id(assigns.form))

    ~H"""
    <div class="rounded-lg border border-base-300 bg-base-200/60 p-4">
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
          <div class="form-control">
            <label class="label"><span class="label-text">Name</span></label>
            <input
              type="text"
              name="controller[name]"
              value={Phoenix.HTML.Form.input_value(@form, :name)}
              required
              class="input input-bordered input-sm"
              placeholder="Production AWX"
            />
          </div>

          <div class="form-control">
            <label class="label"><span class="label-text">Agent ID</span></label>
            <input
              type="text"
              name="controller[agent_id]"
              value={Phoenix.HTML.Form.input_value(@form, :agent_id)}
              required
              class="input input-bordered input-sm"
              placeholder="agent-edge-01"
            />
          </div>

          <div class="form-control md:col-span-2">
            <label class="label"><span class="label-text">Description</span></label>
            <input
              type="text"
              name="controller[description]"
              value={Phoenix.HTML.Form.input_value(@form, :description)}
              class="input input-bordered input-sm"
            />
          </div>

          <div class="form-control md:col-span-2">
            <label class="label"><span class="label-text">Base URL</span></label>
            <input
              type="url"
              name="controller[base_url]"
              value={Phoenix.HTML.Form.input_value(@form, :base_url)}
              required
              class="input input-bordered input-sm"
              placeholder="https://awx.internal.example.com"
            />
          </div>

          <div class="form-control md:col-span-2">
            <label class="label">
              <span class="label-text">
                {if @editing_id, do: "New AWX API token", else: "AWX API token"}
              </span>
              <span class="label-text-alt text-xs text-base-content/60">
                {if @editing_id,
                  do: "Leave blank to keep the existing encrypted token.",
                  else: "Stored encrypted as a network credential."}
              </span>
            </label>
            <input
              type="password"
              name="controller[awx_api_token]"
              value=""
              class="input input-bordered input-sm font-mono"
              autocomplete="off"
              placeholder={if @editing_id, do: "Paste only to rotate", else: "Paste AWX token"}
            />
          </div>

          <div class="form-control md:col-span-2">
            <label class="label">
              <span class="label-text">Existing credential secret</span>
              <span class="label-text-alt text-xs text-base-content/60">
                Provision AWX tokens in Settings → Credentials → New Secret → AWX API Token.
              </span>
            </label>
            <select
              name="controller[credential_secret_id]"
              class="select select-bordered select-sm"
            >
              <option value="" selected={@selected_secret_id in [nil, ""]}>
                — none / paste a token above —
              </option>
              <option
                :for={secret <- @awx_secrets}
                value={secret.id}
                selected={to_string(secret.id) == @selected_secret_id}
              >
                {secret.name}
              </option>
              <option
                :if={@selected_secret_id not in ["" | Enum.map(@awx_secrets, &to_string(&1.id))]}
                value={@selected_secret_id}
                selected={true}
              >
                {@selected_secret_id} (current)
              </option>
            </select>
          </div>

          <div class="form-control">
            <label class="label">
              <span class="label-text">Inventory sync (s)</span>
            </label>
            <input
              type="number"
              name="controller[inventory_sync_interval_seconds]"
              value={Phoenix.HTML.Form.input_value(@form, :inventory_sync_interval_seconds) || 300}
              min="30"
              class="input input-bordered input-sm"
            />
          </div>

          <div class="form-control">
            <label class="label">
              <span class="label-text">Catalog sync (s)</span>
            </label>
            <input
              type="number"
              name="controller[catalog_sync_interval_seconds]"
              value={Phoenix.HTML.Form.input_value(@form, :catalog_sync_interval_seconds) || 600}
              min="60"
              class="input input-bordered input-sm"
            />
          </div>

          <div class="form-control">
            <label class="label">
              <span class="label-text">Run pulse (ms)</span>
            </label>
            <input
              type="number"
              name="controller[run_pulse_interval_ms]"
              value={Phoenix.HTML.Form.input_value(@form, :run_pulse_interval_ms) || 2000}
              min="250"
              max="60000"
              class="input input-bordered input-sm"
            />
          </div>
        </div>

        <div class="flex justify-end gap-2 pt-2">
          <button type="button" phx-click="cancel_form" class="btn btn-sm btn-ghost">Cancel</button>
          <button type="submit" class="btn btn-sm btn-primary">
            {if @editing_id, do: "Save changes", else: "Create controller"}
          </button>
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

  defp repositories_panel(assigns) do
    ~H"""
    <div class="flex items-center justify-between">
      <p class="text-sm text-base-content/70">
        <span class="font-medium">{@repository_count}</span>
        registered git repositor{if @repository_count == 1, do: "y", else: "ies"}.
      </p>
      <button type="button" phx-click="new_repository" class="btn btn-sm btn-primary">
        + Add repository
      </button>
    </div>

    <div
      :if={@repository_count == 0 and !@show_form}
      class="rounded-lg border border-dashed border-base-300 p-8 text-center text-sm text-base-content/70"
    >
      <p>No playbook repositories registered yet.</p>
      <p class="mt-2">Click <strong>Add repository</strong> to register your first.</p>
    </div>

    <.repository_form :if={@show_form} form={@form} editing_id={@editing_id} />

    <div
      :if={@repository_count > 0}
      class="overflow-x-auto rounded-lg border border-base-300 bg-base-100"
    >
      <table class="table table-zebra">
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
              <div :if={repo.description} class="text-xs text-base-content/60">
                {repo.description}
              </div>
            </td>
            <td><code class="text-xs">{repo.git_url}</code></td>
            <td><code class="text-xs">{repo.git_ref}</code></td>
            <td>
              <span class={["badge", sync_badge_class(repo.last_sync_status)]}>
                {repo.last_sync_status}
              </span>
              <div :if={repo.last_sync_at} class="text-xs text-base-content/60 mt-1">
                {Calendar.strftime(repo.last_sync_at, "%Y-%m-%d %H:%M:%S UTC")}
              </div>
              <div :if={repo.last_sync_summary} class="text-xs text-base-content/60 mt-1">
                {repo.last_sync_summary}
              </div>
            </td>
            <td>
              <div class="flex gap-1">
                <button
                  type="button"
                  class="btn btn-xs"
                  phx-click="edit_repository"
                  phx-value-id={repo.id}
                >
                  Edit
                </button>
                <button
                  type="button"
                  class="btn btn-xs btn-error btn-outline"
                  phx-click="delete_repository"
                  phx-value-id={repo.id}
                  data-confirm={"Delete repository '#{repo.name}'? Playbooks sourced from it will be removed too."}
                >
                  Delete
                </button>
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
    <div class="rounded-lg border border-base-300 bg-base-200/60 p-4">
      <h2 class="text-lg font-medium mb-3">
        {if @editing_id, do: "Edit repository", else: "Add repository"}
      </h2>

      <.form
        for={@form}
        phx-change="validate_repository"
        phx-submit="save_repository"
        class="space-y-3"
      >
        <div class="grid grid-cols-1 md:grid-cols-2 gap-3">
          <div class="form-control">
            <label class="label"><span class="label-text">Name</span></label>
            <input
              type="text"
              name="repository[name]"
              value={Phoenix.HTML.Form.input_value(@form, :name)}
              required
              class="input input-bordered input-sm"
              placeholder="ops-playbooks"
            />
          </div>

          <div class="form-control">
            <label class="label"><span class="label-text">Ref</span></label>
            <input
              type="text"
              name="repository[git_ref]"
              value={Phoenix.HTML.Form.input_value(@form, :git_ref)}
              required
              class="input input-bordered input-sm"
              placeholder="main"
            />
          </div>

          <div class="form-control md:col-span-2">
            <label class="label"><span class="label-text">Description</span></label>
            <input
              type="text"
              name="repository[description]"
              value={Phoenix.HTML.Form.input_value(@form, :description)}
              class="input input-bordered input-sm"
            />
          </div>

          <div class="form-control md:col-span-2">
            <label class="label"><span class="label-text">Git URL (HTTPS)</span></label>
            <input
              type="url"
              name="repository[git_url]"
              value={Phoenix.HTML.Form.input_value(@form, :git_url)}
              required
              class="input input-bordered input-sm font-mono"
              placeholder="https://github.com/example/playbooks.git"
            />
          </div>

          <div class="form-control md:col-span-2">
            <label class="label">
              <span class="label-text">Deploy token secret ID</span>
              <span class="label-text-alt text-xs text-base-content/60">
                Optional. Required for private repos. UUID from Settings → Credentials.
              </span>
            </label>
            <input
              type="text"
              name="repository[credential_secret_id]"
              value={Phoenix.HTML.Form.input_value(@form, :credential_secret_id)}
              class="input input-bordered input-sm font-mono"
              placeholder="(public repo — leave blank)"
            />
          </div>

          <div class="form-control">
            <label class="label">
              <span class="label-text">Sync interval (s)</span>
            </label>
            <input
              type="number"
              name="repository[sync_interval_seconds]"
              value={Phoenix.HTML.Form.input_value(@form, :sync_interval_seconds) || 600}
              min="60"
              class="input input-bordered input-sm"
            />
          </div>
        </div>

        <div class="flex justify-end gap-2 pt-2">
          <button type="button" phx-click="cancel_form" class="btn btn-sm btn-ghost">Cancel</button>
          <button type="submit" class="btn btn-sm btn-primary">
            {if @editing_id, do: "Save changes", else: "Create repository"}
          </button>
        </div>
      </.form>
    </div>
    """
  end

  ## Schedule panel + form ----------------------------------------------------

  attr(:schedules, :any, required: true)
  attr(:schedule_count, :integer, required: true)
  attr(:show_form, :boolean, required: true)
  attr(:form, :any, required: true)
  attr(:editing_id, :string, default: nil)
  attr(:playbooks, :any, required: true)

  defp schedules_panel(assigns) do
    ~H"""
    <div class="flex items-center justify-between">
      <p class="text-sm text-base-content/70">
        <span class="font-medium">{@schedule_count}</span>
        scheduled run{if @schedule_count == 1, do: "", else: "s"} registered.
      </p>
      <button type="button" phx-click="new_schedule" class="btn btn-sm btn-primary">
        + Add schedule
      </button>
    </div>

    <div
      :if={@schedule_count == 0 and !@show_form}
      class="rounded-lg border border-dashed border-base-300 p-8 text-center text-sm text-base-content/70"
    >
      <p>No schedules registered.</p>
      <p class="mt-2">Click <strong>Add schedule</strong> to create a cron-driven run.</p>
    </div>

    <.schedule_form :if={@show_form} form={@form} editing_id={@editing_id} playbooks={@playbooks} />

    <div
      :if={@schedule_count > 0}
      class="overflow-x-auto rounded-lg border border-base-300 bg-base-100"
    >
      <table class="table table-zebra">
        <thead>
          <tr>
            <th>Name</th>
            <th>Cron</th>
            <th>Last fire</th>
            <th>Next run</th>
            <th>State</th>
            <th class="w-40">Actions</th>
          </tr>
        </thead>
        <tbody id="ansible-schedules" phx-update="stream">
          <tr :for={{id, sched} <- @schedules} id={id}>
            <td>
              <div class="font-medium">{sched.name}</div>
              <div :if={sched.description} class="text-xs text-base-content/60">
                {sched.description}
              </div>
            </td>
            <td>
              <code class="text-xs">{sched.cron}</code>
              <div class="text-xs text-base-content/60">{sched.timezone}</div>
            </td>
            <td>
              <div :if={sched.last_evaluated_at} class="text-xs">
                {Calendar.strftime(sched.last_evaluated_at, "%Y-%m-%d %H:%M:%S UTC")}
              </div>
              <span
                :if={sched.last_evaluation_outcome}
                class={["badge badge-xs mt-1", outcome_badge_class(sched.last_evaluation_outcome)]}
              >
                {sched.last_evaluation_outcome}
              </span>
              <div :if={!sched.last_evaluated_at} class="text-xs text-base-content/60">
                never fired
              </div>
            </td>
            <td>
              <div :if={sched.next_run_at} class="text-xs">
                {Calendar.strftime(sched.next_run_at, "%Y-%m-%d %H:%M:%S UTC")}
              </div>
              <div :if={!sched.next_run_at} class="text-xs text-base-content/60">—</div>
            </td>
            <td>
              <span :if={sched.enabled} class="badge badge-success">enabled</span>
              <span :if={!sched.enabled} class="badge badge-ghost">disabled</span>
              <span :if={sched.allow_concurrent} class="badge badge-xs badge-warning mt-1">
                concurrent
              </span>
            </td>
            <td>
              <div class="flex gap-1 flex-wrap">
                <button
                  type="button"
                  class="btn btn-xs"
                  phx-click="toggle_schedule"
                  phx-value-id={sched.id}
                >
                  {if sched.enabled, do: "Disable", else: "Enable"}
                </button>
                <button
                  type="button"
                  class="btn btn-xs"
                  phx-click="edit_schedule"
                  phx-value-id={sched.id}
                >
                  Edit
                </button>
                <button
                  type="button"
                  class="btn btn-xs btn-error btn-outline"
                  phx-click="delete_schedule"
                  phx-value-id={sched.id}
                  data-confirm={"Delete schedule '#{sched.name}'?"}
                >
                  Delete
                </button>
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
  attr(:playbooks, :any, required: true)

  defp schedule_form(assigns) do
    ~H"""
    <div class="rounded-lg border border-base-300 bg-base-200/60 p-4">
      <h2 class="text-lg font-medium mb-3">
        {if @editing_id, do: "Edit schedule", else: "Add schedule"}
      </h2>

      <.form for={@form} phx-change="validate_schedule" phx-submit="save_schedule" class="space-y-3">
        <div class="grid grid-cols-1 md:grid-cols-2 gap-3">
          <div class="form-control">
            <label class="label"><span class="label-text">Name</span></label>
            <input
              type="text"
              name="schedule[name]"
              value={Phoenix.HTML.Form.input_value(@form, :name)}
              required
              class="input input-bordered input-sm"
              placeholder="nightly-deploy"
            />
          </div>

          <div class="form-control">
            <label class="label cursor-pointer justify-start gap-2">
              <input
                type="checkbox"
                name="schedule[enabled]"
                value="true"
                checked={truthy?(Phoenix.HTML.Form.input_value(@form, :enabled))}
                class="checkbox checkbox-sm"
              />
              <span class="label-text">Enabled</span>
            </label>
            <label class="label cursor-pointer justify-start gap-2">
              <input
                type="checkbox"
                name="schedule[allow_concurrent]"
                value="true"
                checked={truthy?(Phoenix.HTML.Form.input_value(@form, :allow_concurrent))}
                class="checkbox checkbox-sm"
              />
              <span class="label-text">Allow concurrent runs</span>
            </label>
          </div>

          <div class="form-control md:col-span-2">
            <label class="label"><span class="label-text">Description</span></label>
            <input
              type="text"
              name="schedule[description]"
              value={Phoenix.HTML.Form.input_value(@form, :description)}
              class="input input-bordered input-sm"
            />
          </div>

          <div class="form-control md:col-span-2">
            <label class="label">
              <span class="label-text">Playbook</span>
              <span class="label-text-alt text-xs text-base-content/60">
                {length(@playbooks)} launchable
              </span>
            </label>
            <select name="schedule[playbook_id]" required class="select select-bordered select-sm">
              <option
                value=""
                disabled
                selected={Phoenix.HTML.Form.input_value(@form, :playbook_id) in [nil, ""]}
              >
                — pick a playbook —
              </option>
              <option
                :for={pb <- @playbooks}
                value={pb.id}
                selected={Phoenix.HTML.Form.input_value(@form, :playbook_id) == pb.id}
              >
                {pb.name} ({pb.source_type})
              </option>
            </select>
          </div>

          <div class="form-control md:col-span-2">
            <label class="label">
              <span class="label-text">Target device UIDs</span>
              <span class="label-text-alt text-xs text-base-content/60">comma-separated</span>
            </label>
            <input
              type="text"
              name="schedule[target_device_uids]"
              value={Phoenix.HTML.Form.input_value(@form, :target_device_uids)}
              required
              class="input input-bordered input-sm font-mono text-xs"
              placeholder="sr:a,sr:b,sr:c"
            />
          </div>

          <div class="form-control">
            <label class="label">
              <span class="label-text">Cron</span>
              <span class="label-text-alt text-xs text-base-content/60">5-field, UTC for v1</span>
            </label>
            <input
              type="text"
              name="schedule[cron]"
              value={Phoenix.HTML.Form.input_value(@form, :cron)}
              required
              class="input input-bordered input-sm font-mono"
              placeholder="0 3 * * *"
            />
          </div>

          <div class="form-control">
            <label class="label"><span class="label-text">Timezone</span></label>
            <input
              type="text"
              name="schedule[timezone]"
              value={Phoenix.HTML.Form.input_value(@form, :timezone) || "UTC"}
              required
              class="input input-bordered input-sm"
              placeholder="UTC"
            />
            <p class="text-xs text-base-content/60 mt-1">
              Non-UTC needs the tzdata dep — v1 supports UTC / Etc/UTC.
            </p>
          </div>

          <div class="form-control md:col-span-2">
            <label class="label">
              <span class="label-text">extra_vars (JSON)</span>
              <span class="label-text-alt text-xs text-base-content/60">
                passed to AWX on each fire
              </span>
            </label>
            <textarea
              name="schedule[requested_extra_vars]"
              rows="3"
              class="textarea textarea-bordered font-mono text-xs"
              placeholder={"{\n  \"target_version\": \"1.2.3\"\n}"}
            >{Phoenix.HTML.Form.input_value(@form, :requested_extra_vars)}</textarea>
          </div>
        </div>

        <div class="flex justify-end gap-2 pt-2">
          <button type="button" phx-click="cancel_form" class="btn btn-sm btn-ghost">Cancel</button>
          <button type="submit" class="btn btn-sm btn-primary">
            {if @editing_id, do: "Save changes", else: "Create schedule"}
          </button>
        </div>
      </.form>
    </div>
    """
  end

  ## Retention panel (read-only docs) -----------------------------------------

  attr(:config, :map, required: true)

  defp retention_panel(assigns) do
    ~H"""
    <div class="space-y-4">
      <div class="rounded-lg border border-base-300 bg-base-100 p-6 text-sm space-y-3">
        <header>
          <h2 class="text-lg font-medium">Retention</h2>
          <p class="text-base-content/70">
            Run-detail + run-summary retention windows are operator-tunable via
            environment variables. Worker cadences (health check, watchdog,
            schedule evaluator) follow the same pattern. Values shown here reflect
            the current process; changes require a redeploy.
          </p>
        </header>

        <div class="overflow-x-auto">
          <table class="table table-sm">
            <thead>
              <tr>
                <th class="w-1/3">Setting</th>
                <th>Current value</th>
                <th>Env var</th>
              </tr>
            </thead>
            <tbody>
              <tr>
                <td>
                  <div class="font-medium">Run detail retention</div>
                  <div class="text-xs text-base-content/60">
                    Past this age, prune `PlaybookPlay` / `PlaybookTask` /
                    `PlaybookTaskResult` rows. Run + targets stay so the run
                    header / per-target outcomes remain queryable.
                  </div>
                </td>
                <td><code>{format_days(@config.run_detail_days)}</code></td>
                <td><code class="text-xs">ANSIBLE_RETENTION_RUN_DETAIL_DAYS</code></td>
              </tr>
              <tr>
                <td>
                  <div class="font-medium">Run summary retention</div>
                  <div class="text-xs text-base-content/60">
                    When set, deletes the entire `PlaybookRun` (cascading to
                    targets / plays / tasks / results) past this age. Default
                    `nil` keeps run summaries forever.
                  </div>
                </td>
                <td><code>{format_days_optional(@config.run_summary_days)}</code></td>
                <td><code class="text-xs">ANSIBLE_RETENTION_RUN_SUMMARY_DAYS</code></td>
              </tr>
              <tr>
                <td>
                  <div class="font-medium">Retention sweep interval</div>
                  <div class="text-xs text-base-content/60">
                    How often the RetentionWorker scans. Defaults to daily.
                  </div>
                </td>
                <td><code>{format_seconds(@config.interval_seconds)}</code></td>
                <td><code class="text-xs">ANSIBLE_RETENTION_INTERVAL_SECONDS</code></td>
              </tr>
              <tr>
                <td>
                  <div class="font-medium">Controller health probe interval</div>
                </td>
                <td><code>{format_seconds(@config.health_interval_seconds)}</code></td>
                <td><code class="text-xs">AWX_CONTROLLER_HEALTH_INTERVAL_SECONDS</code></td>
              </tr>
              <tr>
                <td>
                  <div class="font-medium">Run watchdog interval</div>
                  <div class="text-xs text-base-content/60">
                    Threshold: 2× the AWX job_template timeout, or 1 h fallback
                    if no template timeout is known.
                  </div>
                </td>
                <td><code>{format_seconds(@config.watchdog_interval_seconds)}</code></td>
                <td><code class="text-xs">AWX_RUN_WATCHDOG_INTERVAL_SECONDS</code></td>
              </tr>
              <tr>
                <td>
                  <div class="font-medium">Schedule evaluator interval</div>
                </td>
                <td><code>{format_seconds(@config.scheduler_interval_seconds)}</code></td>
                <td><code class="text-xs">AWX_SCHEDULE_EVALUATOR_INTERVAL_SECONDS</code></td>
              </tr>
              <tr>
                <td>
                  <div class="font-medium">Git catalog cache directory</div>
                </td>
                <td><code class="text-xs">{@config.catalog_base_dir}</code></td>
                <td><code class="text-xs">ANSIBLE_CATALOG_BASE_DIR</code></td>
              </tr>
            </tbody>
          </table>
        </div>

        <p class="text-xs text-base-content/60">
          Per-controller / per-repository / per-schedule overrides take precedence
          over the global defaults above. Each `AnsibleController` carries its own
          `run_pulse_interval_ms` (drives RunPulseWorker), `inventory_sync_interval_seconds`,
          and `catalog_sync_interval_seconds`.
        </p>
      </div>
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
      with {:ok, credential_secret_id} <- resolve_controller_credential_secret_id(params, nil),
           {:ok, ctrl} <-
             Controller.create_controller(controller_attrs(params, credential_secret_id),
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
      with {:ok, credential_secret_id} <-
             resolve_controller_credential_secret_id(params, ctrl.credential_secret_id),
           {:ok, updated} <-
             Controller.update_controller(ctrl, controller_attrs(params, credential_secret_id), actor: actor()) do
        updated
      else
        {:error, reason} -> Ash.DataLayer.rollback([NetworkCredentialSecret, Controller], reason)
      end
    end)
    |> normalize_transaction_result()
  end

  defp resolve_controller_credential_secret_id(params, existing_secret_id) do
    token = nilify_blank(params["awx_api_token"])
    secret_id = nilify_blank(params["credential_secret_id"]) || existing_secret_id

    cond do
      token ->
        create_awx_token_secret(params, token)

      secret_id ->
        validate_credential_secret_id(secret_id)

      true ->
        {:error, :missing_awx_credential}
    end
  end

  defp create_awx_token_secret(params, token) do
    case NetworkCredentialSecret.create_secret(
           %{
             name: awx_token_secret_name(params["name"]),
             description: "AWX OAuth2 token for Ansible controller #{nonempty_string(params["name"], "unnamed")}",
             provider: @awx_credential_provider,
             credential_kind: :api_token,
             secret_payload: token,
             last_rotated_at: DateTime.utc_now(),
             metadata: %{
               "source" => "ansible_controller_form",
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

  defp validate_credential_secret_id(secret_id) do
    case Ecto.UUID.cast(secret_id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_credential_secret_id}
    end
  end

  defp controller_attrs(params, credential_secret_id) do
    %{
      name: params["name"],
      description: nilify_blank(params["description"]),
      base_url: params["base_url"],
      agent_id: params["agent_id"],
      credential_secret_id: credential_secret_id,
      inventory_sync_interval_seconds: to_int(params["inventory_sync_interval_seconds"]) || 300,
      catalog_sync_interval_seconds: to_int(params["catalog_sync_interval_seconds"]) || 600,
      run_pulse_interval_ms: to_int(params["run_pulse_interval_ms"]) || 2000
    }
  end

  defp default_controller_form do
    %{
      "name" => "",
      "description" => "",
      "base_url" => "",
      "agent_id" => "",
      "awx_api_token" => "",
      "credential_secret_id" => "",
      "inventory_sync_interval_seconds" => "300",
      "catalog_sync_interval_seconds" => "600",
      "run_pulse_interval_ms" => "2000"
    }
  end

  defp controller_form_from(%Controller{} = ctrl) do
    %{
      "name" => ctrl.name,
      "description" => ctrl.description || "",
      "base_url" => ctrl.base_url,
      "agent_id" => ctrl.agent_id,
      "awx_api_token" => "",
      "credential_secret_id" => ctrl.credential_secret_id,
      "inventory_sync_interval_seconds" => to_string(ctrl.inventory_sync_interval_seconds),
      "catalog_sync_interval_seconds" => to_string(ctrl.catalog_sync_interval_seconds),
      "run_pulse_interval_ms" => to_string(ctrl.run_pulse_interval_ms)
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

  defp controller_form_secret_id(form) do
    form
    |> Phoenix.HTML.Form.input_value(:credential_secret_id)
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

  defp sync_badge_class(:ok), do: "badge-success"
  defp sync_badge_class(:error), do: "badge-error"
  defp sync_badge_class(:pending), do: "badge-ghost"
  defp sync_badge_class(_), do: "badge-ghost"

  ## Schedule helpers ---------------------------------------------------------

  defp list_schedules do
    query = Ash.Query.sort(PlaybookSchedule, name: :asc)

    case Ash.read(query, actor: actor()) do
      {:ok, rows} -> rows
      {:error, error} -> log_list_failure("schedules", error)
    end
  end

  defp launchable_playbooks do
    query =
      Playbook
      |> Ash.Query.filter(not is_nil(awx_job_template_id))
      |> Ash.Query.sort(name: :asc)
      |> Ash.Query.limit(500)

    case Ash.read(query, actor: actor()) do
      {:ok, rows} -> rows
      _ -> []
    end
  end

  defp create_schedule(socket, params) do
    case validate_and_normalize_schedule(params) do
      {:ok, attrs} ->
        case PlaybookSchedule.create_schedule(attrs, actor: actor()) do
          {:ok, sched} ->
            sched = compute_next_run(sched)

            {:noreply,
             socket
             |> put_flash(:info, "Schedule \"#{sched.name}\" created.")
             |> assign(:show_schedule_form, false)
             |> stream_insert(:schedules, sched)
             |> update(:schedule_count, &(&1 + 1))}

          {:error, error} ->
            Logger.info("Schedule create failed", error: inspect(error))

            {:noreply,
             socket
             |> assign(:schedule_form, to_form(params, as: :schedule))
             |> put_flash(:error, format_ash_error(error))}
        end

      {:error, message} ->
        {:noreply,
         socket
         |> assign(:schedule_form, to_form(params, as: :schedule))
         |> put_flash(:error, message)}
    end
  end

  defp update_schedule(socket, id, params) do
    with {:ok, attrs} <- validate_and_normalize_schedule(params),
         {:ok, sched} <- PlaybookSchedule.get_by_id(id, actor: actor()),
         {:ok, updated} <- PlaybookSchedule.update_schedule(sched, attrs, actor: actor()) do
      updated = compute_next_run(updated)

      {:noreply,
       socket
       |> put_flash(:info, "Schedule \"#{updated.name}\" updated.")
       |> assign(:show_schedule_form, false)
       |> stream_insert(:schedules, updated)}
    else
      {:error, %Invalid{} = err} ->
        {:noreply,
         socket
         |> assign(:schedule_form, to_form(params, as: :schedule))
         |> put_flash(:error, format_ash_error(err))}

      {:error, message} when is_binary(message) ->
        {:noreply,
         socket
         |> assign(:schedule_form, to_form(params, as: :schedule))
         |> put_flash(:error, message)}

      {:error, error} ->
        Logger.info("Schedule update failed", error: inspect(error))

        {:noreply,
         socket
         |> assign(:schedule_form, to_form(params, as: :schedule))
         |> put_flash(:error, format_ash_error(error))}
    end
  end

  defp toggle_enabled(%PlaybookSchedule{enabled: true} = sched), do: PlaybookSchedule.disable(sched, actor: actor())

  defp toggle_enabled(%PlaybookSchedule{enabled: false} = sched), do: PlaybookSchedule.enable(sched, actor: actor())

  defp validate_and_normalize_schedule(params) do
    with uids when is_list(uids) <- parse_uids(params["target_device_uids"]),
         {:ok, extra_vars} <- parse_extra_vars(params["requested_extra_vars"]),
         :ok <- ensure_cron(params["cron"]) do
      attrs = %{
        name: params["name"],
        description: nilify_blank(params["description"]),
        enabled: truthy?(params["enabled"]),
        playbook_id: nilify_blank(params["playbook_id"]),
        target_device_uids: uids,
        requested_extra_vars: extra_vars,
        cron: params["cron"],
        timezone: nilify_blank(params["timezone"]) || "UTC",
        allow_concurrent: truthy?(params["allow_concurrent"])
      }

      {:ok, attrs}
    else
      [] -> {:error, "At least one target device UID is required."}
      {:error, {:bad_extra_vars, msg}} -> {:error, "extra_vars JSON invalid: #{msg}"}
      {:error, :bad_cron} -> {:error, "cron expression is invalid."}
      other -> other
    end
  end

  defp parse_uids(nil), do: []
  defp parse_uids(""), do: []

  defp parse_uids(s) when is_binary(s) do
    s
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp parse_uids(_), do: []

  defp parse_extra_vars(nil), do: {:ok, %{}}
  defp parse_extra_vars(""), do: {:ok, %{}}

  defp parse_extra_vars(s) when is_binary(s) do
    trimmed = String.trim(s)

    if trimmed == "" do
      {:ok, %{}}
    else
      case Jason.decode(trimmed) do
        {:ok, m} when is_map(m) ->
          {:ok, m}

        {:ok, _} ->
          {:error, {:bad_extra_vars, "must be a JSON object"}}

        {:error, %Jason.DecodeError{} = err} ->
          {:error, {:bad_extra_vars, Exception.message(err)}}
      end
    end
  end

  defp ensure_cron(nil), do: {:error, :bad_cron}
  defp ensure_cron(""), do: {:error, :bad_cron}

  defp ensure_cron(s) when is_binary(s) do
    case Oban.Cron.Expression.parse(s) do
      {:ok, _} -> :ok
      _ -> {:error, :bad_cron}
    end
  end

  defp ensure_cron(_), do: {:error, :bad_cron}

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?("on"), do: true
  defp truthy?("yes"), do: true
  defp truthy?(_), do: false

  defp compute_next_run(%PlaybookSchedule{} = sched) do
    now = DateTime.utc_now()

    case ScheduleEvaluatorWorker.compute_next_run_at(sched, now) do
      {:ok, next} ->
        case PlaybookSchedule.record_evaluation(
               sched,
               %{
                 last_run_id: sched.last_run_id,
                 next_run_at: next,
                 last_evaluation_outcome: sched.last_evaluation_outcome
               },
               actor: actor()
             ) do
          {:ok, updated} -> updated
          _ -> sched
        end

      _ ->
        sched
    end
  end

  defp default_schedule_form do
    %{
      "name" => "",
      "description" => "",
      "enabled" => "true",
      "playbook_id" => "",
      "target_device_uids" => "",
      "requested_extra_vars" => "{}",
      "cron" => "0 3 * * *",
      "timezone" => "UTC",
      "allow_concurrent" => ""
    }
  end

  defp schedule_form_from(%PlaybookSchedule{} = sched) do
    %{
      "name" => sched.name,
      "description" => sched.description || "",
      "enabled" => to_string(sched.enabled),
      "playbook_id" => sched.playbook_id || "",
      "target_device_uids" => Enum.join(sched.target_device_uids || [], ","),
      "requested_extra_vars" => Jason.encode!(sched.requested_extra_vars || %{}, pretty: true),
      "cron" => sched.cron,
      "timezone" => sched.timezone || "UTC",
      "allow_concurrent" => to_string(sched.allow_concurrent)
    }
  end

  defp outcome_badge_class(:fired), do: "badge-success"
  defp outcome_badge_class(:skipped_overlap), do: "badge-warning"
  defp outcome_badge_class(:skipped_disabled), do: "badge-ghost"
  defp outcome_badge_class(:skipped_ineligible_targets), do: "badge-warning"
  defp outcome_badge_class(:error), do: "badge-error"
  defp outcome_badge_class(_), do: "badge-ghost"

  ## Retention helpers --------------------------------------------------------

  defp retention_config do
    base = RetentionWorker.read_config()

    %{
      run_detail_days: base.run_detail_days,
      run_summary_days: base.run_summary_days,
      interval_seconds: Application.get_env(:serviceradar_core, :ansible_retention_interval_seconds, 86_400),
      health_interval_seconds: Application.get_env(:serviceradar_core, :awx_controller_health_interval_seconds, 30),
      watchdog_interval_seconds: Application.get_env(:serviceradar_core, :awx_run_watchdog_interval_seconds, 60),
      scheduler_interval_seconds: Application.get_env(:serviceradar_core, :awx_schedule_evaluator_interval_seconds, 60),
      catalog_base_dir:
        Application.get_env(
          :serviceradar_core,
          :ansible_catalog_base_dir,
          Path.join(System.tmp_dir!(), "serviceradar_ansible_catalog")
        )
    }
  end

  defp format_days(:disabled), do: "disabled"
  defp format_days(n) when is_integer(n) and n > 0, do: "#{n} day#{if n == 1, do: "", else: "s"}"
  defp format_days(_), do: "—"

  defp format_days_optional(nil), do: "forever"
  defp format_days_optional(other), do: format_days(other)

  defp format_seconds(n) when is_integer(n) and n >= 86_400 do
    days = div(n, 86_400)
    "#{days} day#{if days == 1, do: "", else: "s"}"
  end

  defp format_seconds(n) when is_integer(n) and n >= 3600 do
    hours = div(n, 3600)
    "#{hours} hour#{if hours == 1, do: "", else: "s"}"
  end

  defp format_seconds(n) when is_integer(n) and n >= 60 do
    minutes = div(n, 60)
    "#{minutes} minute#{if minutes == 1, do: "", else: "s"}"
  end

  defp format_seconds(n) when is_integer(n) and n > 0, do: "#{n}s"
  defp format_seconds(_), do: "—"

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

  defp health_badge_class(:ok), do: "badge-success"
  defp health_badge_class(:degraded), do: "badge-warning"
  defp health_badge_class(:unreachable), do: "badge-error"
  defp health_badge_class(:unauthorized), do: "badge-error"
  defp health_badge_class(_), do: "badge-ghost"

  defp to_atom_tab(tab) when is_binary(tab) do
    case tab do
      "controllers" -> :controllers
      "repositories" -> :repositories
      "schedules" -> :schedules
      "retention" -> :retention
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

  defp format_controller_error(:missing_awx_credential), do: "Enter an AWX API token or an existing credential secret ID."

  defp format_controller_error(:invalid_credential_secret_id),
    do: "Existing credential secret ID must be a UUID. Paste the AWX token in the AWX API token field."

  defp format_controller_error(other), do: format_ash_error(other)

  defp normalize_transaction_result({:ok, value}), do: {:ok, value}
  defp normalize_transaction_result({:error, reason}), do: {:error, reason}
  defp normalize_transaction_result({:error, reason, _stacktrace}), do: {:error, reason}

  defp sanitize_controller_form_params(params) do
    Map.put(params, "awx_api_token", "")
  end

  defp awx_token_secret_name(name) do
    base =
      name
      |> nonempty_string("AWX controller")
      |> String.slice(0, 80)

    "AWX token - #{base} - #{System.unique_integer([:positive])}"
  end

  defp nonempty_string(value, fallback) when is_binary(value) do
    case String.trim(value) do
      "" -> fallback
      trimmed -> trimmed
    end
  end

  defp nonempty_string(_value, fallback), do: fallback
end
