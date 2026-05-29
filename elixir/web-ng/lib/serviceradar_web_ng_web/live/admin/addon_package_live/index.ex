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
  import ServiceRadarWebNGWeb.SettingsComponents

  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadarWebNG.Plugins.AddonAssignments
  alias ServiceRadarWebNG.Plugins.AddonPackages
  alias ServiceRadarWebNG.RBAC

  require Ash.Query

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if RBAC.can?(scope, "plugins.view") do
      {:ok,
       socket
       |> assign(:can_assign_addons, RBAC.can?(scope, "plugins.assign"))
       |> assign(:page_title, "Add-ons")
       |> assign(:current_path, nil)
       |> assign(:addons_base_path, "/settings/agents/addons")
       |> assign(:packages, list_addon_packages(scope))
       |> assign(:agents, list_agents(scope))
       |> assign(:show_details_modal, false)
       |> assign(:selected_package, nil)
       |> assign(:assignments, [])
       |> assign(:assignment_form, default_assignment_form())}
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
  end

  defp apply_action(socket, :show, %{"id" => id}) do
    scope = socket.assigns.current_scope

    case AddonPackages.get(id, scope: scope) do
      {:ok, package} ->
        socket
        |> assign(:selected_package, package)
        |> assign(:show_details_modal, true)
        |> assign(:assignment_form, default_assignment_form())
        |> assign(:assignments, list_assignments_for_package(package.id, scope))

      _ ->
        socket
        |> put_flash(:error, "Add-on not found.")
        |> push_navigate(to: socket.assigns.addons_base_path)
    end
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, assign(socket, :packages, list_addon_packages(socket.assigns.current_scope))}
  end

  def handle_event("view_package", %{"id" => id}, socket) do
    {:noreply, push_patch(socket, to: socket.assigns.addons_base_path <> "/" <> id)}
  end

  def handle_event("close_details", _params, socket) do
    {:noreply, push_patch(socket, to: socket.assigns.addons_base_path)}
  end

  def handle_event("assignment_change", %{"assignment" => form}, socket) do
    {:noreply, assign(socket, :assignment_form, Map.merge(default_assignment_form(), form))}
  end

  def handle_event("create_assignment", _params, %{assigns: %{can_assign_addons: false}} = socket) do
    {:noreply, put_flash(socket, :error, "You don't have permission to assign add-ons.")}
  end

  def handle_event("create_assignment", %{"assignment" => form}, socket) do
    scope = socket.assigns.current_scope
    package = socket.assigns.selected_package

    with {:ok, agent_uid} <- fetch_agent_uid(form),
         {:ok, params} <- parse_params(form, package.config_schema) do
      attrs = %{
        agent_uid: agent_uid,
        addon_package_id: package.id,
        params: params,
        args: parse_args(Map.get(form, "args"))
      }

      case AddonAssignments.create(attrs, scope: scope) do
        {:ok, _assignment} ->
          {:noreply,
           socket
           |> put_flash(:info, "Add-on assigned to agent.")
           |> assign(:assignments, list_assignments_for_package(package.id, scope))
           |> assign(:assignment_form, default_assignment_form())}

        {:error, error} ->
          {:noreply, put_flash(socket, :error, "Failed to assign: #{format_error(error)}")}
      end
    else
      {:error, :missing_agent} ->
        {:noreply, put_flash(socket, :error, "Select an agent.")}

      {:error, {:invalid_params, message}} ->
        {:noreply, put_flash(socket, :error, "Invalid configuration: #{message}")}
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
      <.settings_shell current_path={@current_path || @addons_base_path}>
        <.settings_nav
          current_path={@current_path || @addons_base_path}
          current_scope={@current_scope}
        />
        <.edge_nav
          current_path={@current_path || @addons_base_path}
          class="mt-2"
          current_scope={@current_scope}
        />

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

        <.ui_panel>
          <:header>
            <div>
              <div class="text-sm font-semibold">Available add-ons</div>
              <p class="text-xs text-base-content/60">
                Approved add-on packages available to deploy to agents.
              </p>
            </div>
          </:header>

          <%= if @packages == [] do %>
            <div class="rounded-xl border border-dashed border-base-200 bg-base-100 p-8 text-center">
              <div class="text-sm font-semibold text-base-content">No approved add-ons</div>
              <p class="mt-1 text-xs text-base-content/60">
                Approved add-on packages appear here once imported and reviewed.
              </p>
            </div>
          <% else %>
            <div class="overflow-x-auto">
              <table class="table table-sm">
                <thead>
                  <tr class="text-xs uppercase tracking-wide text-base-content/60">
                    <th>Add-on</th>
                    <th>Version</th>
                    <th>Delivery</th>
                    <th>Capabilities</th>
                    <th>Status</th>
                    <th></th>
                  </tr>
                </thead>
                <tbody>
                  <%= for package <- @packages do %>
                    <tr class="hover:bg-base-200/30">
                      <td>
                        <div class="font-medium">{package.name}</div>
                        <div class="text-xs text-base-content/60 font-mono">{package.addon_id}</div>
                      </td>
                      <td class="text-xs">{package.version}</td>
                      <td class="text-xs">{package.delivery}</td>
                      <td class="text-xs">{Enum.join(package.capabilities || [], ", ")}</td>
                      <td>
                        <span class="badge badge-sm badge-success">{package.status}</span>
                      </td>
                      <td class="text-right">
                        <.ui_button
                          variant="ghost"
                          size="sm"
                          phx-click="view_package"
                          phx-value-id={package.id}
                        >
                          View
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
            <div class="w-full max-w-2xl rounded-2xl bg-base-100 p-6 shadow-xl space-y-4 overflow-y-auto max-h-[90vh]">
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
              </dl>

              <div class="rounded-xl border border-base-200 p-4 space-y-2">
                <div class="text-sm font-semibold">Current assignments</div>
                <%= if @assignments == [] do %>
                  <p class="text-xs text-base-content/60">Not assigned to any agent yet.</p>
                <% else %>
                  <ul class="divide-y divide-base-200">
                    <%= for assignment <- @assignments do %>
                      <li class="flex items-center justify-between gap-2 py-2">
                        <div class="text-xs font-mono">{assignment.agent_uid}</div>
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
                <div class="text-sm font-semibold">Assign to Agent</div>
                <form phx-submit="create_assignment" phx-change="assignment_change" class="space-y-3">
                  <div>
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
                      disabled={@selected_package.status != :approved or not @can_assign_addons}
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
              </div>
            </div>
          </div>
        <% end %>
      </.settings_shell>
    </Layouts.app>
    """
  end

  defp list_addon_packages(scope), do: AddonPackages.list_approved(scope: scope)

  defp list_assignments_for_package(package_id, scope) do
    AddonAssignments.list(%{addon_package_id: package_id}, scope: scope)
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

  defp agent_label(agent) do
    name = agent.name || agent.host || agent.uid
    "#{name} (#{agent.uid})"
  end

  defp default_assignment_form do
    %{"agent_uid" => "", "params" => "", "params_raw" => "", "args" => ""}
  end

  defp fetch_agent_uid(form) do
    case String.trim(Map.get(form, "agent_uid") || "") do
      "" -> {:error, :missing_agent}
      uid -> {:ok, uid}
    end
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

  defp current_path_from_url(url), do: URI.parse(url).path

  defp addons_base_path_from_url(url) do
    path = URI.parse(url).path || ""

    if String.starts_with?(path, "/admin/addons") do
      "/admin/addons"
    else
      "/settings/agents/addons"
    end
  end

  defp format_error(error) when is_binary(error), do: error
  defp format_error(error) when is_atom(error), do: Atom.to_string(error)
  defp format_error(%Ash.Error.Invalid{} = error), do: Exception.message(error)
  defp format_error(error), do: inspect(error)
end
