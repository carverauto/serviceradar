defmodule ServiceRadarWebNGWeb.TraceLive.Show do
  @moduledoc """
  Trace detail view: span waterfall built from `in:traces trace_id:<id>` plus
  trace-scoped correlated logs. Reached from the observability traces pane.
  """
  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.UIComponents

  alias ServiceRadarWebNGWeb.SRQL.Builder
  alias ServiceRadarWebNGWeb.SRQL.Page, as: SRQLPage

  @span_limit 1000
  @log_limit 50
  # Limit forwarded to the observability traces pane when the SRQL bar submits.
  @srql_limit 20
  # Padding applied around the trace's own start/end when querying logs.
  @log_window_pad_seconds 300
  @nanos_per_second 1_000_000_000

  @trace_id_pattern ~r/^[0-9a-f]{32}$/
  @span_id_pattern ~r/^[0-9a-f]{16}$/

  @doc """
  Normalizes a candidate trace id to canonical 32-char lowercase hex.

  Returns `{:ok, trace_id}` or `:error`. Shared with the observability traces
  pane so rows without a usable trace id render without navigation.
  """
  def normalize_trace_id(value) when is_binary(value) do
    id = value |> String.trim() |> String.downcase()

    if Regex.match?(@trace_id_pattern, id) do
      {:ok, id}
    else
      :error
    end
  end

  def normalize_trace_id(_value), do: :error

  @doc """
  Normalizes a candidate span id to canonical 16-char lowercase hex.

  Returns `{:ok, span_id}` or `:error`. Mirrors `normalize_trace_id/1` and is
  shared with views that deep-link into a specific span of the waterfall.
  """
  def normalize_span_id(value) when is_binary(value) do
    id = value |> String.trim() |> String.downcase()

    if Regex.match?(@span_id_pattern, id) do
      {:ok, id}
    else
      :error
    end
  end

  def normalize_span_id(_value), do: :error

  @impl true
  def mount(params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Trace")
     |> assign(:trace_id, nil)
     |> assign(:summary, nil)
     |> assign(:rows, [])
     |> assign(:span_count, 0)
     |> assign(:error_count, 0)
     |> assign(:duration_ms, nil)
     |> assign(:root_service, nil)
     |> assign(:root_operation, nil)
     |> assign(:expanded_idx, nil)
     |> assign(:highlight_idx, nil)
     |> assign(:span_truncated?, false)
     |> assign(:span_limit_display, @span_limit)
     |> assign(:state, :not_found)
     |> assign(:logs, [])
     |> assign(:logs_query, nil)
     |> assign(:logs_error, nil)
     |> assign(:error, nil)
     |> assign(:limit, @srql_limit)
     |> SRQLPage.init("otel_trace_summaries", default_limit: @srql_limit)
     |> prefill_srql_bar(params)}
  end

  @impl true
  def handle_params(%{"trace_id" => raw} = params, _uri, socket) do
    case normalize_trace_id(raw) do
      {:ok, trace_id} ->
        {:noreply,
         socket
         |> assign(:trace_id, trace_id)
         |> assign(:page_title, "Trace #{String.slice(trace_id, 0, 8)}")
         |> assign(:expanded_idx, nil)
         |> assign(:highlight_idx, nil)
         |> load_trace(srql_module(), trace_id)
         |> maybe_expand_span(Map.get(params, "span"))}

      :error ->
        {:noreply,
         socket
         |> put_flash(:error, "Invalid trace id — expected 32 hexadecimal characters.")
         |> push_navigate(to: "/observability/traces")}
    end
  end

  def handle_params(_params, _uri, socket) do
    {:noreply,
     socket
     |> put_flash(:error, "Missing trace id.")
     |> push_navigate(to: "/observability/traces")}
  end

  @impl true
  def handle_event("toggle_span", %{"idx" => idx}, socket) do
    idx =
      case Integer.parse(to_string(idx)) do
        {n, _rest} -> n
        :error -> nil
      end

    expanded = if socket.assigns.expanded_idx == idx, do: nil, else: idx
    {:noreply, socket |> assign(:expanded_idx, expanded) |> assign(:highlight_idx, nil)}
  end

  def handle_event("srql_change", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_change", params)}
  end

  def handle_event("srql_submit", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_submit", params, fallback_path: "/observability")}
  end

  def handle_event("srql_reset", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_reset", params, fallback_path: "/observability")}
  end

  def handle_event("srql_builder_toggle", _params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_toggle", %{}, entity: "otel_trace_summaries")}
  end

  def handle_event("srql_builder_change", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_change", params)}
  end

  def handle_event("srql_builder_apply", _params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_apply", %{})}
  end

  def handle_event("srql_builder_run", _params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_run", %{}, fallback_path: "/observability")}
  end

  def handle_event("srql_builder_add_filter", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_add_filter", params, entity: "otel_trace_summaries")}
  end

  def handle_event("srql_builder_remove_filter", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_remove_filter", params, entity: "otel_trace_summaries")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} srql={@srql}>
      <div class="mx-auto max-w-7xl p-6">
        <.header>
          Trace
          <:subtitle>
            <span class="inline-flex items-center gap-2">
              <span class="font-mono text-xs">{@trace_id || "—"}</span>
              <.ui_button
                :if={is_binary(@trace_id)}
                type="button"
                id="trace-id-copy"
                phx-hook=".CopyText"
                data-copy={@trace_id}
                title="Copy trace id"
                size="xs"
                variant="ghost"
              >
                Copy
              </.ui_button>
            </span>
          </:subtitle>
          <:actions>
            <.ui_button href={~p"/observability/traces"} variant="ghost" size="sm">
              Back to Observability
            </.ui_button>
          </:actions>
        </.header>

        <div :if={is_binary(@error)} class={ui_alert_class(variant: "error", class: "mb-4")}>
          <.icon name="hero-exclamation-triangle" class="size-5" />
          <span class="text-sm">{@error}</span>
        </div>

        <div
          :if={@state == :not_found and is_nil(@error)}
          class={ui_alert_class(variant: "warning", class: "mb-4")}
          id="trace-not-found"
        >
          <.icon name="hero-magnifying-glass" class="size-5" />
          <span class="text-sm">Trace not found or expired.</span>
        </div>

        <div
          :if={@state != :not_found}
          class="mb-4 flex flex-wrap items-center gap-3"
          id="trace-summary-bar"
        >
          <div class="text-sm font-semibold truncate max-w-[40rem]">
            {@root_service || "—"} · {@root_operation || "—"}
          </div>
          <.ui_badge variant="ghost" size="sm">{format_duration_ms(@duration_ms)}</.ui_badge>
          <.ui_badge variant="ghost" size="sm">{@span_count} spans</.ui_badge>
          <.ui_badge :if={@error_count > 0} variant="error" size="sm" id="trace-error-badge">
            {@error_count} {if @error_count == 1, do: "error", else: "errors"}
          </.ui_badge>
        </div>

        <div
          :if={@state == :spans_expired}
          class={ui_alert_class(variant: "info", class: "mb-4")}
          id="trace-spans-expired"
        >
          <.icon name="hero-clock" class="size-5" />
          <span class="text-sm">Span data for this trace is no longer retained.</span>
        </div>

        <div
          :if={@span_truncated?}
          class={ui_alert_class(variant: "warning", class: "mb-4")}
          id="trace-spans-truncated"
        >
          <.icon name="hero-exclamation-triangle" class="size-5" />
          <span class="text-sm">
            Large trace: showing the first {@span_limit_display} spans by start time.
          </span>
        </div>

        <.ui_panel :if={@state == :ok} class="mb-4">
          <:header>
            <div class="min-w-0">
              <div class="text-sm font-semibold">Span Waterfall</div>
              <div class="text-xs text-sr-muted">
                Click a span to inspect its attributes, events, and links.
              </div>
            </div>
          </:header>

          <div class="sr-ui-table-shell">
            <table id="trace-spans" class={ui_table_class(size: "sm", class: "w-full")}>
              <thead>
                <tr>
                  <th class="text-xs font-semibold text-sr-muted bg-sr-subtle/60">Operation</th>
                  <th class="whitespace-nowrap text-xs font-semibold text-sr-muted bg-sr-subtle/60 w-36">
                    Service
                  </th>
                  <th class="text-xs font-semibold text-sr-muted bg-sr-subtle/60 w-[30%] min-w-[12rem]">
                    Timeline
                  </th>
                  <th class="whitespace-nowrap text-xs font-semibold text-sr-muted bg-sr-subtle/60 w-24 text-right">
                    Duration
                  </th>
                  <th class="whitespace-nowrap text-xs font-semibold text-sr-muted bg-sr-subtle/60 w-20 text-right">
                    Status
                  </th>
                </tr>
              </thead>
              <tbody>
                <%= for {row, idx} <- Enum.with_index(@rows) do %>
                  <tr
                    id={"trace-spans-row-#{idx}"}
                    class={[
                      "hover:bg-sr-subtle/40 cursor-pointer transition-colors",
                      @highlight_idx == idx && "ring-2 ring-inset ring-sr-brand/60 bg-sr-brand/5"
                    ]}
                    phx-click="toggle_span"
                    phx-value-idx={idx}
                  >
                    <td>
                      <div
                        class="flex items-center gap-1 text-xs min-w-0"
                        style={"padding-left: #{row.depth * 16}px"}
                      >
                        <span :if={row.depth > 0} class="text-sr-muted shrink-0">└</span>
                        <span class="truncate max-w-[24rem]" title={row.name}>{row.name}</span>
                      </div>
                    </td>
                    <td>
                      <.ui_badge size="xs" variant="ghost" title={row.service}>
                        {row.service}
                      </.ui_badge>
                    </td>
                    <td>
                      <div class="relative h-3 w-full rounded bg-sr-subtle/60 overflow-hidden">
                        <div
                          class={[
                            "absolute inset-y-0 rounded",
                            (row.error? && "bg-error/80") || "bg-sr-brand/60"
                          ]}
                          style={"left: #{row.offset_pct}%; width: #{row.width_pct}%"}
                        >
                        </div>
                      </div>
                    </td>
                    <td class="whitespace-nowrap text-xs font-mono text-right">
                      {format_duration_ms(row.duration_ms)}
                    </td>
                    <td class="text-right">
                      <.ui_badge size="xs" variant={status_badge_variant(row.status_code)}>
                        {status_label(row.status_code)}
                      </.ui_badge>
                    </td>
                  </tr>
                  <tr :if={@expanded_idx == idx} id={"trace-spans-detail-#{idx}"}>
                    <td colspan="5" class="bg-sr-subtle/30">
                      <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-3 py-2">
                        <.kv label="Span ID" value={row.span_id} mono />
                        <.kv label="Parent Span ID" value={row.parent_span_id} mono />
                        <.kv label="Kind" value={span_kind_label(row.kind)} />
                        <.kv label="Status" value={span_status_detail(row)} />
                        <.time_kv
                          id={"trace-span-#{span_identity(row, idx)}-start-time"}
                          label="Start"
                          value={datetime_from_ns(row.start_ns)}
                          fallback="—"
                          timezone={@current_scope.user.timezone || "Etc/UTC"}
                        />
                        <.time_kv
                          id={"trace-span-#{span_identity(row, idx)}-end-time"}
                          label="End"
                          value={datetime_from_ns(row.end_ns)}
                          fallback="—"
                          timezone={@current_scope.user.timezone || "Etc/UTC"}
                        />
                        <.kv label="Duration" value={format_duration_ms(row.duration_ms)} mono />
                        <.kv label="Service" value={row.service} />
                        <.kv
                          :if={non_empty(Map.get(row.span, "ingest_identity"))}
                          label="Ingest Identity"
                          value={Map.get(row.span, "ingest_identity")}
                          mono
                        />
                        <.kv
                          :if={non_empty(Map.get(row.span, "ingest_agent_id"))}
                          label="Ingest Agent"
                          value={Map.get(row.span, "ingest_agent_id")}
                          mono
                        />
                        <.kv
                          :if={non_empty(Map.get(row.span, "ingest_partition"))}
                          label="Ingest Partition"
                          value={Map.get(row.span, "ingest_partition")}
                          mono
                        />
                      </div>
                      <.json_block
                        label="Attributes"
                        content={pretty_json(Map.get(row.span, "attributes"))}
                      />
                      <.json_block
                        label="Resource Attributes"
                        content={pretty_json(Map.get(row.span, "resource_attributes"))}
                      />
                      <.json_block label="Events" content={pretty_json(Map.get(row.span, "events"))} />
                      <.json_block label="Links" content={pretty_json(Map.get(row.span, "links"))} />
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        </.ui_panel>

        <.ui_panel :if={@state != :not_found}>
          <:header>
            <div class="min-w-0">
              <div class="text-sm font-semibold">Correlated Logs</div>
              <div class="text-xs text-sr-muted">
                Logs sharing this trace id within the trace's own time window (±5 minutes).
              </div>
            </div>
            <.ui_button
              :if={is_binary(@logs_query)}
              id="trace-logs-tab-link"
              href={logs_tab_href(@logs_query)}
              size="xs"
              variant="outline"
            >
              View in logs tab
            </.ui_button>
          </:header>

          <div :if={is_binary(@logs_error)} class="text-sm text-warning">{@logs_error}</div>

          <div
            :if={@logs == [] and is_nil(@logs_error)}
            class="text-sm text-sr-muted"
            id="trace-logs-empty"
          >
            No correlated logs found in the trace window.
          </div>

          <div :if={@logs != []} class="overflow-x-auto">
            <table id="trace-logs" class={ui_table_class(size: "sm", zebra: true, class: "w-full")}>
              <thead>
                <tr>
                  <th class="whitespace-nowrap text-xs font-semibold text-sr-muted bg-sr-subtle/60 w-40">
                    Time
                  </th>
                  <th class="whitespace-nowrap text-xs font-semibold text-sr-muted bg-sr-subtle/60 w-24">
                    Severity
                  </th>
                  <th class="whitespace-nowrap text-xs font-semibold text-sr-muted bg-sr-subtle/60 w-40">
                    Service
                  </th>
                  <th class="text-xs font-semibold text-sr-muted bg-sr-subtle/60">Message</th>
                </tr>
              </thead>
              <tbody>
                <%= for {log, idx} <- Enum.with_index(@logs) do %>
                  <% log_path = log_detail_path(log) %>
                  <tr
                    id={"trace-logs-row-#{idx}"}
                    class={["transition-colors", log_path && "hover:bg-sr-subtle/40 cursor-pointer"]}
                    phx-click={log_path && JS.navigate(log_path)}
                  >
                    <td class="whitespace-nowrap text-xs font-mono">
                      <% timestamp = effective_log_timestamp(log) %>
                      <.user_time
                        id={"trace-log-#{log_identity(log, idx)}-time"}
                        value={timestamp}
                        timezone={@current_scope.user.timezone || "Etc/UTC"}
                        style={:full}
                        fallback="—"
                        class="font-mono text-xs"
                      />
                    </td>
                    <td>
                      <.ui_badge size="xs" variant={severity_badge_variant(log)}>
                        {log_severity(log)}
                      </.ui_badge>
                    </td>
                    <td
                      class="whitespace-nowrap text-xs truncate max-w-[10rem]"
                      title={Map.get(log, "service_name")}
                    >
                      {Map.get(log, "service_name") || "—"}
                    </td>
                    <td class="text-xs truncate max-w-[36rem]" title={log_body(log)}>
                      {log_body(log)}
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        </.ui_panel>
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".CopyText">
        export default {
          mounted() {
            this.el.addEventListener("click", () => {
              const text = this.el.dataset.copy
              if (!text || !navigator.clipboard) return
              navigator.clipboard.writeText(text).then(() => {
                const original = this.el.textContent
                this.el.textContent = "Copied"
                setTimeout(() => { this.el.textContent = original }, 1200)
              })
            })
          }
        }
      </script>
    </Layouts.app>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, default: nil
  attr :mono, :boolean, default: false

  defp kv(assigns) do
    ~H"""
    <div class="rounded-lg border border-sr-line bg-sr-surface p-3">
      <div class="text-[11px] uppercase tracking-wider text-sr-muted mb-1">{@label}</div>
      <div class={["text-sm break-all", @mono && "font-mono text-xs"]}>{format_value(@value)}</div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :fallback, :string, required: true
  attr :timezone, :string, required: true

  defp time_kv(assigns) do
    ~H"""
    <div class="rounded-lg border border-sr-line bg-sr-surface p-3">
      <div class="mb-1 text-[11px] uppercase tracking-wider text-sr-muted">{@label}</div>
      <.user_time
        id={@id}
        value={@value}
        timezone={@timezone}
        style={:full}
        fallback={@fallback}
        class="break-all font-mono text-xs"
      />
    </div>
    """
  end

  attr :label, :string, required: true
  attr :content, :any, default: nil

  defp json_block(assigns) do
    ~H"""
    <div :if={is_binary(@content)} class="mt-3 pb-2">
      <div class="text-[11px] uppercase tracking-wider text-sr-muted mb-1">{@label}</div>
      <pre class="text-xs font-mono bg-sr-surface rounded-lg border border-sr-line p-3 overflow-x-auto max-h-64">{@content}</pre>
    </div>
    """
  end

  defp format_value(nil), do: "—"
  defp format_value(""), do: "—"
  defp format_value(v) when is_binary(v), do: v
  defp format_value(v), do: to_string(v)

  # ----------------------------------------------------------------------
  # Loading
  # ----------------------------------------------------------------------

  defp load_trace(socket, srql, trace_id) do
    scope = socket.assigns.current_scope
    {summary, summary_error} = fetch_summary(srql, trace_id, scope)
    {spans, spans_error, truncated?} = fetch_spans(srql, trace_id, scope)

    state =
      cond do
        spans != [] -> :ok
        is_binary(spans_error) -> :error
        is_map(summary) -> :spans_expired
        true -> :not_found
      end

    {rows, min_start, max_end} = build_rows(spans)

    socket =
      socket
      |> assign(:summary, summary)
      |> assign(:rows, rows)
      |> assign(:state, state)
      |> assign(:span_truncated?, truncated?)
      |> assign(:span_limit_display, @span_limit)
      |> assign(:error, spans_error || summary_error)
      |> assign_header(summary, rows, min_start, max_end)

    case state do
      :not_found ->
        socket |> assign(:logs, []) |> assign(:logs_query, nil) |> assign(:logs_error, nil)

      _ ->
        load_logs(socket, srql, trace_id, derive_log_window(min_start, max_end, summary))
    end
  end

  # Deep-link support: when the URL carries a valid `?span=` that matches a
  # loaded span, auto-expand that span's detail panel and highlight its row.
  # Unknown, malformed, or absent span params are ignored.
  defp maybe_expand_span(socket, span_param) do
    with {:ok, span_id} <- normalize_span_id(span_param),
         idx when is_integer(idx) <-
           Enum.find_index(socket.assigns.rows, &(&1.span_id == span_id)) do
      socket
      |> assign(:expanded_idx, idx)
      |> assign(:highlight_idx, idx)
    else
      _ -> socket
    end
  end

  defp fetch_summary(srql, trace_id, scope) do
    query = ~s(in:otel_trace_summaries trace_id:"#{trace_id}" limit:1)

    case srql.query(query, %{scope: scope}) do
      {:ok, %{"results" => [%{} = summary | _]}} -> {summary, nil}
      {:ok, %{"results" => _}} -> {nil, nil}
      {:error, reason} -> {nil, "Failed to load trace summary: #{format_error(reason)}"}
      {:ok, other} -> {nil, "Unexpected trace summary response: #{inspect(other)}"}
    end
  end

  defp fetch_spans(srql, trace_id, scope) do
    query = ~s(in:traces trace_id:"#{trace_id}" sort:start_time_unix_nano:asc limit:#{@span_limit})

    case srql.query(query, %{scope: scope}) do
      {:ok, %{"results" => spans}} when is_list(spans) ->
        {spans, nil, length(spans) >= @span_limit}

      {:error, reason} ->
        {[], "Failed to load spans: #{format_error(reason)}", false}

      {:ok, other} ->
        {[], "Unexpected spans response: #{inspect(other)}", false}
    end
  end

  defp assign_header(socket, summary, rows, min_start, max_end) do
    summary = summary || %{}
    first_root = Enum.find(rows, &(&1.depth == 0)) || List.first(rows)

    computed_duration =
      if is_integer(min_start) and is_integer(max_end) and max_end >= min_start do
        (max_end - min_start) / 1_000_000
      end

    span_count =
      if rows == [] do
        to_int(Map.get(summary, "span_count")) || 0
      else
        length(rows)
      end

    error_count =
      case to_int(Map.get(summary, "error_count")) do
        nil -> Enum.count(rows, & &1.error?)
        count -> count
      end

    socket
    |> assign(
      :root_service,
      non_empty(Map.get(summary, "root_service_name")) ||
        (first_root && first_root.service) ||
        first_service(Map.get(summary, "service_set"))
    )
    |> assign(:root_operation, non_empty(Map.get(summary, "root_span_name")) || (first_root && first_root.name))
    |> assign(:duration_ms, to_number(Map.get(summary, "duration_ms")) || computed_duration)
    |> assign(:span_count, span_count)
    |> assign(:error_count, error_count)
  end

  # ----------------------------------------------------------------------
  # Waterfall construction
  # ----------------------------------------------------------------------

  defp build_rows([]), do: {[], nil, nil}

  defp build_rows(spans) do
    normalized =
      spans
      |> Enum.with_index()
      |> Enum.map(fn {span, idx} -> normalize_span(span, idx) end)

    known_ids =
      normalized
      |> Enum.map(& &1.span_id)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    {roots, children} =
      Enum.split_with(normalized, fn span ->
        is_nil(span.parent_span_id) or not MapSet.member?(known_ids, span.parent_span_id)
      end)

    children_by_parent = Enum.group_by(children, & &1.parent_span_id)

    {rows, visited} =
      roots
      |> Enum.sort_by(&sort_key/1)
      |> Enum.reduce({[], MapSet.new()}, fn root, {acc, vis} ->
        {new_rows, vis} = walk(root, 0, children_by_parent, vis)
        {acc ++ new_rows, vis}
      end)

    # Spans unreachable through the parent chain (cycles, malformed parents)
    # are appended flat at depth 0 so no span is silently dropped.
    {leftover_rows, _visited} =
      children
      |> Enum.reject(&MapSet.member?(visited, &1.key))
      |> Enum.sort_by(&sort_key/1)
      |> Enum.reduce({[], visited}, fn span, {acc, vis} ->
        if MapSet.member?(vis, span.key) do
          {acc, vis}
        else
          {new_rows, vis} = walk(span, 0, children_by_parent, vis)
          {acc ++ new_rows, vis}
        end
      end)

    rows = rows ++ leftover_rows

    starts = rows |> Enum.map(& &1.start_ns) |> Enum.filter(&is_integer/1)
    ends = rows |> Enum.map(& &1.end_ns) |> Enum.filter(&is_integer/1)
    min_start = Enum.min(starts, fn -> nil end)
    max_end = Enum.max(ends, fn -> nil end)

    {Enum.map(rows, &add_timing(&1, min_start, max_end)), min_start, max_end}
  end

  defp walk(span, depth, children_by_parent, visited) do
    if MapSet.member?(visited, span.key) do
      {[], visited}
    else
      visited = MapSet.put(visited, span.key)
      row = Map.put(span, :depth, depth)

      kids =
        case span.span_id do
          nil -> []
          span_id -> children_by_parent |> Map.get(span_id, []) |> Enum.sort_by(&sort_key/1)
        end

      Enum.reduce(kids, {[row], visited}, fn kid, {acc, vis} ->
        {kid_rows, vis} = walk(kid, depth + 1, children_by_parent, vis)
        {acc ++ kid_rows, vis}
      end)
    end
  end

  defp sort_key(span), do: {span.start_ns || 0, span.span_id || ""}

  defp normalize_span(span, idx) do
    start_ns = to_int(Map.get(span, "start_time_unix_nano"))
    end_ns = to_int(Map.get(span, "end_time_unix_nano"))

    end_ns =
      if is_integer(start_ns) and is_integer(end_ns) and end_ns < start_ns do
        start_ns
      else
        end_ns
      end

    status_code = to_int(Map.get(span, "status_code")) || 0

    %{
      key: idx,
      span: span,
      span_id: canon_hex(Map.get(span, "span_id")),
      parent_span_id: canon_parent(Map.get(span, "parent_span_id")),
      start_ns: start_ns,
      end_ns: end_ns,
      name: non_empty(Map.get(span, "name")) || "—",
      service: non_empty(Map.get(span, "service_name")) || "—",
      status_code: status_code,
      error?: status_code == 2,
      kind: Map.get(span, "kind")
    }
  end

  defp add_timing(row, min_start, max_end) do
    duration_ms =
      if is_integer(row.start_ns) and is_integer(row.end_ns) do
        (row.end_ns - row.start_ns) / 1_000_000
      end

    total =
      if is_integer(min_start) and is_integer(max_end) and max_end > min_start do
        max_end - min_start
      end

    {offset_pct, width_pct} =
      if is_nil(total) or is_nil(row.start_ns) or is_nil(row.end_ns) do
        {0.0, 100.0}
      else
        offset = clamp((row.start_ns - min_start) / total * 100.0, 0.0, 100.0)
        width = max((row.end_ns - row.start_ns) / total * 100.0, 0.5)
        {Float.round(offset, 2), Float.round(clamp(width, 0.5, 100.0 - offset + 0.5), 2)}
      end

    row
    |> Map.put(:duration_ms, duration_ms)
    |> Map.put(:offset_pct, offset_pct)
    |> Map.put(:width_pct, width_pct)
  end

  defp clamp(value, low, high), do: value |> max(low) |> min(high)

  defp canon_hex(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "" -> nil
      hex -> hex
    end
  end

  defp canon_hex(_value), do: nil

  # Roots arrive as NULL after the canonical-ID change, but tolerate the
  # legacy '' and all-zero parent encodings.
  defp canon_parent(value) do
    case canon_hex(value) do
      nil -> nil
      hex -> if Regex.match?(~r/^0+$/, hex), do: nil, else: hex
    end
  end

  # ----------------------------------------------------------------------
  # Correlated logs
  # ----------------------------------------------------------------------

  defp load_logs(socket, _srql, _trace_id, :error) do
    socket |> assign(:logs, []) |> assign(:logs_query, nil) |> assign(:logs_error, nil)
  end

  defp load_logs(socket, srql, trace_id, {:ok, from_dt, to_dt}) do
    query =
      ~s(in:logs trace_id:"#{trace_id}" ) <>
        "time:[#{DateTime.to_iso8601(from_dt)},#{DateTime.to_iso8601(to_dt)}] " <>
        "sort:timestamp:asc limit:#{@log_limit}"

    socket = assign(socket, :logs_query, query)

    case srql.query(query, %{scope: socket.assigns.current_scope}) do
      {:ok, %{"results" => logs}} when is_list(logs) ->
        socket |> assign(:logs, logs) |> assign(:logs_error, nil)

      {:error, reason} ->
        socket
        |> assign(:logs, [])
        |> assign(:logs_error, "Failed to load correlated logs: #{format_error(reason)}")

      {:ok, other} ->
        socket
        |> assign(:logs, [])
        |> assign(:logs_error, "Unexpected logs response: #{inspect(other)}")
    end
  end

  defp derive_log_window(min_start, max_end, _summary) when is_integer(min_start) and is_integer(max_end) do
    pad = @log_window_pad_seconds * @nanos_per_second

    with {:ok, from_dt} <- DateTime.from_unix(min_start - pad, :nanosecond),
         {:ok, to_dt} <- DateTime.from_unix(max_end + pad, :nanosecond) do
      {:ok, DateTime.truncate(from_dt, :second), DateTime.truncate(to_dt, :second)}
    else
      _ -> :error
    end
  end

  defp derive_log_window(_min_start, _max_end, %{} = summary) do
    case parse_timestamp(Map.get(summary, "timestamp")) do
      {:ok, ts} ->
        duration_ms = to_number(Map.get(summary, "duration_ms")) || 0
        from_dt = DateTime.add(ts, -@log_window_pad_seconds, :second)

        to_dt =
          ts
          |> DateTime.add(round(duration_ms), :millisecond)
          |> DateTime.add(@log_window_pad_seconds, :second)

        {:ok, DateTime.truncate(from_dt, :second), DateTime.truncate(to_dt, :second)}

      _ ->
        :error
    end
  end

  defp derive_log_window(_min_start, _max_end, _summary), do: :error

  defp logs_tab_href(query) do
    "/observability/logs?" <> URI.encode_query(%{q: query})
  end

  defp log_detail_path(log) do
    case Map.get(log, "id") do
      id when is_binary(id) and id != "" -> "/logs/#{id}"
      _ -> nil
    end
  end

  defp effective_log_timestamp(log) do
    Map.get(log, "observed_timestamp") || Map.get(log, "timestamp")
  end

  defp span_identity(row, index) do
    if row.span_id in [nil, ""], do: "row-#{index}", else: row.span_id
  end

  defp log_identity(log, index) do
    case Map.get(log, "id") do
      id when id not in [nil, ""] -> id
      _id -> "row-#{index}"
    end
  end

  defp log_severity(log) do
    non_empty(Map.get(log, "severity_text")) || non_empty(Map.get(log, "severity")) || "—"
  end

  defp severity_badge_variant(log) do
    log
    |> log_severity()
    |> String.upcase()
    |> case do
      sev when sev in ["ERROR", "FATAL", "CRITICAL"] -> "error"
      sev when sev in ["WARN", "WARNING"] -> "warning"
      _ -> "ghost"
    end
  end

  defp log_body(log) do
    non_empty(Map.get(log, "body")) || non_empty(Map.get(log, "message")) || "—"
  end

  # ----------------------------------------------------------------------
  # Formatting helpers
  # ----------------------------------------------------------------------

  defp pretty_json(value) when is_binary(value) do
    case String.trim(value) do
      "" ->
        nil

      trimmed ->
        case Jason.decode(trimmed) do
          {:ok, decoded} when decoded == %{} or decoded == [] -> nil
          {:ok, decoded} -> Jason.encode!(decoded, pretty: true)
          {:error, _} -> trimmed
        end
    end
  end

  defp pretty_json(value) when is_map(value) or is_list(value) do
    if value == %{} or value == [] do
      nil
    else
      Jason.encode!(value, pretty: true)
    end
  end

  defp pretty_json(_value), do: nil

  defp span_kind_label(kind) do
    case to_int(kind) do
      0 -> "unspecified"
      1 -> "internal"
      2 -> "server"
      3 -> "client"
      4 -> "producer"
      5 -> "consumer"
      _ -> kind_fallback(kind)
    end
  end

  defp kind_fallback(nil), do: "—"

  defp kind_fallback(kind) when is_binary(kind) do
    kind |> String.downcase() |> String.replace_prefix("span_kind_", "")
  end

  defp kind_fallback(kind), do: to_string(kind)

  defp status_label(2), do: "error"
  defp status_label(1), do: "ok"
  defp status_label(_), do: "unset"

  defp status_badge_variant(2), do: "error"
  defp status_badge_variant(1), do: "success"
  defp status_badge_variant(_), do: "ghost"

  defp span_status_detail(row) do
    case non_empty(Map.get(row.span, "status_message")) do
      nil -> status_label(row.status_code)
      message -> "#{status_label(row.status_code)} — #{message}"
    end
  end

  defp datetime_from_ns(ns) when is_integer(ns) do
    case DateTime.from_unix(ns, :nanosecond) do
      {:ok, dt} -> dt
      _ -> nil
    end
  end

  defp datetime_from_ns(_ns), do: nil

  defp format_duration_ms(nil), do: "—"

  defp format_duration_ms(ms) when is_number(ms) do
    cond do
      ms < 1 -> "#{round(ms * 1000)}µs"
      ms < 1000 -> "#{Float.round(ms * 1.0, 1)}ms"
      true -> "#{Float.round(ms / 1000, 2)}s"
    end
  end

  defp format_duration_ms(ms) do
    case to_number(ms) do
      nil -> "—"
      value -> format_duration_ms(value)
    end
  end

  defp non_empty(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp non_empty(_value), do: nil

  # Orphan traces have a NULL root_service_name in the summary but still record
  # the services seen on the trace in service_set; use the first as a fallback.
  defp first_service(services) when is_list(services) do
    Enum.find_value(services, &non_empty/1)
  end

  defp first_service(_value), do: nil

  defp to_int(value) when is_integer(value), do: value
  defp to_int(value) when is_float(value), do: trunc(value)

  defp to_int(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {n, _rest} -> n
      :error -> nil
    end
  end

  defp to_int(_value), do: nil

  defp to_number(value) when is_number(value), do: value

  defp to_number(value) when is_binary(value) do
    trimmed = String.trim(value)

    case Float.parse(trimmed) do
      {n, _rest} -> n
      :error -> nil
    end
  end

  defp to_number(_value), do: nil

  defp parse_timestamp(value) when is_binary(value) do
    value = String.trim(value)

    # Trace summaries are source text; only an explicit offset identifies an instant.
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} ->
        {:ok, dt}

      {:error, _} ->
        :error
    end
  end

  defp parse_timestamp(_value), do: :error

  defp format_error(%Jason.DecodeError{} = err), do: Exception.message(err)
  defp format_error(%ArgumentError{} = err), do: Exception.message(err)
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

  # Prefills the shared SRQL bar with a trace-summary query for the current
  # trace. Submitting the bar routes through the entity catalog, so trace
  # summary queries land on /observability/traces.
  defp prefill_srql_bar(socket, params) do
    case normalize_trace_id(Map.get(params, "trace_id")) do
      {:ok, trace_id} ->
        query = ~s(in:otel_trace_summaries trace_id:"#{trace_id}")

        srql =
          socket.assigns.srql
          |> Map.merge(%{
            query: query,
            draft: query,
            page_path: "/observability/traces/#{trace_id}"
          })
          |> sync_builder_state(query)

        assign(socket, :srql, srql)

      :error ->
        socket
    end
  end

  defp sync_builder_state(srql, query) do
    case Builder.parse(query) do
      {:ok, builder} ->
        Map.merge(srql, %{builder: builder, builder_supported: true, builder_sync: true})

      {:error, _reason} ->
        Map.merge(srql, %{builder_supported: false, builder_sync: false})
    end
  end

  defp srql_module do
    Application.get_env(:serviceradar_web_ng, :srql_module, ServiceRadarWebNG.SRQL)
  end
end
