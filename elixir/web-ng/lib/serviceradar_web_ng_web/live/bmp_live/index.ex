defmodule ServiceRadarWebNGWeb.BmpLive.Index do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.UIComponents

  alias ServiceRadarWebNGWeb.SRQL.Page, as: SRQLPage

  @default_limit 50
  @max_limit 200

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "BMP Events")
     |> assign(:bmp_events, [])
     |> assign(:limit, @default_limit)
     |> assign(:summary, empty_summary())
     |> stream(:bmp_events, [], dom_id: &bmp_event_dom_id/1)
     |> SRQLPage.init("bmp_events", default_limit: @default_limit)}
  end

  @impl true
  def handle_params(params, uri, socket) do
    socket = SRQLPage.load_list(socket, params, uri, :bmp_events, default_limit: @default_limit, max_limit: @max_limit)

    summary = compute_summary(socket.assigns.bmp_events)

    {:noreply,
     socket
     |> stream(:bmp_events, socket.assigns.bmp_events, reset: true, dom_id: &bmp_event_dom_id/1)
     |> assign(:summary, summary)}
  end

  @impl true
  def handle_event("srql_change", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_change", params)}
  end

  def handle_event("srql_submit", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_submit", params, fallback_path: "/observability/bmp")}
  end

  def handle_event("srql_builder_toggle", _params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_toggle", %{}, entity: "bmp_events")}
  end

  def handle_event("srql_builder_change", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_change", params)}
  end

  def handle_event("srql_builder_apply", _params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_apply", %{})}
  end

  def handle_event("srql_builder_run", _params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_run", %{}, fallback_path: "/observability/bmp")}
  end

  def handle_event("srql_builder_add_filter", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_add_filter", params, entity: "bmp_events")}
  end

  def handle_event("srql_builder_remove_filter", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_remove_filter", params, entity: "bmp_events")}
  end

  @impl true
  def render(assigns) do
    pagination = get_in(assigns, [:srql, :pagination]) || %{}
    assigns = assign(assigns, :pagination, pagination)

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} srql={@srql}>
      <div class="mx-auto max-w-7xl p-6 space-y-4">
        <div class="flex items-center justify-between">
          <div>
            <h1 class="text-xl font-semibold">BMP Routing Events</h1>
            <p class="text-sm text-base-content/70">
              Raw routing telemetry from <code>platform.bmp_routing_events</code>.
            </p>
          </div>
          <.ui_button href={~p"/events"} variant="ghost" size="sm">Curated Events</.ui_button>
        </div>

        <.summary_cards summary={@summary} />

        <.ui_panel>
          <:header>
            <div class="text-sm font-semibold">BMP Stream</div>
          </:header>

          <div class="overflow-x-auto">
            <table class="table table-zebra table-sm">
              <thead>
                <tr>
                  <th>Time</th>
                  <th>Type</th>
                  <th>Severity</th>
                  <th>Router</th>
                  <th>Peer</th>
                  <th>Prefix</th>
                  <th>Message</th>
                </tr>
              </thead>
              <tbody id="bmp-events" phx-update="stream">
                <tr :if={length(@bmp_events) == 0}>
                  <td colspan="7" class="text-center text-base-content/60 py-8">
                    No BMP events found.
                  </td>
                </tr>
                <%= for {dom_id, event} <- @streams.bmp_events do %>
                  <tr id={dom_id}>
                    <td class="whitespace-nowrap text-xs">
                      {event["time"] || event[:time] || "—"}
                    </td>
                    <td>
                      <span class="badge badge-ghost badge-sm">
                        {event["event_type"] || event[:event_type] || "unknown"}
                      </span>
                    </td>
                    <td>{event["severity_id"] || event[:severity_id] || "—"}</td>
                    <td>{event["router_ip"] || event[:router_ip] || "—"}</td>
                    <td>{event["peer_ip"] || event[:peer_ip] || "—"}</td>
                    <td>{event["prefix"] || event[:prefix] || "—"}</td>
                    <td class="max-w-xl truncate">{event["message"] || event[:message] || "—"}</td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>

          <div class="mt-4 pt-4 border-t border-base-200">
            <.ui_pagination
              prev_cursor={Map.get(@pagination, "prev_cursor")}
              next_cursor={Map.get(@pagination, "next_cursor")}
              base_path="/observability/bmp"
              query={Map.get(@srql, :query, "")}
              limit={@limit}
              result_count={length(@bmp_events)}
            />
          </div>
        </.ui_panel>
      </div>
    </Layouts.app>
    """
  end

  attr :summary, :map, required: true

  defp summary_cards(assigns) do
    ~H"""
    <div class="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-6 gap-3">
      <.summary_card title="Total" value={@summary.total} tone="neutral" query="in:bmp_events" />
      <.summary_card
        title="Updates"
        value={@summary.route_update}
        tone="info"
        query="in:bmp_events event_type:route_update"
      />
      <.summary_card
        title="Withdraws"
        value={@summary.route_withdraw}
        tone="warning"
        query="in:bmp_events event_type:route_withdraw"
      />
      <.summary_card
        title="Peer Up"
        value={@summary.peer_up}
        tone="success"
        query="in:bmp_events event_type:peer_up"
      />
      <.summary_card
        title="Peer Down"
        value={@summary.peer_down}
        tone="error"
        query="in:bmp_events event_type:peer_down"
      />
      <.summary_card
        title="High+"
        value={@summary.high_or_higher}
        tone="error"
        query="in:bmp_events severity_id:>=4"
      />
    </div>
    """
  end

  attr :title, :string, required: true
  attr :value, :integer, required: true
  attr :tone, :string, required: true
  attr :query, :string, required: true

  defp summary_card(assigns) do
    ~H"""
    <.link
      patch={~p"/observability/bmp?#{%{q: @query}}"}
      class={[
        "rounded-lg p-3 border transition-colors hover:bg-base-200/70",
        summary_tone_class(@tone)
      ]}
    >
      <div class="text-xs uppercase tracking-wider text-base-content/60">{@title}</div>
      <div class="text-2xl font-semibold mt-1">{@value}</div>
    </.link>
    """
  end

  defp summary_tone_class("neutral"), do: "border-base-200 bg-base-100"
  defp summary_tone_class("info"), do: "border-info/30 bg-info/5"
  defp summary_tone_class("warning"), do: "border-warning/30 bg-warning/5"
  defp summary_tone_class("success"), do: "border-success/30 bg-success/5"
  defp summary_tone_class("error"), do: "border-error/30 bg-error/5"
  defp summary_tone_class(_), do: "border-base-200 bg-base-100"

  defp compute_summary(events) when is_list(events) do
    Enum.reduce(events, empty_summary(), fn event, acc ->
      event_type = to_string(event["event_type"] || event[:event_type] || "")
      severity = parse_int(event["severity_id"] || event[:severity_id])

      acc
      |> Map.update!(:total, &(&1 + 1))
      |> bump_type(event_type)
      |> bump_high_severity(severity)
    end)
  end

  defp compute_summary(_), do: empty_summary()

  defp bump_type(acc, "route_update"), do: Map.update!(acc, :route_update, &(&1 + 1))
  defp bump_type(acc, "route_withdraw"), do: Map.update!(acc, :route_withdraw, &(&1 + 1))
  defp bump_type(acc, "peer_up"), do: Map.update!(acc, :peer_up, &(&1 + 1))
  defp bump_type(acc, "peer_down"), do: Map.update!(acc, :peer_down, &(&1 + 1))
  defp bump_type(acc, _), do: acc

  defp bump_high_severity(acc, severity) when is_integer(severity) and severity >= 4,
    do: Map.update!(acc, :high_or_higher, &(&1 + 1))

  defp bump_high_severity(acc, _), do: acc

  defp parse_int(value) when is_integer(value), do: value

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp parse_int(_), do: nil

  defp empty_summary do
    %{
      total: 0,
      route_update: 0,
      route_withdraw: 0,
      peer_up: 0,
      peer_down: 0,
      high_or_higher: 0
    }
  end

  defp bmp_event_dom_id(event) do
    id = event["id"] || event[:id] || System.unique_integer([:positive])
    "bmp-event-#{id}"
  end
end
