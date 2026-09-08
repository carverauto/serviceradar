defmodule ServiceRadarWebNGWeb.LogLive.Show do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.Observability.SignalDisplayComponents
  import ServiceRadarWebNGWeb.UIComponents

  alias ServiceRadar.Inventory.Device
  alias ServiceRadarWebNG.Observability.SignalDisplay
  alias ServiceRadarWebNGWeb.Components.PromotionRuleBuilder
  alias ServiceRadarWebNGWeb.Observability.DetailStreamComponents
  alias ServiceRadarWebNGWeb.SRQL.Builder
  alias ServiceRadarWebNGWeb.SRQL.Page, as: SRQLPage

  @redacted "[REDACTED]"
  @sensitive_log_keys ~w(
    authorization api_key apikey bearer cookie credential credentials jwt password
    private_key secret secret_key seed signing_key token nkey_seed nkey
  )
  # Side stream only — must not drive the main Observability logs list limit.
  @stream_page_size 10
  # Matches LogLive.Index / SRQL bar defaults when running a query from detail.
  @srql_default_limit 20

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Log Viewer")
     |> assign(:log_id, nil)
     |> assign(:log, nil)
     |> assign(:signal_display, nil)
     |> assign(:error, nil)
     |> assign(:show_rule_builder, false)
     |> assign(:stream_entries, [])
     |> assign(:stream_severity, "all")
     |> assign(:stream_query, nil)
     |> assign(:stream_cursor, nil)
     |> assign(:stream_next_cursor, nil)
     |> assign(:stream_prev_cursor, nil)
     |> assign(:stream_page, 1)
     |> assign(:stream_page_size, @stream_page_size)
     |> assign(:body_mode, "highlighted")
     |> assign(:limit, @srql_default_limit)
     |> SRQLPage.init("logs", default_limit: @srql_default_limit)}
  end

  @impl true
  def handle_params(%{"log_id" => log_id}, uri, socket) do
    log_id = normalize_uuid(log_id)
    {log, error} = load_log(log_id, socket.assigns.current_scope)
    # Side stream: related entries (service/time context). SRQL chrome: this log.
    stream_query = stream_query_for_log(log)
    detail_query = detail_query_for_log(log_id)

    {stream, next_cursor, prev_cursor} =
      load_stream_page(stream_query, log, log_id, nil, socket.assigns.current_scope)

    body =
      if is_map(log) do
        log_message(log)
      else
        ""
      end

    body_mode =
      cond do
        message_is_json?(body) -> "json"
        extract_kv_pairs(body) != [] -> "parsed"
        true -> "raw"
      end

    {:noreply,
     socket
     |> assign(:log_id, log_id)
     |> assign(:log, log)
     |> assign(:signal_display, build_signal_display(log))
     |> assign(:error, error)
     |> assign(:stream_entries, stream)
     |> assign(:stream_query, stream_query)
     |> assign(:stream_cursor, nil)
     |> assign(:stream_next_cursor, next_cursor)
     |> assign(:stream_prev_cursor, prev_cursor)
     |> assign(:stream_page, 1)
     |> assign(:stream_severity, "all")
     |> assign(:body_mode, body_mode)
     |> assign(:page_title, page_title_for(log, log_id))
     |> prefill_srql_bar(detail_query, uri, log_id)}
  end

  @impl true
  def handle_event("open_rule_builder", _params, socket) do
    {:noreply, assign(socket, :show_rule_builder, true)}
  end

  def handle_event("set_body_mode", %{"mode" => mode}, socket) when mode in ~w(parsed raw json highlighted) do
    # "highlighted" kept as alias for older sessions
    mode = if mode == "highlighted", do: "parsed", else: mode
    {:noreply, assign(socket, :body_mode, mode)}
  end

  def handle_event("set_stream_severity", %{"severity" => severity}, socket)
      when severity in ~w(all info warn warning error debug) do
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
    {:noreply, push_event(socket, "clipboard", %{text: socket.assigns.log_id || ""})}
  end

  def handle_event("copy_json", _params, socket) do
    text =
      case socket.assigns.log do
        %{} = log -> log |> Map.delete("source_device_uid") |> Jason.encode!(pretty: true)
        _ -> ""
      end

    {:noreply, push_event(socket, "clipboard", %{text: text})}
  end

  def handle_event("copy_message", _params, socket) do
    text =
      case socket.assigns.log do
        %{} = log -> log_message(log)
        _ -> ""
      end

    {:noreply, push_event(socket, "clipboard", %{text: text})}
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
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_toggle", %{}, entity: "logs")}
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
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_add_filter", params, entity: "logs")}
  end

  def handle_event("srql_builder_remove_filter", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_remove_filter", params, entity: "logs")}
  end

  @impl true
  def handle_info({:rule_builder_closed}, socket) do
    {:noreply, assign(socket, :show_rule_builder, false)}
  end

  def handle_info({:rule_created, rule}, socket) do
    {:noreply,
     socket
     |> assign(:show_rule_builder, false)
     |> put_flash(:info, "Rule \"#{rule.name}\" created successfully.")
     |> push_navigate(to: ~p"/settings/rules?#{%{tab: "events"}}")}
  end

  def handle_info({:rule_creation_failed, reason}, socket) do
    {:noreply, put_flash(socket, :error, "Failed to create rule: #{format_error(reason)}")}
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
          :logs
        )
      )

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} srql={@srql}>
      <div class="sr-log-viewer flex min-w-0 max-w-full flex-col pt-2 sm:pt-3 lg:h-[calc(100dvh-7.5rem)] lg:max-h-[calc(100dvh-7.5rem)] lg:overflow-hidden">
        <div :if={@error} class="shrink-0 border-b border-sr-line px-1 py-3 sm:px-2">
          <div class={ui_alert_class(variant: "error")}>
            <.icon name="hero-exclamation-circle" class="size-5 shrink-0" />
            <p>{@error}</p>
          </div>
        </div>

        <div
          :if={is_map(@log)}
          class="grid min-h-0 min-w-0 max-w-full flex-1 grid-cols-1 overflow-hidden border-t border-sr-line lg:grid-cols-[15.5rem_minmax(0,1fr)] xl:grid-cols-[16.5rem_minmax(0,1fr)]"
        >
          <%!-- Desktop-only stream; mobile is detail-only --%>
          <.detail_stream_pane
            id="log-stream"
            title="Log stream"
            class="sr-log-stream"
            entries={@visible_stream}
            timezone={@current_scope.user.timezone}
            page_count={length(@visible_stream)}
            page={@stream_page}
            selected_id={@log_id}
            stream_severity={@stream_severity}
            severity_filters={~w(all info warn error debug)}
            context_label={Map.get(@log, "service_name")}
            stream_query={@stream_query || Map.get(@srql, :query)}
            has_prev={@stream_page > 1}
            has_next={is_binary(@stream_next_cursor) and @stream_next_cursor != ""}
            empty_label="No matching entries"
          />

          <section class="flex min-h-0 min-w-0 flex-col overflow-hidden lg:border-l lg:border-sr-line">
            <.log_detail_header
              log={@log}
              log_id={@log_id}
              can_create_rules?={can_create_rules?(@current_scope)}
            />
            <.log_meta_strip log={@log} timezone={@current_scope.user.timezone} />

            <div class="min-h-0 min-w-0 flex-1 space-y-5 overflow-x-hidden overflow-y-auto px-3 py-5 sm:px-5">
              <.log_message_hero log={@log} body_mode={@body_mode} />
              <.log_attributes_panel log={@log} />
              <.signal_display_panel
                :if={is_list(@signal_display)}
                id="log-signal-display"
                widgets={@signal_display}
                timezone={@current_scope.user.timezone}
              />
            </div>
          </section>
        </div>
      </div>

      <.live_component
        :if={@show_rule_builder}
        module={PromotionRuleBuilder}
        id="rule-builder"
        log={@log}
        current_scope={@current_scope}
      />
    </Layouts.app>
    """
  end

  # -- data loading -----------------------------------------------------------

  defp load_log(log_id, scope) do
    query = detail_query_for_log(log_id) <> " limit:1"

    case srql_module().query(query, %{scope: scope}) do
      {:ok, %{"results" => [log | _]}} when is_map(log) ->
        {augment_log(log, scope), nil}

      {:ok, %{"results" => []}} ->
        {nil, "Log entry not found."}

      {:ok, _} ->
        {nil, "Unexpected response format"}

      {:error, reason} ->
        error_msg = format_error(reason)

        if String.contains?(error_msg, "unsupported filter") do
          {nil, "Log detail view is not available - ID-based filtering is unsupported."}
        else
          {nil, "Failed to load log: #{error_msg}"}
        end
    end
  end

  # Query that pinpoints the open log entry (SRQL chrome / re-run from detail).
  defp detail_query_for_log(log_id) when is_binary(log_id) do
    ~s|in:logs id:"#{escape_value(log_id)}" time:last_24h|
  end

  defp detail_query_for_log(_), do: "in:logs time:last_24h"

  # Related stream for the left rail — same service, not the single-id lookup.
  defp stream_query_for_log(%{} = log) do
    service = Map.get(log, "service_name")

    if is_binary(service) and String.trim(service) != "" do
      ~s|in:logs service_name:"#{escape_value(service)}" time:last_24h sort:timestamp:desc|
    else
      "in:logs time:last_24h sort:timestamp:desc"
    end
  end

  defp stream_query_for_log(_), do: "in:logs time:last_24h sort:timestamp:desc"

  defp load_stream_into_socket(socket, cursor, page) do
    query = socket.assigns.stream_query || stream_query_for_log(socket.assigns.log)

    {stream, next_cursor, prev_cursor} =
      load_stream_page(
        query,
        socket.assigns.log,
        socket.assigns.log_id,
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

  defp load_stream_page(query, log, selected_id, cursor, scope) when is_binary(query) do
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
          if is_nil(cursor) and is_map(log) do
            ensure_selected_in_stream(entries, log, selected_id)
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

  defp load_stream_page(_, log, selected_id, cursor, scope) when is_map(log) do
    load_stream_page(stream_query_for_log(log), log, selected_id, cursor, scope)
  end

  defp load_stream_page(_, _, _, _, _), do: {[], nil, nil}

  defp refresh_stream_from_srql(socket) do
    raw =
      case Map.get(socket.assigns.srql || %{}, :query) do
        q when is_binary(q) -> String.trim(q)
        _ -> ""
      end

    fallback = socket.assigns.stream_query || stream_query_for_log(socket.assigns.log)

    query =
      if raw != "" and String.contains?(raw, "in:logs") do
        strip_embedded_limit(raw)
      else
        fallback
      end

    {stream, next_cursor, prev_cursor} =
      load_stream_page(
        query,
        socket.assigns.log,
        socket.assigns.log_id,
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

  defp prefill_srql_bar(socket, query, uri, log_id) when is_binary(query) do
    page_path =
      case uri do
        path when is_binary(path) and path != "" ->
          URI.parse(uri).path || "/logs/#{log_id}"

        _ ->
          "/logs/#{log_id}"
      end

    srql =
      socket.assigns.srql
      |> Map.merge(%{
        enabled: true,
        entity: "logs",
        query: query,
        draft: query,
        page_path: page_path || "/logs/#{log_id}",
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

  defp stream_entry(log, idx) when is_map(log) do
    body = log_message(log)
    id = entry_id(log, idx)

    %{
      id: id,
      dom_id: "log-entry-#{idx}",
      href: ~p"/logs/#{id}",
      severity: Map.get(log, "severity_text"),
      secondary: Map.get(log, "service_name") || Map.get(log, "service") || "—",
      timestamp: Map.get(log, "observed_timestamp") || Map.get(log, "timestamp"),
      preview: message_preview(body)
    }
  end

  defp ensure_selected_in_stream(entries, log, selected_id) do
    if Enum.any?(entries, &(&1.id == selected_id)) do
      entries
    else
      [stream_entry(Map.put(log, "id", selected_id), "selected") | entries]
    end
  end

  defp page_title_for(%{} = log, log_id) do
    case log_headline(log_message(log)) do
      nil -> "Log · #{String.slice(to_string(log_id), 0, 8)}"
      title -> title
    end
  end

  defp page_title_for(_, log_id), do: "Log · #{String.slice(to_string(log_id), 0, 8)}"

  # -- detail header / meta ---------------------------------------------------

  attr :log, :map, required: true
  attr :log_id, :string, required: true
  attr :can_create_rules?, :boolean, default: false

  defp log_detail_header(assigns) do
    body = log_message(assigns.log)
    title = log_headline(body) || "Log entry"

    assigns =
      assigns
      |> assign(:title, title)
      |> assign(:source_kind, log_source_kind(assigns.log))
      |> assign(:short_id, String.slice(assigns.log_id, 0, 8))

    ~H"""
    <header class="space-y-3 border-b border-sr-line px-4 pb-4 pt-5 font-sans sm:px-6 sm:pt-6">
      <div class="flex flex-wrap items-center justify-between gap-x-3 gap-y-2">
        <div class="flex min-w-0 flex-wrap items-center gap-x-2 gap-y-1 text-sm text-sr-muted">
          <.link navigate={~p"/observability/logs"} class="hover:text-sr-ink">
            logs
          </.link>
          <span class="text-sr-line-strong">/</span>
          <span class="text-sr-ink/80">{@source_kind}</span>
          <span class="text-sr-line-strong">/</span>
          <span class="font-mono text-sr-ink">{@short_id}</span>
        </div>

        <div class="flex shrink-0 flex-wrap items-center gap-1.5">
          <.ui_button href={~p"/observability/logs"} variant="outline" size="xs">
            Back to logs
          </.ui_button>
          <.ui_button type="button" variant="outline" size="xs" phx-click="copy_json">
            Copy JSON
          </.ui_button>
          <.ui_button
            :if={@can_create_rules?}
            phx-click="open_rule_builder"
            variant="primary"
            size="xs"
          >
            <.icon name="hero-plus" class="size-3.5" /> Create event rule
          </.ui_button>
        </div>
      </div>

      <div class="min-w-0 space-y-2">
        <div class="flex min-w-0 items-start gap-2.5">
          <.severity_badge value={Map.get(@log, "severity_text")} />
          <h1
            class="min-w-0 flex-1 font-sans text-lg font-semibold leading-snug tracking-tight text-sr-ink sm:text-xl line-clamp-2"
            title={@title}
          >
            {@title}
          </h1>
        </div>
        <div class="flex flex-wrap items-center gap-2">
          <code class="break-all font-mono text-xs text-sr-muted">{@log_id}</code>
          <.ui_button type="button" size="xs" variant="ghost" phx-click="copy_id">Copy ID</.ui_button>
        </div>
      </div>
    </header>
    """
  end

  attr :log, :map, required: true
  attr :timezone, :string, required: true

  defp log_meta_strip(assigns) do
    attrs = parse_attributes(Map.get(assigns.log, "attributes")) || %{}
    service = Map.get(assigns.log, "service_name")
    source_ip = Map.get(assigns.log, "source_ip")
    timestamp = timestamp_meta(assigns.log)
    target = scalar_attr(attrs, ["target_name", "target"])
    agent = log_agent_identity(assigns.log, attrs)
    error = scalar_attr(attrs, ["error", "err"])

    facts =
      Enum.reject(
        [
          %{label: "Target", value: target, mono?: true, href: nil},
          %{label: "Agent", value: agent, mono?: true, href: nil},
          %{
            label: "Service",
            value: service,
            mono?: false,
            href: logs_filter_href("service_name", service)
          },
          %{
            label: "Source IP",
            value: source_ip,
            mono?: true,
            href: logs_filter_href("source_ip", source_ip)
          },
          %{label: "Error", value: error, mono?: true, href: nil},
          %{label: "Facility", value: log_facility(assigns.log), mono?: false, href: nil},
          %{label: "Format", value: log_format(assigns.log), mono?: true, href: nil},
          %{label: "Scope", value: Map.get(assigns.log, "scope_name"), mono?: true, href: nil}
        ],
        fn fact -> blank_value?(fact.value) end
      )

    n = length(facts) + 1

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
      |> assign(:timestamp, timestamp)
      |> assign(:col_class, col_class)

    ~H"""
    <div class={["grid gap-px border-b border-sr-line bg-sr-line", @col_class]}>
      <div class="flex min-w-0 flex-col gap-1 bg-sr-surface px-4 py-3">
        <span class="font-sans text-xs font-medium uppercase tracking-wide text-sr-muted">
          Timestamp
        </span>
        <.user_time
          id="log-detail-time"
          value={@timestamp.value}
          timezone={@timezone}
          style={:full}
          fallback={@timestamp.fallback}
          class="truncate font-mono text-[13px] tracking-tight text-sr-ink"
        />
      </div>
      <div
        :for={fact <- @facts}
        class="flex min-w-0 flex-col gap-1 bg-sr-surface px-4 py-3"
      >
        <span class="font-sans text-xs font-medium uppercase tracking-wide text-sr-muted">
          {fact.label}
        </span>
        <.link
          :if={is_binary(fact.href)}
          navigate={fact.href}
          class={[
            "group inline-flex min-w-0 max-w-full items-center gap-1 truncate text-sm text-sr-brand transition-colors hover:text-sr-brand-strong hover:underline",
            fact.mono? && "font-mono text-[13px] tracking-tight"
          ]}
          title={"Filter logs by #{fact.label}: #{fact.value}"}
        >
          <span class="truncate">{fact.value}</span>
          <.icon
            name="hero-arrow-top-right-on-square"
            class="size-3.5 shrink-0 opacity-60 transition-opacity group-hover:opacity-100"
          />
        </.link>
        <span
          :if={is_nil(fact.href)}
          class={[
            "truncate font-sans text-sm text-sr-ink",
            fact.mono? && "font-mono text-[13px] tracking-tight"
          ]}
        >
          {fact.value}
        </span>
      </div>
    </div>
    """
  end

  # Main log viewer with a single equality filter (service / source IP).
  defp logs_filter_href(_field, value) when not is_binary(value) or value == "", do: nil

  defp logs_filter_href(field, value) when is_binary(field) and is_binary(value) do
    value = String.trim(value)

    if value == "" do
      nil
    else
      query =
        ~s|in:logs #{field}:"#{escape_value(value)}" time:last_24h sort:timestamp:desc|

      ~p"/observability/logs?#{%{q: query}}"
    end
  end

  # -- message hero -----------------------------------------------------------

  attr :log, :map, required: true
  attr :body_mode, :string, required: true

  defp log_message_hero(assigns) do
    body = redact_secret_text(log_message(assigns.log))
    is_json = message_is_json?(body)
    pairs = extract_message_pairs(body)
    prefix = message_prefix(body) || wevent_message_prefix(body)
    has_structure? = pairs != []

    pretty_json =
      if is_json do
        case Jason.decode(body) do
          {:ok, decoded} -> Jason.encode!(decoded, pretty: true)
          _ -> nil
        end
      end

    # Prefer structured parse when available; otherwise fall back to raw-style view.
    default_mode =
      cond do
        is_json -> "json"
        has_structure? -> "parsed"
        true -> "raw"
      end

    modes =
      cond do
        is_json and has_structure? -> ~w(parsed raw json)
        is_json -> ~w(raw json)
        has_structure? -> ~w(parsed raw)
        true -> ~w(raw)
      end

    body_mode =
      if assigns.body_mode in modes do
        assigns.body_mode
      else
        default_mode
      end

    assigns =
      assigns
      |> assign(:body, body)
      |> assign(:is_json, is_json)
      |> assign(:pretty_json, pretty_json)
      |> assign(:pairs, pairs)
      |> assign(:prefix, prefix)
      |> assign(:has_structure?, has_structure?)
      |> assign(:empty?, body == "")
      |> assign(:modes, modes)
      |> assign(:body_mode, body_mode)

    ~H"""
    <div :if={not @empty?} class="space-y-3">
      <div class="flex flex-wrap items-center justify-between gap-3">
        <div class="flex flex-wrap items-center gap-2">
          <span class="font-sans text-xs font-medium uppercase tracking-wide text-sr-muted">
            Message
          </span>
          <div
            :if={length(@modes) > 1}
            class="inline-flex gap-0.5 rounded-sr-control border border-sr-line bg-sr-subtle/40 p-0.5"
          >
            <.ui_button
              :for={mode <- @modes}
              type="button"
              size="xs"
              variant={if(@body_mode == mode, do: "soft", else: "ghost")}
              phx-click="set_body_mode"
              phx-value-mode={mode}
              class="min-h-7 px-2.5 capitalize"
            >
              {mode}
            </.ui_button>
          </div>
        </div>
        <.ui_button type="button" size="xs" variant="ghost" phx-click="copy_message">Copy</.ui_button>
      </div>

      <%!-- Parsed: structured fields only (no duplicate wall of text) --%>
      <div
        :if={@body_mode == "parsed" and @has_structure?}
        class="overflow-hidden rounded-sr-surface border border-sr-line bg-sr-surface shadow-sr-surface"
      >
        <div
          :if={is_binary(@prefix) and @prefix != ""}
          class="border-b border-sr-line bg-sr-subtle/40 px-4 py-3 font-mono text-sm text-sr-ink"
        >
          {@prefix}
        </div>
        <div class="grid grid-cols-1 divide-y divide-sr-line sm:grid-cols-2 sm:divide-x sm:divide-y-0 lg:grid-cols-3">
          <div
            :for={{key, value} <- @pairs}
            class="flex min-w-0 flex-col gap-1 px-4 py-3 even:bg-sr-subtle/20 sm:even:bg-transparent sm:[&:nth-child(2n)]:bg-sr-subtle/15 lg:[&:nth-child(2n)]:bg-transparent lg:[&:nth-child(3n+2)]:bg-sr-subtle/15"
          >
            <span class="font-mono text-xs uppercase tracking-wide text-sr-muted">{key}</span>
            <span class={[
              "break-all font-mono text-sm text-sr-ink",
              value_looks_like_ip?(value) && "text-sr-brand"
            ]}>
              {if value == "", do: "—", else: value}
            </span>
          </div>
        </div>
      </div>

      <%!-- Raw / JSON: original payload only --%>
      <div
        :if={@body_mode in ["raw", "json"] or not @has_structure?}
        class="rounded-sr-surface border border-sr-line bg-[color-mix(in_srgb,var(--color-sr-canvas)_78%,var(--color-sr-subtle))] p-4 shadow-sr-surface sm:p-5"
      >
        <pre
          :if={@body_mode == "json" and is_binary(@pretty_json)}
          class="whitespace-pre-wrap break-words font-mono text-sm leading-relaxed text-sr-ink selection:bg-sr-brand/25"
        >{@pretty_json}</pre>
        <pre
          :if={@body_mode != "json" or is_nil(@pretty_json)}
          class="whitespace-pre-wrap break-words font-mono text-sm leading-relaxed text-sr-ink selection:bg-sr-brand/25"
        >{@body}</pre>
      </div>
    </div>
    """
  end

  attr :log, :map, required: true

  defp log_attributes_panel(assigns) do
    attrs = parse_attributes(Map.get(assigns.log, "attributes")) || %{}
    resource = parse_attributes(Map.get(assigns.log, "resource_attributes")) || %{}

    source_device_uid =
      case Map.get(assigns.log, "source_device_uid") do
        uid when is_binary(uid) and uid != "" -> uid
        _ -> ""
      end

    promoted = MapSet.new(["target_name", "target", "error", "err", "agent_id"])

    attr_pairs =
      attrs
      |> Map.delete("serviceradar.ingest")
      |> flatten_attribute_values()
      |> Enum.reject(fn {key, _} -> MapSet.member?(promoted, key) end)

    ingest_pairs =
      attrs
      |> Map.get("serviceradar.ingest")
      |> flatten_attribute_values()

    resource_pairs = flatten_attribute_values(resource)

    assigns =
      assigns
      |> assign(:attr_pairs, attr_pairs)
      |> assign(:ingest_pairs, ingest_pairs)
      |> assign(:resource_pairs, resource_pairs)
      |> assign(:source_device_uid, source_device_uid)
      |> assign(
        :empty?,
        attr_pairs == [] and ingest_pairs == [] and resource_pairs == []
      )

    ~H"""
    <div :if={not @empty?} class="space-y-4">
      <.log_kv_section
        :if={@attr_pairs != []}
        title="Attributes"
        pairs={@attr_pairs}
        source_device_uid={@source_device_uid}
      />
      <.log_kv_section
        :if={@resource_pairs != []}
        title="Resource Attributes"
        pairs={@resource_pairs}
        source_device_uid={@source_device_uid}
      />
      <.log_kv_section
        :if={@ingest_pairs != []}
        title="Ingest"
        pairs={@ingest_pairs}
      />
    </div>
    """
  end

  attr :title, :string, required: true
  attr :pairs, :list, required: true
  attr :source_device_uid, :string, default: ""

  defp log_kv_section(assigns) do
    ~H"""
    <div class="space-y-2">
      <span class="font-sans text-xs font-medium uppercase tracking-wide text-sr-muted">
        {@title}
      </span>
      <div class="overflow-hidden rounded-sr-surface border border-sr-line bg-sr-surface shadow-sr-surface">
        <div class="grid grid-cols-1 divide-y divide-sr-line sm:grid-cols-2 sm:divide-x sm:divide-y-0 lg:grid-cols-3">
          <div
            :for={{key, value} <- @pairs}
            class="flex min-w-0 flex-col gap-1 px-4 py-3 even:bg-sr-subtle/20 sm:even:bg-transparent sm:[&:nth-child(2n)]:bg-sr-subtle/15 lg:[&:nth-child(2n)]:bg-transparent lg:[&:nth-child(3n+2)]:bg-sr-subtle/15"
          >
            <span class="font-mono text-xs uppercase tracking-wide text-sr-muted">{key}</span>
            <.link
              :if={key == "source" and is_binary(@source_device_uid) and @source_device_uid != ""}
              navigate={~p"/devices/#{@source_device_uid}"}
              class="break-all font-mono text-sm text-sr-brand hover:underline"
            >
              {format_attribute_value(key, value)}
            </.link>
            <span
              :if={key != "source" or @source_device_uid in [nil, ""]}
              class="break-all font-mono text-sm text-sr-ink"
            >
              {format_attribute_value(key, value)}
            </span>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # -- message helpers --------------------------------------------------------

  defp log_message(log) when is_map(log), do: Map.get(log, "body") || Map.get(log, "message") || ""
  defp log_message(_), do: ""

  defp message_is_json?(body) when is_binary(body) do
    t = String.trim(body)
    String.starts_with?(t, "{") or String.starts_with?(t, "[")
  end

  defp message_is_json?(_), do: false

  defp message_preview(body, max \\ 72)

  defp message_preview(body, max) when is_binary(body) do
    body = body |> String.replace(~r/\s+/, " ") |> String.trim()

    cond do
      body == "" -> "—"
      String.length(body) > max -> String.slice(body, 0, max - 1) <> "…"
      true -> body
    end
  end

  defp message_preview(_, _), do: "—"

  # Hero title next to the severity badge — short scan line only.
  # Full body always lives in the Message section below.
  defp log_headline(body) when is_binary(body) do
    body = body |> String.replace(~r/\s+/, " ") |> String.trim()

    if body == "" do
      nil
    else
      # iptables/nft LOG: [RULE] DESCR="Allow SSH…" (not bare rule id)
      # Compact UniFi wevent (EVENT + iface/MAC)
      # Syslog: keep process context — "dnsmasq-dhcp[4129]: Updating leases"
      Enum.find_value(
        [
          extract_firewall_rule_headline(body),
          extract_event_subject(body),
          extract_wevent_headline(body),
          extract_syslog_process_headline(body),
          extract_function_event(body),
          extract_subject_after_syslog(body),
          extract_bracket_title(body),
          first_log_sentence(peel_host_prefix(body))
        ],
        fn candidate ->
          case candidate do
            title when is_binary(title) ->
              title = summarize_headline(title)
              if usable_headline?(title), do: title

            _ ->
              nil
          end
        end
      )
    end
  end

  defp log_headline(_), do: nil

  # Cap hero text: drop stacktraces/docs, keep ~one short line.
  defp summarize_headline(title) when is_binary(title) do
    title
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> strip_logger_stack_and_docs()
    |> first_log_sentence()
    |> truncate_headline(110)
  end

  defp summarize_headline(_), do: nil

  # Logger/Ash walls: cut at stack frames or the long "This happens when…" docs.
  defp strip_logger_stack_and_docs(text) when is_binary(text) do
    text
    # (elixir 1.19.4) lib/... stack frames
    |> then(fn t ->
      case Regex.split(~r/\s*[,(]\s*\(elixir\s+\d/, t, parts: 2) do
        [head | _] -> head
        _ -> t
      end
    end)
    # ", lib/foo.ex:" or " lib/ash/..." embedded frames
    |> then(fn t ->
      case Regex.split(~r/,\s*lib\/|\s+lib\/[a-z_]+\/|\s+lib\/[a-z_]+\.ex:/, t, parts: 2) do
        [head | _] -> head
        _ -> t
      end
    end)
    # Ash missed-notifications essay after the real warning
    |> then(fn t ->
      case Regex.split(
             ~r/,\s*,\s*This happens when\b|,\s*This happens when\b|\.\s+This happens when\b/,
             t,
             parts: 2
           ) do
        [head | _] -> head
        _ -> t
      end
    end)
    # Logger iodata glue ", ,"
    |> then(fn t ->
      case Regex.split(~r/,\s*,\s*/, t, parts: 2) do
        [head | _] -> head
        _ -> t
      end
    end)
    |> String.trim()
    |> String.trim_trailing(",")
    |> String.trim()
  end

  defp strip_logger_stack_and_docs(text), do: text

  # First sentence / clause; avoid chopping Module.Name.func.
  defp first_log_sentence(text) when is_binary(text) do
    text = String.trim(text)

    cond do
      text == "" ->
        nil

      # Sentence end: ". " then capital letter (prose), not Module.func
      m = Regex.run(~r/^(.+?\.)\s+(?=[A-Z])(.*)$/s, text) ->
        [_, first, _rest] = m
        String.trim(first)

      true ->
        text
    end
  end

  defp first_log_sentence(_), do: nil

  defp truncate_headline(nil, _), do: nil

  defp truncate_headline(text, max) when is_binary(text) and is_integer(max) do
    text = String.trim(text)

    cond do
      text == "" ->
        nil

      String.length(text) <= max ->
        text

      true ->
        cut =
          text
          |> String.slice(0, max)
          |> String.replace(~r/\s+\S*$/, "")
          |> String.trim_trailing(".,;:")

        if cut == "", do: String.slice(text, 0, max) <> "…", else: cut <> "…"
    end
  end

  defp truncate_headline(text, _), do: text

  defp usable_headline?(title) when is_binary(title) do
    title = String.trim(title)

    title != "" and has_latin_letter?(title) and not pure_numeric_token?(title) and
      not mac_tail_headline?(title) and not metrics_only_headline?(title) and
      not kernel_timestamp_headline?(title) and not generic_wrapper_only?(title)
  end

  defp usable_headline?(_), do: false

  # "wevent[2066]: wevent.ubnt_custom_event(): EVENT_STA_JOIN wifi0ap0: aa:bb:… / 2"
  defp extract_wevent_headline(body) when is_binary(body) do
    case Regex.run(~r/\b(wevent\[\d+\]:\s*.+)$/i, body) do
      [_, subject] ->
        subject = String.trim(subject)
        if usable_headline?(subject), do: subject

      _ ->
        nil
    end
  end

  defp extract_wevent_headline(_), do: nil

  # "tonka01 dnsmasq-dhcp[4129]: Updating leases :: AGE=…"
  # Keep process[pid] in the hero — it is the real context (not just hostname).
  defp extract_syslog_process_headline(body) when is_binary(body) do
    head =
      body
      |> peel_host_prefix()
      # Drop KEY= tail (AGE=6sec FILE=…)
      |> String.replace(~r/\s+[A-Za-z_][A-Za-z0-9_]{0,24}=.*$/, "")
      # Drop trailing empty "::" markers
      |> String.replace(~r/\s*::\s*$/, "")
      |> String.trim()
      |> String.trim_trailing(":")
      |> String.trim()

    if Regex.match?(~r/\b[A-Za-z_][\w.-]+\[\d+\]:/, head) and usable_headline?(head) do
      head
    end
  end

  defp extract_syslog_process_headline(_), do: nil

  # tonka01 [WAN_CUSTOM2-A-10008] DESCR="Allow SSH to forgejo" IN=… DPT=22
  # Prefer human DESCR + rule id over bare "[WAN_CUSTOM2-A-10008]".
  defp extract_firewall_rule_headline(body) when is_binary(body) do
    rule =
      case Regex.run(~r/\[([A-Za-z][A-Za-z0-9_.-]{2,63})\]/, body) do
        [_, name] -> name
        _ -> nil
      end

    descr =
      case Regex.run(~r/\bDESCR="([^"]{1,120})"/i, body) do
        [_, text] ->
          String.trim(text)

        _ ->
          case Regex.run(~r/\bDESCR=([^\s]{1,120})/i, body) do
            [_, text] -> String.trim(text)
            _ -> nil
          end
      end

    proto =
      case Regex.run(~r/\bPROTO=([A-Za-z0-9]+)/i, body) do
        [_, p] -> String.upcase(p)
        _ -> nil
      end

    dpt =
      case Regex.run(~r/\bDPT=(\d+)/i, body) do
        [_, p] -> p
        _ -> nil
      end

    port_bit =
      cond do
        is_binary(proto) and is_binary(dpt) -> " · #{proto}/#{dpt}"
        is_binary(dpt) -> " · :#{dpt}"
        true -> ""
      end

    cond do
      is_binary(rule) and is_binary(descr) and descr != "" ->
        "[#{rule}] #{descr}#{port_bit}"

      is_binary(descr) and descr != "" ->
        descr <> port_bit

      true ->
        nil
    end
  end

  defp extract_firewall_rule_headline(_), do: nil

  # EVENT_STA_JOIN … (full tail including iface/MAC when present)
  defp extract_event_subject(body) when is_binary(body) do
    case Regex.run(~r/\b(EVENT_[A-Z][A-Z0-9_]{2,48}\b.*)$/, body) do
      [_, subject] ->
        subject = String.trim(subject)
        if usable_headline?(subject), do: subject

      _ ->
        nil
    end
  end

  defp extract_event_subject(_), do: nil

  defp extract_event_code(body) when is_binary(body) do
    case Regex.run(~r/\b(EVENT_[A-Z][A-Z0-9_]{2,48})\b/, body) do
      [_, code] -> code
      _ -> nil
    end
  end

  defp extract_event_code(_), do: nil

  # "… mcad[1977]: wireless_agg_stats.log_sta_anomalies(): BSSID=…"
  # Skip when a richer wevent/EVENT subject exists.
  defp extract_function_event(body) when is_binary(body) do
    if extract_wevent_headline(body) || extract_event_code(body) do
      nil
    else
      case Regex.scan(~r"\b([A-Za-z_][\w.]*[A-Za-z0-9_]\(\))", body) do
        [] ->
          nil

        matches ->
          matches
          |> Enum.map(fn
            [_, name] -> String.trim(name)
            _ -> nil
          end)
          |> Enum.filter(&(is_binary(&1) and String.contains?(&1, ".")))
          |> Enum.reject(&generic_wrapper_only?/1)
          |> List.last()
      end
    end
  end

  defp extract_function_event(_), do: nil

  # Bare wrapper name with nothing else is not a useful title.
  defp generic_wrapper_only?(name) when is_binary(name) do
    n = name |> String.trim() |> String.downcase() |> String.trim_trailing("()")

    n in ["wevent.ubnt_custom_event", "ubnt_custom_event"] or
      String.ends_with?(n, ".ubnt_custom_event")
  end

  defp generic_wrapper_only?(_), do: false

  # Peel host/kernel/iface prefixes; keep the human subject intact.
  # Do NOT split on ":" — that shatters MAC addresses into "b9 idle(60)…".
  defp extract_subject_after_syslog(body) when is_binary(body) do
    subject =
      case message_prefix(body) do
        prefix when is_binary(prefix) and prefix != "" -> prefix
        _ -> body
      end

    cleaned =
      subject
      |> peel_host_prefix()
      |> peel_log_prefix()
      |> String.trim()
      |> String.trim_trailing(":")
      |> String.trim()

    if usable_headline?(cleaned), do: cleaned
  end

  defp extract_subject_after_syslog(_), do: nil

  defp extract_bracket_title(body) when is_binary(body) do
    ~r"\[([^\]]{2,64})\]"
    |> Regex.scan(body)
    |> Enum.map(fn
      [_, title] -> String.trim(title)
      _ -> nil
    end)
    # Keep "[POSTROUTING-SNAT-1]"; drop "[1977]" / "[2652784.576992]".
    |> Enum.find(&usable_headline?/1)
  end

  defp extract_bracket_title(_), do: nil

  defp pure_numeric_token?(s) when is_binary(s) do
    s = String.trim(s)
    s != "" and Regex.match?(~r/^\d+(?:\.\d+)?$/, s)
  end

  defp pure_numeric_token?(_), do: true

  defp has_latin_letter?(s) when is_binary(s), do: Regex.match?(~r/[A-Za-z]/, s)
  defp has_latin_letter?(_), do: false

  # "b9 idle(60) timeout(180)" — leftover from colon-splitting a MAC.
  defp mac_tail_headline?(title) when is_binary(title) do
    t = String.trim(title)

    Regex.match?(~r/^[0-9a-fA-F]{1,2}(?:\s|:)/, t) or
      Regex.match?(~r/^[0-9a-fA-F]{2}(?::[0-9a-fA-F]{2}){1,5}\b/, t)
  end

  defp mac_tail_headline?(_), do: false

  # Titles that are only metric tokens: idle(60) timeout(180)
  defp metrics_only_headline?(title) when is_binary(title) do
    tokens = String.split(title)

    tokens != [] and
      Enum.all?(tokens, &Regex.match?(~r/^[A-Za-z_][\w-]*\(\d+\)$/, &1))
  end

  defp metrics_only_headline?(_), do: false

  defp kernel_timestamp_headline?(title) when is_binary(title) do
    Regex.match?(~r/^\d+\.\d+$/, String.trim(title))
  end

  defp kernel_timestamp_headline?(_), do: false

  # Host/mac only — keeps wevent[pid] and the rest of the payload.
  defp peel_host_prefix(body) when is_binary(body) do
    cleaned =
      body
      # ac8ba9d587dd,U6-Mesh-6.8.2+15592:
      |> String.replace(~r/^[0-9a-fA-F]{6,},[^:]+:\s*/, "")
      # stray empty tag from "host: : wevent"
      |> String.replace(~r/^:\s*/, "")
      |> String.trim()

    if cleaned == "", do: body, else: cleaned
  end

  defp peel_host_prefix(body), do: body

  # Aggressive peel for fallback subjects only (after process/wevent extractors).
  # Prefer extract_syslog_process_headline so dnsmasq-dhcp[pid] is not discarded.
  defp peel_log_prefix(body) when is_binary(body) do
    cleaned =
      body
      |> peel_host_prefix()
      # optional short hostname token before process (tonka01 dnsmasq-dhcp[…])
      # kept when process headline wins; here we only strip facility noise for fallbacks
      # mcad[1977]: / process[12345]: (not wevent — wevent handled separately)
      |> String.replace(~r/\b(?!wevent)[A-Za-z_][\w.-]*\[\d+\]:\s*/i, "")
      # one or more short facility tags at the front: kernel: syslog: …
      |> String.replace(~r/^(?:[A-Za-z_][\w.-]{0,24}:\s*)+/, "")
      # [2652784.576992] kernel uptime stamp
      |> String.replace(~r/^\[\d+(?:\.\d+)?\]\s*/, "")
      # iface / subsystem tag: ra0: eth0: wlan0:
      |> String.replace(~r/^[A-Za-z][\w.-]{0,15}:\s*/, "")
      |> String.trim()

    if cleaned == "", do: body, else: cleaned
  end

  defp peel_log_prefix(body), do: body

  # Text before the first KEY= token (e.g. "tonka01 [POSTROUTING-SNAT-1]").
  defp message_prefix(body) when is_binary(body) do
    case Regex.run(~r/^(.*?)(?=\b[A-Za-z_][A-Za-z0-9_]{0,24}=)/s, body) do
      [_, prefix] ->
        prefix = String.trim(prefix)
        if prefix == "", do: nil, else: prefix

      _ ->
        nil
    end
  end

  defp message_prefix(_), do: nil

  # Prefix above the parsed grid: host/device line (without the EVENT payload).
  defp wevent_message_prefix(body) when is_binary(body) do
    if extract_event_code(body) || Regex.match?(~r/\bwevent\[\d+\]:/i, body) do
      case Regex.run(~r/^(.*?)(?=\bwevent\[\d+\]:)/i, body) do
        [_, host] ->
          host = host |> String.trim() |> String.trim_trailing(":") |> String.trim()
          if host == "", do: nil, else: host

        _ ->
          body
          |> peel_host_prefix()
          |> String.replace(~r/\bwevent\[\d+\]:.*$/i, "")
          |> String.trim()
          |> then(fn p -> if p == "", do: nil, else: p end)
      end
    end
  end

  defp wevent_message_prefix(_), do: nil

  # Structured fields for the parsed message grid.
  defp extract_message_pairs(body) when is_binary(body) do
    (extract_event_pairs(body) ++ extract_kv_pairs(body))
    |> Enum.uniq_by(fn {k, _} -> k end)
    |> Enum.take(32)
  end

  defp extract_message_pairs(_), do: []

  # UniFi wevent: "wevent[2066]: wevent.ubnt_custom_event(): EVENT_STA_JOIN wifi0ap0: mac / 2"
  defp extract_event_pairs(body) when is_binary(body) do
    process_pairs =
      case Regex.run(~r/\b([A-Za-z_][\w.-]*)\[(\d+)\]:/, body) do
        [_, name, pid] -> [{"process", name}, {"pid", pid}]
        _ -> []
      end

    dispatcher_pairs =
      case Regex.run(~r/\b((?:wevent\.)?ubnt_custom_event\(\))/i, body) do
        [_, fn_name] -> [{"dispatcher", fn_name}]
        _ -> []
      end

    event = extract_event_code(body)

    event_pairs =
      if is_nil(event) do
        []
      else
        base = [{"event", event}]

        rest =
          case Regex.run(
                 ~r"\bEVENT_[A-Z][A-Z0-9_]{2,48}\s+([A-Za-z][\w.-]{0,24}):\s*([0-9a-fA-F]{2}(?::[0-9a-fA-F]{2}){5})(?:\s*/\s*(\d+))?",
                 body
               ) do
            [_, iface, mac, count] when is_binary(count) and count != "" ->
              [{"interface", iface}, {"sta", String.downcase(mac)}, {"index", count}]

            [_, iface, mac | _] ->
              [{"interface", iface}, {"sta", String.downcase(mac)}]

            _ ->
              []
          end

        base ++ rest
      end

    process_pairs ++ dispatcher_pairs ++ event_pairs
  end

  defp extract_event_pairs(_), do: []

  defp extract_kv_pairs(body) when is_binary(body) do
    ~r/\b([A-Za-z_][A-Za-z0-9_]{0,24})=(?:"([^"]*)"|([^\s]*))/
    |> Regex.scan(body)
    |> Enum.flat_map(&kv_pair_from_scan/1)
    |> Enum.uniq_by(fn {k, _} -> k end)
    |> Enum.take(32)
  end

  defp extract_kv_pairs(_), do: []

  defp kv_pair_from_scan([_full, key, quoted, _plain]) when is_binary(key) and is_binary(quoted) and quoted != "" do
    [{key, quoted}]
  end

  defp kv_pair_from_scan([_full, key, _quoted, plain]) when is_binary(key) and is_binary(plain) do
    [{key, plain}]
  end

  defp kv_pair_from_scan([_full, key, value]) when is_binary(key) and is_binary(value) do
    [{key, value}]
  end

  defp kv_pair_from_scan([_full, key]) when is_binary(key), do: [{key, ""}]
  defp kv_pair_from_scan(_), do: []

  defp value_looks_like_ip?(v) when is_binary(v), do: Regex.match?(~r/^(?:\d{1,3}\.){3}\d{1,3}$/, v)
  defp value_looks_like_ip?(_), do: false

  defp entry_id(log, idx) do
    case Map.get(log, "id") do
      <<_::binary-size(16)>> = bin -> uuid_to_string(bin)
      id when is_binary(id) and id != "" -> id
      _ -> "row-#{idx}"
    end
  end

  defp log_source_kind(log) do
    attrs = parse_attributes(Map.get(log, "attributes")) || %{}

    case Map.get(attrs, "source_kind") do
      v when is_binary(v) and v != "" -> v
      _ -> "log"
    end
  end

  defp log_facility(log) do
    attrs = parse_attributes(Map.get(log, "attributes")) || %{}
    Map.get(log, "facility") || leaf_attr(attrs, "facility")
  end

  defp log_format(log) do
    attrs = parse_attributes(Map.get(log, "attributes")) || %{}

    Map.get(log, "syslog_format") ||
      leaf_attr(attrs, "_syslog_format") ||
      leaf_attr(attrs, "syslog_format")
  end

  defp leaf_attr(attrs, key) when is_map(attrs) do
    case Map.get(attrs, key) do
      %{"value" => v} -> v
      v when is_binary(v) -> v
      v when is_number(v) or is_boolean(v) -> to_string(v)
      _ -> nil
    end
  end

  defp leaf_attr(_, _), do: nil

  defp scalar_attr(attrs, keys) when is_map(attrs) and is_list(keys) do
    Enum.find_value(keys, &leaf_attr(attrs, &1))
  end

  defp scalar_attr(_attrs, _keys), do: nil

  defp log_agent_identity(log, attrs) when is_map(log) and is_map(attrs) do
    Enum.find(
      [
        Map.get(log, "ingest_agent_id"),
        scalar_attr(attrs, ["agent_id", "agent.id"]),
        Map.get(log, "service_instance")
      ],
      fn value -> is_binary(value) and String.trim(value) != "" end
    )
  end

  defp log_agent_identity(_log, _attrs), do: nil

  # RBAC check - only operators and admins can create rules
  defp can_create_rules?(%{user: _} = scope), do: ServiceRadarWebNG.RBAC.can?(scope, "observability.rules.create")

  defp can_create_rules?(_), do: false

  defp build_signal_display(log) when is_map(log) do
    case SignalDisplay.render_record(log) do
      {:ok, widgets} -> widgets
      :error -> nil
    end
  end

  defp build_signal_display(_log), do: nil

  defp augment_log(%{} = log, scope) do
    attributes = parse_attributes(Map.get(log, "attributes")) || %{}

    resource_attributes =
      parse_attributes(Map.get(log, "resource_attributes")) ||
        extract_resource_from_attributes(attributes)

    {scope_name, scope_version} =
      extract_scope_from_attributes(
        Map.get(log, "scope_name"),
        Map.get(log, "scope_version"),
        attributes
      )

    attributes =
      attributes
      |> drop_attribute_keys(["resource", "resource_attributes", "resourceAttributes", "scope"])
      |> unwrap_nested_attributes()

    log
    |> Map.put("attributes", if(map_size(attributes) == 0, do: nil, else: attributes))
    |> Map.put("resource_attributes", resource_attributes || Map.get(log, "resource_attributes"))
    |> Map.put("scope_name", scope_name)
    |> Map.put("scope_version", scope_version)
    |> put_service_from_resource(resource_attributes)
    |> put_source_device_from_resource(resource_attributes, scope)
  end

  defp extract_resource_from_attributes(attributes) when is_map(attributes) do
    attributes
    |> Map.get("resource")
    |> parse_attributes()
    |> case do
      nil ->
        attributes
        |> Map.get("resource_attributes")
        |> parse_attributes()
        |> case do
          nil ->
            attributes
            |> Map.get("resourceAttributes")
            |> parse_attributes()

          resource ->
            resource
        end

      resource ->
        resource
    end
  end

  defp extract_scope_from_attributes(scope_name, scope_version, attributes)
       when scope_name in [nil, ""] or scope_version in [nil, ""] do
    case Map.get(attributes, "scope") do
      scope when is_binary(scope) and scope != "" ->
        {scope_name || scope, scope_version}

      %{} = scope_map ->
        {
          scope_name || Map.get(scope_map, "name") || Map.get(scope_map, "scope_name"),
          scope_version || Map.get(scope_map, "version") || Map.get(scope_map, "scope_version")
        }

      _ ->
        {scope_name, scope_version}
    end
  end

  defp extract_scope_from_attributes(scope_name, scope_version, _attributes), do: {scope_name, scope_version}

  defp drop_attribute_keys(attributes, keys) when is_map(attributes) do
    Enum.reduce(keys, attributes, fn key, acc -> Map.delete(acc, key) end)
  end

  defp drop_attribute_keys(attributes, _keys), do: attributes

  defp unwrap_nested_attributes(%{"attributes" => %{} = nested} = attributes) when map_size(attributes) == 1 do
    nested
  end

  defp unwrap_nested_attributes(attributes), do: attributes

  defp put_service_from_resource(log, resource_attributes) when is_map(resource_attributes) do
    log
    |> put_if_blank("service_name", Map.get(resource_attributes, "service.name"))
    |> put_if_blank("service_version", Map.get(resource_attributes, "service.version"))
    |> put_if_blank("service_instance", Map.get(resource_attributes, "service.instance.id"))
  end

  defp put_service_from_resource(log, _resource_attributes), do: log

  defp put_source_device_from_resource(log, resource_attributes, scope) when is_map(resource_attributes) do
    case source_device_uid(resource_attributes, scope) do
      uid when is_binary(uid) and uid != "" -> Map.put(log, "source_device_uid", uid)
      _ -> log
    end
  end

  defp put_source_device_from_resource(log, _resource_attributes, _scope), do: log

  defp source_device_uid(resource_attributes, scope) when is_map(resource_attributes) do
    resource_attributes
    |> Map.get("source")
    |> normalize_source_host()
    |> case do
      nil -> nil
      ip -> lookup_device_uid_by_ip(ip, scope)
    end
  end

  defp lookup_device_uid_by_ip(_ip, nil), do: nil

  defp lookup_device_uid_by_ip(ip, scope) when is_binary(ip) do
    case Device.get_by_ip(ip, false, scope: scope) do
      {:ok, [%Device{} = device | _]} -> device.uid
      {:ok, %{results: [%Device{} = device | _]}} -> device.uid
      _ -> nil
    end
  end

  defp normalize_source_host(nil), do: nil

  defp normalize_source_host(source) when is_binary(source) do
    source = String.trim(source)

    if source == "" do
      nil
    else
      case URI.parse("//" <> source) do
        %URI{host: host} when is_binary(host) and host != "" -> host
        _ -> source
      end
    end
  end

  defp normalize_source_host(_source), do: nil

  defp put_if_blank(%{} = log, _key, value) when value in [nil, ""], do: log

  defp put_if_blank(%{} = log, key, value) do
    case Map.get(log, key) do
      nil -> Map.put(log, key, value)
      "" -> Map.put(log, key, value)
      _ -> log
    end
  end

  # Parse attribute strings into structured maps
  # Handles: already-parsed maps, JSON strings, key={json},key2={json} format, key=value format
  defp parse_attributes(nil), do: nil
  defp parse_attributes(""), do: nil
  defp parse_attributes(value) when is_map(value), do: normalize_metadata_value(value)

  defp parse_attributes(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      # Try JSON first
      String.starts_with?(value, "{") or String.starts_with?(value, "[") ->
        case Jason.decode(value) do
          {:ok, decoded} when is_map(decoded) -> normalize_metadata_value(decoded)
          _ -> parse_key_value_format(value)
        end

      # Try key={json},key2={json} or key=value format
      String.contains?(value, "=") ->
        parse_key_value_format(value)

      true ->
        nil
    end
  end

  defp parse_attributes(_), do: nil

  defp normalize_metadata_value(value) when is_map(value) do
    Map.new(value, fn {key, nested_value} -> {key, normalize_metadata_value(key, nested_value)} end)
  end

  defp normalize_metadata_value(value) when is_list(value), do: normalize_metadata_list(value)
  defp normalize_metadata_value(value), do: value

  defp normalize_metadata_value(key, value) when is_list(value) do
    cond do
      printable_charlist?(value) ->
        List.to_string(value)

      key == "mfa" ->
        format_mfa(value)

      true ->
        Enum.map(value, &normalize_metadata_value/1)
    end
  end

  defp normalize_metadata_value(_key, value), do: normalize_metadata_value(value)

  defp normalize_metadata_list(value) do
    if printable_charlist?(value) do
      List.to_string(value)
    else
      Enum.map(value, &normalize_metadata_value/1)
    end
  end

  # Parse formats like: attributes={"error":"nats: no heartbeat"},resource={"service.name":"foo"}
  # or simpler: key=value,key2=value2
  defp parse_key_value_format(value) do
    # Match pattern: key={...} or key=value. OTEL attribute keys commonly
    # contain dots, such as `service_radar.signal_schema.producer_id`.
    result =
      ~r/([\w.-]+)=(\{[^}]*\}|[^,]+?)(?=,[\w.-]+=|$)/
      |> Regex.scan(value)
      |> Enum.reduce(%{}, fn
        [_full, key, json_value], acc when binary_part(json_value, 0, 1) == "{" ->
          case Jason.decode(json_value) do
            {:ok, decoded} -> Map.put(acc, key, decoded)
            _ -> Map.put(acc, key, json_value)
          end

        [_full, key, plain_value], acc ->
          Map.put(acc, key, String.trim(plain_value))
      end)

    if map_size(result) > 0, do: result
  end

  defp redact_secret_text(value) when is_binary(value) do
    value
    |> redact_erlang_secret("nkey_seed")
    |> redact_erlang_secret("jwt")
    |> redact_json_secret("nkey_seed")
    |> redact_json_secret("jwt")
    |> redact_json_secret("token")
    |> redact_json_secret("password")
    |> redact_json_secret("secret")
    |> redact_json_secret("api_key")
    |> redact_assignment_secret("authorization")
    |> redact_assignment_secret("token")
    |> redact_assignment_secret("password")
    |> redact_assignment_secret("secret")
    |> redact_assignment_secret("api_key")
  end

  defp redact_secret_text(value), do: value

  defp redact_erlang_secret(value, key) do
    Regex.replace(~r/(#{Regex.escape(key)}\s*=>\s*<<")[^"]*(">>)/i, value, "\\1#{@redacted}\\2")
  end

  defp redact_json_secret(value, key) do
    Regex.replace(~r/("#{Regex.escape(key)}"\s*:\s*")[^"]*(")/i, value, "\\1#{@redacted}\\2")
  end

  defp redact_assignment_secret(value, key) do
    Regex.replace(~r/(#{Regex.escape(key)}\s*[=:]\s*)[^\s,}\]]+/i, value, "\\1#{@redacted}")
  end

  defp flatten_attribute_values(values) when is_map(values) do
    values
    |> Enum.flat_map(fn
      {k, v} when is_map(v) ->
        Enum.map(v, fn {nested_k, nested_v} -> {"#{k}.#{nested_k}", nested_v} end)

      {k, v} ->
        [{k, v}]
    end)
    |> Enum.reject(fn {_k, v} -> blank_value?(v) end)
    |> Enum.sort_by(fn {k, _} -> k end)
  end

  defp flatten_attribute_values(_), do: []

  defp format_attribute_value(key, value) when is_binary(key) do
    if sensitive_log_key?(key), do: @redacted, else: format_attribute_value(value)
  end

  defp format_attribute_value(_key, value), do: format_attribute_value(value)

  defp format_attribute_value(value) when is_binary(value), do: redact_secret_text(value)
  defp format_attribute_value(value) when is_number(value), do: to_string(value)
  defp format_attribute_value(value) when is_boolean(value), do: to_string(value)

  defp format_attribute_value(value) when is_map(value) do
    value |> normalize_metadata_value() |> redact_secret_value() |> Jason.encode!()
  end

  defp format_attribute_value(value) when is_list(value) do
    value
    |> normalize_metadata_value()
    |> redact_secret_value()
    |> case do
      normalized when is_binary(normalized) -> redact_secret_text(normalized)
      normalized -> Jason.encode!(normalized)
    end
  end

  defp format_attribute_value(nil), do: "—"
  defp format_attribute_value(value), do: inspect(value)

  defp redact_secret_value(nil), do: nil

  defp redact_secret_value(value) when is_map(value) do
    Map.new(value, fn {key, nested} ->
      if sensitive_log_key?(key) do
        {key, @redacted}
      else
        {key, redact_secret_value(nested)}
      end
    end)
  end

  defp redact_secret_value(value) when is_list(value), do: Enum.map(value, &redact_secret_value/1)
  defp redact_secret_value(value) when is_binary(value), do: redact_secret_text(value)
  defp redact_secret_value(value), do: value

  defp sensitive_log_key?(key) do
    key
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_]+/, "_")
    |> then(fn normalized ->
      normalized in @sensitive_log_keys or
        Enum.any?(@sensitive_log_keys, fn key -> String.ends_with?(normalized, "_#{key}") end)
    end)
  end

  defp blank_value?(nil), do: true
  defp blank_value?(""), do: true
  defp blank_value?(_), do: false

  defp printable_charlist?(value) when is_list(value) and value != [] do
    Enum.all?(value, &printable_codepoint?/1)
  end

  defp printable_charlist?(_value), do: false

  defp printable_codepoint?(codepoint) when is_integer(codepoint) do
    codepoint in [9, 10, 13] or codepoint in 32..126
  end

  defp printable_codepoint?(_value), do: false

  defp format_mfa([module, function, arity]) when is_binary(module) and is_binary(function) do
    "#{module}.#{function}/#{arity}"
  end

  defp format_mfa(value), do: Enum.map(value, &normalize_metadata_value/1)

  attr :value, :any, default: nil

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
      s when s in ["medium", "info"] -> "info"
      s when s in ["low", "debug", "trace", "ok"] -> "success"
      _ -> "ghost"
    end
  end

  defp severity_label(nil), do: "—"
  defp severity_label(""), do: "—"

  defp severity_label(value) do
    case normalize_severity(value) do
      "" -> "—"
      s -> String.upcase(s)
    end
  end

  defp normalize_severity(nil), do: ""

  defp normalize_severity(v) when is_binary(v) do
    # OTel-SDK producers write the raw SeverityNumber enum name into severity_text
    # (e.g. "SEVERITY_NUMBER_INFO", "SEVERITY_NUMBER_WARN3") and leave severity_number
    # null. Strip the enum prefix + any numbered-variant suffix so the badge resolves to
    # info/warn/error (label + color), matching the Go agent's lowercase severity_text.
    v
    |> String.trim()
    |> String.downcase()
    |> String.replace_prefix("severity_number_", "")
    |> String.replace(~r/\d+$/, "")
  end

  defp normalize_severity(v), do: v |> to_string() |> normalize_severity()

  defp timestamp_meta(log) do
    value = Map.get(log, "observed_timestamp") || Map.get(log, "timestamp")

    case parse_timestamp(value) do
      {:ok, dt} -> %{value: dt, fallback: DateTime.to_iso8601(dt)}
      _ -> %{value: nil, fallback: value || "—"}
    end
  end

  defp parse_timestamp(nil), do: :error
  defp parse_timestamp(""), do: :error
  defp parse_timestamp(%DateTime{} = value), do: {:ok, value}

  # Typed NaiveDateTime values are a canonical DB representation. Source text must carry an offset.
  defp parse_timestamp(%NaiveDateTime{} = value), do: {:ok, DateTime.from_naive!(value, "Etc/UTC")}

  defp parse_timestamp(value) when is_binary(value) do
    value = String.trim(value)

    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} ->
        {:ok, dt}

      {:error, _} ->
        :error
    end
  end

  defp parse_timestamp(_), do: :error

  defp escape_value(value) when is_binary(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end

  defp format_error(%Jason.DecodeError{} = err), do: Exception.message(err)
  defp format_error(%ArgumentError{} = err), do: Exception.message(err)
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

  defp srql_module do
    Application.get_env(:serviceradar_web_ng, :srql_module, ServiceRadarWebNG.SRQL)
  end

  # Convert raw 16-byte binary UUID to string format, or return as-is if already a string
  defp normalize_uuid(<<_::binary-size(16)>> = bin) do
    uuid_to_string(bin)
  end

  defp normalize_uuid(id) when is_binary(id), do: id

  defp uuid_to_string(<<a::32, b::16, c::16, d::16, e::48>>) do
    [a, b, c, d, e]
    |> Enum.map(&Integer.to_string(&1, 16))
    |> Enum.map(&String.downcase/1)
    |> Enum.zip([8, 4, 4, 4, 12])
    |> Enum.map_join("-", fn {hex, len} -> String.pad_leading(hex, len, "0") end)
  end
end
