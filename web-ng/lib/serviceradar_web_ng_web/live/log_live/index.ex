defmodule ServiceRadarWebNGWeb.LogLive.Index do
  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.UIComponents

  alias Phoenix.LiveView.JS
  alias ServiceRadarWebNGWeb.SRQL.Page, as: SRQLPage

  @default_limit 20
  @max_limit 100
  @default_stats_window "last_24h"

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Observability")
     |> assign(:active_tab, "logs")
     |> assign(:logs, [])
     |> assign(:traces, [])
     |> assign(:metrics, [])
     |> assign(:summary, %{total: 0, fatal: 0, error: 0, warning: 0, info: 0, debug: 0})
     |> assign(:trace_stats, %{total: 0, error_traces: 0, slow_traces: 0})
     |> assign(:metrics_total, 0)
     |> assign(:limit, @default_limit)
     |> SRQLPage.init("logs", default_limit: @default_limit)}
  end

  @impl true
  def handle_params(params, uri, socket) do
    path = uri |> to_string() |> URI.parse() |> Map.get(:path)

    tab =
      case Map.get(params, "tab") do
        "logs" -> "logs"
        "traces" -> "traces"
        "metrics" -> "metrics"
        _ -> default_tab_for_path(path)
      end

    {entity, list_key} =
      case tab do
        "traces" -> {"otel_trace_summaries", :traces}
        "metrics" -> {"otel_metrics", :metrics}
        _ -> {"logs", :logs}
      end

    socket =
      socket
      |> assign(:active_tab, tab)
      |> assign(:logs, [])
      |> assign(:traces, [])
      |> assign(:metrics, [])
      |> ensure_srql_entity(entity)
      |> SRQLPage.load_list(params, uri, list_key,
        default_limit: @default_limit,
        max_limit: @max_limit
      )

    srql_module = srql_module()

    socket =
      case tab do
        "traces" ->
          socket
          |> assign(:trace_stats, load_trace_stats(srql_module))
          |> assign(:metrics_total, 0)

        "metrics" ->
          socket
          |> assign(:metrics_total, load_metrics_total(srql_module))
          |> assign(:trace_stats, %{total: 0, error_traces: 0, slow_traces: 0})

        _ ->
          summary = load_summary(srql_module, Map.get(socket.assigns.srql, :query))

          summary =
            case summary do
              %{total: 0} when is_list(socket.assigns.logs) and socket.assigns.logs != [] ->
                compute_summary(socket.assigns.logs)

              other ->
                other
            end

          socket
          |> assign(:summary, summary)
          |> assign(:trace_stats, %{total: 0, error_traces: 0, slow_traces: 0})
          |> assign(:metrics_total, 0)
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("srql_change", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_change", params)}
  end

  def handle_event("srql_submit", params, socket) do
    extra_params = %{"tab" => socket.assigns.active_tab}

    {:noreply,
     SRQLPage.handle_event(socket, "srql_submit", params,
       fallback_path: "/observability",
       extra_params: extra_params
     )}
  end

  def handle_event("srql_builder_toggle", _params, socket) do
    {:noreply,
     SRQLPage.handle_event(socket, "srql_builder_toggle", %{}, entity: current_entity(socket))}
  end

  def handle_event("srql_builder_change", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_change", params)}
  end

  def handle_event("srql_builder_apply", _params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_apply", %{})}
  end

  def handle_event("srql_builder_run", _params, socket) do
    extra_params = %{"tab" => socket.assigns.active_tab}

    {:noreply,
     SRQLPage.handle_event(socket, "srql_builder_run", %{},
       fallback_path: "/observability",
       extra_params: extra_params
     )}
  end

  def handle_event("srql_builder_add_filter", params, socket) do
    {:noreply,
     SRQLPage.handle_event(socket, "srql_builder_add_filter", params,
       entity: current_entity(socket)
     )}
  end

  def handle_event("srql_builder_remove_filter", params, socket) do
    {:noreply,
     SRQLPage.handle_event(socket, "srql_builder_remove_filter", params,
       entity: current_entity(socket)
     )}
  end

  @impl true
  def render(assigns) do
    pagination = get_in(assigns, [:srql, :pagination]) || %{}
    assigns = assign(assigns, :pagination, pagination)

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} srql={@srql}>
      <div class="mx-auto max-w-7xl p-6">
        <div class="space-y-4">
          <div class="flex items-start justify-between gap-4">
            <div class="min-w-0">
              <div class="text-xl font-semibold">Observability</div>
              <div class="text-sm text-base-content/60">
                Unified view of logs, traces, and metrics.
              </div>
            </div>
          </div>

          <.observability_tabs active={@active_tab} />

          <.log_summary :if={@active_tab == "logs"} summary={@summary} />
          <.traces_summary :if={@active_tab == "traces"} stats={@trace_stats} />
          <.metrics_summary :if={@active_tab == "metrics"} total={@metrics_total} />

          <.ui_panel>
            <:header>
              <div class="min-w-0">
                <div class="text-sm font-semibold">{panel_title(@active_tab)}</div>
                <div class="text-xs text-base-content/70">
                  {panel_subtitle(@active_tab)}
                </div>
              </div>
            </:header>

            <.logs_table :if={@active_tab == "logs"} id="logs" logs={@logs} />
            <.traces_table :if={@active_tab == "traces"} id="traces" traces={@traces} />
            <.metrics_table :if={@active_tab == "metrics"} id="metrics" metrics={@metrics} />

            <div class="mt-4 pt-4 border-t border-base-200">
              <.ui_pagination
                prev_cursor={Map.get(@pagination, "prev_cursor")}
                next_cursor={Map.get(@pagination, "next_cursor")}
                base_path={Map.get(@srql, :page_path) || "/observability"}
                query={Map.get(@srql, :query, "")}
                limit={@limit}
                result_count={panel_result_count(@active_tab, @logs, @traces, @metrics)}
                extra_params={%{tab: @active_tab}}
              />
            </div>
          </.ui_panel>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :summary, :map, required: true

  defp log_summary(assigns) do
    total = assigns.summary.total
    fatal = assigns.summary.fatal
    error = assigns.summary.error
    warning = assigns.summary.warning
    info = assigns.summary.info
    debug = assigns.summary.debug

    assigns =
      assigns
      |> assign(:total, total)
      |> assign(:fatal, fatal)
      |> assign(:error, error)
      |> assign(:warning, warning)
      |> assign(:info, info)
      |> assign(:debug, debug)

    ~H"""
    <div class="rounded-xl border border-base-200 bg-base-100 shadow-sm p-4">
      <div class="flex items-center justify-between mb-3">
        <div class="text-xs text-base-content/50 uppercase tracking-wider">Log Level Breakdown</div>
        <div class="flex items-center gap-1">
          <.link patch={~p"/observability?#{%{tab: "logs"}}"} class="btn btn-ghost btn-xs">
            All Logs
          </.link>
          <.link
            patch={
              ~p"/observability?#{%{tab: "logs", q: "in:logs severity_text:(fatal,error,FATAL,ERROR) time:last_24h sort:timestamp:desc"}}"
            }
            class="btn btn-ghost btn-xs text-error"
          >
            Errors Only
          </.link>
        </div>
      </div>
      <div class="grid grid-cols-2 sm:grid-cols-5 gap-3">
        <.level_stat label="Fatal" count={@fatal} total={@total} color="error" level="fatal,FATAL" />
        <.level_stat label="Error" count={@error} total={@total} color="warning" level="error,ERROR" />
        <.level_stat
          label="Warning"
          count={@warning}
          total={@total}
          color="info"
          level="warn,warning,WARN,WARNING"
        />
        <.level_stat label="Info" count={@info} total={@total} color="primary" level="info,INFO" />
        <.level_stat
          label="Debug"
          count={@debug}
          total={@total}
          color="success"
          level="debug,trace,DEBUG,TRACE"
        />
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :count, :integer, required: true
  attr :total, :integer, required: true
  attr :color, :string, required: true
  attr :level, :string, required: true

  defp level_stat(assigns) do
    pct = if assigns.total > 0, do: round(assigns.count / assigns.total * 100), else: 0
    query = "in:logs severity_text:(#{assigns.level}) time:last_24h sort:timestamp:desc"

    assigns =
      assigns
      |> assign(:pct, pct)
      |> assign(:query, query)

    ~H"""
    <.link
      patch={~p"/observability?#{%{tab: "logs", q: @query}}"}
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
  defp color_class("primary"), do: "text-primary"
  defp color_class("success"), do: "text-success"
  defp color_class(_), do: "text-base-content"

  defp color_bg("error"), do: "bg-error"
  defp color_bg("warning"), do: "bg-warning"
  defp color_bg("info"), do: "bg-info"
  defp color_bg("primary"), do: "bg-primary"
  defp color_bg("success"), do: "bg-success"
  defp color_bg(_), do: "bg-base-content"

  attr :active, :string, required: true

  defp observability_tabs(assigns) do
    ~H"""
    <div class="rounded-xl border border-base-200 bg-base-100 shadow-sm p-2">
      <div class="flex flex-wrap gap-2">
        <.tab_button id="logs" label="Logs" icon="hero-rectangle-stack" active={@active} />
        <.tab_button id="traces" label="Traces" icon="hero-clock" active={@active} />
        <.tab_button id="metrics" label="Metrics" icon="hero-chart-bar" active={@active} />
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :icon, :string, required: true
  attr :active, :string, required: true

  defp tab_button(assigns) do
    active? = assigns.active == assigns.id
    assigns = assign(assigns, :active?, active?)

    ~H"""
    <.link
      patch={~p"/observability?#{%{tab: @id}}"}
      class={[
        "btn btn-sm rounded-lg flex items-center gap-2 transition-colors",
        @active? && "btn-primary",
        not @active? && "btn-ghost"
      ]}
    >
      <.icon name={@icon} class="size-4" />
      {@label}
    </.link>
    """
  end

  attr :stats, :map, required: true

  defp traces_summary(assigns) do
    total = Map.get(assigns.stats, :total, 0)
    error_traces = Map.get(assigns.stats, :error_traces, 0)
    slow_traces = Map.get(assigns.stats, :slow_traces, 0)
    error_rate = if total > 0, do: Float.round(error_traces / total * 100.0, 1), else: 0.0

    assigns =
      assigns
      |> assign(:total, total)
      |> assign(:error_traces, error_traces)
      |> assign(:slow_traces, slow_traces)
      |> assign(:error_rate, error_rate)

    ~H"""
    <div class="grid grid-cols-1 sm:grid-cols-3 gap-3">
      <div class="rounded-xl border border-base-200 bg-base-100 shadow-sm p-4">
        <div class="text-xs text-base-content/50 uppercase tracking-wider mb-1">Traces (24h)</div>
        <div class="text-2xl font-bold">{@total}</div>
      </div>
      <div class="rounded-xl border border-base-200 bg-base-100 shadow-sm p-4">
        <div class="text-xs text-base-content/50 uppercase tracking-wider mb-1">Error Rate</div>
        <div class={["text-2xl font-bold", @error_rate > 5 && "text-error"]}>{@error_rate}%</div>
        <div class="text-xs text-base-content/50">{@error_traces} error traces</div>
      </div>
      <div class="rounded-xl border border-base-200 bg-base-100 shadow-sm p-4">
        <div class="text-xs text-base-content/50 uppercase tracking-wider mb-1">Slow Traces</div>
        <div class={["text-2xl font-bold", @slow_traces > 0 && "text-warning"]}>{@slow_traces}</div>
        <div class="text-xs text-base-content/50">&gt;100ms</div>
      </div>
    </div>
    """
  end

  attr :total, :integer, required: true

  defp metrics_summary(assigns) do
    ~H"""
    <div class="grid grid-cols-1 sm:grid-cols-3 gap-3">
      <div class="rounded-xl border border-base-200 bg-base-100 shadow-sm p-4">
        <div class="text-xs text-base-content/50 uppercase tracking-wider mb-1">Metrics (24h)</div>
        <div class="text-2xl font-bold">{@total}</div>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :logs, :list, default: []

  defp logs_table(assigns) do
    ~H"""
    <div class="overflow-x-auto">
      <table id={@id} class="table table-sm table-zebra w-full">
        <thead>
          <tr>
            <th class="whitespace-nowrap text-xs font-semibold text-base-content/70 bg-base-200/60 w-40">
              Time
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-base-content/70 bg-base-200/60 w-20">
              Level
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-base-content/70 bg-base-200/60 w-32">
              Service
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-base-content/70 bg-base-200/60">
              Message
            </th>
          </tr>
        </thead>
        <tbody>
          <tr :if={@logs == []}>
            <td colspan="4" class="text-sm text-base-content/60 py-8 text-center">
              No log entries found.
            </td>
          </tr>

          <%= for {log, idx} <- Enum.with_index(@logs) do %>
            <tr
              id={"#{@id}-row-#{idx}"}
              class="hover:bg-base-200/40 cursor-pointer transition-colors"
              phx-click={JS.navigate(~p"/logs/#{log_id(log)}")}
            >
              <td class="whitespace-nowrap text-xs font-mono">
                {format_timestamp(log)}
              </td>
              <td class="whitespace-nowrap text-xs">
                <.severity_badge value={Map.get(log, "severity_text")} />
              </td>
              <td class="whitespace-nowrap text-xs truncate max-w-[10rem]" title={log_service(log)}>
                {log_service(log)}
              </td>
              <td class="text-xs truncate max-w-[36rem]" title={log_message(log)}>
                {log_message(log)}
              </td>
            </tr>
          <% end %>
        </tbody>
      </table>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :traces, :list, default: []

  defp traces_table(assigns) do
    ~H"""
    <div class="overflow-x-auto">
      <table id={@id} class="table table-sm table-zebra w-full">
        <thead>
          <tr>
            <th class="whitespace-nowrap text-xs font-semibold text-base-content/70 bg-base-200/60 w-40">
              Time
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-base-content/70 bg-base-200/60 w-40">
              Service
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-base-content/70 bg-base-200/60">
              Operation
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-base-content/70 bg-base-200/60 w-24 text-right">
              Duration
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-base-content/70 bg-base-200/60 w-24 text-right">
              Errors
            </th>
          </tr>
        </thead>
        <tbody>
          <tr :if={@traces == []}>
            <td colspan="5" class="text-sm text-base-content/60 py-8 text-center">
              No traces found.
            </td>
          </tr>

          <%= for {trace, idx} <- Enum.with_index(@traces) do %>
            <tr
              id={"#{@id}-row-#{idx}"}
              class="hover:bg-base-200/40 cursor-pointer transition-colors"
              phx-click={JS.navigate(correlate_trace_href(trace))}
            >
              <td class="whitespace-nowrap text-xs font-mono">{format_timestamp(trace)}</td>
              <td
                class="whitespace-nowrap text-xs truncate max-w-[14rem]"
                title={Map.get(trace, "root_service_name")}
              >
                {Map.get(trace, "root_service_name") || "—"}
              </td>
              <td class="text-xs truncate max-w-[28rem]" title={Map.get(trace, "root_span_name")}>
                {Map.get(trace, "root_span_name") || "—"}
              </td>
              <td class="whitespace-nowrap text-xs font-mono text-right">
                {format_duration_ms(Map.get(trace, "duration_ms"))}
              </td>
              <td class="whitespace-nowrap text-xs font-mono text-right">
                <span class={error_count_class(Map.get(trace, "error_count", 0) |> to_int())}>
                  {Map.get(trace, "error_count", 0) |> to_int()}
                </span>
              </td>
            </tr>
          <% end %>
        </tbody>
      </table>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :metrics, :list, default: []

  defp metrics_table(assigns) do
    ~H"""
    <div class="overflow-x-auto">
      <table id={@id} class="table table-sm table-zebra w-full">
        <thead>
          <tr>
            <th class="whitespace-nowrap text-xs font-semibold text-base-content/70 bg-base-200/60 w-40">
              Time
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-base-content/70 bg-base-200/60 w-40">
              Service
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-base-content/70 bg-base-200/60 w-36">
              Type
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-base-content/70 bg-base-200/60">
              Operation
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-base-content/70 bg-base-200/60 w-24 text-right">
              Slow
            </th>
          </tr>
        </thead>
        <tbody>
          <tr :if={@metrics == []}>
            <td colspan="5" class="text-sm text-base-content/60 py-8 text-center">
              No metrics found.
            </td>
          </tr>

          <%= for {metric, idx} <- Enum.with_index(@metrics) do %>
            <tr
              id={"#{@id}-row-#{idx}"}
              class="hover:bg-base-200/40 cursor-pointer transition-colors"
              phx-click={JS.navigate(correlate_metric_href(metric))}
            >
              <td class="whitespace-nowrap text-xs font-mono">{format_timestamp(metric)}</td>
              <td
                class="whitespace-nowrap text-xs truncate max-w-[14rem]"
                title={Map.get(metric, "service_name")}
              >
                {Map.get(metric, "service_name") || "—"}
              </td>
              <td
                class="whitespace-nowrap text-xs truncate max-w-[10rem]"
                title={Map.get(metric, "metric_type")}
              >
                {Map.get(metric, "metric_type") || "—"}
              </td>
              <td class="text-xs truncate max-w-[28rem]" title={metric_operation(metric)}>
                {metric_operation(metric)}
              </td>
              <td class="whitespace-nowrap text-xs font-mono text-right">
                <span class={slow_badge_class(Map.get(metric, "is_slow"))}>
                  {if Map.get(metric, "is_slow") == true, do: "YES", else: "—"}
                </span>
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
    variant =
      case normalize_severity(assigns.value) do
        s when s in ["critical", "fatal", "error"] -> "error"
        s when s in ["high", "warn", "warning"] -> "warning"
        s when s in ["medium", "info"] -> "info"
        s when s in ["low", "debug", "trace", "ok"] -> "success"
        _ -> "ghost"
      end

    label =
      case assigns.value do
        nil -> "—"
        "" -> "—"
        v when is_binary(v) -> String.upcase(String.slice(v, 0, 5))
        v -> v |> to_string() |> String.upcase() |> String.slice(0, 5)
      end

    assigns = assign(assigns, :variant, variant) |> assign(:label, label)

    ~H"""
    <.ui_badge variant={@variant} size="xs">{@label}</.ui_badge>
    """
  end

  defp normalize_severity(nil), do: ""
  defp normalize_severity(v) when is_binary(v), do: v |> String.trim() |> String.downcase()
  defp normalize_severity(v), do: v |> to_string() |> normalize_severity()

  defp log_id(log) do
    Map.get(log, "id") || Map.get(log, "log_id") || "unknown"
  end

  defp format_timestamp(log) do
    ts = Map.get(log, "timestamp") || Map.get(log, "observed_timestamp")

    case parse_timestamp(ts) do
      {:ok, dt} -> Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
      _ -> ts || "—"
    end
  end

  defp load_summary(srql_module, current_query) do
    base_query = base_query_for_summary(current_query)

    queries = %{
      total: "#{base_query} stats:count() as total",
      fatal: "#{base_query} severity_text:(fatal,FATAL) stats:count() as fatal",
      error: "#{base_query} severity_text:(error,ERROR) stats:count() as error",
      warning: "#{base_query} severity_text:(warning,warn,WARNING,WARN) stats:count() as warning",
      info: "#{base_query} severity_text:(info,INFO) stats:count() as info",
      debug: "#{base_query} severity_text:(debug,trace,DEBUG,TRACE) stats:count() as debug"
    }

    results =
      Enum.reduce(queries, %{}, fn {key, query}, acc ->
        Map.put(acc, key, srql_module.query(query))
      end)

    %{
      total: extract_stat(results[:total], "total"),
      fatal: extract_stat(results[:fatal], "fatal"),
      error: extract_stat(results[:error], "error"),
      warning: extract_stat(results[:warning], "warning"),
      info: extract_stat(results[:info], "info"),
      debug: extract_stat(results[:debug], "debug")
    }
  end

  defp base_query_for_summary(nil), do: "in:logs time:#{@default_stats_window}"

  defp base_query_for_summary(query) when is_binary(query) do
    trimmed = String.trim(query)

    cond do
      trimmed == "" ->
        "in:logs time:#{@default_stats_window}"

      String.contains?(trimmed, "in:logs") ->
        trimmed
        |> strip_tokens_for_stats()
        |> ensure_time_filter()

      true ->
        "in:logs time:#{@default_stats_window}"
    end
  end

  defp base_query_for_summary(_), do: "in:logs time:#{@default_stats_window}"

  defp strip_tokens_for_stats(query) do
    query = Regex.replace(~r/(?:^|\s)limit:\S+/, query, "")
    query = Regex.replace(~r/(?:^|\s)sort:\S+/, query, "")
    query = Regex.replace(~r/(?:^|\s)cursor:\S+/, query, "")
    query |> String.trim() |> String.replace(~r/\s+/, " ")
  end

  defp ensure_time_filter(query) do
    if Regex.match?(~r/(?:^|\s)time:\S+/, query) do
      query
    else
      "#{query} time:#{@default_stats_window}"
    end
  end

  defp extract_stat({:ok, %{"results" => [%{} = row | _]}}, key) when is_binary(key) do
    row
    |> Map.get(key)
    |> to_int()
  end

  defp extract_stat({:ok, %{"results" => [value | _]}}, _key), do: to_int(value)
  defp extract_stat(_result, _key), do: 0

  defp to_int(value) when is_integer(value), do: value
  defp to_int(value) when is_float(value), do: trunc(value)

  defp to_int(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> 0
    end
  end

  defp to_int(_), do: 0

  defp srql_module do
    Application.get_env(:serviceradar_web_ng, :srql_module, ServiceRadarWebNG.SRQL)
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

  defp panel_title("traces"), do: "Traces"
  defp panel_title("metrics"), do: "Metrics"
  defp panel_title(_), do: "Log Stream"

  defp panel_subtitle("traces"), do: "Click a trace to jump to correlated logs."

  defp panel_subtitle("metrics"),
    do: "Click a metric to jump to correlated logs (if trace_id is present)."

  defp panel_subtitle(_), do: "Click any log entry to view full details."

  defp panel_result_count("traces", _logs, traces, _metrics), do: length(traces)
  defp panel_result_count("metrics", _logs, _traces, metrics), do: length(metrics)
  defp panel_result_count(_, logs, _traces, _metrics), do: length(logs)

  defp default_tab_for_path("/observability"), do: "traces"
  defp default_tab_for_path(_), do: "logs"

  defp ensure_srql_entity(socket, entity) when is_binary(entity) do
    current = socket.assigns |> Map.get(:srql, %{}) |> Map.get(:entity)

    if current == entity do
      socket
    else
      SRQLPage.init(socket, entity, default_limit: @default_limit)
    end
  end

  defp current_entity(socket) do
    socket.assigns |> Map.get(:srql, %{}) |> Map.get(:entity) || "logs"
  end

  defp load_trace_stats(srql_module) do
    query =
      "in:otel_trace_summaries time:last_24h " <>
        ~s|stats:"count() as total, sum(if(status_code != 1, 1, 0)) as error_traces, sum(if(duration_ms > 100, 1, 0)) as slow_traces"|

    case srql_module.query(query) do
      {:ok, %{"results" => [%{} = row | _]}} ->
        %{
          total: row |> Map.get("total") |> to_int(),
          error_traces: row |> Map.get("error_traces") |> to_int(),
          slow_traces: row |> Map.get("slow_traces") |> to_int()
        }

      _ ->
        %{total: 0, error_traces: 0, slow_traces: 0}
    end
  end

  defp load_metrics_total(srql_module) do
    query = "in:otel_metrics time:last_24h stats:count() as total"

    case srql_module.query(query) do
      {:ok, %{"results" => [%{} = row | _]}} -> row |> Map.get("total") |> to_int()
      {:ok, %{"results" => [value | _]}} -> to_int(value)
      _ -> 0
    end
  end

  defp format_duration_ms(value) do
    ms = extract_number(value)

    cond do
      not is_number(ms) -> "—"
      ms >= 1000 -> "#{Float.round(ms / 1000.0, 2)}s"
      true -> "#{Float.round(ms * 1.0, 1)}ms"
    end
  end

  defp error_count_class(count) when is_integer(count) and count > 0, do: "text-error font-bold"
  defp error_count_class(_), do: "text-base-content/60"

  defp metric_operation(metric) do
    http_route = Map.get(metric, "http_route")
    http_method = Map.get(metric, "http_method")
    grpc_service = Map.get(metric, "grpc_service")
    grpc_method = Map.get(metric, "grpc_method")

    cond do
      is_binary(grpc_service) and grpc_service != "" and is_binary(grpc_method) and
          grpc_method != "" ->
        "#{grpc_service}/#{grpc_method}"

      is_binary(http_method) and http_method != "" and is_binary(http_route) and http_route != "" ->
        "#{http_method} #{http_route}"

      is_binary(http_route) and http_route != "" ->
        http_route

      true ->
        Map.get(metric, "span_name") || "—"
    end
  end

  defp slow_badge_class(true), do: "text-warning font-bold"
  defp slow_badge_class(_), do: "text-base-content/50"

  defp correlate_trace_href(trace) do
    trace_id = trace |> Map.get("trace_id") |> escape_srql_value()
    q = "in:logs trace_id:\"#{trace_id}\" time:last_24h sort:timestamp:desc"
    "/observability?" <> URI.encode_query(%{tab: "logs", q: q, limit: 50})
  end

  defp correlate_metric_href(metric) do
    trace_id = metric |> Map.get("trace_id")

    if is_binary(trace_id) and trace_id != "" do
      q = "in:logs trace_id:\"#{escape_srql_value(trace_id)}\" time:last_24h sort:timestamp:desc"
      "/observability?" <> URI.encode_query(%{tab: "logs", q: q, limit: 50})
    else
      "/observability?" <> URI.encode_query(%{tab: "logs"})
    end
  end

  defp escape_srql_value(nil), do: ""

  defp escape_srql_value(value) when is_binary(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end

  defp escape_srql_value(value), do: value |> to_string() |> escape_srql_value()

  defp extract_number(value) when is_number(value), do: value

  defp extract_number(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp extract_number(_), do: nil

  defp log_service(log) do
    service =
      Map.get(log, "service_name") ||
        Map.get(log, "source") ||
        Map.get(log, "scope_name")

    case service do
      nil -> "—"
      "" -> "—"
      v when is_binary(v) -> v
      v -> to_string(v)
    end
  end

  defp log_message(log) do
    message =
      Map.get(log, "body") ||
        Map.get(log, "message") ||
        Map.get(log, "short_message")

    case message do
      nil -> "—"
      "" -> "—"
      v when is_binary(v) -> String.slice(v, 0, 300)
      v -> v |> to_string() |> String.slice(0, 300)
    end
  end

  # Compute summary stats from logs
  # Must match the same patterns as severity_badge for consistency
  defp compute_summary(logs) when is_list(logs) do
    initial = %{total: 0, fatal: 0, error: 0, warning: 0, info: 0, debug: 0}

    Enum.reduce(logs, initial, fn log, acc ->
      severity = normalize_severity(Map.get(log, "severity_text"))

      updated =
        case severity do
          s when s in ["fatal", "critical"] -> Map.update!(acc, :fatal, &(&1 + 1))
          s when s in ["error", "err"] -> Map.update!(acc, :error, &(&1 + 1))
          s when s in ["warn", "warning", "high"] -> Map.update!(acc, :warning, &(&1 + 1))
          s when s in ["info", "information", "medium"] -> Map.update!(acc, :info, &(&1 + 1))
          s when s in ["debug", "trace", "low", "ok"] -> Map.update!(acc, :debug, &(&1 + 1))
          _ -> acc
        end

      Map.update!(updated, :total, &(&1 + 1))
    end)
  end

  defp compute_summary(_), do: %{total: 0, fatal: 0, error: 0, warning: 0, info: 0, debug: 0}
end
