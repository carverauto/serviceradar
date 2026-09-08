defmodule ServiceRadarWebNGWeb.EventLive.Show do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.Observability.SignalDisplayComponents
  import ServiceRadarWebNGWeb.UIComponents

  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Monitoring.Alert
  alias ServiceRadarWebNG.Observability.SignalDisplay
  alias ServiceRadarWebNGWeb.AnomalySeriesKey
  alias ServiceRadarWebNGWeb.Dashboard.Engine
  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Table, as: TablePlugin
  alias ServiceRadarWebNGWeb.Observability.DetailStreamComponents
  alias ServiceRadarWebNGWeb.Observability.EventDeviceReference
  alias ServiceRadarWebNGWeb.SRQL.Builder
  alias ServiceRadarWebNGWeb.SRQL.Page, as: SRQLPage

  require Ash.Query
  require Logger

  # Side stream only — must not drive the main Observability events list limit.
  @stream_page_size 10
  # Matches Observability events tab / SRQL bar defaults when running a query from detail.
  @srql_default_limit 20
  @anomaly_chart_side_seconds 2 * 60 * 60
  # Keep room for multi-series interface rates across ±2h at 1–5m buckets.
  @snmp_metrics_limit 3_600

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Event Details")
     |> assign(:event_id, nil)
     |> assign(:event, nil)
     |> assign(:signal_display, nil)
     |> assign(:device_ref, nil)
     |> assign(:related, %{log_id: nil, alert: nil})
     |> assign(:error, nil)
     |> assign(:stream_entries, [])
     |> assign(:stream_severity, "all")
     |> assign(:stream_query, nil)
     |> assign(:stream_cursor, nil)
     |> assign(:stream_next_cursor, nil)
     |> assign(:stream_prev_cursor, nil)
     |> assign(:stream_page, 1)
     |> assign(:stream_page_size, @stream_page_size)
     |> assign(:show_raw_json, false)
     |> assign(:anomaly_context, nil)
     |> assign(:anomaly_metric_panels, [])
     |> assign(:anomaly_metrics_loading, false)
     |> assign(:anomaly_metrics_error, nil)
     |> assign(:limit, @srql_default_limit)
     |> SRQLPage.init("events", default_limit: @srql_default_limit)}
  end

  @impl true
  def handle_params(%{"event_id" => event_id}, uri, socket) do
    {event, error} = load_event(event_id, socket.assigns.current_scope)
    stream_query = stream_query_for_event(event)
    detail_query = detail_query_for_event(event_id)

    {stream, next_cursor, prev_cursor} =
      load_stream_page(stream_query, event, event_id, nil, socket.assigns.current_scope)

    related = build_related(event, socket.assigns.current_scope)

    device_lookup_scope =
      if connected?(socket), do: socket.assigns.current_scope

    signal_display = build_signal_display(event, device_lookup_scope)
    device_ref = build_device_ref(event, socket.assigns.current_scope)
    anomaly_context = build_anomaly_context(event, device_ref)

    socket =
      socket
      |> assign(:event_id, event_id)
      |> assign(:event, event)
      |> assign(:signal_display, signal_display)
      |> assign(:device_ref, device_ref)
      |> assign(:related, related)
      |> assign(:error, error)
      |> assign(:stream_entries, stream)
      |> assign(:stream_query, stream_query)
      |> assign(:stream_cursor, nil)
      |> assign(:stream_next_cursor, next_cursor)
      |> assign(:stream_prev_cursor, prev_cursor)
      |> assign(:stream_page, 1)
      |> assign(:stream_severity, "all")
      |> assign(:show_raw_json, false)
      |> assign(:anomaly_context, anomaly_context)
      |> assign(:anomaly_metric_panels, [])
      |> assign(:anomaly_metrics_loading, false)
      |> assign(:anomaly_metrics_error, nil)
      |> assign(:page_title, page_title_for(event, event_id))
      |> prefill_srql_bar(detail_query, uri, event_id)

    socket =
      if connected?(socket) and anomaly_metrics_loadable?(anomaly_context) do
        scope = socket.assigns.current_scope

        socket
        |> assign(:anomaly_metrics_loading, true)
        |> start_async(:anomaly_metrics, fn ->
          load_anomaly_metric_panels(anomaly_context, event, scope)
        end)
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_async(:anomaly_metrics, {:ok, {:ok, panels}}, socket) do
    {:noreply,
     socket
     |> assign(:anomaly_metrics_loading, false)
     |> assign(:anomaly_metric_panels, panels)
     |> assign(:anomaly_metrics_error, nil)}
  end

  def handle_async(:anomaly_metrics, {:ok, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(:anomaly_metrics_loading, false)
     |> assign(:anomaly_metric_panels, [])
     |> assign(:anomaly_metrics_error, reason)}
  end

  def handle_async(:anomaly_metrics, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(:anomaly_metrics_loading, false)
     |> assign(:anomaly_metric_panels, [])
     |> assign(:anomaly_metrics_error, "Failed to load metric context: #{inspect(reason)}")}
  end

  @impl true
  def handle_event("set_stream_severity", %{"severity" => severity}, socket)
      when severity in ~w(all critical high medium low info) do
    {:noreply, assign(socket, :stream_severity, severity)}
  end

  def handle_event("stream_next", _params, socket) do
    cursor = socket.assigns.stream_next_cursor

    if is_binary(cursor) and cursor != "" do
      {:noreply, load_stream_into_socket(socket, cursor, socket.assigns.stream_page + 1)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("stream_prev", _params, socket) do
    cursor = socket.assigns.stream_prev_cursor
    page = max(socket.assigns.stream_page - 1, 1)

    cond do
      page <= 1 ->
        {:noreply, load_stream_into_socket(socket, nil, 1)}

      is_binary(cursor) and cursor != "" ->
        {:noreply, load_stream_into_socket(socket, cursor, page)}

      true ->
        {:noreply, socket}
    end
  end

  def handle_event("copy_id", _params, socket) do
    {:noreply, push_event(socket, "clipboard", %{text: socket.assigns.event_id || ""})}
  end

  def handle_event("copy_json", _params, socket) do
    text =
      case socket.assigns.event do
        %{} = event -> Jason.encode!(event, pretty: true)
        _ -> ""
      end

    {:noreply, push_event(socket, "clipboard", %{text: text})}
  end

  def handle_event("copy_message", _params, socket) do
    text =
      case socket.assigns.event do
        %{} = event -> event_message(event)
        _ -> ""
      end

    {:noreply, push_event(socket, "clipboard", %{text: text})}
  end

  def handle_event("toggle_raw_json", _params, socket) do
    {:noreply, assign(socket, :show_raw_json, not socket.assigns.show_raw_json)}
  end

  def handle_event("srql_change", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_change", params)}
  end

  def handle_event("srql_submit", params, socket) do
    {:noreply,
     SRQLPage.handle_event(socket, "srql_submit", params,
       fallback_path: "/observability",
       extra_params: %{}
     )}
  end

  def handle_event("srql_reset", params, socket) do
    {:noreply,
     SRQLPage.handle_event(socket, "srql_reset", params,
       fallback_path: "/observability",
       extra_params: %{}
     )}
  end

  def handle_event("srql_builder_toggle", _params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_toggle", %{}, entity: "events")}
  end

  def handle_event("srql_builder_change", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_change", params)}
  end

  def handle_event("srql_builder_apply", _params, socket) do
    socket = SRQLPage.handle_event(socket, "srql_builder_apply", %{})
    {:noreply, refresh_stream_from_srql(socket)}
  end

  def handle_event("srql_builder_run", _params, socket) do
    {:noreply,
     SRQLPage.handle_event(socket, "srql_builder_run", %{},
       fallback_path: "/observability",
       extra_params: %{}
     )}
  end

  def handle_event("srql_builder_add_filter", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_add_filter", params, entity: "events")}
  end

  def handle_event("srql_builder_remove_filter", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_remove_filter", params, entity: "events")}
  end

  @impl true
  def render(assigns) do
    assigns =
      assign(
        assigns,
        :visible_stream,
        DetailStreamComponents.filter_stream_entries(
          assigns.stream_entries,
          assigns.stream_severity,
          :events
        )
      )

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} srql={@srql}>
      <div class="sr-event-viewer flex min-w-0 max-w-full flex-col pt-2 sm:pt-3 lg:h-[calc(100dvh-7.5rem)] lg:max-h-[calc(100dvh-7.5rem)] lg:overflow-hidden">
        <div :if={@error} class="shrink-0 border-b border-sr-line px-1 py-3 sm:px-2">
          <div class={ui_alert_class(variant: "error")}>
            <.icon name="hero-exclamation-circle" class="size-5 shrink-0" />
            <p>{@error}</p>
          </div>
        </div>

        <div
          :if={is_map(@event)}
          class="grid min-h-0 min-w-0 max-w-full flex-1 grid-cols-1 overflow-hidden border-t border-sr-line lg:grid-cols-[15.5rem_minmax(0,1fr)] xl:grid-cols-[16.5rem_minmax(0,1fr)]"
        >
          <%!-- Desktop-only stream; mobile is detail-only --%>
          <.detail_stream_pane
            id="event-stream"
            title="Event stream"
            class="sr-event-stream"
            entries={@visible_stream}
            timezone={@current_scope.user.timezone}
            page_count={length(@visible_stream)}
            page={@stream_page}
            selected_id={@event_id}
            stream_severity={@stream_severity}
            severity_filters={~w(all critical high medium low info)}
            context_label={stream_context_label(@event)}
            stream_query={@stream_query || Map.get(@srql, :query)}
            has_prev={@stream_page > 1}
            has_next={is_binary(@stream_next_cursor) and @stream_next_cursor != ""}
            empty_label="No matching events"
          />

          <section class="flex min-h-0 min-w-0 flex-col overflow-hidden lg:border-l lg:border-sr-line">
            <.event_detail_header event={@event} event_id={@event_id} />
            <.event_meta_strip event={@event} timezone={@current_scope.user.timezone} />

            <div class="min-h-0 min-w-0 flex-1 space-y-5 overflow-x-hidden overflow-y-auto px-3 py-5 sm:px-5">
              <.event_message_hero event={@event} />
              <.event_context_panel event={@event} timezone={@current_scope.user.timezone} />
              <.affected_device
                :if={is_map(@device_ref)}
                device_ref={@device_ref}
                anomaly_context={@anomaly_context}
              />
              <.signal_display_panel
                :if={is_list(@signal_display)}
                id="event-signal-display"
                widgets={@signal_display}
                timezone={@current_scope.user.timezone}
              />
              <.anomaly_detection_summary
                :if={anomaly_finding?(@event)}
                event={@event}
                anomaly_context={@anomaly_context}
                metric_panels={@anomaly_metric_panels}
                metrics_loading={@anomaly_metrics_loading}
                metrics_error={@anomaly_metrics_error}
                timezone={@current_scope.user.timezone}
              />
              <.capacity_forecast_summary
                :if={capacity_forecast_event?(@event)}
                event={@event}
                timezone={@current_scope.user.timezone}
              />
              <.waf_finding_summary :if={waf_event?(@event)} event={@event} />
              <.falco_runtime_summary :if={falco_event?(@event)} event={@event} />
              <.related_links related={@related} />
              <.event_details event={@event} timezone={@current_scope.user.timezone} />
              <.event_raw_toggle event={@event} open?={@show_raw_json} />
            </div>
          </section>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # -- data loading -----------------------------------------------------------

  defp load_event(event_id, scope) do
    query = detail_query_for_event(event_id) <> " limit:1"

    case srql_module().query(query, %{scope: scope}) do
      {:ok, %{"results" => [event | _]}} when is_map(event) ->
        {event, nil}

      {:ok, %{"results" => []}} ->
        {nil, "Event not found. Note: Event detail view requires event_id field support."}

      {:ok, _other} ->
        {nil, "Unexpected response format"}

      {:error, reason} ->
        error_msg = format_error(reason)

        if String.contains?(error_msg, "unsupported filter") do
          {nil, "Event detail view is not available - the events entity does not support filtering by id."}
        else
          {nil, "Failed to load event: #{error_msg}"}
        end
    end
  end

  # Query that pinpoints the open event (SRQL chrome / re-run from detail).
  defp detail_query_for_event(event_id) when is_binary(event_id) do
    ~s|in:events id:"#{escape_value(event_id)}" time:last_7d|
  end

  defp detail_query_for_event(_), do: "in:events time:last_7d"

  # Related stream for the left rail — host/provider context, not the single-id lookup.
  defp stream_query_for_event(%{} = event) do
    host = Map.get(event, "host")
    provider = Map.get(event, "log_provider")

    cond do
      is_binary(host) and String.trim(host) != "" ->
        ~s|in:events host:"#{escape_value(host)}" time:last_7d sort:time:desc|

      is_binary(provider) and String.trim(provider) != "" ->
        ~s|in:events log_provider:"#{escape_value(provider)}" time:last_7d sort:time:desc|

      true ->
        "in:events time:last_7d sort:time:desc"
    end
  end

  defp stream_query_for_event(_), do: "in:events time:last_7d sort:time:desc"

  defp load_stream_into_socket(socket, cursor, page) do
    query = socket.assigns.stream_query || stream_query_for_event(socket.assigns.event)

    {stream, next_cursor, prev_cursor} =
      load_stream_page(
        query,
        socket.assigns.event,
        socket.assigns.event_id,
        cursor,
        socket.assigns.current_scope
      )

    socket
    |> assign(:stream_entries, stream)
    |> assign(:stream_cursor, cursor)
    |> assign(:stream_next_cursor, next_cursor)
    |> assign(:stream_prev_cursor, prev_cursor)
    |> assign(:stream_page, page)
  end

  defp load_stream_page(query, event, selected_id, cursor, scope) when is_binary(query) do
    opts =
      if is_binary(cursor) and cursor != "" do
        %{limit: @stream_page_size, cursor: cursor, scope: scope}
      else
        %{limit: @stream_page_size, scope: scope}
      end

    case srql_module().query(strip_embedded_limit(query), opts) do
      {:ok, %{"results" => results} = resp} when is_list(results) ->
        entries = results |> Enum.with_index() |> Enum.map(fn {row, idx} -> stream_entry(row, idx) end)

        entries =
          if is_nil(cursor) and is_map(event) do
            ensure_selected_in_stream(entries, event, selected_id)
          else
            entries
          end

        pag = Map.get(resp, "pagination") || %{}
        next_c = Map.get(pag, "next_cursor") || Map.get(pag, :next_cursor)
        prev_c = Map.get(pag, "prev_cursor") || Map.get(pag, :prev_cursor)
        {entries, next_c, prev_c}

      _ ->
        {[], nil, nil}
    end
  end

  defp load_stream_page(_, event, selected_id, cursor, scope) when is_map(event) do
    load_stream_page(stream_query_for_event(event), event, selected_id, cursor, scope)
  end

  defp load_stream_page(_, _, _, _, _), do: {[], nil, nil}

  defp refresh_stream_from_srql(socket) do
    raw =
      case Map.get(socket.assigns.srql || %{}, :query) do
        q when is_binary(q) -> String.trim(q)
        _ -> ""
      end

    fallback = socket.assigns.stream_query || stream_query_for_event(socket.assigns.event)

    query =
      if raw != "" and String.contains?(raw, "in:events") do
        strip_embedded_limit(raw)
      else
        fallback
      end

    {stream, next_cursor, prev_cursor} =
      load_stream_page(
        query,
        socket.assigns.event,
        socket.assigns.event_id,
        nil,
        socket.assigns.current_scope
      )

    socket
    |> assign(:stream_entries, stream)
    |> assign(:stream_query, query)
    |> assign(:stream_cursor, nil)
    |> assign(:stream_next_cursor, next_cursor)
    |> assign(:stream_prev_cursor, prev_cursor)
    |> assign(:stream_page, 1)
    |> assign(:stream_severity, "all")
  end

  defp strip_embedded_limit(query) when is_binary(query) do
    query
    |> String.replace(~r/\s*limit:\d+\b/i, "")
    |> String.trim()
  end

  defp prefill_srql_bar(socket, query, uri, event_id) when is_binary(query) do
    page_path =
      case uri do
        path when is_binary(path) and path != "" ->
          URI.parse(uri).path || "/events/#{event_id}"

        _ ->
          "/events/#{event_id}"
      end

    srql =
      socket.assigns.srql
      |> Map.merge(%{
        enabled: true,
        entity: "events",
        query: query,
        draft: query,
        page_path: page_path || "/events/#{event_id}",
        error: nil,
        loading: false
      })
      |> sync_builder_state(query)

    assign(socket, :srql, srql)
  end

  defp sync_builder_state(srql, query) do
    case Builder.parse(query) do
      {:ok, builder} ->
        Map.merge(srql, %{builder: builder, builder_supported: true, builder_sync: true})

      {:error, _reason} ->
        Map.merge(srql, %{builder_supported: false, builder_sync: false})
    end
  end

  defp stream_entry(event, idx) when is_map(event) do
    id = entry_id(event, idx)

    %{
      id: id,
      dom_id: "event-entry-#{idx}",
      href: ~p"/events/#{id}",
      severity: Map.get(event, "severity"),
      secondary: Map.get(event, "host") || Map.get(event, "log_provider") || "—",
      timestamp: Map.get(event, "time") || Map.get(event, "event_timestamp") || Map.get(event, "timestamp"),
      preview: message_preview(event_message(event))
    }
  end

  defp ensure_selected_in_stream(entries, event, selected_id) do
    if Enum.any?(entries, &(&1.id == selected_id)) do
      entries
    else
      [stream_entry(Map.put(event, "id", selected_id), "selected") | entries]
    end
  end

  defp page_title_for(%{} = event, event_id) do
    case event_headline(event) do
      nil -> "Event · #{String.slice(to_string(event_id), 0, 8)}"
      title -> title
    end
  end

  defp page_title_for(_, event_id), do: "Event · #{String.slice(to_string(event_id), 0, 8)}"

  defp stream_context_label(%{} = event) do
    Map.get(event, "host") || Map.get(event, "log_provider") || Map.get(event, "source")
  end

  defp stream_context_label(_), do: nil

  # -- detail header / meta ---------------------------------------------------

  attr :event, :map, required: true
  attr :event_id, :string, required: true

  defp event_detail_header(assigns) do
    title = event_headline(assigns.event) || "Event"

    assigns =
      assigns
      |> assign(:title, title)
      |> assign(:source_kind, event_source_kind(assigns.event))
      |> assign(:short_id, String.slice(assigns.event_id, 0, 8))

    ~H"""
    <header class="space-y-3 border-b border-sr-line px-4 pb-4 pt-5 font-sans sm:px-6 sm:pt-6">
      <div class="flex flex-wrap items-center justify-between gap-x-3 gap-y-2">
        <div class="flex min-w-0 flex-wrap items-center gap-x-2 gap-y-1 text-sm text-sr-muted">
          <.link navigate={~p"/observability/events"} class="hover:text-sr-ink">
            events
          </.link>
          <span class="text-sr-line-strong">/</span>
          <span class="text-sr-ink/80">{@source_kind}</span>
          <span class="text-sr-line-strong">/</span>
          <span class="font-mono text-sr-ink">{@short_id}</span>
        </div>

        <div class="flex shrink-0 flex-wrap items-center gap-1.5">
          <.ui_button href={~p"/observability/events"} variant="outline" size="xs">
            Back to events
          </.ui_button>
          <.ui_button type="button" variant="outline" size="xs" phx-click="copy_json">
            Copy JSON
          </.ui_button>
        </div>
      </div>

      <div class="min-w-0 space-y-2">
        <div class="flex min-w-0 items-start gap-2.5">
          <.severity_badge value={Map.get(@event, "severity")} />
          <h1
            class="min-w-0 flex-1 font-sans text-lg font-semibold leading-snug tracking-tight text-sr-ink sm:text-xl line-clamp-2"
            title={@title}
          >
            {@title}
          </h1>
        </div>
        <div class="flex flex-wrap items-center gap-2">
          <code class="break-all font-mono text-xs text-sr-muted">{@event_id}</code>
          <.ui_button type="button" size="xs" variant="ghost" phx-click="copy_id">Copy ID</.ui_button>
        </div>
      </div>
    </header>
    """
  end

  attr :event, :map, required: true
  attr :timezone, :string, required: true

  defp event_meta_strip(assigns) do
    event = assigns.event
    host = Map.get(event, "host")
    provider = Map.get(event, "log_provider")
    activity = Map.get(event, "activity_name")
    log_name = Map.get(event, "log_name")
    log_level = Map.get(event, "log_level") || Map.get(event, "level")
    actor_app = nested_string(event, ["actor", "app_name"])
    actor_process = nested_string(event, ["actor", "process"])

    facts =
      [
        %{label: "Time", value: event_timestamp_value(event), mono?: true, href: nil, time?: true},
        %{
          label: "Provider",
          value: provider,
          mono?: false,
          href: events_filter_href("log_provider", provider)
        },
        %{
          label: "Log name",
          value: log_name,
          mono?: true,
          href: events_filter_href("log_name", log_name)
        },
        %{label: "Level", value: log_level, mono?: false, href: nil},
        %{
          label: "Host",
          value: host,
          mono?: true,
          href: events_filter_href("host", host)
        },
        %{
          label: "App",
          value: actor_app,
          mono?: true,
          href: nil
        },
        %{
          label: "Process",
          value: shorten_module(actor_process),
          mono?: true,
          href: nil,
          title: actor_process
        },
        %{
          label: "Activity",
          value: activity,
          mono?: false,
          href: events_filter_href("activity_name", activity)
        }
      ]
      |> Enum.reject(fn fact -> blank_value?(fact.value) end)
      |> Enum.uniq_by(fn fact -> {fact.label, fact.value} end)

    assigns = assign(assigns, :facts, facts)

    ~H"""
    <%!-- auto-fit so a short final row expands to fill width (no dead empty cells) --%>
    <div class="grid grid-cols-[repeat(auto-fit,minmax(9.5rem,1fr))] gap-px border-b border-sr-line bg-sr-line">
      <div
        :for={fact <- @facts}
        class="flex min-w-0 flex-col gap-1 bg-sr-surface px-4 py-3"
      >
        <span class="font-sans text-xs font-medium uppercase tracking-wide text-sr-muted">
          {fact.label}
        </span>
        <.user_time
          :if={Map.get(fact, :time?, false)}
          id="event-detail-time"
          value={fact.value}
          timezone={@timezone}
          style={:full}
          fallback={to_string(fact.value)}
          class="font-mono text-[13px] tracking-tight"
        />
        <.link
          :if={not Map.get(fact, :time?, false) and is_binary(fact.href)}
          navigate={fact.href}
          class={[
            "group inline-flex min-w-0 max-w-full items-center gap-1 truncate text-sm text-sr-brand transition-colors hover:text-sr-brand-strong hover:underline",
            fact.mono? && "font-mono text-[13px] tracking-tight"
          ]}
          title={"Filter events by #{fact.label}: #{fact.value}"}
        >
          <span class="truncate">{fact.value}</span>
          <.icon
            name="hero-arrow-top-right-on-square"
            class="size-3.5 shrink-0 opacity-60 transition-opacity group-hover:opacity-100"
          />
        </.link>
        <span
          :if={not Map.get(fact, :time?, false) and is_nil(fact.href)}
          class={[
            "truncate font-sans text-sm text-sr-ink",
            fact.mono? && "font-mono text-[13px] tracking-tight"
          ]}
          title={Map.get(fact, :title) || fact.value}
        >
          {fact.value}
        </span>
      </div>
    </div>
    """
  end

  # Main events list with a single equality filter.
  defp events_filter_href(_field, value) when not is_binary(value) or value == "", do: nil

  defp events_filter_href(field, value) when is_binary(field) and is_binary(value) do
    value = String.trim(value)

    if value == "" do
      nil
    else
      query =
        ~s|in:events #{field}:"#{escape_value(value)}" time:last_7d sort:time:desc|

      ~p"/observability/events?#{%{q: query}}"
    end
  end

  # -- message hero / context -------------------------------------------------

  attr :event, :map, required: true

  defp event_message_hero(assigns) do
    short = Map.get(assigns.event, "short_message")
    full = Map.get(assigns.event, "message")
    body = event_message(assigns.event)

    # Prefer the longer useful body once; avoid duplicate short/full cards.
    primary =
      cond do
        is_binary(full) and String.trim(full) != "" -> full
        is_binary(short) and String.trim(short) != "" -> short
        true -> body
      end

    assigns =
      assigns
      |> assign(:primary, primary)
      |> assign(:empty?, primary == "" or is_nil(primary))

    ~H"""
    <div :if={not @empty?} class="space-y-3">
      <div class="flex flex-wrap items-center justify-between gap-3">
        <span class="font-sans text-xs font-medium uppercase tracking-wide text-sr-muted">
          Message
        </span>
        <.ui_button type="button" size="xs" variant="ghost" phx-click="copy_message">Copy</.ui_button>
      </div>

      <div class="rounded-sr-surface border border-sr-line bg-[color-mix(in_srgb,var(--color-sr-canvas)_78%,var(--color-sr-subtle))] p-4 shadow-sr-surface sm:p-5">
        <p class="whitespace-pre-wrap break-words font-sans text-[15px] leading-relaxed text-sr-ink selection:bg-sr-brand/25">
          {@primary}
        </p>
      </div>
    </div>
    """
  end

  attr :event, :map, required: true
  attr :timezone, :string, required: true

  defp event_context_panel(assigns) do
    facts = event_context_facts(assigns.event)
    assigns = assign(assigns, :facts, facts)

    ~H"""
    <div
      :if={@facts != []}
      class="overflow-hidden rounded-sr-surface border border-sr-line bg-sr-surface shadow-sr-surface"
    >
      <div class="border-b border-sr-line bg-sr-subtle/30 px-4 py-2.5">
        <span class="font-sans text-xs font-medium uppercase tracking-wide text-sr-muted">
          Context
        </span>
      </div>
      <div class="grid grid-cols-1 divide-y divide-sr-line sm:grid-cols-2 sm:divide-x sm:divide-y-0 lg:grid-cols-3">
        <div
          :for={fact <- @facts}
          class="flex min-w-0 flex-col gap-1 px-4 py-3 even:bg-sr-subtle/15 sm:even:bg-transparent sm:[&:nth-child(2n)]:bg-sr-subtle/10 lg:[&:nth-child(2n)]:bg-transparent lg:[&:nth-child(3n+2)]:bg-sr-subtle/10"
        >
          <span class="font-sans text-xs font-medium uppercase tracking-wide text-sr-muted">
            {fact.label}
          </span>
          <.user_time
            :if={Map.get(fact, :timestamp?, false)}
            id={"event-context-#{String.replace(fact.key, "_", "-")}-time"}
            value={fact.value}
            timezone={@timezone}
            style={:full}
            fallback={fact.value}
            class="break-all font-mono text-[13px] tracking-tight text-sr-ink"
          />
          <span
            :if={not Map.get(fact, :timestamp?, false)}
            class={[
              "break-all text-sm text-sr-ink",
              fact.mono? && "font-mono text-[13px] tracking-tight"
            ]}
            title={Map.get(fact, :title) || fact.value}
          >
            {fact.value}
          </span>
        </div>
      </div>
    </div>
    """
  end

  defp event_context_facts(event) when is_map(event) do
    actor = map_value(event, "actor") || %{}
    metadata = map_value(event, "metadata") || %{}
    unmapped = map_value(event, "unmapped") || %{}
    raw = map_value(event, "raw_data") || %{}

    base = [
      %{
        label: "Application",
        value: nested_string(event, ["actor", "app_name"]) || map_value(actor, "app_name"),
        mono?: true
      },
      %{
        label: "Process",
        value: nested_string(event, ["actor", "process"]) || map_value(actor, "process"),
        mono?: true
      },
      %{
        label: "Status",
        value: Map.get(event, "status") || Map.get(event, "status_detail"),
        mono?: false
      },
      %{
        label: "Action",
        value: scalar_from_maps([raw, unmapped], ["action"]),
        mono?: false
      },
      %{
        label: "Purpose",
        value: scalar_from_maps([raw, unmapped], ["purpose"]),
        mono?: false
      },
      %{
        label: "Grant type",
        value: scalar_from_maps([raw, unmapped], ["grant_type"]),
        mono?: true
      },
      %{
        label: "Consumer",
        value: scalar_from_maps([raw, unmapped], ["consumer_id"]),
        mono?: true
      },
      %{
        label: "Consumer kind",
        value: scalar_from_maps([raw, unmapped], ["consumer_kind"]),
        mono?: false
      },
      %{
        label: "Agent",
        value: scalar_from_maps([raw, unmapped], ["agent_id"]),
        mono?: true
      },
      %{
        label: "Grant ID",
        value: scalar_from_maps([raw, unmapped], ["credential_broker_grant_id"]),
        mono?: true
      },
      %{
        label: "Rule ID",
        value: scalar_from_maps([raw, unmapped], ["credential_rule_id"]),
        mono?: true
      },
      %{
        label: "Secret ID",
        value: scalar_from_maps([raw, unmapped], ["network_credential_secret_id"]),
        mono?: true
      },
      %{
        label: "Event family",
        value: scalar_from_maps([raw, unmapped], ["event_family"]),
        mono?: true
      },
      %{
        label: "Resolution",
        value: scalar_from_maps([raw, unmapped], ["resolution_location"]),
        mono?: false
      },
      %{
        label: "Job",
        value:
          nested_string(unmapped, ["job"]) ||
            nested_string(unmapped, ["oban_job"]) ||
            nested_string(metadata, ["job"]),
        mono?: true
      },
      %{
        label: "Trace",
        value: Map.get(event, "trace_id") || nested_string(metadata, ["trace_id"]),
        mono?: true
      }
    ]

    # Any remaining flat raw_data keys not already covered.
    used_labels = MapSet.new(Enum.map(base, & &1.label))

    extra =
      raw
      |> flatten_scalar_facts()
      |> Enum.reject(fn fact -> MapSet.member?(used_labels, fact.label) end)

    (base ++ extra)
    |> Enum.reject(fn fact -> blank_value?(fact.value) end)
    |> Enum.uniq_by(fn fact -> {fact.label, to_string(fact.value)} end)
  end

  defp event_context_facts(_), do: []

  defp scalar_from_maps(maps, keys) when is_list(maps) and is_list(keys) do
    Enum.find_value(maps, fn
      %{} = map ->
        Enum.find_value(keys, fn key ->
          case map_value(map, key) do
            v when is_binary(v) and v != "" -> v
            v when is_number(v) or is_boolean(v) -> to_string(v)
            _ -> nil
          end
        end)

      _ ->
        nil
    end)
  end

  @event_context_timestamp_keys MapSet.new(
                                  ~w(time timestamp event_time logged_time observed_at created_at updated_at expires_at creationTimestamp updateTimestamp)
                                )

  defp flatten_scalar_facts(%{} = map) do
    map
    |> Enum.sort_by(fn {k, _} -> to_string(k) end)
    |> Enum.flat_map(fn {key, value} ->
      cond do
        value in [nil, "", []] ->
          []

        is_map(value) or is_list(value) ->
          []

        true ->
          key = to_string(key)

          [
            %{
              key: key,
              label: humanize_field(key),
              value: to_string(value),
              mono?: is_binary(value) and String.length(value) > 20,
              timestamp?: MapSet.member?(@event_context_timestamp_keys, key)
            }
          ]
      end
    end)
  end

  defp flatten_scalar_facts(_), do: []

  # -- domain panels (preserved) ----------------------------------------------

  attr(:related, :map, required: true)

  defp related_links(assigns) do
    log_id = Map.get(assigns.related, :log_id)
    alert = Map.get(assigns.related, :alert)

    assigns =
      assigns
      |> assign(:log_id, log_id)
      |> assign(:alert, alert)

    ~H"""
    <div
      :if={is_binary(@log_id) or is_struct(@alert)}
      class="overflow-hidden rounded-sr-surface border border-sr-line bg-sr-surface shadow-sr-surface"
    >
      <div class="border-b border-sr-line bg-sr-subtle/30 px-4 py-2.5">
        <span class="font-sans text-xs font-medium uppercase tracking-wide text-sr-muted">
          Related records
        </span>
      </div>
      <div class="flex flex-wrap gap-2 p-4">
        <.ui_button :if={@log_id} href={~p"/logs/#{@log_id}"} size="sm" variant="outline">
          View source log
        </.ui_button>
        <.ui_button
          :if={is_struct(@alert)}
          href={~p"/alerts/#{@alert.id}"}
          size="sm"
          variant="outline"
        >
          View alert ({@alert.status})
        </.ui_button>
      </div>
    </div>
    """
  end

  attr(:device_ref, :map, required: true)
  attr(:anomaly_context, :map, default: nil)

  defp affected_device(assigns) do
    ctx = assigns.anomaly_context || %{}
    device_href = Map.get(ctx, :device_href) || ~p"/devices/#{assigns.device_ref.uid}"
    iface_href = Map.get(ctx, :interfaces_href)
    snmp_href = Map.get(ctx, :snmp_metrics_href)

    assigns =
      assigns
      |> assign(:label, device_ref_label(assigns.device_ref))
      |> assign(:device_href, device_href)
      |> assign(:iface_href, iface_href)
      |> assign(:snmp_href, snmp_href)
      |> assign(:if_index, Map.get(ctx, :if_index))
      |> assign(:metric_name, Map.get(ctx, :metric_name))

    ~H"""
    <div class="overflow-hidden rounded-sr-surface border border-sr-brand/30 bg-sr-brand/5 shadow-sr-surface">
      <div class="flex flex-wrap items-center justify-between gap-4 px-4 py-4 sm:px-5">
        <div class="min-w-0">
          <span class="font-sans text-xs font-medium uppercase tracking-wide text-sr-brand block mb-1">
            Affected device
          </span>
          <div class="text-sm font-medium text-sr-ink truncate">{@label}</div>
          <div :if={@device_ref.guest} class="mt-0.5 text-xs font-mono text-sr-muted">
            Guest {@device_ref.guest}
          </div>
          <div class="mt-0.5 text-xs font-mono text-sr-muted break-all">
            {@device_ref.uid}
          </div>
          <div
            :if={@if_index || @metric_name}
            class="mt-2 flex flex-wrap gap-x-3 gap-y-1 text-xs text-sr-muted"
          >
            <span :if={@if_index} class="font-mono">ifIndex {@if_index}</span>
            <span :if={@metric_name} class="font-mono">{@metric_name}</span>
          </div>
        </div>
        <div class="flex flex-wrap items-center gap-2">
          <.ui_button navigate={@device_href} variant="primary" size="sm">
            View device →
          </.ui_button>
          <.ui_button :if={@iface_href} navigate={@iface_href} variant="outline" size="sm">
            Interfaces
          </.ui_button>
          <.ui_button :if={@snmp_href} navigate={@snmp_href} variant="outline" size="sm">
            SNMP metrics
          </.ui_button>
        </div>
      </div>
    </div>
    """
  end

  defp device_ref_label(%{hostname: hostname}) when is_binary(hostname) and hostname != "", do: hostname

  defp device_ref_label(%{guest: guest}) when is_binary(guest) and guest != "", do: "Proxmox guest #{guest}"

  defp device_ref_label(%{uid: uid}), do: uid

  defp build_device_ref(event, scope) when is_map(event), do: EventDeviceReference.resolve(event, scope)

  defp build_device_ref(_event, _scope), do: nil

  # -- anomaly context / metric panels -----------------------------------------

  defp build_anomaly_context(event, device_ref) when is_map(event) do
    if anomaly_finding?(event) do
      finding = anomaly_detection_payload(event)
      dimensions = anomaly_dimensions(event, finding)

      series_key =
        blank_to_nil(
          first_present([
            map_value(finding, "series_key"),
            map_value(dimensions, "series_key"),
            nested_value(event, ["metadata", "service_radar", "series_key"]),
            nested_value(event, ["metadata", "security_signal", "series_key"])
          ])
        )

      decoded = AnomalySeriesKey.decode(series_key)

      device_uid =
        blank_to_nil(
          first_present([
            is_map(device_ref) && Map.get(device_ref, :uid),
            map_value(finding, "device_id"),
            map_value(finding, "device_uid"),
            map_value(dimensions, "device_id"),
            map_value(dimensions, "device_uid"),
            nested_value(event, ["metadata", "service_radar", "device_uid"]),
            nested_value(event, ["metadata", "service_radar", "device_id"]),
            nested_value(event, ["metadata", "security_signal", "device_id"]),
            AnomalySeriesKey.component(decoded, "identity")
          ])
        )

      if_index =
        parse_if_index(
          first_present([
            map_value(finding, "if_index"),
            map_value(dimensions, "if_index"),
            nested_value(event, ["metadata", "service_radar", "if_index"]),
            nested_value(event, ["metadata", "security_signal", "if_index"]),
            AnomalySeriesKey.component(decoded, "if_index"),
            nested_value(finding, ["source_identity", "if_index"]),
            nested_value(event, ["unmapped", "if_index"])
          ])
        )

      metric_name =
        blank_to_nil(
          first_present([
            map_value(finding, "metric_name"),
            map_value(dimensions, "metric_name"),
            nested_value(event, ["metadata", "service_radar", "metric_name"]),
            nested_value(event, ["metadata", "security_signal", "metric_name"]),
            AnomalySeriesKey.component(decoded, "metric")
          ])
        )

      metric_class =
        blank_to_nil(
          first_present([
            map_value(finding, "metric_class"),
            map_value(dimensions, "metric_class"),
            nested_value(event, ["metadata", "service_radar", "metric_class"]),
            nested_value(event, ["metadata", "security_signal", "metric_class"]),
            anomaly_metric_class(decoded)
          ])
        )

      interface_label = anomaly_interface_label(decoded, finding, dimensions, if_index)
      snmp? = snmp_like_anomaly?(metric_class, metric_name, if_index, series_key, interface_label)
      event_time = event_time_from_event(event)

      base = %{
        device_uid: device_uid,
        if_index: if_index,
        metric_name: metric_name,
        metric_class: metric_class,
        interface_label: interface_label,
        series_key: series_key,
        snmp?: snmp?,
        event_time: event_time,
        device_href: nil,
        interfaces_href: nil,
        snmp_metrics_href: nil,
        chart_focus: anomaly_chart_focus(event, finding, series_key, metric_name, event_time)
      }

      if is_binary(device_uid) and device_uid != "" do
        device_href = ~p"/devices/#{device_uid}"
        interfaces_href = ~p"/devices/#{device_uid}?tab=interfaces"

        %{
          base
          | device_href: device_href,
            interfaces_href: if(snmp?, do: interfaces_href),
            snmp_metrics_href: if(snmp?, do: interfaces_href)
        }
      else
        base
      end
    end
  end

  defp build_anomaly_context(_event, _device_ref), do: nil

  defp anomaly_dimensions(event, finding) when is_map(event) do
    event
    |> nested_map(["metadata", "finding_info", "dimensions"])
    |> then(fn dims ->
      if map_size(dims) > 0, do: dims, else: nested_map(finding, ["dimensions"])
    end)
  end

  defp anomaly_dimensions(_event, _finding), do: %{}

  # Load charts when we have enough identity to query collected metrics.
  defp anomaly_metrics_loadable?(%{device_uid: device_uid, if_index: if_index, snmp?: true})
       when is_binary(device_uid) and device_uid != "" and is_integer(if_index) and if_index > 0 do
    true
  end

  defp anomaly_metrics_loadable?(%{device_uid: device_uid, metric_name: metric_name})
       when is_binary(device_uid) and device_uid != "" and is_binary(metric_name) and metric_name != "" do
    true
  end

  defp anomaly_metrics_loadable?(_), do: false

  defp load_anomaly_metric_panels(ctx, event, scope) when is_map(ctx) do
    queries = anomaly_metric_queries(ctx, event)

    if queries == [] do
      {:ok, []}
    else
      case try_anomaly_metric_queries(queries, scope, ctx) do
        {:ok, panels} ->
          {:ok, panels}

        {:error, reason} ->
          {:error, reason}
      end
    end
  rescue
    error ->
      Logger.warning("anomaly metric panel load crashed: #{Exception.message(error)}")
      {:error, Exception.message(error)}
  end

  defp load_anomaly_metric_panels(_ctx, _event, _scope), do: {:ok, []}

  defp try_anomaly_metric_queries(queries, scope, ctx) do
    result =
      Enum.reduce_while(queries, %{panels: [], last_error: nil}, fn query, acc ->
        case query_anomaly_metric_panels(query, scope, ctx) do
          {:ok, panels} when is_list(panels) and panels != [] ->
            {:halt, %{panels: Enum.take(panels, 2), last_error: nil}}

          {:ok, []} ->
            {:cont, acc}

          {:error, reason} ->
            Logger.debug("anomaly metric query failed: #{inspect(reason)} query=#{query}")
            {:cont, %{acc | last_error: format_error(reason)}}
        end
      end)

    cond do
      result.panels != [] -> {:ok, result.panels}
      is_binary(result.last_error) -> {:error, result.last_error}
      true -> {:ok, []}
    end
  end

  defp query_anomaly_metric_panels(query, scope, ctx) when is_binary(query) do
    case srql_module().query(query, %{scope: scope}) do
      {:ok, %{"results" => results} = response} when is_list(results) and results != [] ->
        panels =
          response
          |> Engine.build_panels()
          |> Enum.reject(&(&1.plugin == TablePlugin))
          |> Enum.map(&decorate_anomaly_metric_panel(&1, ctx))

        if panels == [] do
          # Still useful: force a timeseries attempt if Engine only built a table.
          case Engine.build_panels(response) do
            [panel | _] -> {:ok, [decorate_anomaly_metric_panel(panel, ctx)]}
            _ -> {:ok, []}
          end
        else
          {:ok, panels}
        end

      {:ok, %{"results" => []}} ->
        {:ok, []}

      {:ok, _other} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, "Unexpected metric response: #{inspect(other)}"}
    end
  end

  defp decorate_anomaly_metric_panel(panel, ctx) when is_map(panel) do
    title =
      cond do
        is_binary(Map.get(ctx, :metric_name)) and is_integer(Map.get(ctx, :if_index)) ->
          "#{ctx.metric_name} · ifIndex #{ctx.if_index}"

        is_binary(Map.get(ctx, :metric_name)) ->
          ctx.metric_name

        is_integer(Map.get(ctx, :if_index)) ->
          "Interface ifIndex #{ctx.if_index}"

        true ->
          Map.get(panel, :title) || "Metric series"
      end

    assigns =
      panel.assigns
      |> Map.put(:compact, true)
      |> Map.put(:chart_mode, :combined)
      # SRQL already applies agg:rate when used; leave points as-is for display.
      |> Map.put(:rate_mode, :none)
      |> maybe_put_interface_label(ctx)

    %{panel | title: title, assigns: assigns}
  end

  defp maybe_put_interface_label(assigns, %{interface_label: label}) when is_binary(label) do
    Map.put(assigns, :interface_label, label)
  end

  defp maybe_put_interface_label(assigns, _ctx), do: assigns

  defp anomaly_metric_queries(ctx, event) do
    device_uid = Map.get(ctx, :device_uid)
    if_index = Map.get(ctx, :if_index)
    metric_name = Map.get(ctx, :metric_name)
    snmp? = Map.get(ctx, :snmp?, false)
    absolute = anomaly_metric_time_range(ctx, event)

    # Prefer a wide relative window first (reliable), then absolute event window.
    time_windows = [absolute, "last_24h", "last_6h"] |> Enum.reject(&is_nil/1) |> Enum.uniq()

    for_result =
      for time_range <- time_windows,
          query <-
            build_anomaly_metric_query_variants(device_uid, if_index, metric_name, snmp?, time_range),
          is_binary(query) do
        query
      end

    Enum.uniq(for_result)
  end

  defp build_anomaly_metric_query_variants(device_uid, if_index, metric_name, snmp?, time_range)
       when is_binary(device_uid) and device_uid != "" and is_binary(time_range) do
    escaped_uid = escape_value(device_uid)
    metric_filter = metric_name_filter(metric_name)

    snmp_queries =
      if snmp? and is_integer(if_index) and if_index > 0 do
        base =
          "in:snmp_metrics device_id:\"#{escaped_uid}\" if_index:#{if_index} time:#{time_range}"

        [
          # Rate series (preferred for counters like ifOutOctets)
          Enum.join(
            Enum.reject(
              [
                base,
                metric_filter,
                "bucket:5m",
                "agg:rate",
                "series:metric_name",
                "limit:#{@snmp_metrics_limit}"
              ],
              &is_nil/1
            ),
            " "
          ),
          # Avg fallback without rate transform
          Enum.join(
            Enum.reject(
              [
                base,
                metric_filter,
                "bucket:5m",
                "agg:avg",
                "series:metric_name",
                "limit:#{@snmp_metrics_limit}"
              ],
              &is_nil/1
            ),
            " "
          ),
          # Raw points for the specific metric
          if metric_filter do
            "#{base} #{metric_filter} sort:timestamp:asc limit:#{@snmp_metrics_limit}"
          end
        ]
      else
        []
      end

    generic_queries =
      if is_binary(metric_name) and metric_name != "" do
        [
          Enum.join(
            [
              "in:timeseries_metrics",
              "device_id:\"#{escaped_uid}\"",
              ~s(metric_name:"#{escape_value(metric_name)}"),
              "time:#{time_range}",
              "bucket:5m",
              "agg:avg",
              "series:metric_name",
              "limit:#{@snmp_metrics_limit}"
            ],
            " "
          ),
          Enum.join(
            [
              "in:timeseries_metrics",
              "device_id:\"#{escaped_uid}\"",
              ~s(metric_name:"#{escape_value(metric_name)}"),
              "time:#{time_range}",
              "sort:timestamp:asc",
              "limit:#{@snmp_metrics_limit}"
            ],
            " "
          )
        ]
      else
        []
      end

    Enum.reject(snmp_queries ++ generic_queries, &is_nil/1)
  end

  defp build_anomaly_metric_query_variants(_device_uid, _if_index, _metric_name, _snmp?, _time_range), do: []

  defp metric_name_filter(metric_name) when is_binary(metric_name) and metric_name != "" do
    ~s(metric_name:"#{escape_value(metric_name)}")
  end

  defp metric_name_filter(_), do: nil

  defp anomaly_panel_assigns(panel, chart_focus, timezone) when is_map(panel) do
    assigns =
      panel
      |> Map.get(:assigns, %{})
      |> Map.put(:compact, true)
      |> Map.put(:timezone, timezone)

    if is_map(chart_focus) do
      Map.put(assigns, :chart_focus, chart_focus)
    else
      assigns
    end
  end

  defp anomaly_panel_assigns(_panel, _chart_focus, timezone), do: %{compact: true, timezone: timezone}

  defp anomaly_metric_time_range(ctx, event) do
    center = Map.get(ctx, :event_time) || event_time_from_event(event)

    case center do
      %DateTime{} = dt ->
        start_dt = DateTime.add(dt, -@anomaly_chart_side_seconds, :second)
        end_dt = DateTime.add(dt, @anomaly_chart_side_seconds, :second)
        "[#{DateTime.to_iso8601(start_dt)},#{DateTime.to_iso8601(end_dt)}]"

      _ ->
        "last_24h"
    end
  end

  defp anomaly_chart_focus(event, finding, series_key, metric_name, event_time) do
    case event_time do
      %DateTime{} = dt ->
        %{
          timestamp: dt,
          label: metric_name || map_value(finding, "state") || "Anomaly event",
          severity: Map.get(event, "severity") || Map.get(event, "severity_id"),
          series: metric_name || series_key,
          series_key: series_key,
          metric_name: metric_name,
          before_seconds: @anomaly_chart_side_seconds,
          after_seconds: @anomaly_chart_side_seconds
        }

      _ ->
        nil
    end
  end

  defp snmp_like_anomaly?(metric_class, metric_name, if_index, series_key, interface_label) do
    text =
      [metric_class, metric_name, series_key, interface_label]
      |> Enum.reject(&is_nil/1)
      |> Enum.map_join(" ", &to_string/1)
      |> String.downcase()

    is_integer(if_index) or
      String.contains?(text, "snmp") or
      String.contains?(text, "interface") or
      String.contains?(text, "if_") or
      String.contains?(text, "ifhc") or
      String.contains?(text, "ifinoctets") or
      String.contains?(text, "ifoutoctets") or
      String.contains?(text, "ifout") or
      String.contains?(text, "ifin")
  end

  defp anomaly_metric_class(decoded) do
    class = AnomalySeriesKey.component(decoded, "class")
    family = AnomalySeriesKey.component(decoded, "family")

    cond do
      is_binary(class) and is_binary(family) -> "#{class}/#{family}"
      is_binary(class) -> class
      is_binary(family) -> family
      true -> nil
    end
  end

  defp anomaly_interface_label(decoded, finding, dimensions, if_index) do
    label =
      first_present([
        AnomalySeriesKey.tag(decoded, "label"),
        AnomalySeriesKey.tag(decoded, "if_name"),
        AnomalySeriesKey.tag(decoded, "interface_name"),
        map_value(finding, "interface_name"),
        map_value(finding, "if_name"),
        map_value(dimensions, "resource_label"),
        nested_value(finding, ["source_identity", "label"]),
        nested_value(finding, ["source_identity", "if_name"])
      ])

    cond do
      is_binary(label) and is_integer(if_index) and not String.contains?(label, "ifIndex") ->
        "#{label} / ifIndex #{if_index}"

      is_binary(label) ->
        label

      is_integer(if_index) ->
        "ifIndex #{if_index}"

      true ->
        nil
    end
  end

  defp parse_if_index(value) when is_integer(value) and value > 0, do: value

  defp parse_if_index(value) when is_float(value) and value > 0 do
    trunc(value)
  end

  defp parse_if_index(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {n, ""} when n > 0 -> n
      _ -> nil
    end
  end

  defp parse_if_index(_), do: nil

  defp first_present(values) when is_list(values) do
    Enum.find_value(values, fn
      nil -> nil
      false -> nil
      value when is_binary(value) -> if String.trim(value) == "", do: nil, else: value
      value -> value
    end)
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value) when is_binary(value), do: if(String.trim(value) == "", do: nil, else: value)
  defp blank_to_nil(value), do: value

  attr(:event, :map, required: true)
  attr(:anomaly_context, :map, default: nil)
  attr(:metric_panels, :list, default: [])
  attr(:metrics_loading, :boolean, default: false)
  attr(:metrics_error, :any, default: nil)
  attr(:timezone, :string, required: true)

  defp anomaly_detection_summary(assigns) do
    finding = anomaly_detection_payload(assigns.event)
    finding_info = nested_map(assigns.event, ["metadata", "finding_info"])
    series_key = map_value(finding, "series_key")
    ctx = assigns.anomaly_context || %{}

    assigns =
      assigns
      |> assign(:finding, finding)
      |> assign(:finding_info, finding_info)
      |> assign(:series_key, series_key)
      |> assign(:series_display, AnomalySeriesKey.display(series_key) || series_key)
      |> assign(:ctx, ctx)
      |> assign(:chart_focus, Map.get(ctx, :chart_focus))

    ~H"""
    <div class="overflow-hidden rounded-sr-surface border border-amber-500/25 bg-amber-500/5 shadow-sr-surface">
      <div class="flex items-start justify-between gap-4 border-b border-amber-500/15 px-4 py-3 sm:px-5">
        <div class="min-w-0">
          <span class="font-sans text-xs font-medium uppercase tracking-wide text-amber-600 dark:text-amber-400 block mb-1">
            Anomaly detection finding
          </span>
          <h2 class="text-base font-semibold leading-tight text-sr-ink sm:text-lg">
            {map_value(@finding_info, "title") || Map.get(@event, "message") ||
              "Anomalous metric behavior detected"}
          </h2>
        </div>
        <.severity_badge value={Map.get(@event, "severity")} />
      </div>

      <div class="grid grid-cols-1 gap-4 p-4 sm:grid-cols-2 sm:p-5">
        <.finding_fact label="Series" value={@series_display} title={@series_key} />
        <.finding_fact
          label="Metric"
          value={Map.get(@ctx, :metric_name) || map_value(@finding, "metric_name")}
          mono
        />
        <.finding_fact
          label="Metric class"
          value={map_value(@finding, "metric_class") || Map.get(@ctx, :metric_class)}
        />
        <.finding_fact label="Interface" value={Map.get(@ctx, :interface_label)} mono />
        <.finding_fact label="State" value={map_value(@finding, "state")} />
        <.finding_fact label="Score" value={map_value(@finding, "score")} mono />
        <.finding_fact label="Reason" value={map_value(@finding, "reason")} />
        <.finding_fact label="Finding UID" value={map_value(@finding_info, "uid")} mono />
      </div>

      <div
        :if={
          Map.get(@ctx, :device_href) || Map.get(@ctx, :interfaces_href) ||
            Map.get(@ctx, :snmp_metrics_href)
        }
        class="flex flex-wrap gap-2 border-t border-amber-500/15 px-4 py-3 sm:px-5"
      >
        <.ui_button
          :if={Map.get(@ctx, :device_href)}
          navigate={Map.get(@ctx, :device_href)}
          size="sm"
          variant="primary"
        >
          Open device
        </.ui_button>
        <.ui_button
          :if={Map.get(@ctx, :interfaces_href)}
          navigate={Map.get(@ctx, :interfaces_href)}
          size="sm"
          variant="outline"
        >
          Device interfaces
        </.ui_button>
        <.ui_button
          :if={Map.get(@ctx, :snmp_metrics_href)}
          navigate={Map.get(@ctx, :snmp_metrics_href)}
          size="sm"
          variant="outline"
        >
          SNMP metrics for interface
        </.ui_button>
      </div>

      <div class="border-t border-amber-500/15 px-4 py-4 sm:px-5">
        <div class="mb-2 flex flex-wrap items-center justify-between gap-2">
          <div>
            <div class="text-xs font-semibold uppercase tracking-wide text-sr-muted">
              Metric context
            </div>
            <p class="mt-0.5 text-xs text-sr-muted">
              Vertical marker is this event time. Chart is scoped to the series (±2h).
            </p>
          </div>
          <span :if={@metrics_loading} class="text-xs text-sr-muted">Loading metrics…</span>
        </div>

        <div
          :if={is_binary(@metrics_error)}
          class="rounded-lg border border-warning/30 bg-warning/10 p-3 text-xs text-warning"
        >
          {@metrics_error}
        </div>

        <div
          :if={not @metrics_loading and @metric_panels == [] and is_nil(@metrics_error)}
          class="rounded-lg border border-sr-line/70 bg-sr-surface/50 p-4 text-sm text-sr-muted"
        >
          No metric series loaded for this finding yet.
          <span :if={Map.get(@ctx, :snmp_metrics_href)}>
            Use the SNMP metrics link above to open the full series.
          </span>
        </div>

        <div :if={@metric_panels != []} class="space-y-3">
          <%= for {panel, idx} <- Enum.with_index(@metric_panels) do %>
            <.live_component
              module={panel.plugin}
              id={"event-anomaly-metric-#{idx}"}
              title={Map.get(panel, :title) || "Metric series"}
              panel_assigns={anomaly_panel_assigns(panel, @chart_focus, @timezone)}
            />
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  attr(:event, :map, required: true)
  attr(:timezone, :string, required: true)

  defp capacity_forecast_summary(assigns) do
    forecast = capacity_forecast_payload(assigns.event)

    assigns =
      assigns
      |> assign(:forecast, forecast)
      |> assign(:resource, map_value(forecast, "resource_label") || map_value(forecast, "resource_key"))

    ~H"""
    <div class="overflow-hidden rounded-sr-surface border border-rose-500/25 bg-rose-500/5 shadow-sr-surface">
      <div class="flex items-start justify-between gap-4 border-b border-rose-500/15 px-4 py-3 sm:px-5">
        <div class="min-w-0">
          <span class="font-sans text-xs font-medium uppercase tracking-wide text-rose-600 dark:text-rose-400 block mb-1">
            Capacity forecast
          </span>
          <h2 class="text-base font-semibold leading-tight text-sr-ink sm:text-lg">
            {Map.get(@event, "message") || "Resource projected to cross capacity threshold"}
          </h2>
        </div>
        <.severity_badge value={Map.get(@event, "severity")} />
      </div>

      <div class="grid grid-cols-1 gap-4 p-4 sm:grid-cols-2 sm:p-5">
        <.finding_fact label="Resource" value={@resource} mono />
        <.finding_fact label="Metric" value={map_value(@forecast, "metric_name")} />
        <.finding_fact label="Status" value={map_value(@forecast, "status")} />
        <.finding_fact label="Current" value={map_value(@forecast, "current_value")} mono />
        <.finding_fact label="Projected" value={map_value(@forecast, "projected_value")} mono />
        <.finding_fact label="Threshold" value={map_value(@forecast, "exhaustion_threshold")} mono />
        <.finding_time_fact
          id="event-projected-exhaustion-time"
          label="Projected Exhaustion"
          value={map_value(@forecast, "projected_exhaustion_at")}
          timezone={@timezone}
        />
        <.finding_fact label="Confidence" value={map_value(@forecast, "confidence")} mono />
      </div>
    </div>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :any, default: nil)
  attr(:title, :any, default: nil)
  attr(:mono, :boolean, default: false)

  defp finding_fact(assigns) do
    assigns = assign(assigns, :title_value, display_value(assigns.title || assigns.value))

    ~H"""
    <div class="min-w-0">
      <span class="font-sans text-xs font-medium uppercase tracking-wide text-sr-muted block mb-1">
        {@label}
      </span>
      <span
        class={[
          "text-sm break-words text-sr-ink",
          if(@mono, do: "font-mono break-all", else: nil),
          if(blank?(@value), do: "text-sr-muted", else: nil)
        ]}
        title={@title_value}
      >
        {display_value(@value)}
      </span>
    </div>
    """
  end

  attr(:id, :string, required: true)
  attr(:label, :string, required: true)
  attr(:value, :any, default: nil)
  attr(:timezone, :string, required: true)

  defp finding_time_fact(assigns) do
    ~H"""
    <div :if={not blank?(@value)} class="min-w-0">
      <span class="font-sans text-xs font-medium uppercase tracking-wide text-sr-muted block mb-1">
        {@label}
      </span>
      <.user_time
        id={@id}
        value={@value}
        timezone={@timezone}
        style={:full}
        fallback="—"
        class="break-all font-mono text-sm text-sr-ink"
      />
    </div>
    """
  end

  attr(:event, :map, required: true)

  defp falco_runtime_summary(assigns) do
    diagnostics = falco_diagnostics(assigns.event)

    assigns =
      assigns
      |> assign(:diagnostics, diagnostics)
      |> assign(:rule, diagnostic_value(diagnostics, ["rule"]))
      |> assign(:host, diagnostic_value(diagnostics, ["host"]))
      |> assign(:process, diagnostic_value(diagnostics, ["process"]))
      |> assign(:parent_process, diagnostic_value(diagnostics, ["parent_process"]))
      |> assign(:user, diagnostic_value(diagnostics, ["user"]))
      |> assign(:container, diagnostic_value(diagnostics, ["container"]))
      |> assign(:kubernetes, diagnostic_value(diagnostics, ["kubernetes"]))
      |> assign(:attribution, diagnostic_value(diagnostics, ["attribution"]))

    ~H"""
    <div class="overflow-hidden rounded-sr-surface border border-rose-500/25 bg-rose-500/5 shadow-sr-surface">
      <div class="flex items-start justify-between gap-4 border-b border-rose-500/15 px-4 py-3 sm:px-5">
        <div class="min-w-0">
          <span class="font-sans text-xs font-medium uppercase tracking-wide text-rose-600 dark:text-rose-400 block mb-1">
            Falco runtime event
          </span>
          <h2 class="text-base font-semibold leading-tight text-sr-ink sm:text-lg">
            {diagnostic_value(@rule, ["name"]) || Map.get(@event, "message") || "Falco rule matched"}
          </h2>
        </div>
        <.severity_badge value={diagnostic_value(@rule, ["priority"]) || Map.get(@event, "severity")} />
      </div>

      <div class="grid grid-cols-1 gap-4 p-4 sm:grid-cols-2 sm:p-5">
        <.diagnostic_fact label="Rule" value={diagnostic_value(@rule, ["name"])} />
        <.diagnostic_fact label="Host" value={diagnostic_value(@host, ["name"])} mono />
        <.diagnostic_fact label="Process" value={diagnostic_value(@process, ["name"])} />
        <.diagnostic_fact label="Parent" value={diagnostic_value(@parent_process, ["name"])} />
        <.diagnostic_fact label="Command" value={diagnostic_value(@process, ["command"])} mono />
        <.diagnostic_fact label="Working Dir" value={diagnostic_value(@process, ["cwd"])} mono />
        <.diagnostic_fact label="Executable" value={diagnostic_value(@process, ["executable"])} mono />
        <.diagnostic_fact
          label="Executable Flags"
          value={diagnostic_value(@process, ["executable_flags"])}
          mono
        />
        <.diagnostic_fact label="User" value={diagnostic_value(@user, ["name"])} />
        <.diagnostic_fact label="Container" value={container_display(@container)} mono />
        <.diagnostic_fact label="Image" value={image_display(@container)} mono />
        <.diagnostic_fact
          label="Kubernetes Namespace"
          value={diagnostic_value(@kubernetes, ["namespace"])}
        />
        <.diagnostic_fact label="Kubernetes Pod" value={diagnostic_value(@kubernetes, ["pod"])} />
        <.diagnostic_fact
          label="Attribution"
          value={attribution_display(@attribution)}
        />
      </div>
    </div>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :any, default: nil)
  attr(:mono, :boolean, default: false)

  defp diagnostic_fact(assigns) do
    ~H"""
    <div class="min-w-0">
      <span class="font-sans text-xs font-medium uppercase tracking-wide text-sr-muted block mb-1">
        {@label}
      </span>
      <span class={[
        "text-sm break-words text-sr-ink",
        if(@mono, do: "font-mono", else: nil),
        if(blank?(@value), do: "text-sr-muted", else: nil)
      ]}>
        {display_diagnostic_value(@value)}
      </span>
    </div>
    """
  end

  attr(:event, :map, required: true)

  defp waf_finding_summary(assigns) do
    assigns =
      assigns
      |> assign(:waf, waf_payload(assigns.event))
      |> assign(:src_ip, waf_src_ip(assigns.event))

    ~H"""
    <div class="overflow-hidden rounded-sr-surface border border-rose-500/25 bg-rose-500/5 shadow-sr-surface">
      <div class="flex items-start justify-between gap-4 border-b border-rose-500/15 px-4 py-3 sm:px-5">
        <div class="min-w-0">
          <span class="font-sans text-xs font-medium uppercase tracking-wide text-rose-600 dark:text-rose-400 block mb-1">
            WAF finding
          </span>
          <h2 class="text-base font-semibold leading-tight text-sr-ink sm:text-lg">
            {waf_value(@waf, "rule_message") || Map.get(@event, "message") || "Coraza rule matched"}
          </h2>
        </div>
        <.severity_badge value={waf_value(@waf, "rule_severity") || Map.get(@event, "severity")} />
      </div>

      <div class="grid grid-cols-1 gap-4 p-4 sm:grid-cols-2 sm:p-5">
        <.waf_fact label="Client IP" value={@src_ip} mono />
        <.waf_fact label="Rule ID" value={waf_value(@waf, "rule_id")} mono />
        <.waf_fact label="Request Path" value={waf_value(@waf, "request_path")} mono />
        <.waf_fact label="Request ID" value={waf_value(@waf, "request_id")} mono />
        <.waf_fact label="Policy" value={waf_value(@waf, "waf_policy")} />
        <.waf_fact label="Source" value={waf_value(@waf, "source")} />
      </div>
    </div>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :any, default: nil)
  attr(:mono, :boolean, default: false)

  defp waf_fact(assigns) do
    ~H"""
    <div class="min-w-0">
      <span class="font-sans text-xs font-medium uppercase tracking-wide text-sr-muted block mb-1">
        {@label}
      </span>
      <span class={[
        "text-sm break-words text-sr-ink",
        if(@mono, do: "font-mono", else: nil),
        if(blank?(@value), do: "text-sr-muted", else: nil)
      ]}>
        {display_value(@value)}
      </span>
    </div>
    """
  end

  attr(:event, :map, required: true)
  attr(:timezone, :string, required: true)

  @additional_timestamp_keys MapSet.new(~w(updated_at))

  defp event_details(assigns) do
    # Scalars only — no raw JSON blobs. Nested payloads live in context or raw toggle.
    skip =
      MapSet.new(~w(
        id event_id severity severity_id time event_timestamp timestamp host source
        short_message message activity_name activity_id class_uid category_uid type_uid
        class_name category_name type_name log_provider log_name log_level level
        status status_detail status_id status_code created_at actor raw_data unmapped
        metadata observables device src_endpoint dst_endpoint enrichment
      ))

    facts =
      assigns.event
      |> Enum.flat_map(fn
        {key, value} when is_binary(key) ->
          if MapSet.member?(skip, key) do
            []
          else
            case value do
              v when v in [nil, "", []] ->
                []

              %{} = map ->
                if empty_structure?(map), do: [], else: []

              list when is_list(list) ->
                []

              v when is_boolean(v) ->
                [%{label: field_label(key), value: to_string(v), mono?: false}]

              v when is_number(v) ->
                [%{label: field_label(key), value: to_string(v), mono?: true}]

              v when is_binary(v) ->
                if looks_like_json?(v) do
                  []
                else
                  [
                    %{
                      key: key,
                      label: field_label(key),
                      value: v,
                      mono?: String.length(v) > 24,
                      timestamp?: MapSet.member?(@additional_timestamp_keys, key)
                    }
                  ]
                end

              _ ->
                []
            end
          end

        _ ->
          []
      end)
      |> Enum.sort_by(& &1.label)

    assigns = assign(assigns, :facts, facts)

    ~H"""
    <div
      :if={@facts != []}
      class="overflow-hidden rounded-sr-surface border border-sr-line bg-sr-surface shadow-sr-surface"
    >
      <div class="border-b border-sr-line bg-sr-subtle/30 px-4 py-2.5">
        <span class="font-sans text-xs font-medium uppercase tracking-wide text-sr-muted">
          Additional fields
        </span>
      </div>
      <div class="grid grid-cols-1 divide-y divide-sr-line sm:grid-cols-2 sm:divide-x sm:divide-y-0 lg:grid-cols-3">
        <div
          :for={fact <- @facts}
          class="flex min-w-0 flex-col gap-1 px-4 py-3 even:bg-sr-subtle/15 sm:even:bg-transparent sm:[&:nth-child(2n)]:bg-sr-subtle/10 lg:[&:nth-child(2n)]:bg-transparent lg:[&:nth-child(3n+2)]:bg-sr-subtle/10"
        >
          <span class="font-sans text-xs font-medium uppercase tracking-wide text-sr-muted">
            {fact.label}
          </span>
          <.user_time
            :if={Map.get(fact, :timestamp?, false)}
            id={"event-additional-#{String.replace(fact.key, "_", "-")}-time"}
            value={fact.value}
            timezone={@timezone}
            style={:full}
            fallback="—"
            class="break-all font-mono text-[13px] tracking-tight text-sr-ink"
          />
          <span
            :if={not Map.get(fact, :timestamp?, false)}
            class={[
              "break-all text-sm text-sr-ink",
              fact.mono? && "font-mono text-[13px] tracking-tight"
            ]}
          >
            {fact.value}
          </span>
        </div>
      </div>
    </div>
    """
  end

  attr :event, :map, required: true
  attr :open?, :boolean, default: false

  defp event_raw_toggle(assigns) do
    json =
      case assigns.event do
        %{} = event ->
          event
          |> Map.delete("source_device_uid")
          |> Jason.encode!(pretty: true)

        _ ->
          ""
      end

    assigns = assign(assigns, :json, json)

    ~H"""
    <div class="overflow-hidden rounded-sr-surface border border-dashed border-sr-line/80 bg-sr-surface/60">
      <div class="flex flex-wrap items-center justify-between gap-2 px-4 py-2.5">
        <span class="font-sans text-xs font-medium text-sr-muted">
          Technical payload
        </span>
        <div class="flex items-center gap-1.5">
          <.ui_button
            :if={@open?}
            type="button"
            size="xs"
            variant="ghost"
            phx-click="copy_json"
          >
            Copy JSON
          </.ui_button>
          <.ui_button type="button" size="xs" variant="outline" phx-click="toggle_raw_json">
            {if @open?, do: "Hide raw event", else: "Show raw event"}
          </.ui_button>
        </div>
      </div>
      <div :if={@open?} class="border-t border-sr-line px-4 py-3">
        <pre class="max-h-80 overflow-auto rounded-sr-control border border-sr-line bg-sr-subtle/30 p-3 font-mono text-[11px] leading-relaxed text-sr-ink/90 selection:bg-sr-brand/25">{@json}</pre>
      </div>
    </div>
    """
  end

  defp looks_like_json?(value) when is_binary(value) do
    trimmed = String.trim(value)
    String.starts_with?(trimmed, "{") or String.starts_with?(trimmed, "[")
  end

  defp looks_like_json?(_), do: false

  defp empty_structure?(%{} = map) do
    map
    |> Map.values()
    |> Enum.all?(fn
      nil -> true
      "" -> true
      %{} = nested -> empty_structure?(nested)
      list when is_list(list) -> list == [] or Enum.all?(list, &empty_structure?/1)
      _ -> false
    end)
  end

  defp empty_structure?(list) when is_list(list) do
    list == [] or Enum.all?(list, &empty_structure?/1)
  end

  defp empty_structure?(nil), do: true
  defp empty_structure?(""), do: true
  defp empty_structure?(_), do: false

  attr(:value, :any, default: nil)

  defp severity_badge(assigns) do
    variant = severity_variant(assigns.value)
    label = severity_label(assigns.value)

    assigns = assigns |> assign(:variant, variant) |> assign(:label, label)

    ~H"""
    <.ui_badge variant={@variant} size="sm">{@label}</.ui_badge>
    """
  end

  defp severity_variant(value) do
    case normalize_severity(value) do
      s when s in ["critical", "fatal", "error"] -> "error"
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

  defp entry_id(event, idx) do
    case Map.get(event, "id") || Map.get(event, "event_id") do
      <<_::binary-size(16)>> = bin -> uuid_to_string(bin)
      id when is_binary(id) and id != "" -> id
      _ -> "row-#{idx}"
    end
  end

  defp uuid_to_string(<<a::binary-size(4), b::binary-size(2), c::binary-size(2), d::binary-size(2), e::binary-size(6)>>) do
    Base.encode16(a, case: :lower) <>
      "-" <>
      Base.encode16(b, case: :lower) <>
      "-" <>
      Base.encode16(c, case: :lower) <>
      "-" <>
      Base.encode16(d, case: :lower) <>
      "-" <>
      Base.encode16(e, case: :lower)
  end

  defp uuid_to_string(other), do: to_string(other)

  defp message_preview(body, max \\ 72)

  defp message_preview(body, max) when is_binary(body) do
    body = body |> String.trim() |> String.replace(~r/\s+/, " ")

    cond do
      body == "" -> "—"
      String.length(body) <= max -> body
      true -> String.slice(body, 0, max - 1) <> "…"
    end
  end

  defp message_preview(_, _), do: "—"

  defp event_message(event) when is_map(event) do
    case Map.get(event, "short_message") || Map.get(event, "message") do
      v when is_binary(v) -> v
      _ -> ""
    end
  end

  defp event_message(_), do: ""

  defp event_headline(event) when is_map(event) do
    msg = event_message(event)

    cond do
      is_binary(msg) and String.trim(msg) != "" ->
        msg
        |> String.trim()
        |> String.replace(~r/\s+/, " ")
        |> then(fn s ->
          if String.length(s) > 120, do: String.slice(s, 0, 119) <> "…", else: s
        end)

      is_binary(Map.get(event, "activity_name")) and Map.get(event, "activity_name") != "" ->
        Map.get(event, "activity_name")

      true ->
        nil
    end
  end

  defp event_headline(_), do: nil

  defp event_source_kind(event) when is_map(event) do
    log_name = Map.get(event, "log_name")
    provider = Map.get(event, "log_provider")

    cond do
      anomaly_finding?(event) ->
        "anomaly"

      capacity_forecast_event?(event) ->
        "capacity"

      waf_event?(event) ->
        "waf"

      falco_event?(event) ->
        "falco"

      is_binary(log_name) and String.contains?(log_name, "oban") ->
        "oban"

      is_binary(provider) and provider != "" ->
        provider

      is_binary(Map.get(event, "activity_name")) and Map.get(event, "activity_name") != "" ->
        Map.get(event, "activity_name")

      true ->
        "event"
    end
  end

  defp event_source_kind(_), do: "event"

  defp nested_string(map, path) when is_map(map) and is_list(path) do
    case nested_value(map, path) do
      v when is_binary(v) and v != "" -> v
      v when is_number(v) or is_boolean(v) -> to_string(v)
      _ -> nil
    end
  end

  defp nested_string(_, _), do: nil

  defp shorten_module(nil), do: nil
  defp shorten_module(""), do: nil

  defp shorten_module(name) when is_binary(name) do
    parts = String.split(name, ".")

    if length(parts) > 3 do
      parts |> Enum.take(-3) |> Enum.join(".")
    else
      name
    end
  end

  defp shorten_module(other), do: to_string(other)

  defp blank_value?(nil), do: true
  defp blank_value?(""), do: true
  defp blank_value?("—"), do: true
  defp blank_value?(_), do: false

  @device_ip_paths ~w(
    metadata.security_signal.diagnostics.network.source_ip
    metadata.security_signal.diagnostics.network.destination_ip
    src_endpoint.ip
    dst_endpoint.ip
  )

  @netflow_src_ip_paths ~w(
    src_endpoint.ip
    metadata.security_signal.diagnostics.network.source_ip
  )

  @netflow_dst_ip_paths ~w(
    dst_endpoint.ip
    metadata.security_signal.diagnostics.network.destination_ip
  )

  @netflow_src_port_paths ~w(
    src_endpoint.port
    metadata.security_signal.diagnostics.network.source_port
  )

  @netflow_dst_port_paths ~w(
    dst_endpoint.port
    metadata.security_signal.diagnostics.network.destination_port
  )

  @netflow_time_window "last_24h"

  defp build_signal_display(event, scope) when is_map(event) do
    case SignalDisplay.render_record(event) do
      {:ok, widgets} ->
        widgets =
          widgets
          |> Enum.map(&add_device_ip_links(&1, scope))
          |> Enum.map(&add_netflow_endpoint_links/1)
          |> maybe_append_related_netflow_fact(event)
          # Drop empty json sections; non-empty ones render as fact grids in the UI.
          |> Enum.reject(fn
            %{type: :json_section, sections: sections} -> sections == []
            %{type: :summary} = w -> blank?(Map.get(w, :message)) and blank?(Map.get(w, :title))
            _ -> false
          end)

        if widgets == [], do: nil, else: widgets

      :error ->
        nil
    end
  end

  defp build_signal_display(_event, _scope), do: nil

  defp add_device_ip_links(%{type: type, fields: fields} = widget, scope)
       when type in [:facts, :timeline] and is_list(fields) do
    Map.put(widget, :fields, Enum.map(fields, &add_device_ip_link(&1, scope)))
  end

  defp add_device_ip_links(widget, _scope), do: widget

  defp add_device_ip_link(%{path: path, value: ip} = field, scope) when path in @device_ip_paths and is_binary(ip) do
    if valid_ip?(ip) do
      field
      |> Map.put(:href, device_ip_path(ip, scope))
      |> Map.put(:href_label, "Open device inventory for #{ip}")
    else
      field
    end
  end

  defp add_device_ip_link(field, _scope), do: field

  # Netflow links for ports (and IPs that didn't already resolve to a device link).
  defp add_netflow_endpoint_links(%{type: type, fields: fields} = widget)
       when type in [:facts, :timeline] and is_list(fields) do
    Map.put(widget, :fields, Enum.map(fields, &add_netflow_endpoint_link/1))
  end

  defp add_netflow_endpoint_links(widget), do: widget

  defp add_netflow_endpoint_link(%{path: path, value: value} = field)
       when path in @netflow_src_port_paths or path in @netflow_dst_port_paths do
    case normalize_port(value) do
      port when is_integer(port) and port > 0 ->
        field_name = if path in @netflow_src_port_paths, do: "src_endpoint_port", else: "dst_endpoint_port"

        field
        |> Map.put(:href, netflow_observability_path([{field_name, port}]))
        |> Map.put(:href_label, "Open netflow for #{field_name} #{port}")

      _ ->
        field
    end
  end

  defp add_netflow_endpoint_link(%{path: path, value: ip, href: nil} = field)
       when path in @netflow_src_ip_paths or path in @netflow_dst_ip_paths do
    if valid_ip?(to_string(ip)) do
      field_name = if path in @netflow_src_ip_paths, do: "src_endpoint_ip", else: "dst_endpoint_ip"

      field
      |> Map.put(:href, netflow_observability_path([{field_name, to_string(ip)}]))
      |> Map.put(:href_label, "Open netflow for #{field_name} #{ip}")
    else
      field
    end
  end

  # Prefer device inventory when we already attached an inventory href for the IP.
  defp add_netflow_endpoint_link(field), do: field

  defp maybe_append_related_netflow_fact(widgets, event) when is_list(widgets) do
    filters = netflow_filters_from_event(event)

    if filters == [] do
      widgets
    else
      related = %{
        label: "Related netflow",
        path: "related_netflow",
        value: netflow_filters_label(filters),
        href: netflow_observability_path(filters),
        href_label: "Open related netflow conversation"
      }

      case Enum.split_with(widgets, &(&1.type == :facts)) do
        {[], rest} ->
          [%{type: :facts, fields: [related]} | rest]

        {[facts | more_facts], rest} ->
          fields = Map.get(facts, :fields, []) ++ [related]
          [Map.put(facts, :fields, fields) | more_facts] ++ rest
      end
    end
  end

  defp maybe_append_related_netflow_fact(widgets, _event), do: widgets

  defp netflow_filters_from_event(event) when is_map(event) do
    Enum.flat_map(
      [
        {"src_endpoint_ip", dig_event_value(event, ["src_endpoint", "ip"])},
        {"src_endpoint_port", dig_event_value(event, ["src_endpoint", "port"])},
        {"dst_endpoint_ip", dig_event_value(event, ["dst_endpoint", "ip"])},
        {"dst_endpoint_port", dig_event_value(event, ["dst_endpoint", "port"])}
      ],
      fn
        {field, value} when field in ["src_endpoint_ip", "dst_endpoint_ip"] ->
          if is_binary(value) and valid_ip?(value), do: [{field, value}], else: []

        {field, value} when field in ["src_endpoint_port", "dst_endpoint_port"] ->
          case normalize_port(value) do
            port when is_integer(port) and port > 0 -> [{field, port}]
            _ -> []
          end
      end
    )
  end

  defp netflow_filters_from_event(_event), do: []

  defp netflow_filters_label(filters) do
    Enum.map_join(filters, " · ", fn
      {"src_endpoint_ip", ip} -> "src #{ip}"
      {"dst_endpoint_ip", ip} -> "dst #{ip}"
      {"src_endpoint_port", port} -> "sport #{port}"
      {"dst_endpoint_port", port} -> "dport #{port}"
      {field, value} -> "#{field}=#{value}"
    end)
  end

  defp netflow_observability_path(filters) when is_list(filters) and filters != [] do
    tokens =
      Enum.map(filters, fn
        {field, value} when is_binary(value) -> ~s|#{field}:"#{escape_value(value)}"|
        {field, value} when is_integer(value) -> "#{field}:#{value}"
      end)

    query =
      Enum.join(
        ["in:flows"] ++ tokens ++ ["time:#{@netflow_time_window}", "sort:time:desc"],
        " "
      )

    ~p"/observability/netflows?#{%{q: query}}"
  end

  defp dig_event_value(map, [key]) when is_map(map) do
    Map.get(map, key) || Map.get(map, endpoint_atom_key(key))
  end

  defp dig_event_value(map, [key | rest]) when is_map(map) do
    case Map.get(map, key) || Map.get(map, endpoint_atom_key(key)) do
      %{} = nested -> dig_event_value(nested, rest)
      _ -> nil
    end
  end

  defp dig_event_value(_map, _path), do: nil

  # Avoid String.to_atom/1 on arbitrary paths; only known endpoint keys.
  defp endpoint_atom_key("src_endpoint"), do: :src_endpoint
  defp endpoint_atom_key("dst_endpoint"), do: :dst_endpoint
  defp endpoint_atom_key("ip"), do: :ip
  defp endpoint_atom_key("port"), do: :port
  defp endpoint_atom_key(_), do: :__unknown__

  defp normalize_port(value) when is_integer(value) and value > 0 and value <= 65_535, do: value

  defp normalize_port(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {port, ""} when port > 0 and port <= 65_535 -> port
      _ -> nil
    end
  end

  defp normalize_port(_), do: nil

  defp device_ip_path(ip, scope) do
    case lookup_device_by_ip(ip, scope) do
      %Device{uid: uid} when is_binary(uid) and uid != "" ->
        ~p"/devices/#{uid}"

      _ ->
        ~p"/devices?#{%{q: ~s(in:devices ip:\"#{escape_value(ip)}\"), limit: 50}}"
    end
  end

  defp lookup_device_by_ip(_ip, nil), do: nil

  defp lookup_device_by_ip(ip, scope) do
    case Device.get_by_ip(ip, false, scope: scope) do
      {:ok, [%Device{} = device | _]} -> device
      {:ok, %{results: [%Device{} = device | _]}} -> device
      _ -> nil
    end
  end

  defp valid_ip?(ip) when is_binary(ip) do
    case :inet.parse_address(String.to_charlist(String.trim(ip))) do
      {:ok, _address} -> true
      {:error, _reason} -> false
    end
  end

  defp valid_ip?(_), do: false

  defp event_timestamp_value(event) do
    Map.get(event, "time") || Map.get(event, "event_timestamp") || Map.get(event, "timestamp")
  end

  defp waf_event?(event) when is_map(event) do
    waf = waf_payload(event)
    signal = security_signal(event)

    Map.get(event, "log_name") == "security.waf.finding" or
      Map.get(signal, "kind") == "waf" or
      log_attribute(event, "event_type") == "waf.finding" or
      meaningful_map?(waf)
  end

  defp waf_event?(_), do: false

  defp falco_event?(event) when is_map(event) do
    signal = get_in(event, ["metadata", "security_signal"]) || %{}
    falco = falco_payload(event)

    Map.get(signal, "source") == "falco" or
      Map.get(signal, "kind") == "runtime" or
      (is_map(falco) and map_size(falco) > 0)
  end

  defp falco_event?(_), do: false

  defp anomaly_finding?(event) when is_map(event) do
    metadata = map_value(event, "metadata") || %{}

    nested_value(metadata, ["service_radar", "source_type"]) == "anomaly_detection" or
      nested_value(metadata, ["security_signal", "source"]) == "anomaly_detection" or
      nested_value(metadata, ["detection_finding", "type"]) == "anomaly" or
      map_value(event, "log_provider") == "anomaly_detection"
  end

  defp anomaly_finding?(_), do: false

  defp capacity_forecast_event?(event) when is_map(event) do
    metadata = map_value(event, "metadata") || %{}
    unmapped = map_value(event, "unmapped") || %{}

    map_value(metadata, "event_type") == "capacity_forecast" or
      map_value(unmapped, "event_type") == "capacity_forecast" or
      map_value(event, "log_provider") == "capacity_forecasting"
  end

  defp capacity_forecast_event?(_), do: false

  defp anomaly_detection_payload(event) when is_map(event) do
    metadata = map_value(event, "metadata") || %{}
    unmapped = map_value(event, "unmapped") || %{}

    map_value(metadata, "detection_finding") ||
      map_value(unmapped, "detection_finding") ||
      map_value(unmapped, "anomaly") ||
      %{}
  end

  defp anomaly_detection_payload(_), do: %{}

  defp capacity_forecast_payload(event) when is_map(event) do
    metadata = map_value(event, "metadata") || %{}
    unmapped = map_value(event, "unmapped") || %{}

    map_value(unmapped, "capacity_forecast") ||
      map_value(metadata, "capacity_forecast") ||
      %{}
  end

  defp capacity_forecast_payload(_), do: %{}

  defp falco_diagnostics(event) when is_map(event) do
    signal = get_in(event, ["metadata", "security_signal"]) || %{}
    falco = falco_payload(event)

    Map.get(signal, "diagnostics") ||
      Map.get(falco, "diagnostics") ||
      %{}
  end

  defp falco_diagnostics(_), do: %{}

  defp falco_payload(event) when is_map(event) do
    unmapped = Map.get(event, "unmapped") || %{}
    attrs = Map.get(unmapped, "log_attributes") || %{}
    attr_falco = Map.get(attrs, "falco") || Map.get(attrs, :falco)

    Map.get(unmapped, "falco") ||
      Map.get(unmapped, :falco) ||
      attr_falco ||
      %{}
  end

  defp falco_payload(_), do: %{}

  defp waf_payload(event) when is_map(event) do
    unmapped = Map.get(event, "unmapped") || %{}
    attrs = Map.get(unmapped, "log_attributes") || %{}

    payload =
      Map.get(unmapped, "waf") ||
        Map.get(unmapped, :waf) ||
        Map.get(attrs, "waf") ||
        Map.get(attrs, :waf)

    meaningful_payload(payload)
  end

  defp waf_payload(_), do: %{}

  defp security_signal(event) when is_map(event) do
    metadata = Map.get(event, "metadata") || Map.get(event, :metadata) || %{}
    signal = Map.get(metadata, "security_signal") || Map.get(metadata, :security_signal) || %{}

    if is_map(signal), do: signal, else: %{}
  end

  defp security_signal(_event), do: %{}

  defp nested_map(map, path) when is_map(map) and is_list(path) do
    case nested_value(map, path) do
      %{} = nested -> nested
      _ -> %{}
    end
  end

  defp nested_map(_, _), do: %{}

  defp nested_value(map, [key]) when is_map(map), do: map_value(map, key)

  defp nested_value(map, [key | rest]) when is_map(map) do
    case map_value(map, key) do
      %{} = nested -> nested_value(nested, rest)
      _ -> nil
    end
  end

  defp nested_value(_, _), do: nil

  defp map_value(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) ||
      Enum.find_value(map, fn
        {map_key, value} when is_atom(map_key) ->
          if Atom.to_string(map_key) == key, do: value

        _ ->
          nil
      end)
  end

  defp map_value(_, _), do: nil

  defp log_attribute(event, key) when is_map(event) do
    unmapped = Map.get(event, "unmapped") || Map.get(event, :unmapped) || %{}
    attrs = Map.get(unmapped, "log_attributes") || Map.get(unmapped, :log_attributes) || %{}

    if is_map(attrs), do: Map.get(attrs, key) || Map.get(attrs, log_attribute_atom_key(key))
  end

  defp log_attribute(_event, _key), do: nil

  defp log_attribute_atom_key("event_type"), do: :event_type
  defp log_attribute_atom_key(_key), do: :__unknown__

  defp meaningful_payload(payload) when is_map(payload) do
    payload
    |> Enum.reject(fn {_key, value} -> blank?(value) end)
    |> Map.new()
  end

  defp meaningful_payload(_payload), do: %{}

  defp meaningful_map?(map) when is_map(map), do: Enum.any?(map, fn {_key, value} -> not blank?(value) end)

  defp meaningful_map?(_map), do: false

  defp waf_src_ip(event) do
    waf = waf_payload(event)

    waf_value(waf, "client_ip") ||
      get_in(event, ["src_endpoint", "ip"]) ||
      get_in(event, [:src_endpoint, :ip])
  end

  defp waf_value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, waf_atom_key(key))
  end

  defp waf_value(_, _), do: nil

  defp waf_atom_key("client_ip"), do: :client_ip
  defp waf_atom_key("request_id"), do: :request_id
  defp waf_atom_key("request_path"), do: :request_path
  defp waf_atom_key("rule_id"), do: :rule_id
  defp waf_atom_key("rule_message"), do: :rule_message
  defp waf_atom_key("rule_severity"), do: :rule_severity
  defp waf_atom_key("source"), do: :source
  defp waf_atom_key("waf_policy"), do: :waf_policy
  defp waf_atom_key(_), do: :__unknown__

  defp display_value(value) when value in [nil, ""], do: "—"
  defp display_value(value) when is_binary(value), do: value
  defp display_value(value), do: to_string(value)

  defp display_diagnostic_value(value) when value in [nil, ""], do: "—"
  defp display_diagnostic_value(value) when is_binary(value), do: value
  defp display_diagnostic_value(value) when is_boolean(value), do: to_string(value)
  defp display_diagnostic_value(value) when is_number(value), do: to_string(value)

  defp display_diagnostic_value(value) when is_list(value) do
    Enum.map_join(value, ", ", &display_diagnostic_value/1)
  end

  defp display_diagnostic_value(value) when is_map(value) do
    Enum.map_join(value, ", ", fn {key, item} ->
      "#{field_label(to_string(key))}: #{display_diagnostic_value(item)}"
    end)
  end

  defp container_display(container) when is_map(container) do
    diagnostic_value(container, ["name"]) || diagnostic_value(container, ["id"])
  end

  defp container_display(_), do: nil

  defp image_display(container) when is_map(container) do
    repository = diagnostic_value(container, ["image_repository"])
    tag = diagnostic_value(container, ["image_tag"])

    cond do
      is_binary(repository) and is_binary(tag) -> "#{repository}:#{tag}"
      is_binary(repository) -> repository
      true -> diagnostic_value(container, ["image"])
    end
  end

  defp image_display(_), do: nil

  defp attribution_display(attribution) when is_map(attribution) do
    status = diagnostic_value(attribution, ["status"])
    missing = diagnostic_value(attribution, ["missing"])

    case {status, missing} do
      {nil, _} -> nil
      {value, []} -> value
      {value, nil} -> value
      {value, missing_values} -> "#{value} (missing #{display_diagnostic_value(missing_values)})"
    end
  end

  defp attribution_display(_), do: nil

  defp diagnostic_value(data, [key]) when is_map(data), do: Map.get(data, key) || Map.get(data, diagnostic_atom_key(key))

  defp diagnostic_value(data, [key | rest]) when is_map(data) do
    case diagnostic_value(data, [key]) do
      %{} = nested -> diagnostic_value(nested, rest)
      _ -> nil
    end
  end

  defp diagnostic_value(_, _), do: nil

  defp diagnostic_atom_key("rule"), do: :rule
  defp diagnostic_atom_key("host"), do: :host
  defp diagnostic_atom_key("process"), do: :process
  defp diagnostic_atom_key("parent_process"), do: :parent_process
  defp diagnostic_atom_key("user"), do: :user
  defp diagnostic_atom_key("container"), do: :container
  defp diagnostic_atom_key("kubernetes"), do: :kubernetes
  defp diagnostic_atom_key("attribution"), do: :attribution
  defp diagnostic_atom_key("name"), do: :name
  defp diagnostic_atom_key("priority"), do: :priority
  defp diagnostic_atom_key("command"), do: :command
  defp diagnostic_atom_key("cwd"), do: :cwd
  defp diagnostic_atom_key("executable"), do: :executable
  defp diagnostic_atom_key("executable_flags"), do: :executable_flags
  defp diagnostic_atom_key("namespace"), do: :namespace
  defp diagnostic_atom_key("pod"), do: :pod
  defp diagnostic_atom_key("status"), do: :status
  defp diagnostic_atom_key("missing"), do: :missing
  defp diagnostic_atom_key("id"), do: :id
  defp diagnostic_atom_key("image"), do: :image
  defp diagnostic_atom_key("image_repository"), do: :image_repository
  defp diagnostic_atom_key("image_tag"), do: :image_tag
  defp diagnostic_atom_key(_), do: :__unknown__

  defp blank?(value), do: value in [nil, ""]

  @field_labels %{
    "_remote_addr" => "Remote Address",
    "short_message" => "Message",
    "timestamp" => "Timestamp",
    "event_timestamp" => "Event Time",
    "time" => "Event Time",
    "created_at" => "Created At",
    "updated_at" => "Updated At",
    "trace_id" => "Trace ID",
    "span_id" => "Span ID",
    "host" => "Host",
    "level" => "Level",
    "severity" => "Severity",
    "severity_id" => "Severity ID",
    "class_uid" => "Class UID",
    "category_uid" => "Category UID",
    "type_uid" => "Type UID",
    "activity_id" => "Activity ID",
    "activity_name" => "Activity",
    "status_id" => "Status ID",
    "status_code" => "Status Code",
    "status_detail" => "Status Detail",
    "log_name" => "Log Name",
    "log_provider" => "Log Provider",
    "log_level" => "Log Level",
    "log_version" => "Log Version"
  }

  defp field_label(field) when is_binary(field) do
    case Map.get(@field_labels, field) do
      nil -> humanize_field(field)
      label -> label
    end
  end

  defp field_label(field), do: to_string(field)

  defp humanize_field(field) when is_binary(field) do
    field
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp escape_value(value) when is_binary(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end

  defp escape_value(other), do: escape_value(to_string(other))

  defp format_error(%Jason.DecodeError{} = err), do: Exception.message(err)
  defp format_error(%ArgumentError{} = err), do: Exception.message(err)
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

  defp build_related(nil, _scope), do: %{log_id: nil, alert: nil}

  defp build_related(event, scope) when is_map(event) do
    %{
      log_id: event |> log_id_from_event() |> existing_log_id(scope),
      alert: fetch_alert(event, scope)
    }
  end

  defp log_id_from_event(event) do
    metadata = Map.get(event, "metadata") || Map.get(event, :metadata) || %{}
    serviceradar = Map.get(metadata, "serviceradar") || Map.get(metadata, :serviceradar) || %{}

    Map.get(serviceradar, "source_log_id") || Map.get(serviceradar, :source_log_id)
  end

  defp existing_log_id(nil, _scope), do: nil
  defp existing_log_id("", _scope), do: nil

  defp existing_log_id(log_id, scope) when is_binary(log_id) do
    query = "in:logs id:\"#{escape_value(log_id)}\" time:last_24h limit:1"

    case srql_module().query(query, %{scope: scope}) do
      {:ok, %{"results" => [_log | _]}} -> log_id
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp fetch_alert(event, scope) do
    event_id = Map.get(event, "id") || Map.get(event, "event_id")
    event_time = event_time_from_event(event)

    if is_binary(event_id) do
      query =
        Alert
        |> Ash.Query.for_read(:read, %{})
        |> Ash.Query.filter(event_id == ^event_id)
        |> maybe_filter_event_time(event_time)

      case Ash.read(query, scope: scope) do
        {:ok, %Ash.Page.Keyset{results: [alert | _]}} -> alert
        {:ok, [alert | _]} -> alert
        _ -> nil
      end
    end
  end

  defp event_time_from_event(event) do
    case Map.get(event, "time") || Map.get(event, "event_timestamp") ||
           Map.get(event, "timestamp") do
      %DateTime{} = dt -> dt
      value when is_binary(value) -> parse_datetime(value)
      _ -> nil
    end
  end

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp maybe_filter_event_time(query, nil), do: query

  defp maybe_filter_event_time(query, %DateTime{} = event_time) do
    Ash.Query.filter(query, event_time == ^event_time)
  end

  defp srql_module do
    Application.get_env(:serviceradar_web_ng, :srql_module, ServiceRadarWebNG.SRQL)
  end
end
