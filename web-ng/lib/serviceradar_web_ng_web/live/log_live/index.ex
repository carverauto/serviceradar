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
     |> assign(:trace_latency, %{
       avg_duration_ms: 0.0,
       p95_duration_ms: 0.0,
       service_count: 0,
       sample_size: 0
     })
     |> assign(:metrics_stats, %{
       total: 0,
       slow_spans: 0,
       error_spans: 0,
       error_rate: 0.0,
       avg_duration_ms: 0.0,
       p95_duration_ms: 0.0,
       sample_size: 0
     })
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
          trace_latency = compute_trace_latency(socket.assigns.traces)

          socket
          |> assign(:trace_stats, load_trace_stats(srql_module))
          |> assign(:trace_latency, trace_latency)
          |> assign(:metrics_stats, %{
            total: 0,
            slow_spans: 0,
            error_spans: 0,
            error_rate: 0.0,
            avg_duration_ms: 0.0,
            p95_duration_ms: 0.0,
            sample_size: 0
          })

        "metrics" ->
          metrics_counts = load_metrics_counts(srql_module)
          duration_stats = compute_duration_stats(socket.assigns.metrics, "duration_ms")

          metrics_stats =
            metrics_counts
            |> Map.merge(duration_stats)
            |> Map.put(
              :error_rate,
              compute_error_rate(metrics_counts.total, metrics_counts.error_spans)
            )

          socket
          |> assign(:metrics_stats, metrics_stats)
          |> assign(:trace_stats, %{total: 0, error_traces: 0, slow_traces: 0})
          |> assign(:trace_latency, %{
            avg_duration_ms: 0.0,
            p95_duration_ms: 0.0,
            service_count: 0,
            sample_size: 0
          })

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
          |> assign(:trace_latency, %{
            avg_duration_ms: 0.0,
            p95_duration_ms: 0.0,
            service_count: 0,
            sample_size: 0
          })
          |> assign(:metrics_stats, %{
            total: 0,
            slow_spans: 0,
            error_spans: 0,
            error_rate: 0.0,
            avg_duration_ms: 0.0,
            p95_duration_ms: 0.0,
            sample_size: 0
          })
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
          <.traces_summary
            :if={@active_tab == "traces"}
            stats={@trace_stats}
            latency={@trace_latency}
          />
          <.metrics_summary :if={@active_tab == "metrics"} stats={@metrics_stats} />

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
  attr :latency, :map, required: true

  defp traces_summary(assigns) do
    total = Map.get(assigns.stats, :total, 0)
    error_traces = Map.get(assigns.stats, :error_traces, 0)
    slow_traces = Map.get(assigns.stats, :slow_traces, 0)
    error_rate = if total > 0, do: Float.round(error_traces / total * 100.0, 1), else: 0.0
    successful = max(total - error_traces, 0)

    avg_duration_ms = Map.get(assigns.latency, :avg_duration_ms, 0.0)
    p95_duration_ms = Map.get(assigns.latency, :p95_duration_ms, 0.0)
    services_count = Map.get(assigns.latency, :service_count, 0)
    sample_size = Map.get(assigns.latency, :sample_size, 0)

    assigns =
      assigns
      |> assign(:total, total)
      |> assign(:successful, successful)
      |> assign(:error_traces, error_traces)
      |> assign(:slow_traces, slow_traces)
      |> assign(:error_rate, error_rate)
      |> assign(:avg_duration_ms, avg_duration_ms)
      |> assign(:p95_duration_ms, p95_duration_ms)
      |> assign(:services_count, services_count)
      |> assign(:sample_size, sample_size)

    ~H"""
    <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-6 gap-3">
      <.obs_stat title="Total Traces" value={format_compact_int(@total)} icon="hero-clock" />
      <.obs_stat
        title="Successful"
        value={format_compact_int(@successful)}
        icon="hero-check-circle"
        tone="success"
      />
      <.obs_stat
        title="Errors"
        value={format_compact_int(@error_traces)}
        icon="hero-x-circle"
        tone={if @error_traces > 0, do: "error", else: "success"}
      />
      <.obs_stat
        title="Error Rate"
        value={"#{format_pct(@error_rate)}%"}
        icon="hero-trending-up"
        tone={if @error_rate > 1.0, do: "error", else: "success"}
      />
      <.obs_stat
        title="Avg Duration"
        value={format_duration_ms(@avg_duration_ms)}
        subtitle={if @sample_size > 0, do: "sample (#{@sample_size})", else: "sample"}
        icon="hero-chart-bar"
        tone="info"
      />
      <.obs_stat
        title="P95 Duration"
        value={format_duration_ms(@p95_duration_ms)}
        subtitle={if @services_count > 0, do: "#{@services_count} services", else: "sample"}
        icon="hero-bolt"
        tone="warning"
      />
    </div>
    """
  end

  attr :stats, :map, required: true

  defp metrics_summary(assigns) do
    total = Map.get(assigns.stats, :total, 0)
    slow_spans = Map.get(assigns.stats, :slow_spans, 0)
    error_spans = Map.get(assigns.stats, :error_spans, 0)
    error_rate = Map.get(assigns.stats, :error_rate, 0.0)
    avg_duration_ms = Map.get(assigns.stats, :avg_duration_ms, 0.0)
    p95_duration_ms = Map.get(assigns.stats, :p95_duration_ms, 0.0)
    sample_size = Map.get(assigns.stats, :sample_size, 0)

    assigns =
      assigns
      |> assign(:total, total)
      |> assign(:slow_spans, slow_spans)
      |> assign(:error_spans, error_spans)
      |> assign(:error_rate, error_rate)
      |> assign(:avg_duration_ms, avg_duration_ms)
      |> assign(:p95_duration_ms, p95_duration_ms)
      |> assign(:sample_size, sample_size)

    ~H"""
    <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-6 gap-3">
      <.obs_stat title="Total Metrics" value={format_compact_int(@total)} icon="hero-chart-bar" />
      <.obs_stat
        title="Slow Spans"
        value={format_compact_int(@slow_spans)}
        icon="hero-bolt"
        tone={if @slow_spans > 0, do: "warning", else: "success"}
      />
      <.obs_stat
        title="Errors"
        value={format_compact_int(@error_spans)}
        icon="hero-exclamation-triangle"
        tone={if @error_spans > 0, do: "error", else: "success"}
      />
      <.obs_stat
        title="Error Rate"
        value={"#{format_pct(@error_rate)}%"}
        icon="hero-trending-up"
        tone={if @error_rate > 1.0, do: "error", else: "success"}
      />
      <.obs_stat
        title="Avg Duration"
        value={format_duration_ms(@avg_duration_ms)}
        subtitle={if @sample_size > 0, do: "sample (#{@sample_size})", else: "sample"}
        icon="hero-clock"
        tone="info"
      />
      <.obs_stat
        title="P95 Duration"
        value={format_duration_ms(@p95_duration_ms)}
        subtitle="sample"
        icon="hero-chart-bar"
        tone="neutral"
      />
    </div>
    """
  end

  attr :title, :string, required: true
  attr :value, :string, required: true
  attr :subtitle, :string, default: nil
  attr :icon, :string, required: true
  attr :tone, :string, default: "neutral", values: ~w(neutral success warning error info)

  defp obs_stat(assigns) do
    {bg, fg} =
      case assigns.tone do
        "success" -> {"bg-success/10", "text-success"}
        "warning" -> {"bg-warning/10", "text-warning"}
        "error" -> {"bg-error/10", "text-error"}
        "info" -> {"bg-info/10", "text-info"}
        _ -> {"bg-base-200/50", "text-base-content/60"}
      end

    assigns = assign(assigns, :bg, bg) |> assign(:fg, fg)

    ~H"""
    <div class="rounded-xl border border-base-200 bg-base-100 shadow-sm p-3">
      <div class="flex items-center gap-2">
        <div class={["size-8 rounded-lg flex items-center justify-center shrink-0", @bg]}>
          <.icon name={@icon} class={["size-4", @fg]} />
        </div>
        <div class="min-w-0">
          <div class="text-xs text-base-content/60 truncate">{@title}</div>
          <div class="text-lg font-bold tabular-nums truncate">{@value}</div>
          <div :if={is_binary(@subtitle)} class="text-[10px] text-base-content/50 truncate">
            {@subtitle}
          </div>
        </div>
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
    values =
      assigns.metrics
      |> Enum.filter(&is_map/1)
      |> Enum.map(&metric_value_ms/1)
      |> Enum.filter(&is_number/1)

    {min_v, max_v} =
      case values do
        [] -> {0.0, 0.0}
        _ -> {Enum.min(values), Enum.max(values)}
      end

    assigns =
      assigns
      |> assign(:min_v, min_v)
      |> assign(:max_v, max_v)

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
              Value
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-base-content/70 bg-base-200/60 w-32">
              Viz
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-base-content/70 bg-base-200/60 w-24 text-right">
              Slow
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-base-content/70 bg-base-200/60 w-20 text-right">
              Logs
            </th>
          </tr>
        </thead>
        <tbody>
          <tr :if={@metrics == []}>
            <td colspan="8" class="text-sm text-base-content/60 py-8 text-center">
              No metrics found.
            </td>
          </tr>

          <%= for {metric, idx} <- Enum.with_index(@metrics) do %>
            <tr id={"#{@id}-row-#{idx}"} class="hover:bg-base-200/40 transition-colors">
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
                <span class="inline-flex items-center gap-2">
                  <span class={metric_type_badge_class(metric)}>
                    {Map.get(metric, "metric_type") || "—"}
                  </span>
                </span>
              </td>
              <td class="text-xs truncate max-w-[28rem]" title={metric_operation(metric)}>
                <.link
                  :if={is_binary(Map.get(metric, "span_id")) and Map.get(metric, "span_id") != ""}
                  navigate={~p"/observability/metrics/#{Map.get(metric, "span_id")}"}
                  class="link link-hover"
                >
                  {metric_operation(metric)}
                </.link>
                <span :if={
                  not (is_binary(Map.get(metric, "span_id")) and Map.get(metric, "span_id") != "")
                }>
                  {metric_operation(metric)}
                </span>
              </td>
              <td class="whitespace-nowrap text-xs font-mono text-right">
                {format_metric_value(metric)}
              </td>
              <td class="whitespace-nowrap text-xs">
                <.metric_bar value={metric_value_ms(metric)} min_v={@min_v} max_v={@max_v} />
              </td>
              <td class="whitespace-nowrap text-xs font-mono text-right">
                <span class={slow_badge_class(Map.get(metric, "is_slow"))}>
                  {if Map.get(metric, "is_slow") == true, do: "YES", else: "—"}
                </span>
              </td>
              <td class="whitespace-nowrap text-xs text-right">
                <.link
                  :if={is_binary(Map.get(metric, "trace_id")) and Map.get(metric, "trace_id") != ""}
                  navigate={correlate_metric_href(metric)}
                  class="btn btn-ghost btn-xs"
                  title="View correlated logs"
                >
                  <.icon name="hero-arrow-top-right-on-square" class="size-4" />
                </.link>
                <span
                  :if={
                    not (is_binary(Map.get(metric, "trace_id")) and Map.get(metric, "trace_id") != "")
                  }
                  class="text-base-content/40"
                >
                  —
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
  attr :min_v, :float, default: 0.0
  attr :max_v, :float, default: 0.0

  defp metric_bar(assigns) do
    v = assigns.value
    min_v = assigns.min_v
    max_v = assigns.max_v

    pct =
      cond do
        not is_number(v) -> 0
        max_v <= min_v -> 100
        true -> round((v - min_v) / (max_v - min_v) * 100)
      end

    pct = pct |> max(0) |> min(100)

    assigns = assign(assigns, :pct, pct)

    ~H"""
    <div class="h-2 w-full bg-base-200/60 rounded-full overflow-hidden">
      <div class="h-full bg-info/60 rounded-full" style={"width: #{@pct}%"} />
    </div>
    """
  end

  defp metric_type_badge_class(metric) do
    case metric |> Map.get("metric_type") |> normalize_severity() do
      "histogram" -> "badge badge-sm badge-info"
      "gauge" -> "badge badge-sm badge-success"
      "counter" -> "badge badge-sm badge-primary"
      _ -> "badge badge-sm badge-ghost"
    end
  end

  defp format_metric_value(metric) do
    # Determine what kind of value this metric has and format appropriately
    metric_name = Map.get(metric, "span_name") || ""
    metric_type = Map.get(metric, "metric_type") || ""

    cond do
      # Duration metrics - check for duration fields first
      is_duration_metric?(metric) ->
        format_duration_value(metric)

      # Byte metrics - check metric name for "bytes" suffix
      is_bytes_metric?(metric_name) ->
        format_bytes_value(metric)

      # Counters and histograms often have raw values
      has_raw_value?(metric) ->
        format_raw_value(metric, metric_type)

      true ->
        "—"
    end
  end

  defp is_duration_metric?(metric) do
    is_number(metric["duration_ms"]) or is_binary(metric["duration_ms"]) or
      is_number(metric["duration_seconds"]) or is_binary(metric["duration_seconds"])
  end

  defp is_bytes_metric?(name) when is_binary(name) do
    downcased = String.downcase(name)
    String.ends_with?(downcased, "_bytes") or String.contains?(downcased, "bytes")
  end

  defp is_bytes_metric?(_), do: false

  defp has_raw_value?(metric) do
    is_number(metric["value"]) or is_binary(metric["value"]) or
      is_number(metric["sum"]) or is_binary(metric["sum"]) or
      is_number(metric["count"]) or is_binary(metric["count"])
  end

  defp format_duration_value(metric) do
    ms =
      cond do
        is_number(metric["duration_ms"]) ->
          metric["duration_ms"] * 1.0

        is_binary(metric["duration_ms"]) ->
          extract_number(metric["duration_ms"]) || 0.0

        is_number(metric["duration_seconds"]) ->
          metric["duration_seconds"] * 1000.0

        is_binary(metric["duration_seconds"]) ->
          case extract_number(metric["duration_seconds"]) do
            n when is_number(n) -> n * 1000.0
            _ -> 0.0
          end

        true ->
          0.0
      end

    cond do
      ms >= 1000 -> "#{Float.round(ms / 1000.0, 2)}s"
      true -> "#{Float.round(ms * 1.0, 1)}ms"
    end
  end

  defp format_bytes_value(metric) do
    bytes =
      cond do
        is_number(metric["value"]) -> metric["value"]
        is_binary(metric["value"]) -> extract_number(metric["value"]) || 0
        is_number(metric["sum"]) -> metric["sum"]
        is_binary(metric["sum"]) -> extract_number(metric["sum"]) || 0
        true -> 0
      end

    cond do
      bytes >= 1_099_511_627_776 -> "#{Float.round(bytes / 1_099_511_627_776 * 1.0, 1)} TB"
      bytes >= 1_073_741_824 -> "#{Float.round(bytes / 1_073_741_824 * 1.0, 1)} GB"
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576 * 1.0, 1)} MB"
      bytes >= 1024 -> "#{Float.round(bytes / 1024 * 1.0, 1)} KB"
      true -> "#{trunc(bytes)} B"
    end
  end

  defp format_raw_value(metric, _metric_type) do
    value =
      cond do
        is_number(metric["value"]) -> metric["value"]
        is_binary(metric["value"]) -> extract_number(metric["value"])
        is_number(metric["sum"]) -> metric["sum"]
        is_binary(metric["sum"]) -> extract_number(metric["sum"])
        is_number(metric["count"]) -> metric["count"]
        is_binary(metric["count"]) -> extract_number(metric["count"])
        true -> nil
      end

    if is_number(value) do
      # Format based on magnitude
      cond do
        value >= 1_000_000 -> "#{Float.round(value / 1_000_000 * 1.0, 1)}M"
        value >= 1_000 -> "#{Float.round(value / 1_000 * 1.0, 1)}k"
        is_float(value) -> "#{Float.round(value, 2)}"
        true -> "#{trunc(value)}"
      end
    else
      "—"
    end
  end

  # Used for the visualization bar - extracts numeric value for comparison
  defp metric_value_ms(metric) when is_map(metric) do
    cond do
      is_number(metric["duration_ms"]) ->
        metric["duration_ms"] * 1.0

      is_binary(metric["duration_ms"]) ->
        extract_number(metric["duration_ms"])

      is_number(metric["duration_seconds"]) ->
        metric["duration_seconds"] * 1000.0

      is_binary(metric["duration_seconds"]) ->
        case extract_number(metric["duration_seconds"]) do
          n when is_number(n) -> n * 1000.0
          _ -> nil
        end

      # Fall back to raw value for the bar visualization
      is_number(metric["value"]) ->
        metric["value"] * 1.0

      is_binary(metric["value"]) ->
        extract_number(metric["value"])

      is_number(metric["sum"]) ->
        metric["sum"] * 1.0

      is_binary(metric["sum"]) ->
        extract_number(metric["sum"])

      true ->
        nil
    end
  end

  defp metric_value_ms(_), do: nil

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

    stats_expr =
      ~s|count() as total, | <>
        ~s|sum(if(severity_text = 'fatal' OR severity_text = 'FATAL', 1, 0)) as fatal, | <>
        ~s|sum(if(severity_text = 'error' OR severity_text = 'ERROR', 1, 0)) as error, | <>
        ~s|sum(if(severity_text = 'warning' OR severity_text = 'warn' OR severity_text = 'WARNING' OR severity_text = 'WARN', 1, 0)) as warning, | <>
        ~s|sum(if(severity_text = 'info' OR severity_text = 'INFO', 1, 0)) as info, | <>
        ~s|sum(if(severity_text = 'debug' OR severity_text = 'trace' OR severity_text = 'DEBUG' OR severity_text = 'TRACE', 1, 0)) as debug|

    query = ~s|#{base_query} stats:"#{stats_expr}"|

    case srql_module.query(query) do
      {:ok, %{"results" => [%{} = raw | _]}} ->
        row =
          case Map.get(raw, "payload") do
            %{} = payload -> payload
            _ -> raw
          end

        %{
          total: row |> Map.get("total") |> to_int(),
          fatal: row |> Map.get("fatal") |> to_int(),
          error: row |> Map.get("error") |> to_int(),
          warning: row |> Map.get("warning") |> to_int(),
          info: row |> Map.get("info") |> to_int(),
          debug: row |> Map.get("debug") |> to_int()
        }

      _ ->
        %{total: 0, fatal: 0, error: 0, warning: 0, info: 0, debug: 0}
    end
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
    query = Regex.replace(~r/(?:^|\s)stats:(?:"[^"]*"|\S+)/, query, "")
    query |> String.trim() |> String.replace(~r/\s+/, " ")
  end

  defp ensure_time_filter(query) do
    if Regex.match?(~r/(?:^|\s)time:\S+/, query) do
      query
    else
      "#{query} time:#{@default_stats_window}"
    end
  end

  defp to_int(value) when is_integer(value), do: value
  defp to_int(value) when is_float(value), do: trunc(value)

  defp to_int(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> 0
    end
  end

  defp to_int(_), do: 0

  defp extract_stats_count({:ok, %{"results" => [%{} = raw | _]}}, key) when is_binary(key) do
    row =
      case Map.get(raw, "payload") do
        %{} = payload -> payload
        _ -> raw
      end

    row |> Map.get(key) |> to_int()
  end

  defp extract_stats_count({:ok, %{"results" => [value | _]}}, _key), do: to_int(value)
  defp extract_stats_count(_result, _key), do: 0

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
      {:ok, %{"results" => [%{} = raw | _]}} ->
        row =
          case Map.get(raw, "payload") do
            %{} = payload -> payload
            _ -> raw
          end

        %{
          total: row |> Map.get("total") |> to_int(),
          error_traces: row |> Map.get("error_traces") |> to_int(),
          slow_traces: row |> Map.get("slow_traces") |> to_int()
        }

      _ ->
        %{total: 0, error_traces: 0, slow_traces: 0}
    end
  end

  defp load_metrics_counts(srql_module) do
    total_query = ~s|in:otel_metrics time:last_24h stats:"count() as total"|
    slow_query = ~s|in:otel_metrics time:last_24h is_slow:true stats:"count() as total"|

    error_level_query =
      ~s|in:otel_metrics time:last_24h level:(error,ERROR) stats:"count() as total"|

    error_http4_query =
      ~s|in:otel_metrics time:last_24h http_status_code:4% stats:"count() as total"|

    error_http5_query =
      ~s|in:otel_metrics time:last_24h http_status_code:5% stats:"count() as total"|

    error_grpc_query =
      ~s|in:otel_metrics time:last_24h !grpc_status_code:0 !grpc_status_code:"" stats:"count() as total"|

    total = extract_stats_count(srql_module.query(total_query), "total")
    slow_spans = extract_stats_count(srql_module.query(slow_query), "total")

    error_level = extract_stats_count(srql_module.query(error_level_query), "total")

    error_spans =
      if error_level > 0 do
        error_level
      else
        error_http4 = extract_stats_count(srql_module.query(error_http4_query), "total")
        error_http5 = extract_stats_count(srql_module.query(error_http5_query), "total")
        error_grpc = extract_stats_count(srql_module.query(error_grpc_query), "total")
        error_http4 + error_http5 + error_grpc
      end

    %{total: total, slow_spans: slow_spans, error_spans: error_spans}
  end

  defp compute_error_rate(total, errors) when is_integer(total) and total > 0 do
    Float.round(errors / total * 100.0, 1)
  end

  defp compute_error_rate(_total, _errors), do: 0.0

  defp compute_trace_latency(rows) do
    duration_stats = compute_duration_stats(rows, "duration_ms")
    services = unique_services_from_traces(rows)
    Map.put(duration_stats, :service_count, map_size(services))
  end

  defp unique_services_from_traces(rows) when is_list(rows) do
    rows
    |> Enum.filter(&is_map/1)
    |> Enum.reduce(%{}, fn row, acc ->
      name = Map.get(row, "root_service_name") || Map.get(row, "service_name")

      if is_binary(name) and String.trim(name) != "" do
        Map.put(acc, name, true)
      else
        acc
      end
    end)
  end

  defp unique_services_from_traces(_), do: %{}

  defp compute_duration_stats(rows, field) when is_list(rows) and is_binary(field) do
    durations =
      rows
      |> Enum.filter(&is_map/1)
      |> Enum.map(fn row -> extract_number(Map.get(row, field)) end)
      |> Enum.filter(&is_number/1)

    sample_size = length(durations)

    avg =
      if sample_size > 0 do
        Enum.sum(durations) / sample_size
      else
        0.0
      end

    p95 =
      if sample_size > 0 do
        sorted = Enum.sort(durations)
        idx = trunc(Float.floor(sample_size * 0.95))
        Enum.at(sorted, min(idx, sample_size - 1)) || 0.0
      else
        0.0
      end

    %{avg_duration_ms: avg, p95_duration_ms: p95, sample_size: sample_size}
  end

  defp compute_duration_stats(_rows, _field),
    do: %{avg_duration_ms: 0.0, p95_duration_ms: 0.0, sample_size: 0}

  defp format_pct(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 1)
  defp format_pct(value) when is_integer(value), do: Integer.to_string(value)
  defp format_pct(_), do: "0.0"

  defp format_compact_int(n) when is_integer(n) and n >= 1_000_000 do
    :erlang.float_to_binary(n / 1_000_000, decimals: 1)
    |> String.trim_trailing("0")
    |> String.trim_trailing(".")
    |> Kernel.<>("M")
  end

  defp format_compact_int(n) when is_integer(n) and n >= 1_000 do
    :erlang.float_to_binary(n / 1_000, decimals: 1)
    |> String.trim_trailing("0")
    |> String.trim_trailing(".")
    |> Kernel.<>("k")
  end

  defp format_compact_int(n) when is_integer(n), do: Integer.to_string(n)
  defp format_compact_int(_), do: "0"

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
