defmodule ServiceRadarWebNGWeb.Settings.AuditLive.Events do
  @moduledoc """
  Settings → Audit → Events.

  Lists `ServiceRadar.Security.SecurityEvent` rows with filters for
  kind and severity, and live-tails newly recorded events via the
  `"security_events"` Phoenix.PubSub topic (a PG2-backed broadcast
  driven by `ServiceRadar.Security.Events`).
  """

  use ServiceRadarWebNGWeb, :live_view

  import Ash.Expr

  alias ServiceRadar.Identity.RBAC
  alias ServiceRadar.Security.SecurityEvent
  alias ServiceRadarWebNGWeb.Settings.Shell

  require Ash.Query

  on_mount {ServiceRadarWebNGWeb.UserAuth, :require_authenticated}

  @page_size 100

  @impl true
  def mount(_params, _session, socket) do
    {permissions, ash_actor} = permissions_and_actor(socket)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(ServiceRadar.PubSub, "security_events")
    end

    socket =
      socket
      |> assign(:page_title, "Settings → Audit → Events")
      |> assign(:current_path, "/settings/audit/events")
      |> assign(:permissions, permissions)
      |> assign(:ash_actor, ash_actor)
      |> assign(:can_view?, can_view?(permissions))
      |> assign(:kinds, SecurityEvent.kinds())
      |> assign(:severities, SecurityEvent.severities())
      |> assign(:kind_filter, nil)
      |> assign(:severity_filter, nil)
      |> load_events()

    {:ok, socket}
  end

  @impl true
  def handle_event("filter", %{"kind" => kind, "severity" => severity}, socket) do
    {:noreply,
     socket
     |> assign(:kind_filter, blank_to_nil(kind))
     |> assign(:severity_filter, blank_to_nil(severity))
     |> load_events()}
  end

  def handle_event("clear-filters", _params, socket) do
    {:noreply,
     socket
     |> assign(:kind_filter, nil)
     |> assign(:severity_filter, nil)
     |> load_events()}
  end

  @impl true
  def handle_info({:security_event, event}, socket) do
    if event_matches?(event, socket.assigns) do
      events = Enum.take([event | socket.assigns.events], @page_size)
      {:noreply, assign(socket, :events, events)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

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

  defp can_view?(perms) do
    MapSet.member?(perms, "settings.audit.view") or
      MapSet.member?(perms, "settings.audit.manage")
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(value), do: value

  defp event_matches?(event, %{kind_filter: kind_filter, severity_filter: severity_filter}) do
    (is_nil(kind_filter) or to_string(event.kind) == kind_filter) and
      (is_nil(severity_filter) or to_string(event.severity) == severity_filter)
  end

  defp load_events(socket) do
    if socket.assigns.can_view? do
      filters =
        []
        |> maybe_filter(:kind, socket.assigns.kind_filter)
        |> maybe_filter(:severity, socket.assigns.severity_filter)

      query =
        SecurityEvent
        |> Ash.Query.for_read(:read, %{}, actor: socket.assigns.ash_actor)
        |> Ash.Query.sort(occurred_at: :desc)
        |> Ash.Query.limit(@page_size)

      query =
        Enum.reduce(filters, query, fn
          {:kind, value}, q -> Ash.Query.filter(q, expr(kind == ^value))
          {:severity, value}, q -> Ash.Query.filter(q, expr(severity == ^value))
          _, q -> q
        end)

      case Ash.read(query, actor: socket.assigns.ash_actor) do
        {:ok, events} -> assign(socket, :events, events)
        _ -> assign(socket, :events, [])
      end
    else
      assign(socket, :events, [])
    end
  rescue
    # DB unavailable in dev — render an empty list rather than crash.
    _ -> assign(socket, :events, [])
  end

  defp maybe_filter(acc, _key, nil), do: acc

  defp maybe_filter(acc, key, value) when is_binary(value) do
    case key do
      :kind ->
        if value in Enum.map(SecurityEvent.kinds(), &to_string/1),
          do: [{key, String.to_existing_atom(value)} | acc],
          else: acc

      :severity ->
        if value in Enum.map(SecurityEvent.severities(), &to_string/1),
          do: [{key, String.to_existing_atom(value)} | acc],
          else: acc

      _ ->
        acc
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={@current_path}>
      <Shell.settings_chrome
        settings_ui={@settings_ui}
        current_path={@current_path}
        current_scope={@current_scope}
        active_view={@settings_active_view}
        active_category={@settings_active_category}
        breadcrumbs={@settings_breadcrumbs}
        nav_tree={@settings_nav_tree}
        palette={@settings_palette}
        stats={@settings_stats}
        legacy_subnav={:none}
      >
        <header class="space-y-1">
          <h1 class="text-2xl font-semibold">Audit · Events</h1>
          <p class="text-sm text-base-content/60">
            Stateless security events: rate-limit denials, signature failures, policy denials,
            CSP violations, lockout triggers and clears. Live-tailed via Phoenix.PubSub.
          </p>
        </header>

        <%= if @can_view? do %>
          <form phx-change="filter" class="flex flex-wrap items-end gap-3">
            <label class="text-sm">
              <span class="mb-1 block text-base-content/70">Kind</span>
              <select name="kind" class="ui-select">
                <option value="">All</option>
                <%= for kind <- @kinds do %>
                  <option value={to_string(kind)} selected={to_string(kind) == @kind_filter}>
                    {kind}
                  </option>
                <% end %>
              </select>
            </label>

            <label class="text-sm">
              <span class="mb-1 block text-base-content/70">Severity</span>
              <select name="severity" class="ui-select">
                <option value="">All</option>
                <%= for severity <- @severities do %>
                  <option
                    value={to_string(severity)}
                    selected={to_string(severity) == @severity_filter}
                  >
                    {severity}
                  </option>
                <% end %>
              </select>
            </label>

            <button
              type="button"
              class="ui-button"
              phx-click="clear-filters"
            >
              Clear
            </button>
          </form>

          <div class="overflow-x-auto rounded-lg border border-base-200 bg-base-100">
            <table class="min-w-full text-sm text-base-content">
              <thead class="bg-base-200/70 text-base-content/70">
                <tr>
                  <th class="px-4 py-2 text-left">When</th>
                  <th class="px-4 py-2 text-left">Kind</th>
                  <th class="px-4 py-2 text-left">Severity</th>
                  <th class="px-4 py-2 text-left">Actor</th>
                  <th class="px-4 py-2 text-left">IP</th>
                  <th class="px-4 py-2 text-left">Route</th>
                </tr>
              </thead>
              <tbody class="divide-y divide-base-200">
                <%= for e <- @events do %>
                  <tr class="hover:bg-base-200/40">
                    <td class="px-4 py-2 font-mono text-xs whitespace-nowrap">
                      <.link navigate={~p"/settings/audit/events/#{e.id}"} class="link link-hover">
                        {format_dt(e.occurred_at)}
                      </.link>
                    </td>
                    <td class="px-4 py-2">{e.kind}</td>
                    <td class="px-4 py-2">{e.severity}</td>
                    <td class="px-4 py-2 font-mono text-xs">{e.actor_id || "—"}</td>
                    <td class="px-4 py-2 font-mono text-xs">{e.ip || "—"}</td>
                    <td class="px-4 py-2 font-mono text-xs">{e.route || "—"}</td>
                  </tr>
                <% end %>
                <%= if Enum.empty?(@events) do %>
                  <tr>
                    <td colspan="6" class="px-4 py-8 text-center text-base-content/60">
                      No security events yet.
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        <% else %>
          <p class="text-sm text-error">
            You need <code>settings.audit.view</code> to see security events.
          </p>
        <% end %>
      </Shell.settings_chrome>
    </Layouts.app>
    """
  end

  defp format_dt(nil), do: "—"

  defp format_dt(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
  end
end
