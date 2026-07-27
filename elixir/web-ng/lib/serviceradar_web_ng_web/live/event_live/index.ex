defmodule ServiceRadarWebNGWeb.EventLive.Index do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.UIComponents

  alias Phoenix.LiveView.JS
  alias ServiceRadar.Events.PubSub, as: EventsPubSub
  alias ServiceRadar.Infrastructure.HealthPubSub
  alias ServiceRadarWebNGWeb.Observability.EventDeviceReference
  alias ServiceRadarWebNGWeb.SRQL.Page, as: SRQLPage
  alias ServiceRadarWebNGWeb.Stats
  alias ServiceRadarWebNGWeb.Stats.Query, as: StatsQuery

  @default_limit 20
  @max_limit 100
  @events_refresh_debounce_ms 250

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      # Instance scope - subscribe to instance-wide topics
      Phoenix.PubSub.subscribe(ServiceRadar.PubSub, HealthPubSub.topic())
      Phoenix.PubSub.subscribe(ServiceRadar.PubSub, EventsPubSub.topic())
    end

    {:ok,
     socket
     |> assign(:page_title, "Events")
     |> assign(:events, [])
     |> assign(:summary, %{
       total: 0,
       fatal: 0,
       critical: 0,
       high: 0,
       medium: 0,
       low: 0,
       informational: 0
     })
     |> assign(:finding_summary, Stats.empty_anomaly_findings_summary())
     |> assign(:time_window, "last_7d")
     |> assign(:limit, @default_limit)
     |> assign(:events_refresh_scheduled?, false)
     |> stream(:events, [], dom_id: &event_dom_id/1)
     |> SRQLPage.init("events", default_limit: @default_limit)}
  end

  @impl true
  def handle_params(params, uri, socket) do
    socket = SRQLPage.load_list(socket, params, uri, :events, default_limit: @default_limit, max_limit: @max_limit)

    time_window = time_window_from_query(Map.get(socket.assigns, :srql, %{})[:query] || "")
    summary = events_summary(time_window, socket.assigns.events)
    finding_summary = Stats.anomaly_findings_summary(time: time_window, scope: socket.assigns.current_scope)

    {:noreply,
     socket
     |> stream(:events, socket.assigns.events, reset: true, dom_id: &event_dom_id/1)
     |> assign(:summary, summary)
     |> assign(:time_window, time_window)
     |> assign(:finding_summary, finding_summary)}
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

  def handle_event("srql_builder_run", _params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_run", %{}, fallback_path: "/events")}
  end

  def handle_event("srql_builder_add_filter", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_add_filter", params, entity: "events")}
  end

  def handle_event("srql_builder_remove_filter", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_remove_filter", params, entity: "events")}
  end

  @impl true
  def handle_info({:health_event, _event}, socket) do
    {:noreply, schedule_events_refresh(socket)}
  end

  @impl true
  def handle_info({:ocsf_event, _event}, socket) do
    {:noreply, schedule_events_refresh(socket)}
  end

  @impl true
  def handle_info(:debounced_events_refresh, socket) do
    {:noreply,
     socket
     |> assign(:events_refresh_scheduled?, false)
     |> refresh_events()}
  end

  @impl true
  def render(assigns) do
    pagination = get_in(assigns, [:srql, :pagination]) || %{}
    assigns = assign(assigns, :pagination, pagination)

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} srql={@srql}>
      <div class="mx-auto max-w-7xl p-6">
        <div class="space-y-4">
          <.event_summary summary={@summary} time_window={@time_window} />
          <.event_finding_summary summary={@finding_summary} time_window={@time_window} />

          <.ui_panel>
            <:header>
              <div class="min-w-0">
                <div class="text-sm font-semibold">Event Stream</div>
                <div class="text-xs text-base-content/70">
                  Click any event to view full details.
                </div>
              </div>
            </:header>

            <.events_table id="events" events={@streams.events} count={length(@events)} />

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
      </div>
    </Layouts.app>
    """
  end

  attr :summary, :map, required: true
  attr :time_window, :string, required: true

  defp event_summary(assigns) do
    total = assigns.summary.total
    fatal = assigns.summary.fatal
    critical = assigns.summary.critical
    high = assigns.summary.high
    medium = assigns.summary.medium
    low = assigns.summary.low
    informational = assigns.summary.informational

    assigns =
      assigns
      |> assign(:total, total)
      |> assign(:fatal, fatal)
      |> assign(:critical, critical)
      |> assign(:high, high)
      |> assign(:medium, medium)
      |> assign(:low, low)
      |> assign(:informational, informational)

    ~H"""
    <div class="rounded-xl border border-base-200 bg-base-100 p-4">
      <div class="flex items-center justify-between mb-3">
        <div class="text-xs text-base-content/50 uppercase tracking-wider">
          Event Severity Breakdown
        </div>
        <div class="flex items-center gap-1">
          <.ui_button patch={~p"/events"} size="xs" variant="ghost">All Events</.ui_button>
          <.ui_button patch={ ~p"/events?#{%{q: "in:events severity:(Fatal,Critical,High) time:#{@time_window} sort:time:desc"}}" } size="xs" variant="ghost" class="text-error">
            Fatal/Critical/High
          </.ui_button>
        </div>
      </div>
      <div class="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-6 gap-3">
        <.severity_stat
          label="Fatal"
          count={@fatal}
          total={@total}
          color="error"
          severity="Fatal"
          time_window={@time_window}
        />
        <.severity_stat
          label="Critical"
          count={@critical}
          total={@total}
          color="error"
          severity="Critical"
          time_window={@time_window}
        />
        <.severity_stat
          label="High"
          count={@high}
          total={@total}
          color="warning"
          severity="High"
          time_window={@time_window}
        />
        <.severity_stat
          label="Medium"
          count={@medium}
          total={@total}
          color="info"
          severity="Medium"
          time_window={@time_window}
        />
        <.severity_stat
          label="Low"
          count={@low}
          total={@total}
          color="success"
          severity="Low"
          time_window={@time_window}
        />
        <.severity_stat
          label="Informational"
          count={@informational}
          total={@total}
          color="info"
          severity="Informational"
          time_window={@time_window}
        />
      </div>
    </div>
    """
  end

  attr :summary, :map, required: true
  attr :time_window, :string, required: true

  defp event_finding_summary(assigns) do
    total = assigns.summary.total || 0
    anomalies = assigns.summary.anomalies || 0
    at_risk = assigns.summary.at_risk || 0
    critical = assigns.summary.critical || 0
    high = assigns.summary.high || 0

    assigns =
      assigns
      |> assign(:total, total)
      |> assign(:anomalies, anomalies)
      |> assign(:at_risk, at_risk)
      |> assign(:critical, critical)
      |> assign(:high, high)

    ~H"""
    <div class="grid grid-cols-1 md:grid-cols-3 gap-3">
      <.finding_stat
        label="Anomaly findings"
        count={@anomalies}
        detail={"#{@critical} critical, #{@high} high"}
        query={StatsQuery.anomaly_findings_data_query(time: @time_window)}
        color="warning"
      />
      <.finding_stat
        label="At-risk capacity"
        count={@at_risk}
        detail="Projected exhaustion events"
        query={StatsQuery.capacity_at_risk_data_query(time: @time_window)}
        color="error"
      />
      <.finding_stat
        label="Health findings"
        count={@total}
        detail="Anomaly and capacity signals"
        query={StatsQuery.health_findings_data_query(time: @time_window)}
        color="info"
      />
    </div>
    """
  end

  attr :label, :string, required: true
  attr :count, :integer, required: true
  attr :detail, :string, required: true
  attr :query, :string, required: true
  attr :color, :string, required: true

  defp finding_stat(assigns) do
    ~H"""
    <.link
      patch={~p"/events?#{%{q: @query}}"}
      class="rounded-xl border border-base-200 bg-base-100 p-4 hover:bg-base-200/40 transition-colors group"
    >
      <div class="flex items-start justify-between gap-3">
        <div class="min-w-0">
          <div class={["text-xs font-medium uppercase tracking-wider", color_class(@color)]}>
            {@label}
          </div>
          <div class="mt-1 text-xs text-base-content/60 truncate">{@detail}</div>
        </div>
        <div class="text-2xl font-semibold group-hover:text-primary">{@count}</div>
      </div>
    </.link>
    """
  end

  attr :label, :string, required: true
  attr :count, :integer, required: true
  attr :total, :integer, required: true
  attr :color, :string, required: true
  attr :severity, :string, required: true
  attr :time_window, :string, required: true

  defp severity_stat(assigns) do
    pct = if assigns.total > 0, do: round(assigns.count / assigns.total * 100), else: 0
    query = "in:events severity:#{assigns.severity} time:#{assigns.time_window} sort:time:desc"

    assigns =
      assigns
      |> assign(:pct, pct)
      |> assign(:query, query)

    ~H"""
    <.link
      patch={~p"/events?#{%{q: @query}}"}
      class="rounded-lg bg-base-200/50 p-3 hover:bg-base-200 transition-colors cursor-pointer group"
    >
      <div class="flex items-center justify-between mb-1">
        <span class={["text-xs font-medium", color_class(@color)]}>{@label}</span>
        <span class="text-xs text-base-content/50">{@pct}%</span>
      </div>
      <div class="text-xl font-bold group-hover:text-primary">{@count}</div>
      <div class="h-1 bg-base-300 rounded-full mt-2 overflow-hidden">
        <div class={["h-full rounded-full", color_bg(@color)]} style={"width: #{@pct}%"} />
      </div>
    </.link>
    """
  end

  defp color_class("error"), do: "text-error"
  defp color_class("warning"), do: "text-warning"
  defp color_class("info"), do: "text-info"
  defp color_class("success"), do: "text-success"
  defp color_class(_), do: "text-base-content"

  defp color_bg("error"), do: "bg-error"
  defp color_bg("warning"), do: "bg-warning"
  defp color_bg("info"), do: "bg-info"
  defp color_bg("success"), do: "bg-success"
  defp color_bg(_), do: "bg-base-content"

  attr :id, :string, required: true
  attr :events, :any, required: true
  attr :count, :integer, required: true

  defp events_table(assigns) do
    ~H"""
    <div class="sr-ui-table-shell">
      <table id={@id} class={ui_table_class(size: "sm", zebra: true, class: "w-full")}>
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
        <tbody id={"#{@id}-rows"} phx-update="stream">
          <tr :if={@count == 0}>
            <td colspan="4" class="text-sm text-base-content/60 py-8 text-center">
              No events found.
            </td>
          </tr>

          <%= for {dom_id, event} <- @events do %>
            <tr
              id={dom_id}
              class="hover:bg-base-200/40 cursor-pointer transition-colors"
              phx-click={JS.navigate(~p"/events/#{event_id(event)}")}
            >
              <td class="whitespace-nowrap text-xs font-mono">
                {format_timestamp(event)}
              </td>
              <td class="whitespace-nowrap text-xs">
                <.severity_badge value={Map.get(event, "severity")} />
              </td>
              <td class="whitespace-nowrap text-xs truncate max-w-[12rem]" title={event_source(event)}>
                <div class="flex items-center gap-2 min-w-0">
                  <span class="truncate">{event_source(event)}</span>
                  <.finding_badge :if={finding_label(event)} label={finding_label(event)} />
                  <.device_link event={event} />
                </div>
              </td>
              <td class="text-xs truncate max-w-[32rem]" title={event_message(event)}>
                {event_message(event)}
              </td>
            </tr>
          <% end %>
        </tbody>
      </table>
    </div>
    """
  end

  attr :value, :any, default: nil

  defp severity_badge(assigns) do
    variant = severity_variant(assigns.value)
    label = severity_label(assigns.value)

    assigns = assigns |> assign(:variant, variant) |> assign(:label, label)

    ~H"""
    <.ui_badge variant={@variant} size="xs">{@label}</.ui_badge>
    """
  end

  attr :label, :string, required: true

  defp finding_badge(assigns) do
    variant =
      case assigns.label do
        "Capacity" -> "error"
        "Anomaly" -> "warning"
        _ -> "info"
      end

    assigns = assign(assigns, :variant, variant)

    ~H"""
    <.ui_badge variant={@variant} size="xs">{@label}</.ui_badge>
    """
  end

  attr :event, :map, required: true

  defp device_link(assigns) do
    ref = EventDeviceReference.extract(assigns.event)
    assigns = assign(assigns, :ref, ref)

    ~H"""
    <.ui_badge
      :if={@ref}
      size="xs"
      variant="primary"
      class="cursor-pointer whitespace-nowrap"
      phx-click={JS.navigate(~p"/devices/#{@ref.uid}")}
      title={"View affected device #{@ref.uid}"}
    >
      device →
    </.ui_badge>
    """
  end

  defp severity_variant(value) do
    case normalize_severity(value) do
      s when s in ["fatal", "critical", "error"] -> "error"
      s when s in ["high", "warn", "warning"] -> "warning"
      s when s in ["medium", "info", "informational"] -> "info"
      s when s in ["low", "debug", "ok"] -> "success"
      _ -> "ghost"
    end
  end

  defp severity_label(nil), do: "—"
  defp severity_label(""), do: "—"
  defp severity_label(value) when is_binary(value), do: value
  defp severity_label(value), do: to_string(value)

  defp normalize_severity(nil), do: ""
  defp normalize_severity(v) when is_binary(v), do: v |> String.trim() |> String.downcase()
  defp normalize_severity(v), do: v |> to_string() |> normalize_severity()

  defp event_id(event) do
    Map.get(event, "id") || Map.get(event, "event_id") || "unknown"
  end

  defp format_timestamp(event) do
    ts =
      Map.get(event, "time") || Map.get(event, "event_timestamp") || Map.get(event, "timestamp")

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
      {:ok, dt, _offset} ->
        {:ok, dt}

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
      Map.get(event, "log_provider") ||
        Map.get(event, "log_name") ||
        Map.get(event, "host") ||
        Map.get(event, "source") ||
        Map.get(event, "uid") ||
        Map.get(event, "device_id") ||
        Map.get(event, "subject")

    case source do
      nil -> "—"
      "" -> "—"
      v when is_binary(v) -> v
      v -> to_string(v)
    end
  end

  defp finding_label(event) when is_map(event) do
    cond do
      anomaly_finding?(event) -> "Anomaly"
      capacity_forecast_event?(event) -> "Capacity"
      true -> nil
    end
  end

  defp finding_label(_), do: nil

  defp anomaly_finding?(event) do
    get_in(event, ["metadata", "service_radar", "source_type"]) == "anomaly_detection" or
      get_in(event, ["metadata", "security_signal", "source"]) == "anomaly_detection" or
      get_in(event, ["metadata", "detection_finding", "type"]) == "anomaly" or
      Map.get(event, "log_provider") == "anomaly_detection"
  end

  defp capacity_forecast_event?(event) do
    get_in(event, ["metadata", "event_type"]) == "capacity_forecast" or
      get_in(event, ["unmapped", "event_type"]) == "capacity_forecast" or
      Map.get(event, "log_provider") == "capacity_forecasting"
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

  # Compute summary stats from events
  defp compute_summary(events) when is_list(events) do
    initial = %{
      total: 0,
      fatal: 0,
      critical: 0,
      high: 0,
      medium: 0,
      low: 0,
      informational: 0
    }

    Enum.reduce(events, initial, fn event, acc ->
      updated =
        case event_summary_bucket(event) do
          "fatal" -> Map.update!(acc, :fatal, &(&1 + 1))
          "critical" -> Map.update!(acc, :critical, &(&1 + 1))
          "high" -> Map.update!(acc, :high, &(&1 + 1))
          "medium" -> Map.update!(acc, :medium, &(&1 + 1))
          "low" -> Map.update!(acc, :low, &(&1 + 1))
          "informational" -> Map.update!(acc, :informational, &(&1 + 1))
          "info" -> Map.update!(acc, :informational, &(&1 + 1))
          _ -> acc
        end

      Map.update!(updated, :total, &(&1 + 1))
    end)
  end

  defp compute_summary(_), do: %{total: 0, fatal: 0, critical: 0, high: 0, medium: 0, low: 0, informational: 0}

  defp refresh_events(socket) do
    srql = Map.get(socket.assigns, :srql, %{})
    query = Map.get(srql, :query, "")
    limit = Map.get(socket.assigns, :limit, @default_limit)
    params = %{"q" => query, "limit" => limit}
    uri = Map.get(srql, :page_path, "/events")

    socket =
      SRQLPage.load_list(socket, params, uri, :events,
        default_limit: @default_limit,
        max_limit: @max_limit
      )

    time_window = time_window_from_query(query)
    summary = events_summary(time_window, socket.assigns.events)
    finding_summary = Stats.anomaly_findings_summary(time: time_window, scope: socket.assigns.current_scope)

    socket
    |> stream(:events, socket.assigns.events, reset: true, dom_id: &event_dom_id/1)
    |> assign(:summary, summary)
    |> assign(:time_window, time_window)
    |> assign(:finding_summary, finding_summary)
  end

  defp schedule_events_refresh(socket) do
    if socket.assigns[:events_refresh_scheduled?] do
      socket
    else
      Process.send_after(self(), :debounced_events_refresh, @events_refresh_debounce_ms)
      assign(socket, :events_refresh_scheduled?, true)
    end
  end

  defp events_summary(time_window, events) do
    case Stats.events_summary(time: time_window) do
      %{total: total} = summary when total > 0 -> summary
      _ -> compute_summary(events)
    end
  end

  defp to_int(nil), do: 0
  defp to_int(value) when is_integer(value), do: value
  defp to_int(value) when is_float(value), do: trunc(value)
  defp to_int(%Decimal{} = d), do: Decimal.to_integer(d)
  defp to_int(_), do: 0

  defp time_window_from_query(query) when is_binary(query) do
    case Regex.run(~r/\btime:(last_\d+[hd])\b/i, query) do
      [_, value] -> String.downcase(value)
      _ -> "last_7d"
    end
  end

  defp time_window_from_query(_), do: "last_7d"

  defp event_summary_bucket(%{} = event) do
    [
      normalize_severity(Map.get(event, "severity")),
      normalize_severity(Map.get(event, "log_level")),
      severity_bucket_from_id(Map.get(event, "severity_id"))
    ]
    |> Enum.find(&(&1 not in [nil, ""]))
    |> case do
      nil -> ""
      value -> value
    end
  end

  defp event_summary_bucket(_), do: ""

  defp severity_bucket_from_id(nil), do: nil

  defp severity_bucket_from_id(value) do
    case to_int(value) do
      6 -> "fatal"
      5 -> "critical"
      4 -> "high"
      3 -> "medium"
      2 -> "low"
      1 -> "informational"
      _ -> nil
    end
  end

  defp event_dom_id(event) do
    id = event_id(event)

    if id == "unknown" do
      "event-" <> Integer.to_string(:erlang.phash2(event))
    else
      "event-" <> id
    end
  end
end
