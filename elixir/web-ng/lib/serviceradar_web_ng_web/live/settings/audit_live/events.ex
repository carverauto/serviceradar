defmodule ServiceRadarWebNGWeb.Settings.AuditLive.Events do
  @moduledoc """
  Settings → Audit → Events.

  Lists bounded keyset pages of `ServiceRadar.Security.SecurityEvent` rows.
  Only the first page live-tails matching events via the
  `"security_events"` Phoenix.PubSub topic (a PG2-backed broadcast
  driven by `ServiceRadar.Security.Events`).
  """

  use ServiceRadarWebNGWeb, :live_view

  import Ash.Expr

  alias ServiceRadar.Identity.RBAC
  alias ServiceRadar.Security.SecurityEvent
  alias ServiceRadarWebNGWeb.Settings.Shell

  require Ash.Query

  on_mount({ServiceRadarWebNGWeb.UserAuth, :require_authenticated})

  @page_size 25
  @filter_defaults %{
    "kind" => "",
    "severity" => "",
    "actor_id" => "",
    "ip" => "",
    "route" => "",
    "correlation_id" => "",
    "search" => "",
    "time" => "last_24h",
    "from" => "",
    "to" => ""
  }

  @impl true
  def mount(_params, _session, socket) do
    {permissions, ash_actor} = permissions_and_actor(socket)

    if connected?(socket) and can_view?(permissions) do
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
      |> assign(:filters, @filter_defaults)
      |> assign(:form, to_form(@filter_defaults, as: :filters))
      |> assign(:cursors, [])
      |> assign(:events, [])
      |> assign(:has_next?, false)
      |> assign(:query_error, nil)
      |> assign(:selected_event, nil)
      |> assign(:refresh_pending?, false)
      |> load_events()

    {:ok, socket}
  end

  @impl true
  def handle_event(_event, _params, %{assigns: %{can_view?: false}} = socket) do
    {:noreply, socket}
  end

  def handle_event("filter", %{"filters" => filters}, socket) do
    filters = Map.merge(@filter_defaults, Map.take(filters, Map.keys(@filter_defaults)))

    {:noreply,
     socket
     |> assign(:filters, filters)
     |> assign(:form, to_form(filters, as: :filters))
     |> reset_page()
     |> load_events()}
  end

  def handle_event("clear-filters", _params, socket) do
    {:noreply,
     socket
     |> assign(:filters, @filter_defaults)
     |> assign(:form, to_form(@filter_defaults, as: :filters))
     |> reset_page()
     |> load_events()}
  end

  def handle_event("next-page", _params, socket) do
    if socket.assigns.has_next? and socket.assigns.events != [] do
      last = List.last(socket.assigns.events)
      cursor = {last.occurred_at, last.id}

      {:noreply,
       socket
       |> assign(:cursors, [cursor | socket.assigns.cursors])
       |> assign(:selected_event, nil)
       |> load_events()}
    else
      {:noreply, socket}
    end
  end

  def handle_event("previous-page", _params, socket) do
    {:noreply,
     socket
     |> assign(:cursors, Enum.drop(socket.assigns.cursors, 1))
     |> assign(:selected_event, nil)
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
    with true <- socket.assigns.can_view? and socket.assigns.cursors == [],
         false <- socket.assigns.refresh_pending?,
         {:ok, start_at, end_at} <- time_range(socket.assigns.filters),
         at when not is_nil(at) <- Map.get(event, :occurred_at),
         true <- DateTime.compare(at, start_at) != :lt,
         true <- is_nil(end_at) or DateTime.compare(at, end_at) != :gt do
      Process.send_after(self(), :refresh_events, 250)
      {:noreply, assign(socket, :refresh_pending?, true)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_info(:refresh_events, socket) do
    socket = assign(socket, :refresh_pending?, false)

    if socket.assigns.can_view? and socket.assigns.cursors == [],
      do: {:noreply, load_events(socket)},
      else: {:noreply, socket}
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

  defp reset_page(socket), do: assign(socket, cursors: [], selected_event: nil)

  defp load_events(socket) do
    if connected?(socket) and socket.assigns.can_view? do
      with {:ok, start_at, end_at} <- time_range(socket.assigns.filters),
           {:ok, events} <-
             Ash.read(event_query(socket, start_at, end_at), actor: socket.assigns.ash_actor) do
        assign(socket,
          events: Enum.take(events, @page_size),
          has_next?: length(events) > @page_size,
          query_error: nil
        )
      else
        {:error, :invalid_time} ->
          assign(socket,
            events: [],
            has_next?: false,
            query_error: "Choose a valid UTC time range with From before To."
          )

        {:error, _} ->
          assign(socket,
            events: [],
            has_next?: false,
            query_error: "Could not load audit events."
          )
      end
    else
      assign(socket, events: [], has_next?: false)
    end
  end

  defp event_query(socket, start_at, end_at) do
    query =
      SecurityEvent
      |> Ash.Query.for_read(:read, %{}, actor: socket.assigns.ash_actor)
      |> Ash.Query.sort(occurred_at: :desc, id: :desc)
      |> Ash.Query.limit(@page_size + 1)
      |> Ash.Query.filter(occurred_at >= ^start_at)

    query = if end_at, do: Ash.Query.filter(query, occurred_at <= ^end_at), else: query

    query =
      Enum.reduce([:kind, :severity, :actor_id, :ip, :route, :correlation_id], query, fn field, query ->
        case String.trim(socket.assigns.filters[to_string(field)]) do
          "" -> query
          value -> Ash.Query.filter_input(query, %{field => %{eq: value}})
        end
      end)

    search = socket.assigns.filters["search"] |> String.trim() |> String.downcase()

    query =
      if search == "" do
        query
      else
        Ash.Query.filter(
          query,
          expr(
            contains(
              string_downcase(if is_nil(actor_id), do: "", else: actor_id),
              ^search
            ) or
              contains(
                string_downcase(if is_nil(ip), do: "", else: ip),
                ^search
              ) or
              contains(
                string_downcase(if is_nil(route), do: "", else: route),
                ^search
              ) or
              contains(
                string_downcase(if is_nil(correlation_id), do: "", else: correlation_id),
                ^search
              )
          )
        )
      end

    case socket.assigns.cursors do
      [{at, id} | _] ->
        Ash.Query.filter(query, occurred_at < ^at or (occurred_at == ^at and id < ^id))

      [] ->
        query
    end
  end

  defp time_range(%{"time" => "custom", "from" => from, "to" => to}) do
    with {:ok, start_at, _} <- DateTime.from_iso8601(from <> ":00Z"),
         {:ok, end_at, _} <- DateTime.from_iso8601(to <> ":00Z"),
         :lt <- DateTime.compare(start_at, end_at) do
      {:ok, start_at, end_at}
    else
      _ -> {:error, :invalid_time}
    end
  end

  defp time_range(%{"time" => time}) do
    seconds = %{"last_1h" => 3600, "last_24h" => 86_400, "last_7d" => 604_800}[time]

    if seconds,
      do: {:ok, DateTime.add(DateTime.utc_now(), -seconds, :second), nil},
      else: {:error, :invalid_time}
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
            CSP violations, lockout triggers and clears. Live updates apply to page 1 only;
            older pages stay steady until you navigate or change filters.
          </p>
        </header>

        <%= if @can_view? do %>
          <.form
            for={@form}
            id="audit-event-filters"
            phx-change="filter"
            class="grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-4"
          >
            <.input
              field={@form[:time]}
              type="select"
              label="Time range"
              options={[
                {"Last hour", "last_1h"},
                {"Last 24 hours", "last_24h"},
                {"Last 7 days", "last_7d"},
                {"Custom (UTC)", "custom"}
              ]}
            />
            <.input
              field={@form[:kind]}
              type="select"
              label="Kind"
              prompt="All"
              options={Enum.map(@kinds, &{to_string(&1), to_string(&1)})}
            />
            <.input
              field={@form[:severity]}
              type="select"
              label="Severity"
              prompt="All"
              options={Enum.map(@severities, &{to_string(&1), to_string(&1)})}
            />
            <.input
              field={@form[:search]}
              type="text"
              label="Search actor, IP, route or correlation"
              phx-debounce="300"
            />
            <.input
              field={@form[:actor_id]}
              type="text"
              label="Actor ID (exact)"
              phx-debounce="300"
            />
            <.input
              field={@form[:ip]}
              type="text"
              label="IP (exact)"
              phx-debounce="300"
            />
            <.input
              field={@form[:route]}
              type="text"
              label="Route (exact)"
              phx-debounce="300"
            />
            <.input
              field={@form[:correlation_id]}
              type="text"
              label="Correlation ID (exact)"
              phx-debounce="300"
            />
            <.input
              :if={@filters["time"] == "custom"}
              field={@form[:from]}
              type="datetime-local"
              label="From (UTC)"
            />
            <.input
              :if={@filters["time"] == "custom"}
              field={@form[:to]}
              type="datetime-local"
              label="To (UTC)"
            />
            <.ui_button
              id="audit-events-clear"
              type="button"
              phx-click="clear-filters"
              size="sm"
              variant="neutral"
            >Clear all</.ui_button>
          </.form>
          <p :if={@query_error} id="audit-events-error" role="alert" class="text-sm text-error">
            {@query_error}
          </p>
          <div id="audit-events-pagination" class="flex flex-wrap items-center justify-between gap-3">
            <p id="audit-events-page" class="text-sm text-base-content/70">
              Page {length(@cursors) + 1} · {length(@events)} events · {if @cursors == [],
                do: "Live updates on",
                else: "Live updates paused"}
            </p>
            <div class="join">
              <.ui_button
                id="audit-events-previous"
                class="join-item"
                type="button"
                phx-click="previous-page"
                disabled={@cursors == []}
                size="sm"
                variant="neutral"
              >Previous</.ui_button>
              <.ui_button
                id="audit-events-next"
                class="join-item"
                type="button"
                phx-click="next-page"
                disabled={!@has_next?}
                size="sm"
                variant="neutral"
              >Next</.ui_button>
            </div>
          </div>

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
              <tbody id="audit-events-rows" class="divide-y divide-sr-line">
                <%= for e <- @events do %>
                  <tr
                    id={"audit-event-#{e.id}"}
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
