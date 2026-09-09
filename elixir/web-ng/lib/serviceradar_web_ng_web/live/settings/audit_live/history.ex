defmodule ServiceRadarWebNGWeb.Settings.AuditLive.History do
  @moduledoc """
  Settings → Audit → History.

  Unified timeline across the resources in
  `ServiceRadar.Security.AuditHistory`'s two allow-lists: AshPaperTrail
  version rows (`resources/0`) and AshEvents `ApiEvent` rows
  (`ash_events_resources/0`, adapted to the same shape by
  `AuditHistory.list_recent/1`). Operators filter by resource type, actor
  identifier, action type, and time range, and drill into a single row's
  `changes` map for the diff detail. The "Origin" column shows `api` / `web`
  for AshEvents rows and "—" for PaperTrail rows, which have no transport
  concept. Gated by `settings.audit.view`.
  """

  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadar.Identity.RBAC
  alias ServiceRadar.Security.AuditHistory
  alias ServiceRadarWebNGWeb.Settings.Shell

  on_mount {ServiceRadarWebNGWeb.UserAuth, :require_authenticated}

  @page_size 50
  @action_types ~w(create update destroy)

  @impl true
  def mount(_params, _session, socket) do
    {permissions, ash_actor} = permissions_and_actor(socket)

    socket =
      socket
      |> assign(:page_title, "Settings → Audit → History")
      |> assign(:current_path, "/settings/audit/history")
      |> assign(:permissions, permissions)
      |> assign(:ash_actor, ash_actor)
      |> assign(:can_view?, MapSet.member?(permissions, "settings.audit.view"))
      |> assign(:resource_options, resource_options())
      |> assign(:action_types, @action_types)
      |> assign(:resource_filter, nil)
      |> assign(:action_filter, nil)
      |> assign(:actor_filter, nil)
      |> assign(:selected_version, nil)
      |> load_versions()

    {:ok, socket}
  end

  @impl true
  def handle_event("filter", params, socket) do
    {:noreply,
     socket
     |> assign(:resource_filter, blank_to_nil(params["resource"]))
     |> assign(:action_filter, blank_to_nil(params["action"]))
     |> assign(:actor_filter, blank_to_nil(params["actor"]))
     |> assign(:selected_version, nil)
     |> load_versions()}
  end

  def handle_event("clear-filters", _params, socket) do
    {:noreply,
     socket
     |> assign(:resource_filter, nil)
     |> assign(:action_filter, nil)
     |> assign(:actor_filter, nil)
     |> assign(:selected_version, nil)
     |> load_versions()}
  end

  def handle_event("select-version", %{"resource" => resource_str, "id" => id}, socket) do
    case Enum.find(socket.assigns.versions, fn entry ->
           to_string(entry.resource) == resource_str and entry.version.id == id
         end) do
      nil -> {:noreply, socket}
      entry -> {:noreply, assign(socket, :selected_version, entry)}
    end
  end

  def handle_event("close-version", _params, socket) do
    {:noreply, assign(socket, :selected_version, nil)}
  end

  ## Internals

  defp permissions_and_actor(socket) do
    case socket.assigns[:current_scope] do
      %{user: %{} = user} ->
        perms = RBAC.permissions_for_user(user)
        {perms, build_actor(user, perms)}

      _ ->
        {MapSet.new(), nil}
    end
  end

  defp build_actor(user, perms) do
    %{user | role: pick_role(perms)}
  rescue
    _ -> user
  end

  defp pick_role(perms) do
    cond do
      MapSet.member?(perms, "settings.audit.manage") -> :admin
      MapSet.member?(perms, "settings.audit.view") -> :operator
      true -> :viewer
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(value), do: value

  defp resource_options do
    AuditHistory.all_resources()
    |> Enum.map(fn module ->
      label = module |> Module.split() |> List.last()
      {label, to_string(module)}
    end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp load_versions(socket) do
    if socket.assigns.can_view? do
      opts =
        [actor: socket.assigns.ash_actor, limit: @page_size]
        |> maybe_put_resource_filter(socket.assigns.resource_filter)
        |> maybe_put_action_filter(socket.assigns.action_filter)
        |> maybe_put_actor_filter(socket.assigns.actor_filter)

      versions =
        try do
          AuditHistory.list_recent(opts)
        rescue
          # DB unreachable in dev: render an empty page rather than crash.
          _ -> []
        end

      assign(socket, :versions, versions)
    else
      assign(socket, :versions, [])
    end
  end

  defp maybe_put_resource_filter(opts, nil), do: opts

  defp maybe_put_resource_filter(opts, resource_str) do
    case resolve_resource(resource_str) do
      nil -> opts
      module -> Keyword.put(opts, :resource_types, [module])
    end
  end

  defp maybe_put_action_filter(opts, nil), do: opts
  defp maybe_put_action_filter(opts, action) when action in @action_types, do: Keyword.put(opts, :action_types, [action])

  defp maybe_put_action_filter(opts, _), do: opts

  defp maybe_put_actor_filter(opts, nil), do: opts
  defp maybe_put_actor_filter(opts, ""), do: opts
  defp maybe_put_actor_filter(opts, actor), do: Keyword.put(opts, :actor_id, actor)

  defp resolve_resource(resource_str) when is_binary(resource_str) do
    Enum.find(AuditHistory.all_resources(), &(to_string(&1) == resource_str))
  end

  defp resolve_resource(_), do: nil

  defp resource_label(module), do: module |> Module.split() |> List.last()

  # `entry.origin` is "api"/"web" for an AshEvents-adapted row (see
  # `AuditHistory.adapt_ash_event/1`) and nil for a PaperTrail row, which has
  # no transport concept.
  defp origin_label(nil), do: "—"
  defp origin_label(origin) when is_binary(origin), do: origin

  defp truncate_json(nil), do: ""

  defp truncate_json(value) when is_binary(value) do
    if byte_size(value) > 8 * 1024, do: "(#{byte_size(value)} bytes, truncated)", else: value
  end

  defp truncate_json(value) do
    json =
      case Jason.encode(value, pretty: true) do
        {:ok, encoded} -> encoded
        _ -> inspect(value)
      end

    truncate_json(json)
  end

  defp extract_actor(version) do
    # Not every version record carries `version_action_inputs` — e.g. an
    # `ActionInvocation.Version` (`store_action_inputs? false`) omits the
    # attribute entirely, so `ServiceRadar.Security.Changes.StampAuditActor`
    # can only reach it there through the dedicated `:actor`/`:actor_id`
    # attributes it also sets. Check those first, then fall back to
    # `version_action_inputs` for resources that only carry it there.
    # `Map.get/2` (rather than struct access, which would raise `KeyError`)
    # handles both a missing struct key and a resource with neither.
    case Map.get(version, :actor) do
      %{"id" => "system:" <> _ = id} ->
        system_actor_label(id)

      %{"email" => email} when is_binary(email) ->
        email

      %{"id" => id} when is_binary(id) ->
        id

      _ ->
        case Map.get(version, :actor_id) do
          actor_id when is_binary(actor_id) -> actor_label(actor_id)
          _ -> extract_actor_from_inputs(version)
        end
    end
  end

  defp extract_actor_from_inputs(version) do
    inputs = Map.get(version, :version_action_inputs) || %{}

    case inputs do
      %{"actor" => %{"id" => "system:" <> _ = id}} -> system_actor_label(id)
      %{"actor" => %{"email" => email}} when is_binary(email) -> email
      %{"actor" => %{"id" => id}} when is_binary(id) -> id
      %{"actor" => actor} when is_binary(actor) -> actor_label(actor)
      %{"actor_id" => actor_id} when is_binary(actor_id) -> actor_label(actor_id)
      _ -> "—"
    end
  end

  # `ServiceRadar.Actors.SystemActor.system/1` builds ids as "system:<component>"
  # -- a stable, id-only signal (present even when only `actor_id` survived,
  # e.g. via `ApiEvent`'s `metadata["actor_id"]` fallback) that a row was
  # written by a background/plugin actor rather than a person, so it's worth
  # calling out explicitly instead of showing the raw id.
  defp actor_label("system:" <> _ = id), do: system_actor_label(id)
  defp actor_label(id), do: id

  defp system_actor_label("system:" <> component), do: "System · #{component}"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={@current_path}>
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
          <h1 class="text-2xl font-semibold">Audit · History</h1>
          <p class="text-sm text-sr-muted">
            Cross-resource timeline (AshPaperTrail versions and AshEvents API events). Filter by resource, actor, action, and time range; click a row for the diff.
          </p>
        </header>

        <%= if @can_view? do %>
          <form phx-change="filter" class="flex flex-wrap items-end gap-3">
            <label class="text-sm">
              <span class="mb-1 block text-sr-muted">Resource</span>
              <select name="resource" class="ui-select">
                <option value="">All resources</option>
                <%= for {label, value} <- @resource_options do %>
                  <option value={value} selected={value == @resource_filter}>{label}</option>
                <% end %>
              </select>
            </label>

            <label class="text-sm">
              <span class="mb-1 block text-sr-muted">Action</span>
              <select name="action" class="ui-select">
                <option value="">All actions</option>
                <%= for action <- @action_types do %>
                  <option value={action} selected={action == @action_filter}>{action}</option>
                <% end %>
              </select>
            </label>

            <label class="text-sm">
              <span class="mb-1 block text-sr-muted">Actor</span>
              <input
                type="text"
                name="actor"
                value={@actor_filter || ""}
                placeholder="email or id"
                class="ui-input"
              />
            </label>

            <button type="button" class="ui-button" phx-click="clear-filters">Clear</button>
          </form>

          <div class="overflow-x-auto rounded-lg border border-sr-line bg-sr-surface">
            <table class="min-w-full text-sm text-sr-ink">
              <thead class="bg-sr-subtle/70 text-sr-muted">
                <tr>
                  <th class="px-4 py-2 text-left">When</th>
                  <th class="px-4 py-2 text-left">Resource</th>
                  <th class="px-4 py-2 text-left">Action</th>
                  <th class="px-4 py-2 text-left">Actor</th>
                  <th class="px-4 py-2 text-left">Origin</th>
                  <th class="px-4 py-2 text-left">Source row</th>
                </tr>
              </thead>
              <tbody class="divide-y divide-sr-line">
                <%= for entry <- @versions do %>
                  <tr
                    class="cursor-pointer hover:bg-sr-subtle/40"
                    phx-click="select-version"
                    phx-value-resource={to_string(entry.resource)}
                    phx-value-id={entry.version.id}
                  >
                    <td class="px-4 py-2 font-mono text-xs whitespace-nowrap">
                      <.user_time
                        id={"settings-audit-version-#{entry.version.id}-inserted-at"}
                        value={entry.version.version_inserted_at}
                        timezone={@current_scope.user.timezone || "Etc/UTC"}
                        style={:compact}
                        fallback="—"
                      />
                    </td>
                    <td class="px-4 py-2">{resource_label(entry.resource)}</td>
                    <td class="px-4 py-2">{entry.version.version_action_type}</td>
                    <td class="px-4 py-2 font-mono text-xs">{extract_actor(entry.version)}</td>
                    <td class="px-4 py-2 font-mono text-xs">{origin_label(entry.origin)}</td>
                    <td class="px-4 py-2 font-mono text-xs">{entry.version.version_source_id}</td>
                  </tr>
                <% end %>
                <%= if Enum.empty?(@versions) do %>
                  <tr>
                    <td colspan="6" class="px-4 py-8 text-center text-sr-muted">
                      No version history for the current filters.
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>

          <.ui_modal
            :if={@selected_version}
            id="audit-history-version-modal"
            size="lg"
            on_cancel="close-version"
          >
            <:title>
              {resource_label(@selected_version.resource)} · {@selected_version.version.version_action_type} ·
              <.user_time
                id={"settings-audit-selected-version-#{@selected_version.version.id}-inserted-at"}
                value={@selected_version.version.version_inserted_at}
                timezone={@current_scope.user.timezone || "Etc/UTC"}
                style={:compact}
                fallback="—"
              />
            </:title>

            <div>
              <h3 class="mb-1 text-sm text-sr-muted">Changes</h3>
              <pre class="overflow-x-auto rounded bg-sr-subtle/70 p-3 text-xs">{truncate_json(@selected_version.version.changes)}</pre>
            </div>

            <div>
              <h3 class="mb-1 text-sm text-sr-muted">Action inputs</h3>
              <pre class="overflow-x-auto rounded bg-sr-subtle/70 p-3 text-xs">{truncate_json(@selected_version.version.version_action_inputs)}</pre>
            </div>
          </.ui_modal>
        <% else %>
          <p class="text-sm text-error">
            You need <code>settings.audit.view</code> to see version history.
          </p>
        <% end %>
      </Shell.settings_chrome>
    </Layouts.app>
    """
  end
end
