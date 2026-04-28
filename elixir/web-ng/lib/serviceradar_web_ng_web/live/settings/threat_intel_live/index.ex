defmodule ServiceRadarWebNGWeb.Settings.ThreatIntelLive.Index do
  @moduledoc """
  LiveView for assigning the first-party AlienVault OTX threat-intel edge plugin.
  """

  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.SettingsComponents

  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Observability.ThreatIntelSyncStatus
  alias ServiceRadar.Plugins.ConfigSchema
  alias ServiceRadar.Plugins.PluginAssignment
  alias ServiceRadar.Plugins.PluginPackage
  alias ServiceRadarWebNG.Plugins.Assignments
  alias ServiceRadarWebNG.Plugins.Packages

  require Ash.Query
  require Logger

  @plugin_id "alienvault-otx-threat-intel"
  @default_form %{
    "agent_uid" => "",
    "enabled" => "true",
    "interval_seconds" => "3600",
    "timeout_seconds" => "30",
    "base_url" => "https://otx.alienvault.com",
    "api_key_secret_ref" => "",
    "limit" => "50",
    "page" => "1",
    "timeout_ms" => "20000",
    "max_indicators" => "5000"
  }

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if RBAC.can?(scope, "plugins.assign") do
      {:ok, load_page(socket)}
    else
      {:ok,
       socket
       |> put_flash(:error, "Not authorized to manage threat intelligence")
       |> redirect(to: ~p"/settings/profile")}
    end
  end

  @impl true
  def handle_event("assignment_change", %{"assignment" => params}, socket) do
    {:noreply, assign(socket, :assignment_form, Map.merge(socket.assigns.assignment_form, params))}
  end

  def handle_event("save_assignment", %{"assignment" => params}, socket) do
    scope = socket.assigns.current_scope

    with %PluginPackage{} = package <- socket.assigns.approved_package,
         {:ok, attrs} <- parse_assignment(params, package) do
      case existing_assignment(socket.assigns.assignments, attrs.agent_uid) do
        nil ->
          create_assignment(socket, scope, attrs)

        %PluginAssignment{} = assignment ->
          update_assignment(socket, scope, assignment, attrs)
      end
    else
      nil ->
        {:noreply, put_flash(socket, :error, "Approved AlienVault OTX package not found")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, format_error(reason))}
    end
  end

  def handle_event("delete_assignment", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    case Assignments.delete(id, scope: scope) do
      :ok ->
        {:noreply,
         socket
         |> reload_assignments()
         |> put_flash(:info, "Assignment removed")}

      {:ok, _assignment} ->
        {:noreply,
         socket
         |> reload_assignments()
         |> put_flash(:info, "Assignment removed")}

      {:error, error} ->
        Logger.warning("Threat intel assignment deletion failed", id: id, error: inspect(error))
        {:noreply, put_flash(socket, :error, "Failed to remove assignment")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.settings_shell current_path="/settings/networks/threat-intel">
        <div class="space-y-4">
          <.settings_nav
            current_path="/settings/networks/threat-intel"
            current_scope={@current_scope}
          />
          <.network_nav current_path="/settings/networks/threat-intel" current_scope={@current_scope} />
        </div>

        <section class="space-y-4">
          <div class="flex flex-col gap-3 md:flex-row md:items-start md:justify-between">
            <div>
              <h1 class="text-xl font-semibold">Threat Intel</h1>
              <p class="text-sm text-base-content/60">
                Configure edge collection for AlienVault OTX indicators.
              </p>
            </div>
            <.link navigate={~p"/settings/agents/plugins"} class="btn btn-sm btn-ghost">
              Plugin Registry
            </.link>
          </div>

          <div class="grid grid-cols-1 gap-4 xl:grid-cols-[minmax(0,1fr)_minmax(360px,420px)]">
            <div class="space-y-4">
              <div class="rounded-xl border border-base-200 bg-base-100 p-4">
                <div class="flex flex-wrap items-start justify-between gap-3">
                  <div>
                    <div class="text-sm font-semibold">AlienVault OTX Edge Collector</div>
                    <div class="font-mono text-xs text-base-content/60">{@plugin_id}</div>
                  </div>
                  <.package_status package={@latest_package} approved_package={@approved_package} />
                </div>
              </div>

              <div class="rounded-xl border border-base-200 bg-base-100 p-4">
                <div class="mb-3 text-sm font-semibold">Assignments</div>
                <%= if @assignments == [] do %>
                  <div class="rounded-lg border border-dashed border-base-300 p-4 text-sm text-base-content/60">
                    No edge assignments.
                  </div>
                <% else %>
                  <div class="divide-y divide-base-200">
                    <%= for assignment <- @assignments do %>
                      <div class="flex flex-col gap-3 py-3 first:pt-0 last:pb-0 md:flex-row md:items-center md:justify-between">
                        <div>
                          <div class="font-mono text-sm">{assignment.agent_uid}</div>
                          <div class="text-xs text-base-content/60">
                            every {assignment.interval_seconds}s, timeout {assignment.timeout_seconds}s
                          </div>
                        </div>
                        <div class="flex items-center gap-2">
                          <%= if assignment.enabled do %>
                            <.ui_badge size="xs" variant="success">enabled</.ui_badge>
                          <% else %>
                            <.ui_badge size="xs" variant="ghost">disabled</.ui_badge>
                          <% end %>
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
                      </div>
                    <% end %>
                  </div>
                <% end %>
              </div>

              <div class="rounded-xl border border-base-200 bg-base-100 p-4">
                <div class="mb-3 text-sm font-semibold">Sync Health</div>
                <%= if @sync_statuses == [] do %>
                  <div class="rounded-lg border border-dashed border-base-300 p-4 text-sm text-base-content/60">
                    No sync runs recorded.
                  </div>
                <% else %>
                  <div class="divide-y divide-base-200">
                    <%= for status <- @sync_statuses do %>
                      <div class="py-3 first:pt-0 last:pb-0 space-y-2">
                        <div class="flex flex-wrap items-start justify-between gap-2">
                          <div>
                            <div class="font-mono text-sm">{status_agent_label(status)}</div>
                            <div class="text-xs text-base-content/60">
                              {status.collection_id || "collection"} · {format_datetime(
                                status.last_attempt_at
                              )}
                            </div>
                          </div>
                          <.ui_badge size="xs" variant={status_badge_variant(status.last_status)}>
                            {status.last_status}
                          </.ui_badge>
                        </div>
                        <div class="grid grid-cols-2 gap-2 text-xs sm:grid-cols-4">
                          <.status_count label="Objects" value={status.objects_count} />
                          <.status_count label="IOCs" value={status.indicators_count} />
                          <.status_count label="Skipped" value={status.skipped_count} />
                          <.status_count label="Total" value={status.total_count} />
                        </div>
                        <div :if={status.last_error} class="text-xs text-error">
                          {status.last_error}
                        </div>
                      </div>
                    <% end %>
                  </div>
                <% end %>
              </div>
            </div>

            <div class="rounded-xl border border-base-200 bg-base-100 p-4">
              <div class="mb-3 text-sm font-semibold">OTX Assignment</div>
              <form phx-change="assignment_change" phx-submit="save_assignment" class="space-y-3">
                <div>
                  <label class="label">
                    <span class="label-text">Agent</span>
                  </label>
                  <select
                    name="assignment[agent_uid]"
                    class="select select-bordered w-full"
                    disabled={is_nil(@approved_package)}
                  >
                    <option value="">Select an agent</option>
                    <%= for agent <- @agents do %>
                      <option value={agent.uid} selected={@assignment_form["agent_uid"] == agent.uid}>
                        {agent_label(agent)}
                      </option>
                    <% end %>
                  </select>
                </div>

                <div>
                  <label class="label">
                    <span class="label-text">OTX API Key</span>
                  </label>
                  <input
                    type="password"
                    name="assignment[api_key_secret_ref]"
                    value=""
                    class="input input-bordered w-full"
                    autocomplete="off"
                    disabled={is_nil(@approved_package)}
                    placeholder={api_key_placeholder(@assignment_form["agent_uid"], @assignments)}
                  />
                </div>

                <div>
                  <label class="label">
                    <span class="label-text">Base URL</span>
                  </label>
                  <input
                    type="url"
                    name="assignment[base_url]"
                    value={@assignment_form["base_url"]}
                    class="input input-bordered w-full"
                    disabled={is_nil(@approved_package)}
                  />
                </div>

                <div class="grid grid-cols-2 gap-3">
                  <.number_input
                    name="assignment[interval_seconds]"
                    label="Interval"
                    value={@assignment_form["interval_seconds"]}
                    min="60"
                    disabled={is_nil(@approved_package)}
                  />
                  <.number_input
                    name="assignment[timeout_seconds]"
                    label="Timeout"
                    value={@assignment_form["timeout_seconds"]}
                    min="1"
                    disabled={is_nil(@approved_package)}
                  />
                  <.number_input
                    name="assignment[limit]"
                    label="Page Size"
                    value={@assignment_form["limit"]}
                    min="1"
                    disabled={is_nil(@approved_package)}
                  />
                  <.number_input
                    name="assignment[max_indicators]"
                    label="Max IOCs"
                    value={@assignment_form["max_indicators"]}
                    min="1"
                    disabled={is_nil(@approved_package)}
                  />
                  <.number_input
                    name="assignment[page]"
                    label="Page"
                    value={@assignment_form["page"]}
                    min="1"
                    disabled={is_nil(@approved_package)}
                  />
                  <.number_input
                    name="assignment[timeout_ms]"
                    label="HTTP Timeout"
                    value={@assignment_form["timeout_ms"]}
                    min="1000"
                    disabled={is_nil(@approved_package)}
                  />
                </div>

                <label class="flex items-center gap-2 text-sm">
                  <input type="hidden" name="assignment[enabled]" value="false" />
                  <input
                    type="checkbox"
                    name="assignment[enabled]"
                    value="true"
                    class="toggle toggle-sm"
                    checked={@assignment_form["enabled"] == "true"}
                    disabled={is_nil(@approved_package)}
                  /> Enabled
                </label>

                <div class="flex justify-end pt-2">
                  <button
                    class="btn btn-sm btn-primary"
                    type="submit"
                    disabled={is_nil(@approved_package)}
                  >
                    Save Assignment
                  </button>
                </div>
              </form>
            </div>
          </div>
        </section>
      </.settings_shell>
    </Layouts.app>
    """
  end

  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :min, :string, default: nil
  attr :disabled, :boolean, default: false

  defp number_input(assigns) do
    ~H"""
    <div>
      <label class="label">
        <span class="label-text">{@label}</span>
      </label>
      <input
        type="number"
        name={@name}
        value={@value}
        min={@min}
        class="input input-bordered w-full"
        disabled={@disabled}
      />
    </div>
    """
  end

  attr :package, PluginPackage, default: nil
  attr :approved_package, PluginPackage, default: nil

  defp package_status(assigns) do
    ~H"""
    <%= cond do %>
      <% @approved_package -> %>
        <.ui_badge size="sm" variant="success">approved {@approved_package.version}</.ui_badge>
      <% @package -> %>
        <.ui_badge size="sm" variant="warning">{@package.status} {@package.version}</.ui_badge>
      <% true -> %>
        <.ui_badge size="sm" variant="ghost">not imported</.ui_badge>
    <% end %>
    """
  end

  attr :label, :string, required: true
  attr :value, :integer, required: true

  defp status_count(assigns) do
    ~H"""
    <div class="rounded-lg border border-base-200/70 bg-base-100/60 p-2">
      <div class="text-base-content/50">{@label}</div>
      <div class="font-mono text-sm">{@value}</div>
    </div>
    """
  end

  defp load_page(socket) do
    scope = socket.assigns.current_scope
    packages = Packages.list(%{"plugin_id" => @plugin_id, "limit" => 20}, scope: scope)
    approved_package = Enum.find(packages, &(&1.status == :approved))
    latest_package = List.first(packages)

    socket
    |> assign(:page_title, "Threat Intel")
    |> assign(:plugin_id, @plugin_id)
    |> assign(:agents, list_agents(scope))
    |> assign(:packages, packages)
    |> assign(:latest_package, latest_package)
    |> assign(:approved_package, approved_package)
    |> assign(:assignments, list_assignments(approved_package, scope))
    |> assign(:sync_statuses, list_sync_statuses(scope))
    |> assign(:assignment_form, @default_form)
  end

  defp reload_assignments(socket) do
    assign(
      socket,
      :assignments,
      list_assignments(socket.assigns.approved_package, socket.assigns.current_scope)
    )
  end

  defp create_assignment(socket, scope, attrs) do
    case Assignments.create(attrs, scope: scope) do
      {:ok, _assignment} ->
        {:noreply,
         socket
         |> reload_assignments()
         |> assign(:assignment_form, @default_form)
         |> put_flash(:info, "Assignment saved")}

      {:error, error} ->
        Logger.warning("Threat intel assignment creation failed", error: inspect(error))
        {:noreply, put_flash(socket, :error, "Failed to save assignment")}
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
         |> reload_assignments()
         |> assign(:assignment_form, @default_form)
         |> put_flash(:info, "Assignment saved")}

      {:error, error} ->
        Logger.warning("Threat intel assignment update failed",
          id: assignment.id,
          error: inspect(error)
        )

        {:noreply, put_flash(socket, :error, "Failed to save assignment")}
    end
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

  defp list_assignments(nil, _scope), do: []

  defp list_assignments(%PluginPackage{id: package_id}, scope) do
    Assignments.list(%{"plugin_package_id" => package_id, "limit" => 200}, scope: scope)
  end

  defp list_sync_statuses(scope) do
    ThreatIntelSyncStatus
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(source == "alienvault_otx" or plugin_id == ^@plugin_id)
    |> Ash.Query.limit(20)
    |> Ash.Query.sort(last_attempt_at: :desc)
    |> Ash.read!(scope: scope)
  rescue
    _ -> []
  end

  defp parse_assignment(params, package) when is_map(params) do
    with {:ok, agent_uid} <- required_string(params["agent_uid"], "Agent is required"),
         {:ok, interval_seconds} <- parse_positive_int(params["interval_seconds"], 3600),
         {:ok, timeout_seconds} <- parse_positive_int(params["timeout_seconds"], 30),
         {:ok, params_map} <- parse_plugin_params(params, package.config_schema || %{}) do
      {:ok,
       %{
         agent_uid: agent_uid,
         plugin_package_id: package.id,
         enabled: params["enabled"] == "true",
         interval_seconds: interval_seconds,
         timeout_seconds: timeout_seconds,
         params: params_map
       }}
    end
  end

  defp parse_plugin_params(params, config_schema) do
    raw =
      %{
        "base_url" => params["base_url"],
        "api_key_secret_ref" => params["api_key_secret_ref"],
        "limit" => params["limit"],
        "page" => params["page"],
        "timeout_ms" => params["timeout_ms"],
        "max_indicators" => params["max_indicators"]
      }
      |> Enum.reject(fn
        {_key, nil} -> true
        {_key, value} when is_binary(value) -> String.trim(value) == ""
        _ -> false
      end)
      |> Map.new(fn {key, value} -> {key, trim_string(value)} end)

    {:ok, ConfigSchema.normalize_params(stringify_keys(config_schema), raw)}
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp required_string(value, message) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, message}
      trimmed -> {:ok, trimmed}
    end
  end

  defp required_string(_value, message), do: {:error, message}

  defp parse_positive_int(value, default) do
    value = trim_string(value)

    case Integer.parse(value || "") do
      {parsed, ""} when parsed > 0 -> {:ok, parsed}
      _ when is_integer(default) and default > 0 -> {:ok, default}
      _ -> {:error, "Expected a positive integer"}
    end
  end

  defp trim_string(value) when is_binary(value), do: String.trim(value)
  defp trim_string(value), do: value

  defp stringify_keys(%{} = map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp existing_assignment(assignments, agent_uid) do
    Enum.find(assignments, &(&1.agent_uid == agent_uid))
  end

  defp agent_label(agent) do
    cond do
      is_binary(agent.name) and agent.name != "" -> "#{agent.name} (#{agent.uid})"
      is_binary(agent.host) and agent.host != "" -> "#{agent.host} (#{agent.uid})"
      true -> agent.uid
    end
  end

  defp api_key_placeholder(agent_uid, assignments) do
    if is_binary(agent_uid) and existing_assignment(assignments, agent_uid) do
      "Leave blank to keep stored key"
    else
      ""
    end
  end

  defp status_agent_label(%ThreatIntelSyncStatus{} = status) do
    cond do
      status.agent_id != "" -> status.agent_id
      status.plugin_id != "" -> status.plugin_id
      true -> status.source
    end
  end

  defp status_badge_variant(status) when status in ["ok", "success"], do: "success"
  defp status_badge_variant(status) when status in ["warn", "warning"], do: "warning"
  defp status_badge_variant(status) when status in ["critical", "error", "failed"], do: "error"
  defp status_badge_variant(_status), do: "ghost"

  defp format_datetime(nil), do: "-"
  defp format_datetime(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  defp format_datetime(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  defp format_datetime(value), do: to_string(value)

  defp format_error(value) when is_binary(value), do: value
  defp format_error(value), do: inspect(value)
end
