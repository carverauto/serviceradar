defmodule ServiceRadarWebNGWeb.Settings.AvailabilitySourceProfilesLive do
  @moduledoc """
  Settings UI for SRQL-scoped canonical availability source profiles.
  """

  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Inventory.AvailabilitySourceProfile
  alias ServiceRadar.Inventory.AvailabilitySourceProfileMaterializer
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.Settings.Shell

  require Ash.Query

  @current_path "/settings/networks/availability-sources"

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if can_manage?(scope) do
      profiles = load_profiles(scope)
      agents = load_agents(scope)
      profile_params = default_profile_params()

      {:ok,
       socket
       |> assign(:page_title, "Availability Sources")
       |> assign(:current_path, @current_path)
       |> assign(:profiles, profiles)
       |> assign(:agents, agents)
       |> assign(:agent_options, agent_options(agents))
       |> assign(:agent_by_uid, Map.new(agents, &{&1.uid, &1}))
       |> assign(:editing_id, nil)
       |> assign(:profile_params, profile_params)
       |> assign(:profile_form, to_profile_form(profile_params))
       |> assign(:preview, nil)
       |> assign(:materialize_summary, nil)}
    else
      {:ok,
       socket
       |> put_flash(:error, "Not authorized to manage availability source profiles")
       |> redirect(to: ~p"/settings/profile")}
    end
  end

  @impl true
  def handle_event("validate_profile", %{"profile" => params}, socket) do
    profile_params = merge_profile_params(socket.assigns.profile_params, params)

    {:noreply,
     socket
     |> assign(:profile_params, profile_params)
     |> assign(:profile_form, to_profile_form(profile_params))
     |> assign(:preview, nil)}
  end

  def handle_event("preview_profile", _params, socket) do
    profile_params = socket.assigns.profile_params

    case AvailabilitySourceProfileMaterializer.preview_scope(profile_params["srql_query"]) do
      {:ok, preview} ->
        {:noreply, assign(socket, :preview, %{status: :ok, result: preview})}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:preview, %{status: :error, reason: format_error(reason)})
         |> put_flash(:error, "Preview failed: #{format_error(reason)}")}
    end
  end

  def handle_event("save_profile", %{"profile" => params}, socket) do
    scope = socket.assigns.current_scope
    profile_params = merge_profile_params(socket.assigns.profile_params, params)

    with {:ok, attrs} <- attrs_from_params(profile_params),
         {:ok, profile} <- save_profile(scope, socket.assigns.editing_id, attrs) do
      profiles = load_profiles(scope)

      {:noreply,
       socket
       |> put_flash(:info, "Saved #{profile.name}")
       |> assign(:profiles, profiles)
       |> assign(:editing_id, nil)
       |> assign(:profile_params, default_profile_params())
       |> assign(:profile_form, to_profile_form(default_profile_params()))
       |> assign(:preview, nil)}
    else
      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:profile_params, profile_params)
         |> assign(:profile_form, to_profile_form(profile_params))
         |> put_flash(:error, "Save failed: #{format_error(reason)}")}
    end
  end

  def handle_event("edit_profile", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    case get_profile(scope, id) do
      {:ok, %AvailabilitySourceProfile{} = profile} ->
        profile_params = profile_to_params(profile)

        {:noreply,
         socket
         |> assign(:editing_id, profile.id)
         |> assign(:profile_params, profile_params)
         |> assign(:profile_form, to_profile_form(profile_params))
         |> assign(:preview, nil)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not load profile: #{format_error(reason)}")}
    end
  end

  def handle_event("new_profile", _params, socket) do
    profile_params = default_profile_params()

    {:noreply,
     socket
     |> assign(:editing_id, nil)
     |> assign(:profile_params, profile_params)
     |> assign(:profile_form, to_profile_form(profile_params))
     |> assign(:preview, nil)}
  end

  def handle_event("toggle_profile", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    with {:ok, %AvailabilitySourceProfile{} = profile} <- get_profile(scope, id),
         {:ok, _profile} <- update_profile(scope, profile, %{enabled: !profile.enabled}) do
      {:noreply,
       socket
       |> put_flash(:info, "Updated #{profile.name}")
       |> assign(:profiles, load_profiles(scope))}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Update failed: #{format_error(reason)}")}
    end
  end

  def handle_event("delete_profile", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    with {:ok, %AvailabilitySourceProfile{} = profile} <- get_profile(scope, id),
         :ok <- destroy_profile(scope, profile) do
      {:noreply,
       socket
       |> put_flash(:info, "Deleted #{profile.name}")
       |> assign(:profiles, load_profiles(scope))
       |> maybe_reset_form(profile.id)}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Delete failed: #{format_error(reason)}")}
    end
  end

  def handle_event("materialize_profiles", _params, socket) do
    scope = socket.assigns.current_scope

    case AvailabilitySourceProfileMaterializer.materialize(scope: scope) do
      {:ok, summary} ->
        {:noreply,
         socket
         |> put_flash(:info, "Applied availability source profiles")
         |> assign(:profiles, load_profiles(scope))
         |> assign(:materialize_summary, summary)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Apply failed: #{format_error(reason)}")}
    end
  end

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
        <section class="space-y-6">
          <div class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
            <div>
              <h1 class="text-xl font-semibold">Availability Sources</h1>
              <p class="max-w-3xl text-sm text-sr-muted">
                Assign canonical availability agents to SRQL-scoped device sets. Per-device overrides remain authoritative until cleared.
              </p>
            </div>
            <div class="flex flex-wrap gap-2">
              <.ui_button type="button" phx-click="new_profile" size="sm" variant="ghost">
                <.icon name="hero-plus" class="size-4" /> New
              </.ui_button>
              <.ui_button type="button" phx-click="materialize_profiles" size="sm" variant="primary">
                <.icon name="hero-arrow-path" class="size-4" /> Apply
              </.ui_button>
            </div>
          </div>

          <div
            :if={@materialize_summary}
            class="rounded-lg border border-sr-line bg-sr-surface p-4 text-sm"
          >
            <div class="grid gap-3 sm:grid-cols-4">
              <div>
                <div class="text-xs uppercase tracking-wide text-sr-muted">Profiles</div>
                <div class="font-semibold">{@materialize_summary.profiles}</div>
              </div>
              <div>
                <div class="text-xs uppercase tracking-wide text-sr-muted">Matched</div>
                <div class="font-semibold">{@materialize_summary.matched_devices}</div>
              </div>
              <div>
                <div class="text-xs uppercase tracking-wide text-sr-muted">Applied</div>
                <div class="font-semibold">{@materialize_summary.applied_devices}</div>
              </div>
              <div>
                <div class="text-xs uppercase tracking-wide text-sr-muted">Cleared</div>
                <div class="font-semibold">{@materialize_summary.cleared_devices}</div>
              </div>
            </div>
          </div>

          <div class="grid gap-6 xl:grid-cols-[minmax(0,1fr)_420px]">
            <section class="overflow-hidden rounded-lg border border-sr-line bg-sr-surface">
              <div class="sr-ui-table-shell">
                <table class={ui_table_class(size: "sm")}>
                  <thead>
                    <tr>
                      <th>Name</th>
                      <th>Agent</th>
                      <th>Priority</th>
                      <th>Last Run</th>
                      <th>Matches</th>
                      <th>Status</th>
                      <th class="text-right">Actions</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :if={@profiles == []}>
                      <td colspan="7" class="py-8 text-center text-sm text-sr-muted">
                        No availability source profiles have been configured.
                      </td>
                    </tr>
                    <tr :for={profile <- @profiles}>
                      <td class="min-w-56">
                        <div class="font-medium">{profile.name}</div>
                        <div class="max-w-sm truncate font-mono text-xs text-sr-muted">
                          {profile.srql_query}
                        </div>
                      </td>
                      <td>{agent_label(profile.agent_id, @agent_by_uid)}</td>
                      <td>{profile.priority}</td>
                      <td>
                        <.user_time
                          id={"settings-availability-source-profile-#{profile.id}-last-evaluated-at"}
                          value={profile.last_evaluated_at}
                          timezone={@current_scope.user.timezone || "Etc/UTC"}
                          style={:compact}
                          fallback="-"
                        />
                      </td>
                      <td>{profile.applied_count} / {profile.match_count}</td>
                      <td>
                        <.ui_badge
                          size="sm"
                          variant={if(profile.enabled, do: "success", else: "ghost")}
                        >
                          {if profile.enabled, do: "Enabled", else: "Disabled"}
                        </.ui_badge>
                      </td>
                      <td>
                        <div class="flex justify-end gap-1">
                          <.ui_button
                            type="button"
                            phx-click="edit_profile"
                            phx-value-id={profile.id}
                            aria-label="Edit profile"
                            title="Edit profile"
                            size="xs"
                            variant="ghost"
                          >
                            <.icon name="hero-pencil-square" class="size-4" />
                          </.ui_button>
                          <.ui_button
                            type="button"
                            phx-click="toggle_profile"
                            phx-value-id={profile.id}
                            aria-label="Toggle profile"
                            title="Toggle profile"
                            size="xs"
                            variant="ghost"
                          >
                            <.icon
                              name={if profile.enabled, do: "hero-pause", else: "hero-play"}
                              class="size-4"
                            />
                          </.ui_button>
                          <.ui_button
                            type="button"
                            phx-click="delete_profile"
                            phx-value-id={profile.id}
                            data-confirm="Delete this availability source profile?"
                            aria-label="Delete profile"
                            title="Delete profile"
                            size="xs"
                            variant="ghost"
                            class="text-error"
                          >
                            <.icon name="hero-trash" class="size-4" />
                          </.ui_button>
                        </div>
                      </td>
                    </tr>
                  </tbody>
                </table>
              </div>
            </section>

            <aside class="space-y-4">
              <section class="rounded-lg border border-sr-line bg-sr-surface p-4">
                <h2 class="text-base font-semibold">
                  {if @editing_id, do: "Edit Profile", else: "New Profile"}
                </h2>

                <.form
                  for={@profile_form}
                  id="availability-source-profile-form"
                  class="mt-4 space-y-3"
                  phx-change="validate_profile"
                  phx-submit="save_profile"
                >
                  <.input field={@profile_form[:name]} label="Name" />
                  <.input
                    field={@profile_form[:description]}
                    type="textarea"
                    rows="2"
                    label="Description"
                  />
                  <.input
                    field={@profile_form[:srql_query]}
                    type="textarea"
                    rows="3"
                    label="Device SRQL scope"
                    placeholder="in:devices tags.segment:plant"
                  />
                  <.input
                    field={@profile_form[:agent_id]}
                    type="select"
                    label="Canonical agent"
                    prompt="Select agent"
                    options={@agent_options}
                  />
                  <div class="grid grid-cols-2 gap-3">
                    <.input field={@profile_form[:priority]} type="number" label="Priority" />
                    <.input field={@profile_form[:enabled]} type="checkbox" label="Enabled" />
                  </div>

                  <div class="flex justify-end gap-2">
                    <.ui_button type="button" phx-click="preview_profile" size="sm" variant="ghost">
                      <.icon name="hero-eye" class="size-4" /> Preview
                    </.ui_button>
                    <.ui_button type="submit" size="sm" variant="primary">
                      <.icon name="hero-check" class="size-4" /> Save
                    </.ui_button>
                  </div>
                </.form>
              </section>

              <section
                :if={@preview}
                class="rounded-lg border border-sr-line bg-sr-surface p-4 text-sm"
              >
                <%= if @preview.status == :ok do %>
                  <div class="font-medium">Preview</div>
                  <div class="mt-1 font-mono text-xs text-sr-muted">
                    {@preview.result.query}
                  </div>
                  <div class="mt-3 text-sr-muted">
                    Showing {Enum.count(@preview.result.rows)} of up to 25 matching rows.
                  </div>
                  <ul class="mt-3 max-h-72 space-y-2 overflow-auto">
                    <li
                      :for={row <- @preview.result.rows}
                      class="rounded border border-sr-line px-3 py-2"
                    >
                      <div class="font-mono text-xs">{preview_uid(row)}</div>
                      <div class="truncate text-xs text-sr-muted">
                        {preview_label(row)}
                      </div>
                    </li>
                  </ul>
                <% else %>
                  <div class="font-medium text-error">Preview failed</div>
                  <div class="mt-1 text-sr-muted">{@preview.reason}</div>
                <% end %>
              </section>
            </aside>
          </div>
        </section>
      </Shell.settings_chrome>
    </Layouts.app>
    """
  end

  defp load_profiles(scope) do
    AvailabilitySourceProfile
    |> Ash.Query.for_read(:read, %{}, scope: scope)
    |> Ash.Query.sort(priority: :desc, name: :asc)
    |> Ash.read(scope: scope)
    |> unwrap_results()
  end

  defp load_agents(scope) do
    Agent
    |> Ash.Query.for_read(:read, %{}, scope: scope)
    |> Ash.Query.sort(uid: :asc)
    |> Ash.read(scope: scope)
    |> unwrap_results()
  end

  defp get_profile(scope, id) do
    AvailabilitySourceProfile
    |> Ash.Query.for_read(:by_id, %{id: id}, scope: scope)
    |> Ash.read_one(scope: scope)
    |> case do
      {:ok, %AvailabilitySourceProfile{} = profile} -> {:ok, profile}
      {:ok, nil} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp save_profile(scope, nil, attrs) do
    AvailabilitySourceProfile
    |> Ash.Changeset.for_create(:create, attrs, scope: scope)
    |> Ash.create(scope: scope)
  end

  defp save_profile(scope, id, attrs) do
    with {:ok, profile} <- get_profile(scope, id) do
      update_profile(scope, profile, attrs)
    end
  end

  defp update_profile(scope, profile, attrs) do
    profile
    |> Ash.Changeset.for_update(:update, attrs, scope: scope)
    |> Ash.update(scope: scope)
  end

  defp destroy_profile(scope, profile) do
    case Ash.destroy(profile, scope: scope) do
      :ok -> :ok
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp default_profile_params do
    %{
      "name" => "",
      "description" => "",
      "srql_query" => "in:devices ",
      "agent_id" => "",
      "priority" => "100",
      "enabled" => "true"
    }
  end

  defp profile_to_params(%AvailabilitySourceProfile{} = profile) do
    %{
      "name" => profile.name || "",
      "description" => profile.description || "",
      "srql_query" => profile.srql_query || "",
      "agent_id" => profile.agent_id || "",
      "priority" => to_string(profile.priority || 100),
      "enabled" => to_string(profile.enabled)
    }
  end

  defp to_profile_form(params), do: to_form(params, as: :profile)

  defp merge_profile_params(current, params) when is_map(current) and is_map(params) do
    Map.merge(current, params)
  end

  defp attrs_from_params(params) do
    with {:ok, name} <- required_string(params["name"], "Name"),
         {:ok, srql_query} <- required_string(params["srql_query"], "SRQL scope"),
         {:ok, agent_id} <- required_string(params["agent_id"], "Canonical agent"),
         {:ok, priority} <- parse_integer(params["priority"]) do
      {:ok,
       %{
         name: name,
         description: blank_to_nil(params["description"]),
         srql_query: srql_query,
         agent_id: agent_id,
         priority: priority,
         enabled: truthy?(params["enabled"]),
         metadata: %{}
       }}
    end
  end

  defp required_string(value, label) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, "#{label} is required"}
      trimmed -> {:ok, trimmed}
    end
  end

  defp required_string(_value, label), do: {:error, "#{label} is required"}

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> {:ok, int}
      _ -> {:error, "Priority must be an integer"}
    end
  end

  defp parse_integer(value) when is_integer(value), do: {:ok, value}
  defp parse_integer(_value), do: {:error, "Priority must be an integer"}

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_value), do: nil

  defp truthy?(value) when value in [true, "true", "on", "1", 1], do: true
  defp truthy?(_value), do: false

  defp unwrap_results({:ok, %{results: results}}), do: results
  defp unwrap_results({:ok, results}) when is_list(results), do: results
  defp unwrap_results(_), do: []

  defp agent_options(agents) do
    Enum.map(agents, fn agent -> {agent_label(agent), agent.uid} end)
  end

  defp agent_label(%Agent{} = agent) do
    display = agent.name || agent.host || agent.uid
    "#{display} (#{agent.uid})"
  end

  defp agent_label(agent_id, agent_by_uid) do
    case Map.get(agent_by_uid, agent_id) do
      %Agent{} = agent -> agent_label(agent)
      _ -> agent_id || "Unassigned"
    end
  end

  defp preview_uid(row), do: Map.get(row, "uid") || Map.get(row, :uid) || Map.get(row, "id") || Map.get(row, :id) || "-"

  defp preview_label(row) do
    Map.get(row, "hostname") || Map.get(row, :hostname) || Map.get(row, "ip") || Map.get(row, :ip) ||
      inspect(row)
  end

  defp maybe_reset_form(socket, deleted_id) do
    if socket.assigns.editing_id == deleted_id do
      profile_params = default_profile_params()

      socket
      |> assign(:editing_id, nil)
      |> assign(:profile_params, profile_params)
      |> assign(:profile_form, to_profile_form(profile_params))
      |> assign(:preview, nil)
    else
      socket
    end
  end

  defp format_error(error) when is_binary(error), do: error
  defp format_error(%Ash.Error.Invalid{} = error), do: Exception.message(error)
  defp format_error(%Ash.Error.Forbidden{}), do: "not authorized"
  defp format_error(:not_found), do: "not found"
  defp format_error(error), do: inspect(error)

  defp can_manage?(scope), do: RBAC.can?(scope, "settings.networks.manage")
end
