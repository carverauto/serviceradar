defmodule ServiceRadarWebNGWeb.AlertLive.Show do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.UIComponents

  alias ServiceRadar.Observability.EventTitle
  alias ServiceRadarWebNG.AlertActions
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.AnomalySeriesKey
  alias ServiceRadarWebNGWeb.Observability.DetailStreamComponents
  alias ServiceRadarWebNGWeb.SRQL.Builder
  alias ServiceRadarWebNGWeb.SRQL.Page, as: SRQLPage

  @stream_page_size 10
  @srql_default_limit 25

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns[:current_scope]

    {:ok,
     socket
     |> assign(:page_title, "Alert Details")
     |> assign(:alert_id, nil)
     |> assign(:alert, nil)
     |> assign(:error, nil)
     |> assign(:alert_record, nil)
     |> assign(:action_states, AlertActions.action_states(nil))
     |> assign(:alert_snoozed?, false)
     |> assign(:deliveries, [])
     |> assign(:delivery_counts, AlertActions.delivery_counts([]))
     |> assign(:deliveries_error, nil)
     |> assign(:snooze_duration, AlertActions.default_snooze_value())
     |> assign(:snooze_custom_minutes, "")
     |> assign(:can_manage_alerts?, RBAC.can?(scope, AlertActions.permission()))
     |> assign(:can_view_deliveries?, RBAC.can?(scope, AlertActions.deliveries_permission()))
     |> assign(:stream_entries, [])
     |> assign(:stream_severity, "all")
     |> assign(:stream_query, nil)
     |> assign(:stream_cursor, nil)
     |> assign(:stream_next_cursor, nil)
     |> assign(:stream_prev_cursor, nil)
     |> assign(:stream_page, 1)
     |> assign(:stream_page_size, @stream_page_size)
     |> assign(:show_raw_json, false)
     |> assign(:limit, @srql_default_limit)
     |> SRQLPage.init("alerts", default_limit: @srql_default_limit)}
  end

  @impl true
  def handle_params(%{"alert_id" => alert_id}, uri, socket) do
    {alert, error} = load_alert(alert_id, socket.assigns.current_scope)
    stream_query = stream_query_for_alert(alert)
    detail_query = detail_query_for_alert(alert_id)

    {stream, next_cursor, prev_cursor} =
      load_stream_page(stream_query, alert, alert_id, nil, socket.assigns.current_scope)

    {:noreply,
     socket
     |> assign(:alert_id, alert_id)
     |> assign(:alert, alert)
     |> assign(:error, error)
     |> assign(:stream_entries, stream)
     |> assign(:stream_query, stream_query)
     |> assign(:stream_cursor, nil)
     |> assign(:stream_next_cursor, next_cursor)
     |> assign(:stream_prev_cursor, prev_cursor)
     |> assign(:stream_page, 1)
     |> assign(:stream_severity, "all")
     |> assign(:show_raw_json, false)
     |> assign(:page_title, page_title_for(alert, alert_id))
     |> prefill_srql_bar(detail_query, uri, alert_id)
     |> load_lifecycle_state(alert_id)}
  end

  @impl true
  def handle_event("set_stream_severity", %{"severity" => severity}, socket)
      when severity in ~w(all critical warning info) do
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
    {:noreply, push_event(socket, "clipboard", %{text: socket.assigns.alert_id || ""})}
  end

  def handle_event("copy_json", _params, socket) do
    text =
      case socket.assigns.alert do
        %{} = alert -> Jason.encode!(alert, pretty: true)
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
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_toggle", %{}, entity: "alerts")}
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
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_add_filter", params, entity: "alerts")}
  end

  def handle_event("srql_builder_remove_filter", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_remove_filter", params, entity: "alerts")}
  end

  # -- acknowledgement controls ----------------------------------------------
  #
  # Every clause below re-authorizes before it does anything. A hidden button is
  # not authorization: these events are reachable by anyone who can open a
  # socket to this LiveView, so `authorized_to_manage?/1` runs first and
  # `AlertActions` re-derives the caller's authority from persistence again
  # before it touches the engine.

  def handle_event("alert_snooze_duration", %{"duration" => duration} = params, socket) when is_binary(duration) do
    {:noreply,
     socket
     |> assign(:snooze_duration, whitelisted_duration(duration))
     |> assign(:snooze_custom_minutes, custom_minutes_value(Map.get(params, "custom_minutes")))}
  end

  def handle_event("alert_snooze_duration", _params, socket), do: {:noreply, socket}

  def handle_event("alert_acknowledge", _params, socket) do
    with_authorized_alert(socket, fn scope, alert_id ->
      AlertActions.acknowledge(scope, alert_id)
    end)
  end

  def handle_event("alert_resolve", _params, socket) do
    with_authorized_alert(socket, fn scope, alert_id ->
      AlertActions.resolve(scope, alert_id)
    end)
  end

  def handle_event("alert_unsnooze", _params, socket) do
    with_authorized_alert(socket, fn scope, alert_id ->
      AlertActions.unsnooze(scope, alert_id)
    end)
  end

  def handle_event("alert_snooze", params, socket) do
    params = if is_map(params), do: params, else: %{}

    if authorized_to_manage?(socket) do
      socket =
        socket
        |> assign(:snooze_duration, whitelisted_duration(Map.get(params, "duration")))
        |> assign(:snooze_custom_minutes, custom_minutes_value(Map.get(params, "custom_minutes")))

      case AlertActions.snooze_seconds(params) do
        {:ok, seconds} ->
          with_authorized_alert(socket, fn scope, alert_id ->
            AlertActions.snooze(scope, alert_id, seconds)
          end)

        :error ->
          {:noreply, put_flash(socket, :error, AlertActions.describe_error(:invalid_duration))}
      end
    else
      {:noreply, put_flash(socket, :error, AlertActions.describe_error(:not_authorized))}
    end
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
          :alerts
        )
      )

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} srql={@srql}>
      <div class="sr-alert-viewer flex min-w-0 max-w-full flex-col pt-2 sm:pt-3 lg:h-[calc(100dvh-7.5rem)] lg:max-h-[calc(100dvh-7.5rem)] lg:overflow-hidden">
        <div :if={@error} class="shrink-0 border-b border-sr-line px-1 py-3 sm:px-2">
          <div class={ui_alert_class(variant: "error")}>
            <.icon name="hero-exclamation-circle" class="size-5 shrink-0" />
            <p>{@error}</p>
          </div>
        </div>

        <div
          :if={is_map(@alert)}
          class="grid min-h-0 min-w-0 max-w-full flex-1 grid-cols-1 overflow-hidden border-t border-sr-line lg:grid-cols-[15.5rem_minmax(0,1fr)] xl:grid-cols-[16.5rem_minmax(0,1fr)]"
        >
          <.detail_stream_pane
            id="alert-stream"
            title="Alert stream"
            class="sr-alert-stream"
            entries={@visible_stream}
            timezone={@current_scope.user.timezone}
            page_count={length(@visible_stream)}
            page={@stream_page}
            selected_id={@alert_id}
            stream_severity={@stream_severity}
            severity_filters={~w(all critical warning info)}
            context_label={stream_context_label(@alert)}
            stream_query={@stream_query || Map.get(@srql, :query)}
            has_prev={@stream_page > 1}
            has_next={is_binary(@stream_next_cursor) and @stream_next_cursor != ""}
            empty_label="No matching alerts"
          />

          <section class="flex min-h-0 min-w-0 flex-col overflow-hidden lg:border-l lg:border-sr-line">
            <.alert_detail_header alert={@alert} alert_id={@alert_id} />
            <.alert_lifecycle_bar
              alert_record={@alert_record}
              action_states={@action_states}
              snoozed?={@alert_snoozed?}
              snooze_duration={@snooze_duration}
              snooze_custom_minutes={@snooze_custom_minutes}
              can_manage?={@can_manage_alerts?}
              timezone={@current_scope.user.timezone}
            />
            <.alert_meta_strip alert={@alert} timezone={@current_scope.user.timezone} />

            <div class="min-h-0 min-w-0 flex-1 space-y-5 overflow-x-hidden overflow-y-auto px-3 py-5 sm:px-5">
              <.alert_message_hero alert={@alert} />
              <.stateful_incident_summary
                :if={stateful_incident?(@alert)}
                alert={@alert}
                timezone={@current_scope.user.timezone}
              />
              <.alert_context_panel alert={@alert} timezone={@current_scope.user.timezone} />
              <.notification_history
                :if={@can_view_deliveries?}
                alert_id={@alert_id}
                deliveries={@deliveries}
                counts={@delivery_counts}
                error={@deliveries_error}
                timezone={@current_scope.user.timezone}
              />
              <.related_links alert={@alert} />
              <.alert_raw_toggle alert={@alert} open?={@show_raw_json} />
            </div>
          </section>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # -- acknowledgement plumbing ----------------------------------------------

  # Runs `fun` only for a caller that currently holds the manage permission,
  # then re-reads the alert so the rendered state is the state the engine
  # returned. No optimistic update is applied anywhere on this page.
  defp with_authorized_alert(socket, fun) when is_function(fun, 2) do
    alert_id = socket.assigns[:alert_id]

    cond do
      not authorized_to_manage?(socket) ->
        {:noreply, put_flash(socket, :error, AlertActions.describe_error(:not_authorized))}

      not is_binary(alert_id) or alert_id == "" ->
        {:noreply, put_flash(socket, :error, AlertActions.describe_error(:not_found))}

      true ->
        case fun.(socket.assigns.current_scope, alert_id) do
          {:ok, _alert} ->
            {:noreply,
             socket
             |> put_flash(:info, "Alert updated")
             |> load_lifecycle_state(alert_id)}

          {:error, reason} ->
            {:noreply,
             socket
             |> put_flash(:error, AlertActions.describe_error(reason))
             |> load_lifecycle_state(alert_id)}
        end
    end
  end

  defp authorized_to_manage?(socket) do
    RBAC.can?(socket.assigns[:current_scope], AlertActions.permission())
  end

  # Enumerated durations only; never `String.to_atom/1` on the submitted value.
  defp whitelisted_duration(value) when is_binary(value) do
    known = Enum.map(AlertActions.snooze_options(), & &1.value) ++ [AlertActions.custom_snooze_value()]

    if value in known, do: value, else: AlertActions.default_snooze_value()
  end

  defp whitelisted_duration(_value), do: AlertActions.default_snooze_value()

  defp custom_minutes_value(value) when is_binary(value), do: String.slice(String.trim(value), 0, 8)
  defp custom_minutes_value(_value), do: ""

  # Loads the authoritative lifecycle state (and the alert's notification
  # history) from the engine. Deliberately skipped on the disconnected render:
  # the LiveView Iron Laws forbid a database query in a disconnected mount, and
  # the static HTML is replaced as soon as the socket connects.
  defp load_lifecycle_state(socket, alert_id) do
    if connected?(socket) and is_binary(alert_id) and alert_id != "" do
      scope = socket.assigns[:current_scope]

      record =
        case AlertActions.load(scope, alert_id) do
          {:ok, alert} -> alert
          {:error, _reason} -> nil
        end

      socket
      |> assign(:alert_record, record)
      |> assign(:action_states, AlertActions.action_states(record))
      |> assign(:alert_snoozed?, AlertActions.snoozed?(record))
      |> load_deliveries(alert_id)
    else
      socket
    end
  end

  defp load_deliveries(socket, alert_id) do
    if socket.assigns[:can_view_deliveries?] do
      case AlertActions.deliveries(socket.assigns[:current_scope], alert_id) do
        {:ok, deliveries} ->
          socket
          |> assign(:deliveries, deliveries)
          |> assign(:delivery_counts, AlertActions.delivery_counts(deliveries))
          |> assign(:deliveries_error, nil)

        {:error, _reason} ->
          socket
          |> assign(:deliveries, [])
          |> assign(:delivery_counts, AlertActions.delivery_counts([]))
          |> assign(:deliveries_error, "Notification history is unavailable.")
      end
    else
      socket
    end
  end

  # -- data loading -----------------------------------------------------------

  defp load_alert(alert_id, scope) do
    query = detail_query_for_alert(alert_id) <> " limit:1"

    case srql_module().query(query, %{scope: scope}) do
      {:ok, %{"results" => [alert | _]}} when is_map(alert) ->
        {alert, nil}

      {:ok, %{"results" => []}} ->
        {nil, "Alert not found."}

      {:ok, _} ->
        {nil, "Unexpected response format"}

      {:error, reason} ->
        {nil, "Failed to load alert: #{format_error(reason)}"}
    end
  end

  defp detail_query_for_alert(alert_id) when is_binary(alert_id) do
    ~s|in:alerts id:"#{escape_value(alert_id)}" time:last_7d|
  end

  defp detail_query_for_alert(_), do: "in:alerts time:last_7d"

  defp stream_query_for_alert(%{} = alert) do
    status = Map.get(alert, "status")

    if is_binary(status) and String.trim(status) != "" do
      ~s|in:alerts status:"#{escape_value(status)}" time:last_7d sort:timestamp:desc|
    else
      "in:alerts time:last_7d sort:timestamp:desc"
    end
  end

  defp stream_query_for_alert(_), do: "in:alerts time:last_7d sort:timestamp:desc"

  defp load_stream_into_socket(socket, cursor, page) do
    query = socket.assigns.stream_query || stream_query_for_alert(socket.assigns.alert)

    {stream, next_cursor, prev_cursor} =
      load_stream_page(
        query,
        socket.assigns.alert,
        socket.assigns.alert_id,
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

  defp load_stream_page(query, alert, selected_id, cursor, scope) when is_binary(query) do
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
          if is_nil(cursor) and is_map(alert) do
            ensure_selected_in_stream(entries, alert, selected_id)
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

  defp load_stream_page(_, alert, selected_id, cursor, scope) when is_map(alert) do
    load_stream_page(stream_query_for_alert(alert), alert, selected_id, cursor, scope)
  end

  defp load_stream_page(_, _, _, _, _), do: {[], nil, nil}

  defp refresh_stream_from_srql(socket) do
    raw =
      case Map.get(socket.assigns.srql || %{}, :query) do
        q when is_binary(q) -> String.trim(q)
        _ -> ""
      end

    fallback = socket.assigns.stream_query || stream_query_for_alert(socket.assigns.alert)

    query =
      if raw != "" and String.contains?(raw, "in:alerts") do
        strip_embedded_limit(raw)
      else
        fallback
      end

    {stream, next_cursor, prev_cursor} =
      load_stream_page(
        query,
        socket.assigns.alert,
        socket.assigns.alert_id,
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

  defp prefill_srql_bar(socket, query, uri, alert_id) when is_binary(query) do
    page_path =
      case uri do
        path when is_binary(path) and path != "" ->
          URI.parse(uri).path || "/alerts/#{alert_id}"

        _ ->
          "/alerts/#{alert_id}"
      end

    srql =
      (socket.assigns[:srql] || %{})
      |> Map.merge(%{
        enabled: true,
        entity: "alerts",
        query: query,
        draft: query,
        page_path: page_path || "/alerts/#{alert_id}",
        error: nil,
        loading: false,
        builder_available: true,
        builder_open: false
      })
      |> sync_builder_state(query)

    assign(socket, :srql, srql)
  end

  defp sync_builder_state(srql, query) do
    case Builder.parse(query) do
      {:ok, builder} ->
        Map.merge(srql, %{
          builder: builder,
          builder_available: true,
          builder_supported: true,
          builder_sync: true
        })

      {:error, _reason} ->
        Map.merge(srql, %{
          builder_available: true,
          builder_supported: false,
          builder_sync: false
        })
    end
  end

  defp stream_entry(alert, idx) when is_map(alert) do
    id = entry_id(alert, idx)
    title = EventTitle.alert_title(alert)

    %{
      id: id,
      dom_id: "alert-entry-#{idx}",
      href: ~p"/alerts/#{id}",
      severity: Map.get(alert, "severity"),
      secondary: stream_secondary(alert),
      timestamp: alert_timestamp_value(alert),
      preview: message_preview(title || Map.get(alert, "description") || "")
    }
  end

  defp ensure_selected_in_stream(entries, alert, selected_id) do
    if Enum.any?(entries, &(&1.id == selected_id)) do
      entries
    else
      [stream_entry(Map.put(alert, "id", selected_id), "selected") | entries]
    end
  end

  defp page_title_for(%{} = alert, alert_id) do
    case EventTitle.alert_title(alert) do
      title when is_binary(title) and title != "" -> title
      _ -> "Alert · #{String.slice(to_string(alert_id), 0, 8)}"
    end
  end

  defp page_title_for(_, alert_id), do: "Alert · #{String.slice(to_string(alert_id), 0, 8)}"

  defp stream_context_label(%{} = alert) do
    Map.get(alert, "status") || Map.get(alert, "source_type")
  end

  defp stream_context_label(_), do: nil

  # -- header / meta ----------------------------------------------------------

  attr :alert, :map, required: true
  attr :alert_id, :string, required: true

  defp alert_detail_header(assigns) do
    title = EventTitle.alert_title(assigns.alert) || "Alert"

    assigns =
      assigns
      |> assign(:title, title)
      |> assign(:source_kind, alert_source_kind(assigns.alert))
      |> assign(:short_id, String.slice(assigns.alert_id, 0, 8))

    ~H"""
    <header class="space-y-3 border-b border-sr-line px-4 pb-4 pt-5 font-sans sm:px-6 sm:pt-6">
      <div class="flex flex-wrap items-center justify-between gap-x-3 gap-y-2">
        <div class="flex min-w-0 flex-wrap items-center gap-x-2 gap-y-1 text-sm text-sr-muted">
          <.link navigate={~p"/observability/alerts"} class="hover:text-sr-ink">
            alerts
          </.link>
          <span class="text-sr-line-strong">/</span>
          <span class="text-sr-ink/80">{@source_kind}</span>
          <span class="text-sr-line-strong">/</span>
          <span class="font-mono text-sr-ink">{@short_id}</span>
        </div>

        <div class="flex shrink-0 flex-wrap items-center gap-1.5">
          <.ui_button
            navigate={~p"/observability/alerts"}
            variant="outline"
            size="xs"
          >
            Back to alerts
          </.ui_button>
          <.ui_button type="button" variant="outline" size="xs" phx-click="copy_json">
            Copy JSON
          </.ui_button>
        </div>
      </div>

      <div class="min-w-0 space-y-2">
        <div class="flex min-w-0 flex-wrap items-start gap-2.5">
          <.severity_badge value={Map.get(@alert, "severity")} />
          <.status_badge value={Map.get(@alert, "status")} />
          <h1
            class="min-w-0 flex-1 font-sans text-lg font-semibold leading-snug tracking-tight text-sr-ink sm:text-xl line-clamp-2"
            title={@title}
          >
            {@title}
          </h1>
        </div>
        <div class="flex flex-wrap items-center gap-2">
          <code class="break-all font-mono text-xs text-sr-muted">{@alert_id}</code>
          <.ui_button type="button" size="xs" variant="ghost" phx-click="copy_id">Copy ID</.ui_button>
        </div>
      </div>
    </header>
    """
  end

  attr :alert, :map, required: true
  attr :timezone, :string, required: true

  defp alert_meta_strip(assigns) do
    device_uid = Map.get(assigns.alert, "device_uid")
    source_type = Map.get(assigns.alert, "source_type")
    agent = Map.get(assigns.alert, "agent_uid")

    facts =
      Enum.reject(
        [
          %{
            label: "Triggered",
            value: alert_timestamp_value(assigns.alert),
            mono?: true,
            href: nil,
            time?: true
          },
          %{label: "Status", value: status_label(Map.get(assigns.alert, "status")), mono?: false, href: nil},
          %{
            label: "Source",
            value: source_type,
            mono?: false,
            href: alerts_filter_href("source_type", source_type)
          },
          %{
            label: "Device",
            value: short_device(device_uid),
            mono?: true,
            href: if(is_binary(device_uid) and device_uid != "", do: ~p"/devices/#{device_uid}"),
            title: device_uid
          },
          %{label: "Agent", value: agent, mono?: true, href: nil},
          %{
            label: "Metric",
            value: finding_series(assigns.alert).metric || Map.get(assigns.alert, "metric_name"),
            mono?: true,
            href: nil
          }
        ],
        fn fact -> blank_value?(fact.value) end
      )

    n = length(facts)

    col_class =
      cond do
        n <= 1 -> "grid-cols-1"
        n == 2 -> "grid-cols-2"
        n == 3 -> "grid-cols-2 sm:grid-cols-3"
        n == 4 -> "grid-cols-2 lg:grid-cols-4"
        true -> "grid-cols-2 sm:grid-cols-3 lg:grid-cols-5"
      end

    assigns =
      assigns
      |> assign(:facts, facts)
      |> assign(:col_class, col_class)

    ~H"""
    <div class={["grid gap-px border-b border-sr-line bg-sr-line", @col_class]}>
      <div :for={fact <- @facts} class="flex min-w-0 flex-col gap-1 bg-sr-surface px-4 py-3">
        <span class="font-sans text-xs font-medium uppercase tracking-wide text-sr-muted">
          {fact.label}
        </span>
        <.user_time
          :if={Map.get(fact, :time?, false)}
          id="alert-triggered-time"
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
          title={Map.get(fact, :title) || fact.value}
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

  defp alerts_filter_href(_field, value) when not is_binary(value) or value == "", do: nil

  defp alerts_filter_href(field, value) when is_binary(field) and is_binary(value) do
    value = String.trim(value)

    if value == "" do
      nil
    else
      query = ~s|in:alerts #{field}:"#{escape_value(value)}" time:last_7d sort:timestamp:desc|
      ~p"/observability/alerts?#{%{q: query}}"
    end
  end

  # -- lifecycle controls -----------------------------------------------------

  attr :alert_record, :map, default: nil
  attr :action_states, :map, required: true
  attr :snoozed?, :boolean, default: false
  attr :snooze_duration, :string, required: true
  attr :snooze_custom_minutes, :string, default: ""
  attr :can_manage?, :boolean, default: false
  attr :timezone, :string, required: true

  defp alert_lifecycle_bar(assigns) do
    assigns =
      assigns
      |> assign(:snooze_options, AlertActions.snooze_options())
      |> assign(:custom_value, AlertActions.custom_snooze_value())
      |> assign(:min_minutes, AlertActions.min_custom_snooze_minutes())
      |> assign(:max_minutes, AlertActions.max_custom_snooze_minutes())
      |> assign(:acknowledgement, acknowledgement_summary(assigns.alert_record))
      |> assign(:snooze_until, snooze_until_display(assigns.alert_record))
      |> assign(:acknowledge_state, Map.get(assigns.action_states, :acknowledge))
      |> assign(:snooze_state, Map.get(assigns.action_states, :snooze))
      |> assign(:unsnooze_state, Map.get(assigns.action_states, :unsnooze))
      |> assign(:resolve_state, Map.get(assigns.action_states, :resolve))

    ~H"""
    <div
      :if={is_map(@alert_record)}
      class="flex flex-wrap items-center gap-x-4 gap-y-2 border-b border-sr-line bg-sr-subtle/20 px-4 py-3 sm:px-6"
    >
      <div class="flex min-w-0 flex-wrap items-center gap-x-2 gap-y-1">
        <%!--
          "Snoozed" is a derived condition, not a status: the state machine has
          no such state. It is rendered as its own badge so it can never be
          mistaken for one.
        --%>
        <.ui_badge :if={@snoozed?} variant="warning" size="xs">
          Snoozed until
          <.user_time
            id="alert-snooze-until-time"
            value={@snooze_until}
            timezone={@timezone}
            style={:full}
            fallback="—"
            class="font-mono text-[11px]"
          />
        </.ui_badge>

        <div :if={@acknowledgement} class="flex min-w-0 flex-wrap items-center gap-1.5">
          <.ui_badge variant={@acknowledgement.variant} size="xs" title={@acknowledgement.title}>
            {@acknowledgement.kind_label}
          </.ui_badge>
          <span class="truncate font-sans text-xs text-sr-muted">
            Acknowledged by <span class="text-sr-ink">{@acknowledgement.actor}</span>
            <span :if={@acknowledgement.at} class="inline-flex items-center gap-1">
              on
              <.user_time
                id="alert-acknowledged-time"
                value={@acknowledgement.at}
                timezone={@timezone}
                style={:full}
                fallback="—"
                class="font-mono text-[11px]"
              />
            </span>
          </span>
        </div>
      </div>

      <div
        :if={@can_manage?}
        class="flex flex-wrap items-center gap-1.5 sm:ml-auto"
        role="group"
        aria-label="Alert lifecycle actions"
      >
        <.ui_button
          type="button"
          variant="primary"
          size="xs"
          phx-click="alert_acknowledge"
          disabled={not @acknowledge_state.enabled?}
          title={@acknowledge_state.reason}
          aria-label={control_label("Acknowledge alert", @acknowledge_state)}
        >
          Acknowledge
        </.ui_button>

        <form
          id="alert-snooze-form"
          phx-submit="alert_snooze"
          phx-change="alert_snooze_duration"
          class="flex flex-wrap items-center gap-1.5"
        >
          <label for="alert-snooze-duration" class="sr-only">Snooze duration</label>
          <select
            id="alert-snooze-duration"
            name="duration"
            disabled={not @snooze_state.enabled?}
            class={ui_field_class(size: "xs", class: "w-auto")}
          >
            <option
              :for={option <- @snooze_options}
              value={option.value}
              selected={option.value == @snooze_duration}
            >
              {option.label}
            </option>
            <option value={@custom_value} selected={@custom_value == @snooze_duration}>
              Custom
            </option>
          </select>

          <label :if={@snooze_duration == @custom_value} for="alert-snooze-minutes" class="sr-only">
            Snooze minutes ({@min_minutes} to {@max_minutes})
          </label>
          <input
            :if={@snooze_duration == @custom_value}
            id="alert-snooze-minutes"
            type="number"
            name="custom_minutes"
            value={@snooze_custom_minutes}
            min={@min_minutes}
            max={@max_minutes}
            step="1"
            placeholder="minutes"
            disabled={not @snooze_state.enabled?}
            class={ui_field_class(size: "xs", class: "w-24")}
          />

          <.ui_button
            type="submit"
            variant="outline"
            size="xs"
            disabled={not @snooze_state.enabled?}
            title={@snooze_state.reason}
            aria-label={control_label("Snooze alert", @snooze_state)}
          >
            Snooze
          </.ui_button>
        </form>

        <.ui_button
          :if={@unsnooze_state.enabled?}
          type="button"
          variant="ghost"
          size="xs"
          phx-click="alert_unsnooze"
          aria-label="Clear the snooze on this alert"
        >
          Clear snooze
        </.ui_button>

        <.ui_button
          type="button"
          variant="outline"
          size="xs"
          phx-click="alert_resolve"
          disabled={not @resolve_state.enabled?}
          title={@resolve_state.reason}
          aria-label={control_label("Resolve alert", @resolve_state)}
          data-confirm="Resolve this alert? Pending notifications for it stop."
        >
          Resolve
        </.ui_button>
      </div>
    </div>
    """
  end

  defp control_label(label, %{enabled?: false, reason: reason}) when is_binary(reason),
    do: label <> " (unavailable: " <> reason <> ")"

  defp control_label(label, _state), do: label

  # `acknowledged_by_user_id` is a real foreign key. A row without it but with
  # the free-text `acknowledged_by` was acknowledged by an external principal -
  # someone who clicked an emailed action link - and is labelled as such rather
  # than presented as a platform user.
  defp acknowledgement_summary(%{acknowledged_at: %DateTime{} = at} = alert) do
    user_id = Map.get(alert, :acknowledged_by_user_id)
    free_text = Map.get(alert, :acknowledged_by)

    if is_binary(user_id) do
      %{
        kind_label: "Platform user",
        variant: "info",
        title: "Acknowledged by a ServiceRadar user account",
        actor: display_actor(free_text, user_id),
        at: at
      }
    else
      %{
        kind_label: "External principal",
        variant: "outline",
        title: "Acknowledged outside ServiceRadar, through a signed action link",
        actor: display_actor(free_text, nil),
        at: at
      }
    end
  end

  defp acknowledgement_summary(_alert), do: nil

  defp display_actor(free_text, _user_id) when is_binary(free_text) and free_text != "", do: free_text

  defp display_actor(_free_text, user_id) when is_binary(user_id), do: "user " <> String.slice(user_id, 0, 8)

  defp display_actor(_free_text, _user_id), do: "unknown"

  defp snooze_until_display(%{snooze_until: %DateTime{} = until}), do: until
  defp snooze_until_display(_alert), do: nil

  # -- notification history ---------------------------------------------------

  attr :alert_id, :string, required: true
  attr :deliveries, :list, default: []
  attr :counts, :map, required: true
  attr :error, :string, default: nil
  attr :timezone, :string, required: true

  defp notification_history(assigns) do
    assigns = assign(assigns, :delivery_log_href, AlertActions.delivery_log_path(assigns.alert_id))

    ~H"""
    <div class="overflow-hidden rounded-sr-surface border border-sr-line bg-sr-surface shadow-sr-surface">
      <div class="flex flex-wrap items-center justify-between gap-2 border-b border-sr-line bg-sr-subtle/30 px-4 py-2.5">
        <span class="font-sans text-xs font-medium uppercase tracking-wide text-sr-muted">
          Notifications
        </span>
        <div class="flex flex-wrap items-center gap-1.5">
          <.ui_badge variant="ghost" size="xs">{@counts.total} recorded</.ui_badge>
          <.ui_badge :if={@counts.sent > 0} variant="success" size="xs">
            {@counts.sent} sent
          </.ui_badge>
          <.ui_badge :if={@counts.suppressed > 0} variant="warning" size="xs">
            {@counts.suppressed} suppressed
          </.ui_badge>
          <.ui_badge :if={@counts.pending > 0} variant="info" size="xs">
            {@counts.pending} pending retry
          </.ui_badge>
          <.ui_badge :if={@counts.failed > 0} variant="error" size="xs">
            {@counts.failed} failed
          </.ui_badge>
          <.ui_badge
            :if={@counts.test > 0}
            variant="outline"
            size="xs"
            title="Test sends are not counted"
          >
            {@counts.test} test (not counted)
          </.ui_badge>
          <.ui_button href={@delivery_log_href} size="xs" variant="ghost">
            Delivery log
          </.ui_button>
        </div>
      </div>

      <div :if={@error} class="px-4 py-3">
        <div class={ui_alert_class(variant: "warning")}>
          <.icon name="hero-exclamation-triangle" class="size-5 shrink-0" />
          <p>{@error}</p>
        </div>
      </div>

      <p :if={is_nil(@error) and @deliveries == []} class="px-4 py-4 text-sm text-sr-muted">
        No notification was recorded for this alert. Nothing was sent and nothing was withheld.
      </p>

      <div :if={is_nil(@error) and @deliveries != []} class="sr-ui-table-shell">
        <table class={ui_table_class(size: "xs", class: "w-full")}>
          <thead>
            <tr>
              <th class="whitespace-nowrap text-xs font-semibold text-sr-muted">State</th>
              <th class="whitespace-nowrap text-xs font-semibold text-sr-muted">Why</th>
              <th class="whitespace-nowrap text-xs font-semibold text-sr-muted">Channel</th>
              <th class="whitespace-nowrap text-xs font-semibold text-sr-muted">Step</th>
              <th class="whitespace-nowrap text-xs font-semibold text-sr-muted">Attempts</th>
              <th class="whitespace-nowrap text-xs font-semibold text-sr-muted">Recorded</th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={{delivery, delivery_idx} <- Enum.with_index(@deliveries)}
              class={[
                "align-top",
                AlertActions.test_delivery?(delivery) && "bg-sr-subtle/30 italic"
              ]}
            >
              <td class="whitespace-nowrap">
                <div class="flex flex-wrap items-center gap-1">
                  <.ui_badge variant={AlertActions.delivery_state_variant(delivery.state)} size="xs">
                    {AlertActions.delivery_state_label(delivery.state)}
                  </.ui_badge>
                  <.ui_badge :if={AlertActions.test_delivery?(delivery)} variant="outline" size="xs">
                    Test send
                  </.ui_badge>
                </div>
              </td>
              <td class="text-xs text-sr-ink">
                <div>{delivery_reason(delivery)}</div>
                <div :if={delivery.error_class} class="mt-0.5 font-mono text-[11px] text-sr-muted">
                  {delivery.error_class}
                </div>
                <div :if={delivery.error_message} class="mt-0.5 break-words text-[11px] text-sr-muted">
                  {delivery.error_message}
                </div>
              </td>
              <td class="whitespace-nowrap font-mono text-[11px] text-sr-ink">
                {delivery_channel(delivery)}
              </td>
              <td class="whitespace-nowrap text-xs text-sr-muted">
                {delivery_step(delivery)}
              </td>
              <td class="whitespace-nowrap text-xs text-sr-muted">
                {delivery.attempt_count}/{delivery.max_attempts}
                <div :if={delivery.next_attempt_at} class="inline-flex items-center gap-1 text-[11px]">
                  next
                  <.user_time
                    id={"alert-delivery-#{delivery_time_key(delivery, delivery_idx)}-next-attempt-time"}
                    value={delivery.next_attempt_at}
                    timezone={@timezone}
                    style={:full}
                    fallback="—"
                  />
                </div>
              </td>
              <td class="whitespace-nowrap font-mono text-[11px] text-sr-muted">
                <.user_time
                  id={"alert-delivery-#{delivery_time_key(delivery, delivery_idx)}-recorded-time"}
                  value={delivery_timestamp(delivery)}
                  timezone={@timezone}
                  style={:full}
                  fallback="—"
                />
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  defp delivery_reason(%{state: :suppressed, suppression_reason: reason}) do
    AlertActions.suppression_reason_label(reason) || "Suppressed"
  end

  defp delivery_reason(%{state: :sent}), do: "Delivered"
  defp delivery_reason(%{state: :skipped}), do: "Skipped before dispatch"
  defp delivery_reason(%{state: :pending}), do: "Awaiting its next attempt"
  defp delivery_reason(%{state: :dispatching}), do: "In flight"
  defp delivery_reason(%{state: :failed}), do: "Terminal failure"
  defp delivery_reason(%{state: :expired}), do: "Expired before delivery"
  defp delivery_reason(%{state: :cancelled}), do: "Cancelled"
  defp delivery_reason(_delivery), do: "-"

  defp delivery_channel(%{channel: %{name: name}}) when is_binary(name) and name != "", do: name

  defp delivery_channel(%{channel_id: id}) when is_binary(id), do: String.slice(id, 0, 8)

  defp delivery_channel(_delivery), do: "-"

  defp delivery_step(%{step_number: step}) when is_integer(step), do: "step #{step}"
  defp delivery_step(_delivery), do: "-"

  defp delivery_timestamp(delivery) do
    Map.get(delivery, :finished_at) || Map.get(delivery, :started_at) ||
      Map.get(delivery, :queued_at) || Map.get(delivery, :last_evaluated_at) ||
      Map.get(delivery, :inserted_at)
  end

  defp delivery_time_key(%{id: id}, _idx) when is_binary(id), do: id
  defp delivery_time_key(_delivery, idx), do: "row-#{idx}"

  # -- body panels ------------------------------------------------------------

  attr :alert, :map, required: true

  defp alert_message_hero(assigns) do
    description = Map.get(assigns.alert, "description")
    empty? = blank?(description)

    assigns =
      assigns
      |> assign(:description, description)
      |> assign(:empty?, empty?)

    ~H"""
    <div :if={not @empty?} class="space-y-3">
      <span class="font-sans text-xs font-medium uppercase tracking-wide text-sr-muted">
        Description
      </span>
      <div class="rounded-sr-surface border border-sr-line bg-[color-mix(in_srgb,var(--color-sr-canvas)_78%,var(--color-sr-subtle))] p-4 shadow-sr-surface sm:p-5">
        <p class="whitespace-pre-wrap break-words font-sans text-[15px] leading-relaxed text-sr-ink">
          {@description}
        </p>
      </div>
    </div>
    """
  end

  attr :alert, :map, required: true
  attr :timezone, :string, required: true

  defp stateful_incident_summary(assigns) do
    diagnostics = incident_diagnostics(assigns.alert)
    group_parts = group_dimension_parts(assigns.alert)
    series = finding_series(assigns.alert)

    assigns =
      assigns
      |> assign(:diagnostics, diagnostics)
      |> assign(:group_parts, group_parts)
      |> assign(:group_display, group_key_display(raw_group_key(assigns.alert), group_parts))
      |> assign(:process, first_sample(diagnostics, "processes"))
      |> assign(:container, first_sample(diagnostics, "containers"))
      |> assign(:kubernetes, first_sample(diagnostics, "kubernetes"))
      |> assign(:event_ids, diagnostic_value(diagnostics, ["representative_event_ids"]))
      |> assign(:device_uid, group_part(group_parts, "device") || Map.get(assigns.alert, "device_uid"))
      |> assign(:series_display, series.display)
      |> assign(:series_metric, series.metric)
      |> assign(:series_identity, series.identity)
      |> assign(:series_interface, series.interface)
      |> assign(:first_seen_at, incident_seen_at(assigns.alert, "first_seen_at", "incident_first_seen_at"))
      |> assign(:last_seen_at, incident_seen_at(assigns.alert, "last_seen_at", "incident_last_seen_at"))

    ~H"""
    <div class="overflow-hidden rounded-sr-surface border border-amber-500/25 bg-amber-500/5 shadow-sr-surface">
      <div class="flex items-start justify-between gap-4 border-b border-amber-500/15 px-4 py-3 sm:px-5">
        <div class="min-w-0">
          <span class="mb-1 block font-sans text-xs font-medium uppercase tracking-wide text-amber-600 dark:text-amber-400">
            Stateful incident
          </span>
          <h2 class="text-base font-semibold leading-tight text-sr-ink sm:text-lg">
            {EventTitle.alert_title(@alert) ||
              humanize_rule(diagnostic_value(@diagnostics, ["rule_name"])) ||
              "Rule threshold fired"}
          </h2>
        </div>
        <.severity_badge value={Map.get(@alert, "severity")} />
      </div>

      <div class="grid grid-cols-1 gap-4 p-4 sm:grid-cols-2 sm:p-5">
        <.fact_cell
          label="Group"
          value={@group_display}
          mono
          title={raw_group_key(@alert)}
        />
        <.fact_cell label="Metric" value={@series_metric} mono />
        <.fact_cell label="Identity" value={@series_identity} mono />
        <.fact_cell label="Interface" value={@series_interface} mono />
        <.fact_cell label="Series" value={@series_display} mono title={series_key(@alert)} />
        <.fact_cell
          label="Window count"
          value={diagnostic_value(@diagnostics, ["window_count"])}
          mono
        />
        <.fact_cell label="Threshold" value={diagnostic_value(@diagnostics, ["threshold"])} mono />
        <.fact_cell label="Window" value={window_display(@diagnostics)} mono />
        <.time_fact_cell
          id="alert-incident-first-seen-time"
          label="First seen"
          value={@first_seen_at}
          timezone={@timezone}
        />
        <.time_fact_cell
          id="alert-incident-last-seen-time"
          label="Last seen"
          value={@last_seen_at}
          timezone={@timezone}
        />
        <.fact_cell label="Process" value={process_display(@process)} mono />
        <.fact_cell label="Container" value={container_display(@container)} mono />
        <.fact_cell label="Image" value={image_display(@container)} mono />
        <.fact_cell label="Kubernetes" value={kubernetes_display(@kubernetes)} mono />
        <.fact_cell label="Attribution" value={attribution_display(@kubernetes)} />
      </div>

      <div
        :if={@group_parts != []}
        class="border-t border-amber-500/15 px-4 py-4 sm:px-5"
      >
        <span class="mb-3 block font-sans text-xs font-medium uppercase tracking-wide text-sr-muted">
          Group dimensions
        </span>
        <div class="grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-3">
          <div
            :for={part <- @group_parts}
            class="min-w-0 rounded-sr-control border border-sr-line/70 bg-sr-surface/70 px-3 py-2"
          >
            <div class="text-[10px] font-medium uppercase tracking-wide text-sr-muted">
              {part.label}
            </div>
            <.link
              :if={
                part.key == "device" and is_binary(part.value) and
                  String.starts_with?(part.value, "sr:")
              }
              navigate={~p"/devices/#{part.value}"}
              class="mt-0.5 block break-all font-mono text-[12px] leading-snug text-sr-brand hover:underline"
            >
              {part.display}
            </.link>
            <div
              :if={
                not (part.key == "device" and is_binary(part.value) and
                       String.starts_with?(part.value, "sr:"))
              }
              class="mt-0.5 break-all font-mono text-[12px] leading-snug text-sr-ink"
              title={part.value}
            >
              {part.display}
            </div>
          </div>
        </div>
      </div>

      <div
        :if={is_list(@event_ids) and @event_ids != []}
        class="border-t border-amber-500/15 px-4 py-3 sm:px-5"
      >
        <span class="mb-2 block font-sans text-xs font-medium uppercase tracking-wide text-sr-muted">
          Representative events
        </span>
        <div class="flex flex-wrap gap-1.5">
          <.ui_button
            :for={event_id <- Enum.take(@event_ids, 8)}
            href={~p"/events/#{event_id}"}
            size="xs"
            variant="outline"
            class="!font-mono"
          >
            {String.slice(to_string(event_id), 0, 8)}…
          </.ui_button>
        </div>
      </div>
    </div>
    """
  end

  attr :alert, :map, required: true
  attr :timezone, :string, required: true

  defp alert_context_panel(assigns) do
    facts = alert_context_facts(assigns.alert)
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
            :if={Map.get(fact, :time?, false)}
            id={fact.time_id}
            value={fact.value}
            timezone={@timezone}
            style={:full}
            fallback="—"
            class="break-all font-mono text-[13px] tracking-tight text-sr-ink"
          />
          <.link
            :if={not Map.get(fact, :time?, false) and is_binary(Map.get(fact, :href))}
            navigate={fact.href}
            class="break-all text-sm text-sr-brand hover:underline"
          >
            {fact.value}
          </.link>
          <span
            :if={not Map.get(fact, :time?, false) and is_nil(Map.get(fact, :href))}
            class={[
              "break-all text-sm text-sr-ink",
              fact.mono? && "font-mono text-[13px] tracking-tight"
            ]}
            title={Map.get(fact, :title)}
          >
            {fact.value}
          </span>
        </div>
      </div>
    </div>
    """
  end

  defp alert_context_facts(alert) when is_map(alert) do
    metadata = Map.get(alert, "metadata") || %{}
    diagnostics = incident_diagnostics(alert)

    base = [
      %{label: "Source type", value: Map.get(alert, "source_type"), mono?: false},
      %{label: "Source ID", value: Map.get(alert, "source_id"), mono?: true},
      %{label: "Event ID", value: Map.get(alert, "event_id"), mono?: true, href: event_href(Map.get(alert, "event_id"))},
      %{
        label: "Event time",
        value: Map.get(alert, "event_time"),
        mono?: true,
        time?: true,
        time_id: "alert-context-event-time"
      },
      %{
        label: "Hostname",
        value: Map.get(incident_group_values(alert), "hostname"),
        mono?: true
      },
      %{
        label: "Metric",
        value: finding_series(alert).metric || Map.get(alert, "metric_name"),
        mono?: true
      },
      %{
        label: "Identity",
        value: finding_series(alert).identity,
        mono?: true
      },
      %{
        label: "Interface",
        value: finding_series(alert).interface,
        mono?: true
      },
      %{
        label: "Metric value",
        value: format_optional_number(Map.get(alert, "metric_value")),
        mono?: true
      },
      %{
        label: "Threshold",
        value: format_optional_number(Map.get(alert, "threshold_value")),
        mono?: true
      },
      %{label: "Comparison", value: Map.get(alert, "comparison"), mono?: false},
      %{
        label: "Rule",
        value:
          humanize_rule(Map.get(metadata, "incident_rule_name")) ||
            humanize_rule(diagnostic_value(diagnostics, ["rule_name"])),
        mono?: false
      },
      %{
        label: "Log name",
        value: Map.get(metadata, "log_name"),
        mono?: true
      },
      %{
        label: "Provider",
        value: Map.get(metadata, "log_provider"),
        mono?: true
      },
      %{
        label: "Occurrence count",
        value: Map.get(metadata, "incident_occurrence_count") || Map.get(metadata, "incident_window_count"),
        mono?: true
      }
    ]

    (base ++ flatten_scalar_metadata(metadata))
    |> Enum.reject(fn fact -> blank_value?(fact.value) end)
    |> Enum.uniq_by(fn fact -> {fact.label, to_string(fact.value)} end)
  end

  defp alert_context_facts(_), do: []

  # Skip keys already promoted or nested blob keys.
  @skip_metadata_keys MapSet.new([
                        "incident_diagnostics",
                        "incident_group_key",
                        "incident_group_values",
                        "incident_rule_name",
                        "incident_rule_id",
                        "incident_first_seen_at",
                        "incident_last_seen_at",
                        "incident_occurrence_count",
                        "incident_window_count",
                        "event_id",
                        "event_time",
                        "log_name",
                        "log_provider",
                        "severity"
                      ])

  defp flatten_scalar_metadata(%{} = metadata) do
    metadata
    |> Enum.sort_by(fn {k, _} -> to_string(k) end)
    |> Enum.flat_map(fn {key, value} ->
      key = to_string(key)

      cond do
        MapSet.member?(@skip_metadata_keys, key) ->
          []

        value in [nil, "", []] ->
          []

        is_map(value) or is_list(value) ->
          []

        true ->
          [
            %{
              label: humanize_field(key),
              value: to_string(value),
              mono?: is_binary(value) and String.length(value) > 20
            }
          ]
      end
    end)
  end

  defp flatten_scalar_metadata(_), do: []

  attr :alert, :map, required: true

  defp related_links(assigns) do
    event_id = Map.get(assigns.alert, "event_id")
    device_uid = Map.get(assigns.alert, "device_uid")

    assigns =
      assigns
      |> assign(:event_id, event_id)
      |> assign(:device_uid, device_uid)

    ~H"""
    <div
      :if={is_binary(@event_id) or is_binary(@device_uid)}
      class="overflow-hidden rounded-sr-surface border border-sr-line bg-sr-surface shadow-sr-surface"
    >
      <div class="border-b border-sr-line bg-sr-subtle/30 px-4 py-2.5">
        <span class="font-sans text-xs font-medium uppercase tracking-wide text-sr-muted">
          Related
        </span>
      </div>
      <div class="flex flex-wrap gap-2 p-4">
        <.ui_button :if={@event_id} href={~p"/events/#{@event_id}"} size="sm" variant="outline">
          View triggering event
        </.ui_button>
        <.ui_button
          :if={@device_uid}
          navigate={~p"/devices/#{@device_uid}"}
          size="sm"
          variant="outline"
        >
          View device
        </.ui_button>
      </div>
    </div>
    """
  end

  attr :alert, :map, required: true
  attr :open?, :boolean, default: false

  defp alert_raw_toggle(assigns) do
    json =
      case assigns.alert do
        %{} = alert -> Jason.encode!(alert, pretty: true)
        _ -> ""
      end

    assigns = assign(assigns, :json, json)

    ~H"""
    <div class="overflow-hidden rounded-sr-surface border border-dashed border-sr-line/80 bg-sr-surface/60">
      <div class="flex flex-wrap items-center justify-between gap-2 px-4 py-2.5">
        <span class="font-sans text-xs font-medium text-sr-muted">Technical payload</span>
        <div class="flex items-center gap-1.5">
          <.ui_button :if={@open?} type="button" size="xs" variant="ghost" phx-click="copy_json">
            Copy JSON
          </.ui_button>
          <.ui_button type="button" size="xs" variant="outline" phx-click="toggle_raw_json">
            {if @open?, do: "Hide raw alert", else: "Show raw alert"}
          </.ui_button>
        </div>
      </div>
      <div :if={@open?} class="border-t border-sr-line px-4 py-3">
        <pre class="max-h-80 overflow-auto rounded-sr-control border border-sr-line bg-sr-subtle/30 p-3 font-mono text-[11px] leading-relaxed text-sr-ink/90">{@json}</pre>
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, default: nil
  attr :mono, :boolean, default: false
  attr :title, :any, default: nil

  defp fact_cell(assigns) do
    ~H"""
    <div :if={not blank?(@value)} class="min-w-0">
      <span class="mb-1 block font-sans text-xs font-medium uppercase tracking-wide text-sr-muted">
        {@label}
      </span>
      <span
        class={[
          "break-all text-sm text-sr-ink",
          @mono && "font-mono text-[13px] tracking-tight"
        ]}
        title={@title || if(is_binary(@value), do: @value)}
      >
        {display_value(@value)}
      </span>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :any, default: nil
  attr :timezone, :string, required: true

  defp time_fact_cell(assigns) do
    ~H"""
    <div :if={not blank?(@value)} class="min-w-0">
      <span class="mb-1 block font-sans text-xs font-medium uppercase tracking-wide text-sr-muted">
        {@label}
      </span>
      <.user_time
        id={@id}
        value={parsed_time_value(@value)}
        timezone={@timezone}
        style={:full}
        fallback="—"
        class="break-all font-mono text-[13px] tracking-tight text-sr-ink"
      />
    </div>
    """
  end

  # -- badges / formatting ----------------------------------------------------

  attr :value, :any, default: nil

  defp severity_badge(assigns) do
    assigns =
      assigns
      |> assign(:variant, severity_variant(assigns.value))
      |> assign(:label, severity_label(assigns.value))

    ~H"""
    <.ui_badge variant={@variant} size="sm">{@label}</.ui_badge>
    """
  end

  defp severity_variant(value) do
    case normalize_severity(value) do
      s when s in ["emergency", "critical", "error", "fatal"] -> "error"
      s when s in ["warning", "warn", "high"] -> "warning"
      s when s in ["info", "informational", "medium"] -> "info"
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

  attr :value, :any, default: nil

  defp status_badge(assigns) do
    assigns =
      assigns
      |> assign(:variant, status_variant(assigns.value))
      |> assign(:label, status_label(assigns.value))

    ~H"""
    <.ui_badge variant={@variant} size="sm">{@label}</.ui_badge>
    """
  end

  defp status_variant(value) do
    case normalize_status(value) do
      "pending" -> "warning"
      "acknowledged" -> "info"
      "resolved" -> "success"
      "escalated" -> "error"
      "suppressed" -> "ghost"
      _ -> "ghost"
    end
  end

  defp status_label(nil), do: "—"
  defp status_label(""), do: "—"
  defp status_label(value) when is_binary(value), do: String.capitalize(value)
  defp status_label(value), do: value |> to_string() |> String.capitalize()

  defp normalize_status(nil), do: ""
  defp normalize_status(v) when is_binary(v), do: String.downcase(v)
  defp normalize_status(v), do: v |> to_string() |> normalize_status()

  # -- group key / diagnostics ------------------------------------------------

  defp parse_group_key(nil), do: []
  defp parse_group_key(""), do: []

  defp parse_group_key(key) when is_binary(key) do
    key
    |> collect_group_pairs()
    |> Enum.map(fn {k, v} -> dimension_part(k, v) end)
  end

  defp parse_group_key(_), do: []

  defp collect_group_pairs(key) when is_binary(key) do
    key
    |> String.split("|")
    |> Enum.reduce([], fn part, acc ->
      case String.split(part, "=", parts: 2) do
        [k, v] when k != "" and v != "" ->
          [{k, v} | acc]

        [continuation] when continuation != "" ->
          case acc do
            [{k, v} | rest] -> [{k, v <> "|" <> continuation} | rest]
            _ -> acc
          end

        _ ->
          acc
      end
    end)
    |> Enum.reverse()
  end

  defp group_dimension_parts(alert) when is_map(alert) do
    values = incident_group_values(alert)

    if map_size(values) > 0 do
      values
      |> Enum.sort_by(fn {key, _} -> to_string(key) end)
      |> Enum.flat_map(fn {key, value} ->
        case value do
          v when is_binary(v) and v != "" ->
            [dimension_part(to_string(key), v)]

          v when is_atom(v) and not is_nil(v) ->
            [dimension_part(to_string(key), Atom.to_string(v))]

          _ ->
            []
        end
      end)
    else
      parse_group_key(raw_group_key(alert))
    end
  end

  defp group_dimension_parts(_), do: []

  defp dimension_part(key, value) do
    display =
      if String.contains?(key, "series_key") or String.starts_with?(value, "v2") do
        AnomalySeriesKey.display(value) || value
      else
        maybe_decode_hex(value)
      end

    %{
      key: key,
      label: humanize_field(String.replace(key, ".", " ")),
      value: value,
      display: display
    }
  end

  defp incident_group_values(alert) when is_map(alert) do
    metadata = Map.get(alert, "metadata") || %{}
    diagnostics = incident_diagnostics(alert)

    case Map.get(metadata, "incident_group_values") || diagnostic_value(diagnostics, ["group_values"]) do
      %{} = values -> values
      _ -> %{}
    end
  end

  defp incident_group_values(_), do: %{}

  defp raw_group_key(alert) when is_map(alert) do
    metadata = Map.get(alert, "metadata") || %{}

    Map.get(metadata, "incident_group_key") ||
      diagnostic_value(incident_diagnostics(alert), ["group_key"])
  end

  defp raw_group_key(_), do: nil

  defp series_key(alert) when is_map(alert) do
    values = incident_group_values(alert)

    Map.get(values, "anomaly.series_key") ||
      Map.get(values, "series_key") ||
      diagnostic_value(incident_diagnostics(alert), ["group_values", "anomaly.series_key"])
  end

  defp series_key(_), do: nil

  defp finding_series(alert) do
    key = series_key(alert)
    decoded = AnomalySeriesKey.decode(key)

    %{
      key: key,
      display: AnomalySeriesKey.display(key),
      metric: AnomalySeriesKey.component(decoded, "metric") || Map.get(alert, "metric_name"),
      identity: AnomalySeriesKey.component(decoded, "identity") || AnomalySeriesKey.component(decoded, "hint"),
      interface: anomaly_interface_label(decoded)
    }
  end

  defp anomaly_interface_label(decoded) do
    if_index = AnomalySeriesKey.component(decoded, "if_index")
    label = AnomalySeriesKey.tag(decoded, "label") || AnomalySeriesKey.tag(decoded, "if_name")

    cond do
      is_binary(label) and is_binary(if_index) -> "#{label} / ifIndex #{if_index}"
      is_binary(label) -> label
      is_binary(if_index) -> "ifIndex #{if_index}"
      true -> nil
    end
  end

  defp stream_secondary(alert) when is_map(alert) do
    series = finding_series(alert)
    values = incident_group_values(alert)

    first_present_text([
      series.identity,
      Map.get(values, "hostname"),
      series.metric,
      Map.get(alert, "status"),
      Map.get(alert, "source_type")
    ]) || "—"
  end

  defp stream_secondary(_), do: "—"

  defp first_present_text(values) do
    Enum.find_value(values, fn
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      _ ->
        nil
    end)
  end

  defp parsed_time_value(value) do
    case parse_alert_datetime(value) do
      {:ok, datetime} -> datetime
      _ -> value
    end
  end

  defp group_part(parts, key) when is_list(parts) do
    Enum.find_value(parts, fn
      %{key: ^key, value: value} -> value
      _ -> nil
    end)
  end

  defp group_part(_, _), do: nil

  defp group_key_display(raw, parts) when is_list(parts) and parts != [] do
    parts
    |> Enum.take(4)
    |> Enum.map_join(" · ", & &1.display)
    |> then(fn s ->
      if is_binary(raw) and String.length(raw) > 80, do: s, else: s
    end)
  end

  defp group_key_display(raw, _) when is_binary(raw), do: String.slice(raw, 0, 96)
  defp group_key_display(_, _), do: nil

  defp maybe_decode_hex(value) when is_binary(value) do
    if rem(byte_size(value), 2) == 0 and String.match?(value, ~r/\A[0-9a-fA-F]+\z/) do
      case Base.decode16(value, case: :mixed) do
        {:ok, decoded} ->
          if String.printable?(decoded) and String.trim(decoded) != "", do: decoded, else: value

        :error ->
          value
      end
    else
      value
    end
  end

  defp maybe_decode_hex(value), do: value

  defp humanize_rule(nil), do: nil
  defp humanize_rule(""), do: nil

  defp humanize_rule(name) when is_binary(name) do
    name
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp humanize_rule(other), do: to_string(other)

  defp stateful_incident?(alert) when is_map(alert) do
    metadata = Map.get(alert, "metadata") || %{}

    is_map(incident_diagnostics(alert)) and map_size(incident_diagnostics(alert)) > 0 and
      (Map.has_key?(metadata, "incident_rule_id") or Map.has_key?(metadata, "incident_diagnostics"))
  end

  defp stateful_incident?(_), do: false

  defp incident_diagnostics(alert) when is_map(alert) do
    metadata = Map.get(alert, "metadata") || %{}
    diagnostic_value(metadata, ["incident_diagnostics"]) || %{}
  end

  defp incident_diagnostics(_), do: %{}

  defp first_sample(diagnostics, sample_key) do
    diagnostics
    |> diagnostic_value(["samples", sample_key])
    |> case do
      [sample | _] when is_map(sample) -> sample
      _ -> %{}
    end
  end

  defp window_display(diagnostics) do
    case diagnostic_value(diagnostics, ["window_seconds"]) do
      nil -> nil
      seconds -> "#{seconds}s"
    end
  end

  defp process_display(process) when is_map(process) do
    diagnostic_value(process, ["command"]) || diagnostic_value(process, ["name"])
  end

  defp process_display(_), do: nil

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

  defp kubernetes_display(kubernetes) when is_map(kubernetes) do
    namespace = diagnostic_value(kubernetes, ["namespace"])
    pod = diagnostic_value(kubernetes, ["pod"])

    cond do
      is_binary(namespace) and is_binary(pod) -> "#{namespace}/#{pod}"
      is_binary(pod) -> pod
      is_binary(namespace) -> namespace
      true -> nil
    end
  end

  defp kubernetes_display(_), do: nil

  defp attribution_display(kubernetes) when is_map(kubernetes) do
    status = diagnostic_value(kubernetes, ["attribution_status"])
    missing = diagnostic_value(kubernetes, ["missing"])

    case {status, missing} do
      {nil, _} -> nil
      {value, []} -> value
      {value, nil} -> value
      {value, missing_values} -> "#{value} (missing #{display_value(missing_values)})"
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

  defp diagnostic_atom_key("incident_diagnostics"), do: :incident_diagnostics
  defp diagnostic_atom_key("group_values"), do: :group_values
  defp diagnostic_atom_key("samples"), do: :samples
  defp diagnostic_atom_key("processes"), do: :processes
  defp diagnostic_atom_key("containers"), do: :containers
  defp diagnostic_atom_key("kubernetes"), do: :kubernetes
  defp diagnostic_atom_key("rule_name"), do: :rule_name
  defp diagnostic_atom_key("group_key"), do: :group_key
  defp diagnostic_atom_key("window_count"), do: :window_count
  defp diagnostic_atom_key("threshold"), do: :threshold
  defp diagnostic_atom_key("window_seconds"), do: :window_seconds
  defp diagnostic_atom_key("first_seen_at"), do: :first_seen_at
  defp diagnostic_atom_key("last_seen_at"), do: :last_seen_at
  defp diagnostic_atom_key("representative_event_ids"), do: :representative_event_ids
  defp diagnostic_atom_key("command"), do: :command
  defp diagnostic_atom_key("name"), do: :name
  defp diagnostic_atom_key("id"), do: :id
  defp diagnostic_atom_key("image"), do: :image
  defp diagnostic_atom_key("image_repository"), do: :image_repository
  defp diagnostic_atom_key("image_tag"), do: :image_tag
  defp diagnostic_atom_key("namespace"), do: :namespace
  defp diagnostic_atom_key("pod"), do: :pod
  defp diagnostic_atom_key("attribution_status"), do: :attribution_status
  defp diagnostic_atom_key("missing"), do: :missing
  defp diagnostic_atom_key(_), do: :__unknown__

  # -- misc helpers -----------------------------------------------------------

  defp alert_source_kind(%{} = alert) do
    cond do
      stateful_incident?(alert) ->
        "incident"

      is_binary(Map.get(alert, "source_type")) and Map.get(alert, "source_type") != "" ->
        Map.get(alert, "source_type")

      true ->
        "alert"
    end
  end

  defp alert_source_kind(_), do: "alert"

  defp entry_id(alert, idx) do
    case Map.get(alert, "id") || Map.get(alert, "alert_id") do
      id when is_binary(id) and id != "" -> id
      _ -> "row-#{idx}"
    end
  end

  defp alert_timestamp_value(alert) when is_map(alert) do
    raw =
      Enum.find_value(
        [
          alert_map_get(alert, "triggered_at"),
          alert_map_get(alert, "timestamp"),
          alert_map_get(alert, "event_time"),
          alert_map_get(alert, "created_at"),
          alert_map_get(alert, "updated_at"),
          incident_seen_at(alert, "last_seen_at", "incident_last_seen_at"),
          incident_seen_at(alert, "first_seen_at", "incident_first_seen_at")
        ],
        &present_value/1
      )

    case parse_alert_datetime(raw) do
      {:ok, datetime} -> datetime
      _ -> raw
    end
  end

  defp alert_timestamp_value(_), do: nil

  defp incident_seen_at(alert, diagnostic_key, metadata_key) when is_map(alert) do
    metadata = alert_map_get(alert, "metadata")
    metadata = if is_map(metadata), do: metadata, else: %{}

    raw =
      present_value(diagnostic_value(incident_diagnostics(alert), [diagnostic_key])) ||
        present_value(alert_map_get(metadata, metadata_key))

    case parse_alert_datetime(raw) do
      {:ok, datetime} -> datetime
      _ -> raw
    end
  end

  defp incident_seen_at(_, _, _), do: nil

  defp present_value(value) when value in [nil, "", "—"], do: nil

  defp present_value(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp present_value(value), do: value

  defp alert_map_get(map, key) when is_map(map) and is_binary(key) do
    case present_value(Map.get(map, key)) do
      nil -> present_value(Map.get(map, alert_atom_key(key)))
      value -> value
    end
  end

  defp alert_map_get(_, _), do: nil

  defp alert_atom_key("triggered_at"), do: :triggered_at
  defp alert_atom_key("timestamp"), do: :timestamp
  defp alert_atom_key("event_time"), do: :event_time
  defp alert_atom_key("created_at"), do: :created_at
  defp alert_atom_key("updated_at"), do: :updated_at
  defp alert_atom_key("metadata"), do: :metadata
  defp alert_atom_key("incident_first_seen_at"), do: :incident_first_seen_at
  defp alert_atom_key("incident_last_seen_at"), do: :incident_last_seen_at
  defp alert_atom_key(_), do: :__unknown__

  defp parse_alert_datetime(%DateTime{} = datetime), do: {:ok, datetime}

  defp parse_alert_datetime(%NaiveDateTime{} = datetime) do
    {:ok, DateTime.from_naive!(datetime, "Etc/UTC")}
  end

  defp parse_alert_datetime(value) when is_binary(value) do
    value = value |> String.trim() |> String.replace(" ", "T")

    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        {:ok, datetime}

      _ ->
        case NaiveDateTime.from_iso8601(value) do
          {:ok, datetime} -> {:ok, DateTime.from_naive!(datetime, "Etc/UTC")}
          _ -> :error
        end
    end
  end

  defp parse_alert_datetime(_), do: :error

  defp format_optional_number(nil), do: nil
  defp format_optional_number(n) when is_number(n), do: to_string(n)
  defp format_optional_number(n) when is_binary(n), do: n
  defp format_optional_number(_), do: nil

  defp short_device(nil), do: nil
  defp short_device(""), do: nil

  defp short_device(uid) when is_binary(uid) do
    if String.length(uid) > 28, do: String.slice(uid, 0, 24) <> "…", else: uid
  end

  defp short_device(other), do: to_string(other)

  defp event_href(id) when is_binary(id) and id != "", do: ~p"/events/#{id}"
  defp event_href(_), do: nil

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

  defp display_value(value) when value in [nil, ""], do: "—"
  defp display_value(value) when is_binary(value), do: value
  defp display_value(value) when is_list(value), do: Enum.map_join(value, ", ", &display_value/1)
  defp display_value(value), do: to_string(value)

  defp blank?(value), do: value in [nil, ""]
  defp blank_value?(nil), do: true
  defp blank_value?(""), do: true
  defp blank_value?("—"), do: true
  defp blank_value?(_), do: false

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

  defp srql_module do
    Application.get_env(:serviceradar_web_ng, :srql_module, ServiceRadarWebNG.SRQL)
  end
end
