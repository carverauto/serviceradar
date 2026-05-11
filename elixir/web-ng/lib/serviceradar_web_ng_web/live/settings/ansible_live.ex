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
      "cancel_form" => :read,
      "validate_controller" => :read,
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

    if RBAC.can?(scope, "ansible.controllers.manage") do
      controllers = list_controllers()

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
       |> assign(:controller_count, length(controllers))}
    else
      {:ok,
       socket
       |> put_flash(:error, "You don't have permission to manage Ansible controllers.")
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

      <section
        :if={@active_tab != :controllers}
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
