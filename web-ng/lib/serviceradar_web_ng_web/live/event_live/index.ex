defmodule ServiceRadarWebNGWeb.EventLive.Index do
  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.UIComponents

  alias ServiceRadarWebNGWeb.SRQL.Page, as: SRQLPage

  @default_limit 20
  @max_limit 100

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Events")
     |> assign(:events, [])
     |> assign(:limit, @default_limit)
     |> SRQLPage.init("events", default_limit: @default_limit)}
  end

  @impl true
  def handle_params(params, uri, socket) do
    {:noreply,
     socket
     |> SRQLPage.load_list(params, uri, :events,
       default_limit: @default_limit,
       max_limit: @max_limit
     )}
  end

  @impl true
  def handle_event("srql_change", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_change", params)}
  end

  def handle_event("srql_submit", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_submit", params, fallback_path: "/events")}
  end

  def handle_event("srql_builder_toggle", _params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_toggle", %{}, entity: "events")}
  end

  def handle_event("srql_builder_change", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_change", params)}
  end

  def handle_event("srql_builder_apply", _params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_apply", %{})}
  end

  def handle_event("srql_builder_add_filter", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_add_filter", params, entity: "events")}
  end

  def handle_event("srql_builder_remove_filter", params, socket) do
    {:noreply,
     SRQLPage.handle_event(socket, "srql_builder_remove_filter", params, entity: "events")}
  end

  @impl true
  def render(assigns) do
    pagination = get_in(assigns, [:srql, :pagination]) || %{}
    assigns = assign(assigns, :pagination, pagination)

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} srql={@srql}>
      <div class="mx-auto max-w-7xl p-6">
        <.header>
          Events
          <:subtitle>Event stream with severity-based filtering.</:subtitle>
          <:actions>
            <.ui_button variant="ghost" size="sm" patch={~p"/events"}>
              Reset
            </.ui_button>
            <.ui_button
              variant="ghost"
              size="sm"
              patch={
                ~p"/events?#{%{q: "in:events time:last_24h sort:event_timestamp:desc"}}"
              }
            >
              Last 24h
            </.ui_button>
            <.ui_button
              variant="ghost"
              size="sm"
              patch={
                ~p"/events?#{%{q: "in:events severity:(Critical,High) time:last_24h sort:event_timestamp:desc"}}"
              }
            >
              Critical
            </.ui_button>
          </:actions>
        </.header>

        <.ui_panel>
          <:header>
            <div class="min-w-0">
              <div class="text-sm font-semibold">Event Stream</div>
              <div class="text-xs text-base-content/70">
                Click any event to view full details.
              </div>
            </div>
          </:header>

          <.events_table id="events" events={@events} />

          <div class="mt-4 pt-4 border-t border-base-200">
            <.ui_pagination
              prev_cursor={Map.get(@pagination, "prev_cursor")}
              next_cursor={Map.get(@pagination, "next_cursor")}
              base_path="/events"
              query={Map.get(@srql, :query, "")}
              limit={@limit}
              result_count={length(@events)}
            />
          </div>
        </.ui_panel>
      </div>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :events, :list, default: []

  defp events_table(assigns) do
    ~H"""
    <div class="overflow-x-auto">
      <table id={@id} class="table table-sm table-zebra w-full">
        <thead>
          <tr>
            <th class="whitespace-nowrap text-xs font-semibold text-base-content/70 bg-base-200/60 w-40">
              Time
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-base-content/70 bg-base-200/60 w-24">
              Severity
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-base-content/70 bg-base-200/60 w-40">
              Source
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-base-content/70 bg-base-200/60">
              Message
            </th>
          </tr>
        </thead>
        <tbody>
          <tr :if={@events == []}>
            <td colspan="4" class="text-sm text-base-content/60 py-8 text-center">
              No events found.
            </td>
          </tr>

          <%= for {event, idx} <- Enum.with_index(@events) do %>
            <.link
              navigate={~p"/events/#{event_id(event)}"}
              class="contents"
            >
              <tr
                id={"#{@id}-row-#{idx}"}
                class="hover:bg-base-200/40 cursor-pointer transition-colors"
              >
                <td class="whitespace-nowrap text-xs font-mono">
                  {format_timestamp(event)}
                </td>
                <td class="whitespace-nowrap text-xs">
                  <.severity_badge value={Map.get(event, "severity")} />
                </td>
                <td class="whitespace-nowrap text-xs truncate max-w-[12rem]" title={event_source(event)}>
                  {event_source(event)}
                </td>
                <td class="text-xs truncate max-w-[32rem]" title={event_message(event)}>
                  {event_message(event)}
                </td>
              </tr>
            </.link>
          <% end %>
        </tbody>
      </table>
    </div>
    """
  end

  attr :value, :any, default: nil

  defp severity_badge(assigns) do
    variant =
      case normalize_severity(assigns.value) do
        s when s in ["critical", "fatal", "error"] -> "error"
        s when s in ["high", "warn", "warning"] -> "warning"
        s when s in ["medium", "info"] -> "info"
        s when s in ["low", "debug", "ok"] -> "success"
        _ -> "ghost"
      end

    label =
      case assigns.value do
        nil -> "—"
        "" -> "—"
        v when is_binary(v) -> v
        v -> to_string(v)
      end

    assigns = assign(assigns, :variant, variant) |> assign(:label, label)

    ~H"""
    <.ui_badge variant={@variant} size="xs">{@label}</.ui_badge>
    """
  end

  defp normalize_severity(nil), do: ""
  defp normalize_severity(v) when is_binary(v), do: v |> String.trim() |> String.downcase()
  defp normalize_severity(v), do: v |> to_string() |> normalize_severity()

  defp event_id(event) do
    Map.get(event, "id") || Map.get(event, "event_id") || "unknown"
  end

  defp format_timestamp(event) do
    ts = Map.get(event, "event_timestamp") || Map.get(event, "timestamp")

    case parse_timestamp(ts) do
      {:ok, dt} -> Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
      _ -> ts || "—"
    end
  end

  defp parse_timestamp(nil), do: :error
  defp parse_timestamp(""), do: :error

  defp parse_timestamp(value) when is_binary(value) do
    value = String.trim(value)

    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> {:ok, dt}
      {:error, _} ->
        case NaiveDateTime.from_iso8601(value) do
          {:ok, ndt} -> {:ok, DateTime.from_naive!(ndt, "Etc/UTC")}
          {:error, _} -> :error
        end
    end
  end

  defp parse_timestamp(_), do: :error

  defp event_source(event) do
    # Try various source fields in order of preference
    source =
      Map.get(event, "host") ||
      Map.get(event, "source") ||
      Map.get(event, "device_id") ||
      Map.get(event, "subject")

    case source do
      nil -> "—"
      "" -> "—"
      v when is_binary(v) -> v
      v -> to_string(v)
    end
  end

  defp event_message(event) do
    # Try various message fields in order of preference
    message =
      Map.get(event, "short_message") ||
      Map.get(event, "message") ||
      Map.get(event, "subject") ||
      Map.get(event, "description")

    case message do
      nil -> "—"
      "" -> "—"
      v when is_binary(v) -> String.slice(v, 0, 200)
      v -> v |> to_string() |> String.slice(0, 200)
    end
  end
end
