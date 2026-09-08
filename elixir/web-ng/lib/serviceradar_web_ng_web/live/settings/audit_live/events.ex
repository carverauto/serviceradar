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
      |> assign(:selected_event, nil)
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

  def handle_event("show-event", %{"id" => id}, socket) do
    event = Enum.find(socket.assigns.events, &(to_string(&1.id) == id))
    {:noreply, assign(socket, :selected_event, event)}
  end

  def handle_event("close-event", _params, socket) do
    {:noreply, assign(socket, :selected_event, nil)}
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
          <h1 class="text-2xl font-semibold">Audit · Events</h1>
          <p class="text-sm text-sr-muted">
            Stateless security events: rate-limit denials, signature failures, policy denials,
            CSP violations, lockout triggers and clears. Live-tailed via Phoenix.PubSub.
          </p>
        </header>

        <%= if @can_view? do %>
          <form phx-change="filter" class="flex flex-wrap items-end gap-3">
            <label class="text-sm">
              <span class="mb-1 block text-sr-muted">Kind</span>
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
              <span class="mb-1 block text-sr-muted">Severity</span>
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

          <%!-- table-fixed + per-cell truncation keeps the whole table inside the
                container with NO horizontal scroll even for long IPv6 addresses;
                the full value is available on hover (title) and in the row modal. --%>
          <div class="rounded-lg border border-sr-line bg-sr-surface">
            <table class="w-full table-fixed text-sm text-sr-ink">
              <colgroup>
                <col class="w-[11rem]" />
                <col class="w-[9rem]" />
                <col class="w-[6rem]" />
                <col />
                <col />
                <col />
              </colgroup>
              <thead class="bg-sr-subtle/70 text-sr-muted">
                <tr>
                  <th class="px-4 py-2 text-left">When</th>
                  <th class="px-4 py-2 text-left">Kind</th>
                  <th class="px-4 py-2 text-left">Severity</th>
                  <th class="px-4 py-2 text-left">Actor</th>
                  <th class="px-4 py-2 text-left">IP</th>
                  <th class="px-4 py-2 text-left">Route</th>
                </tr>
              </thead>
              <tbody class="divide-y divide-sr-line">
                <%= for e <- @events do %>
                  <tr
                    class="cursor-pointer hover:bg-sr-subtle/50 focus:bg-sr-subtle/60 focus:outline-none"
                    tabindex="0"
                    role="button"
                    aria-label={"View audit event #{e.kind}"}
                    phx-click="show-event"
                    phx-keydown="show-event"
                    phx-key="Enter"
                    phx-value-id={e.id}
                  >
                    <td class="px-4 py-2 font-mono text-xs whitespace-nowrap">
                      <.user_time
                        id={"settings-audit-event-#{e.id}-occurred-at"}
                        value={e.occurred_at}
                        timezone={@current_scope.user.timezone || "Etc/UTC"}
                        style={:compact}
                        fallback="—"
                      />
                    </td>
                    <td class="px-4 py-2 truncate" title={to_string(e.kind)}>{e.kind}</td>
                    <td class="px-4 py-2">{e.severity}</td>
                    <td class="px-4 py-2 font-mono text-xs truncate" title={e.actor_id || ""}>
                      {e.actor_id || "—"}
                    </td>
                    <td class="px-4 py-2 font-mono text-xs truncate" title={e.ip || ""}>
                      {e.ip || "—"}
                    </td>
                    <td class="px-4 py-2 font-mono text-xs truncate" title={e.route || ""}>
                      {e.route || "—"}
                    </td>
                  </tr>
                <% end %>
                <%= if Enum.empty?(@events) do %>
                  <tr>
                    <td colspan="6" class="px-4 py-8 text-center text-sr-muted">
                      No security events yet.
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>

          <.event_modal
            :if={@selected_event}
            event={@selected_event}
            timezone={@current_scope.user.timezone || "Etc/UTC"}
          />
        <% else %>
          <p class="text-sm text-error">
            You need <code>settings.audit.view</code> to see security events.
          </p>
        <% end %>
      </Shell.settings_chrome>
    </Layouts.app>
    """
  end

  # --- Row detail modal ------------------------------------------------------
  # A keyboard-accessible detail modal for a single security event. Opened by a
  # row click or Enter; closed by the X button, the Close action, a backdrop
  # click, or the Escape key (phx-window-keydown). Shows every event field,
  # including the full (untruncated) IP and route plus any details payload.
  attr(:event, :map, required: true)
  attr(:timezone, :string, required: true)

  defp event_modal(assigns) do
    ~H"""
    <div
      class="sr-ui-modal sr-ui-modal-open"
      role="dialog"
      aria-modal="true"
      aria-label="Audit event details"
      phx-window-keydown="close-event"
      phx-key="Escape"
    >
      <div class="sr-ui-modal-box sr-ui-modal-box-md">
        <div class="flex items-start justify-between gap-4">
          <h2 class="text-lg font-semibold">Audit Event</h2>
          <.ui_icon_button
            type="button"
            phx-click="close-event"
            aria-label="Close"
            size="sm"
            variant="ghost"
          >
            <.icon name="hero-x-mark" class="size-5" />
          </.ui_icon_button>
        </div>

        <dl class="mt-4 grid grid-cols-1 gap-3 text-sm sm:grid-cols-2">
          <div class="sm:col-span-2">
            <dt class="text-xs uppercase text-sr-muted">When</dt>
            <dd class="font-mono text-xs">
              <.user_time
                id={"settings-audit-event-modal-#{@event.id}-occurred-at"}
                value={@event.occurred_at}
                timezone={@timezone}
                style={:compact}
                fallback="—"
              />
            </dd>
          </div>
          <div>
            <dt class="text-xs uppercase text-sr-muted">Kind</dt>
            <dd>{@event.kind}</dd>
          </div>
          <div>
            <dt class="text-xs uppercase text-sr-muted">Severity</dt>
            <dd>{@event.severity}</dd>
          </div>
          <div>
            <dt class="text-xs uppercase text-sr-muted">Actor</dt>
            <dd class="font-mono text-xs break-all">{@event.actor_id || "—"}</dd>
          </div>
          <div>
            <dt class="text-xs uppercase text-sr-muted">IP</dt>
            <dd class="font-mono text-xs break-all">{@event.ip || "—"}</dd>
          </div>
          <div class="sm:col-span-2">
            <dt class="text-xs uppercase text-sr-muted">Route</dt>
            <dd class="font-mono text-xs break-all">{@event.route || "—"}</dd>
          </div>
          <div :if={@event.correlation_id} class="sm:col-span-2">
            <dt class="text-xs uppercase text-sr-muted">Correlation ID</dt>
            <dd class="font-mono text-xs break-all">{@event.correlation_id}</dd>
          </div>
        </dl>

        <div :if={has_details?(@event)} class="mt-4">
          <h3 class="text-xs uppercase text-sr-muted">Details</h3>
          <pre class="mt-1 max-h-64 overflow-auto rounded bg-sr-subtle/60 p-3 text-xs leading-relaxed"><%= pretty_details(@event.details) %></pre>
        </div>

        <div class="sr-ui-modal-action">
          <.ui_button navigate={~p"/settings/audit/events/#{@event.id}"} size="sm" variant="ghost">
            Open full page
          </.ui_button>
          <.ui_button type="button" phx-click="close-event" size="sm" variant="neutral">
            Close
          </.ui_button>
        </div>
      </div>
      <button
        type="button"
        class="sr-ui-modal-backdrop"
        phx-click="close-event"
        aria-label="Close audit event details"
      >
        close
      </button>
    </div>
    """
  end

  defp has_details?(%{details: details}) when is_map(details) and map_size(details) > 0, do: true
  defp has_details?(_), do: false

  defp pretty_details(details) when is_map(details) do
    Jason.encode!(details, pretty: true)
  rescue
    _ -> inspect(details, pretty: true)
  end

  defp pretty_details(details), do: inspect(details, pretty: true)
end
