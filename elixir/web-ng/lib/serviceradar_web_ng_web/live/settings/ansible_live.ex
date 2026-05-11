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

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Automation.Ansible.Controller
  alias ServiceRadar.Automation.Ansible.PlaybookRepository
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.SettingsComponents

  require Logger

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
      "cancel_form" => :read,
      "validate_controller" => :read,
      "validate_repository" => :read,
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

    cond do
      RBAC.can?(scope, "ansible.controllers.manage") or
          RBAC.can?(scope, "ansible.repositories.manage") ->
        controllers = list_controllers()
        repositories = list_repositories()

        {:ok,
         socket
         |> assign(:page_title, "Ansible Settings")
         |> assign(:current_path, "/settings/ansible")
         |> assign(:tabs, @tabs)
         |> assign(:active_tab, :controllers)
         |> assign(:show_controller_form, false)
         |> assign(:editing_controller_id, nil)
         |> assign(:controller_form, to_form(default_controller_form(), as: :controller))
         |> stream(:controllers, controllers, reset: true)
         |> assign(:controller_count, length(controllers))
         |> assign(:show_repository_form, false)
         |> assign(:editing_repository_id, nil)
         |> assign(:repository_form, to_form(default_repository_form(), as: :repository))
         |> stream(:repositories, repositories, reset: true)
         |> assign(:repository_count, length(repositories))}

      true ->
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

  ## Render --------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <SettingsComponents.settings_shell current_path={@current_path}>
      <SettingsComponents.settings_nav current_path={@current_path} current_scope={@current_scope} />

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

      <section
        :if={@active_tab not in [:controllers, :repositories]}
        class="rounded-lg border border-base-300 bg-base-100 p-6 text-sm text-base-content/70"
      >
        <p class="font-medium">{tab_label(@active_tab, @tabs)}</p>
        <p class="mt-2">
          Coming in a follow-up commit. Until then, manage this surface via Ash code
          interfaces from <code>iex -S mix</code>.
        </p>
      </section>
    </SettingsComponents.settings_shell>
    """
  end

  attr :controllers, :any, required: true
  attr :controller_count, :integer, required: true
  attr :show_form, :boolean, required: true
  attr :form, :any, required: true
  attr :editing_id, :string, default: nil

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

    <div :if={@controller_count == 0 and !@show_form} class="rounded-lg border border-dashed border-base-300 p-8 text-center text-sm text-base-content/70">
      <p>No AWX/AAP controllers registered yet.</p>
      <p class="mt-2">Click <strong>Add controller</strong> to register your first.</p>
    </div>

    <.controller_form :if={@show_form} form={@form} editing_id={@editing_id} />

    <div :if={@controller_count > 0} class="overflow-x-auto rounded-lg border border-base-300 bg-base-100">
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
              <div :if={ctrl.description} class="text-xs text-base-content/60">{ctrl.description}</div>
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

  attr :form, :any, required: true
  attr :editing_id, :string, default: nil

  defp controller_form(assigns) do
    ~H"""
    <div class="rounded-lg border border-base-300 bg-base-200/60 p-4">
      <h2 class="text-lg font-medium mb-3">
        {if @editing_id, do: "Edit controller", else: "Add controller"}
      </h2>

      <.form for={@form} phx-change="validate_controller" phx-submit="save_controller" class="space-y-3">
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
              <span class="label-text">Credential secret ID</span>
              <span class="label-text-alt text-xs text-base-content/60">
                UUID from Settings → Credentials. v1 limitation: paste manually.
              </span>
            </label>
            <input
              type="text"
              name="controller[credential_secret_id]"
              value={Phoenix.HTML.Form.input_value(@form, :credential_secret_id)}
              required
              class="input input-bordered input-sm font-mono"
              placeholder="018f3f56-1111-7222-8333-..."
            />
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

  attr :repositories, :any, required: true
  attr :repository_count, :integer, required: true
  attr :show_form, :boolean, required: true
  attr :form, :any, required: true
  attr :editing_id, :string, default: nil

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

    <div :if={@repository_count == 0 and !@show_form} class="rounded-lg border border-dashed border-base-300 p-8 text-center text-sm text-base-content/70">
      <p>No playbook repositories registered yet.</p>
      <p class="mt-2">Click <strong>Add repository</strong> to register your first.</p>
    </div>

    <.repository_form :if={@show_form} form={@form} editing_id={@editing_id} />

    <div :if={@repository_count > 0} class="overflow-x-auto rounded-lg border border-base-300 bg-base-100">
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
              <div :if={repo.description} class="text-xs text-base-content/60">{repo.description}</div>
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

  attr :form, :any, required: true
  attr :editing_id, :string, default: nil

  defp repository_form(assigns) do
    ~H"""
    <div class="rounded-lg border border-base-300 bg-base-200/60 p-4">
      <h2 class="text-lg font-medium mb-3">
        {if @editing_id, do: "Edit repository", else: "Add repository"}
      </h2>

      <.form for={@form} phx-change="validate_repository" phx-submit="save_repository" class="space-y-3">
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

  ## Helpers -------------------------------------------------------------------

  defp create_controller(socket, params) do
    attrs = controller_attrs(params)

    case Controller.create_controller(attrs, actor: actor()) do
      {:ok, ctrl} ->
        {:noreply,
         socket
         |> put_flash(:info, "Controller \"#{ctrl.name}\" created.")
         |> assign(:show_controller_form, false)
         |> stream_insert(:controllers, ctrl)
         |> update(:controller_count, &(&1 + 1))}

      {:error, error} ->
        Logger.info("Controller create failed", error: inspect(error))

        {:noreply,
         socket
         |> assign(:controller_form, to_form(params, as: :controller))
         |> put_flash(:error, format_ash_error(error))}
    end
  end

  defp update_controller(socket, id, params) do
    with {:ok, ctrl} <- Controller.get_by_id(id, actor: actor()),
         {:ok, updated} <- Controller.update_controller(ctrl, controller_attrs(params), actor: actor()) do
      {:noreply,
       socket
       |> put_flash(:info, "Controller \"#{updated.name}\" updated.")
       |> assign(:show_controller_form, false)
       |> stream_insert(:controllers, updated)}
    else
      {:error, error} ->
        Logger.info("Controller update failed", error: inspect(error))

        {:noreply,
         socket
         |> assign(:controller_form, to_form(params, as: :controller))
         |> put_flash(:error, format_ash_error(error))}
    end
  end

  defp controller_attrs(params) do
    %{
      name: params["name"],
      description: nilify_blank(params["description"]),
      base_url: params["base_url"],
      agent_id: params["agent_id"],
      credential_secret_id: nilify_blank(params["credential_secret_id"]),
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
      "credential_secret_id" => ctrl.credential_secret_id,
      "inventory_sync_interval_seconds" => to_string(ctrl.inventory_sync_interval_seconds),
      "catalog_sync_interval_seconds" => to_string(ctrl.catalog_sync_interval_seconds),
      "run_pulse_interval_ms" => to_string(ctrl.run_pulse_interval_ms)
    }
  end

  defp list_controllers do
    case Ash.read(Controller, action: :read, actor: actor()) do
      {:ok, rows} -> rows
      _ -> []
    end
  end

  defp list_repositories do
    case Ash.read(PlaybookRepository, action: :read, actor: actor()) do
      {:ok, rows} -> rows
      _ -> []
    end
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
         {:ok, updated} <- PlaybookRepository.update_repository(repo, repository_attrs(params), actor: actor()) do
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

  defp tab_label(active, tabs) do
    Enum.find_value(tabs, "Unknown", fn {k, label} -> if k == active, do: label end)
  end

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

  defp format_ash_error(%Ash.Error.Invalid{errors: errs}) do
    errs
    |> Enum.map(&inspect/1)
    |> Enum.join("; ")
    |> String.slice(0, 240)
  end

  defp format_ash_error(other), do: String.slice(inspect(other), 0, 240)
end
