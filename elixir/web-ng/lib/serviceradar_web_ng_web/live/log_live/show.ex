defmodule ServiceRadarWebNGWeb.LogLive.Show do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.Observability.SignalDisplayComponents
  import ServiceRadarWebNGWeb.UIComponents

  alias ServiceRadar.Inventory.Device
  alias ServiceRadarWebNG.Observability.SignalDisplay
  alias ServiceRadarWebNGWeb.Components.PromotionRuleBuilder
  alias ServiceRadarWebNGWeb.SRQL.Builder
  alias ServiceRadarWebNGWeb.SRQL.Page, as: SRQLPage

  @redacted "[REDACTED]"
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
      load_stream_page(stream_query, log, log_id, nil)

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

  def handle_event("set_body_mode", %{"mode" => mode}, socket)
      when mode in ~w(parsed raw json highlighted) do
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
        %{} = log -> log |> Map.drop(["source_device_uid"]) |> Jason.encode!(pretty: true)
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
       extra_params: %{"tab" => "logs"}
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
       extra_params: %{"tab" => "logs"}
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
        filter_stream(assigns.stream_entries, assigns.stream_severity)
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
          <.log_stream_pane
            entries={@visible_stream}
            page_count={length(@visible_stream)}
            page={@stream_page}
            page_size={@stream_page_size}
            selected_id={@log_id}
            stream_severity={@stream_severity}
            service={Map.get(@log, "service_name")}
            stream_query={@stream_query || Map.get(@srql, :query)}
            has_prev={@stream_page > 1}
            has_next={is_binary(@stream_next_cursor) and @stream_next_cursor != ""}
          />

          <section class="flex min-h-0 min-w-0 flex-col overflow-hidden lg:border-l lg:border-sr-line">
            <.log_detail_header
              log={@log}
              log_id={@log_id}
              can_create_rules?={can_create_rules?(@current_scope)}
            />
            <.log_meta_strip log={@log} />

            <div class="min-h-0 min-w-0 flex-1 space-y-5 overflow-x-hidden overflow-y-auto px-3 py-5 sm:px-5">
              <.log_message_hero log={@log} body_mode={@body_mode} />
              <.signal_display_panel :if={is_list(@signal_display)} widgets={@signal_display} />
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

    case srql_module().query(query) do
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
      load_stream_page(query, socket.assigns.log, socket.assigns.log_id, cursor)

    socket
    |> assign(:stream_entries, stream)
    |> assign(:stream_cursor, cursor)
    |> assign(:stream_next_cursor, next_cursor)
    |> assign(:stream_prev_cursor, prev_cursor)
    |> assign(:stream_page, page)
  end

  defp load_stream_page(query, log, selected_id, cursor) when is_binary(query) do
    opts =
      if is_binary(cursor) and cursor != "" do
        %{limit: @stream_page_size, cursor: cursor}
      else
        %{limit: @stream_page_size}
      end

    case srql_module().query(strip_embedded_limit(query), opts) do
      {:ok, %{"results" => results} = resp} when is_list(results) ->
        entries = Enum.map(results, &stream_entry/1)

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

  defp load_stream_page(_, log, selected_id, cursor) when is_map(log) do
    load_stream_page(stream_query_for_log(log), log, selected_id, cursor)
  end

  defp load_stream_page(_, _, _, _), do: {[], nil, nil}

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
      load_stream_page(query, socket.assigns.log, socket.assigns.log_id, nil)

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

  defp stream_entry(log) when is_map(log) do
    body = log_message(log)

    %{
      id: entry_id(log),
      severity: Map.get(log, "severity_text"),
      service: Map.get(log, "service_name") || Map.get(log, "service") || "—",
      time_short: format_time_short(log),
      preview: message_preview(body)
    }
  end

  defp ensure_selected_in_stream(entries, log, selected_id) do
    if Enum.any?(entries, &(&1.id == selected_id)) do
      entries
    else
      [stream_entry(Map.put(log, "id", selected_id)) | entries]
    end
  end

  defp filter_stream(entries, "all"), do: entries

  defp filter_stream(entries, severity) do
    target = normalize_severity(severity)

    Enum.filter(entries, fn entry ->
      s = normalize_severity(entry.severity)

      cond do
        target in ["warn", "warning"] -> s in ["warn", "warning", "high"]
        target == "error" -> s in ["error", "critical", "fatal"]
        true -> s == target
      end
    end)
  end

  defp page_title_for(%{} = log, log_id) do
    case extract_bracket_title(log_message(log)) do
      nil -> "Log · #{String.slice(to_string(log_id), 0, 8)}"
      title -> title
    end
  end

  defp page_title_for(_, log_id), do: "Log · #{String.slice(to_string(log_id), 0, 8)}"

  # -- stream pane ------------------------------------------------------------

  attr :entries, :list, required: true
  attr :page_count, :integer, required: true
  attr :page, :integer, required: true
  attr :page_size, :integer, required: true
  attr :selected_id, :string, required: true
  attr :stream_severity, :string, required: true
  attr :service, :any, default: nil
  attr :stream_query, :any, default: nil
  attr :has_prev, :boolean, default: false
  attr :has_next, :boolean, default: false

  defp log_stream_pane(assigns) do
    ~H"""
    <aside class="sr-log-stream hidden min-h-0 min-w-0 max-w-full flex-col overflow-hidden border-sr-line bg-sr-surface lg:flex">
      <div class="min-w-0 shrink-0 space-y-2 border-b border-sr-line px-2.5 py-2.5">
        <div class="flex items-center justify-between gap-2">
          <h2 class="text-sm font-semibold tracking-tight text-sr-ink">Log stream</h2>
          <span class="font-mono text-xs text-sr-muted">
            {if @page_count > 0, do: "p.#{@page}", else: "0"}
          </span>
        </div>

        <div
          :if={is_binary(@stream_query) and @stream_query != ""}
          class="truncate rounded-sr-control border border-sr-line bg-sr-subtle/50 px-2 py-1 font-mono text-[11px] text-sr-muted"
          title={@stream_query}
        >
          {@stream_query}
        </div>

        <div class="flex flex-nowrap items-center gap-0.5">
          <.stream_sev_chip
            :for={sev <- ~w(all info warn error debug)}
            severity={sev}
            active={@stream_severity == sev}
          />
        </div>
      </div>

      <div class="min-h-0 min-w-0 flex-1 overflow-x-hidden overflow-y-auto overscroll-contain">
        <div :if={@entries == []} class="px-3 py-6 text-center text-sm text-sr-muted">
          No matching entries
        </div>

        <.link
          :for={entry <- @entries}
          navigate={~p"/logs/#{entry.id}"}
          id={"stream-" <> entry.id}
          class={[
            "group relative block min-w-0 border-b border-sr-line/70 px-2.5 py-2 transition-colors duration-150 ease-sr-out",
            entry.id == @selected_id && "bg-sr-subtle",
            entry.id != @selected_id && "hover:bg-sr-subtle/60"
          ]}
        >
          <div :if={entry.id == @selected_id} class="absolute inset-y-0 left-0 w-0.5 bg-sr-brand"></div>
          <div class="flex min-w-0 items-start gap-2">
            <span class={["mt-1 size-1.5 shrink-0 rounded-full", severity_dot_class(entry.severity)]}></span>
            <div class="min-w-0 flex-1 overflow-hidden">
              <div class="flex min-w-0 items-baseline justify-between gap-2">
                <span class="shrink-0 font-mono text-[11px] text-sr-muted">{entry.time_short}</span>
                <span class="truncate font-mono text-[10px] text-sr-muted">{entry.service}</span>
              </div>
              <p class="mt-0.5 truncate text-xs leading-snug text-sr-ink">{entry.preview}</p>
            </div>
          </div>
        </.link>
      </div>

      <div class="flex shrink-0 items-center justify-between gap-1 border-t border-sr-line px-2 py-1.5">
        <.ui_button type="button" size="xs" variant="outline" phx-click="stream_prev" disabled={not @has_prev}>
          <.icon name="hero-chevron-left" class="size-3.5" /> Prev
        </.ui_button>
        <span class="font-mono text-[11px] text-sr-muted">{@page}</span>
        <.ui_button type="button" size="xs" variant="outline" phx-click="stream_next" disabled={not @has_next}>
          Next <.icon name="hero-chevron-right" class="size-3.5" />
        </.ui_button>
      </div>
    </aside>
    """
  end

  attr :severity, :string, required: true
  attr :active, :boolean, default: false

  defp stream_sev_chip(assigns) do
    label =
      case assigns.severity do
        "all" -> "All"
        "info" -> "Info"
        "warn" -> "Warn"
        "error" -> "Err"
        "debug" -> "Dbg"
        other -> String.upcase(other)
      end

    assigns = assign(assigns, :label, label)

    ~H"""
    <.ui_button
      type="button"
      size="xs"
      variant={if(@active, do: "soft", else: "ghost")}
      active={@active}
      phx-click="set_stream_severity"
      phx-value-severity={@severity}
      class="!min-h-6 h-6 shrink-0 px-1.5 text-[10px] font-medium leading-none tracking-wide"
    >
      {@label}
    </.ui_button>
    """
  end

  # -- detail header / meta ---------------------------------------------------

  attr :log, :map, required: true
  attr :log_id, :string, required: true
  attr :can_create_rules?, :boolean, default: false

  defp log_detail_header(assigns) do
    body = log_message(assigns.log)
    # Full message line for the hero title — actions live on the breadcrumb row
    # so we no longer need a hard 64-char ellipsis.
    title = extract_bracket_title(body) || message_preview(body, 240) || "Log entry"

    assigns =
      assigns
      |> assign(:title, title)
      |> assign(:source_kind, log_source_kind(assigns.log))
      |> assign(:short_id, String.slice(assigns.log_id, 0, 8))

    ~H"""
    <header class="space-y-3 border-b border-sr-line px-4 pb-4 pt-5 font-sans sm:px-6 sm:pt-6">
      <div class="flex flex-wrap items-center justify-between gap-x-3 gap-y-2">
        <div class="flex min-w-0 flex-wrap items-center gap-x-2 gap-y-1 text-sm text-sr-muted">
          <.link navigate={~p"/observability?#{%{tab: "logs"}}"} class="hover:text-sr-ink">logs</.link>
          <span class="text-sr-line-strong">/</span>
          <span class="text-sr-ink/80">{@source_kind}</span>
          <span class="text-sr-line-strong">/</span>
          <span class="font-mono text-sr-ink">{@short_id}</span>
        </div>

        <div class="flex shrink-0 flex-wrap items-center gap-1.5">
          <.ui_button href={~p"/observability?#{%{tab: "logs"}}"} variant="outline" size="xs">
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
          <h1 class="min-w-0 flex-1 font-sans text-lg font-semibold leading-snug tracking-tight text-sr-ink sm:text-xl">
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

  defp log_meta_strip(assigns) do
    facts =
      [
        {"Timestamp", format_timestamp(assigns.log), true},
        {"Service", Map.get(assigns.log, "service_name"), false},
        {"Source IP", Map.get(assigns.log, "source_ip"), true},
        {"Facility", log_facility(assigns.log), false},
        {"Format", log_format(assigns.log), true},
        {"Scope", Map.get(assigns.log, "scope_name"), true}
      ]
      |> Enum.reject(fn {_l, v, _} -> blank_value?(v) end)

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
      <div
        :for={{label, value, mono?} <- @facts}
        class="flex min-w-0 flex-col gap-1 bg-sr-surface px-4 py-3"
      >
        <span class="font-sans text-xs font-medium uppercase tracking-wide text-sr-muted">{label}</span>
        <span class={[
          "truncate font-sans text-sm text-sr-ink",
          mono? && "font-mono text-[13px] tracking-tight"
        ]}>
          {value}
        </span>
      </div>
    </div>
    """
  end

  # -- message hero -----------------------------------------------------------

  attr :log, :map, required: true
  attr :body_mode, :string, required: true

  defp log_message_hero(assigns) do
    body = redact_secret_text(log_message(assigns.log))
    is_json = message_is_json?(body)
    pairs = extract_kv_pairs(body)
    prefix = message_prefix(body)
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

  defp extract_bracket_title(body) when is_binary(body) do
    case Regex.run(~r/\[([^\]]{2,64})\]/, body) do
      [_, title] -> title
      _ -> nil
    end
  end

  defp extract_bracket_title(_), do: nil

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

  defp extract_kv_pairs(body) when is_binary(body) do
    ~r/\b([A-Za-z_][A-Za-z0-9_]{0,24})=(?:"([^"]*)"|([^\s]*))/
    |> Regex.scan(body)
    |> Enum.flat_map(&kv_pair_from_scan/1)
    |> Enum.uniq_by(fn {k, _} -> k end)
    |> Enum.take(32)
  end

  defp extract_kv_pairs(_), do: []

  defp kv_pair_from_scan([_full, key, quoted, _plain])
       when is_binary(key) and is_binary(quoted) and quoted != "" do
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

  defp severity_dot_class(value) do
    case normalize_severity(value) do
      s when s in ["critical", "fatal", "error"] -> "bg-rose-500"
      s when s in ["high", "warn", "warning"] -> "bg-amber-400"
      s when s in ["medium", "info"] -> "bg-sr-brand"
      s when s in ["low", "debug", "trace", "ok"] -> "bg-sky-400"
      _ -> "bg-sr-muted"
    end
  end

  defp format_time_short(log) do
    ts = Map.get(log, "timestamp") || Map.get(log, "observed_timestamp")

    case parse_timestamp(ts) do
      {:ok, dt} -> Calendar.strftime(dt, "%H:%M:%S")
      _ -> "—"
    end
  end

  defp entry_id(log) do
    case Map.get(log, "id") do
      <<_::binary-size(16)>> = bin -> uuid_to_string(bin)
      id when is_binary(id) and id != "" -> id
      _ -> "unknown-" <> Integer.to_string(:erlang.phash2(log))
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
      _ -> nil
    end
  end

  defp leaf_attr(_, _), do: nil


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

  defp format_timestamp(log) do
    ts = Map.get(log, "timestamp") || Map.get(log, "observed_timestamp")

    case parse_timestamp(ts) do
      {:ok, dt} -> Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
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
