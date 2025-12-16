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
     |> assign(:sparklines, %{})
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
          # Query duration stats from continuous aggregation for full 24h data
          duration_stats = load_duration_stats_from_cagg()

          metrics_stats =
            metrics_counts
            |> Map.merge(duration_stats)
            |> Map.put(
              :error_rate,
              compute_error_rate(metrics_counts.total, metrics_counts.error_spans)
            )

          # Load sparkline data for gauge/counter metrics
          sparklines = load_sparklines(socket.assigns.metrics)

          socket
          |> assign(:metrics_stats, metrics_stats)
          |> assign(:sparklines, sparklines)
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
            <.metrics_table :if={@active_tab == "metrics"} id="metrics" metrics={@metrics} sparklines={@sparklines} />

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
        <div class="flex items-center gap-3">
          <div class="text-xs text-base-content/50 uppercase tracking-wider">Log Level Breakdown</div>
          <div class="text-sm font-semibold text-base-content">
            {format_compact_int(@total)} <span class="text-xs font-normal text-base-content/60">total (24h)</span>
          </div>
        </div>
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
      <.obs_stat
        title="Total Traces"
        value={format_compact_int(@total)}
        icon="hero-clock"
        href={~p"/observability?#{%{tab: "traces", q: "in:otel_trace_summaries time:last_24h sort:timestamp:desc limit:100"}}"}
      />
      <.obs_stat
        title="Successful"
        value={format_compact_int(@successful)}
        icon="hero-check-circle"
        tone="success"
        href={~p"/observability?#{%{tab: "traces", q: "in:otel_trace_summaries time:last_24h !status_code:2 sort:timestamp:desc limit:100"}}"}
      />
      <.obs_stat
        title="Errors"
        value={format_compact_int(@error_traces)}
        icon="hero-x-circle"
        tone={if @error_traces > 0, do: "error", else: "success"}
        href={~p"/observability?#{%{tab: "traces", q: "in:otel_trace_summaries time:last_24h status_code:2 sort:timestamp:desc limit:100"}}"}
      />
      <.obs_stat
        title="Error Rate"
        value={"#{format_pct(@error_rate)}%"}
        icon="hero-trending-up"
        tone={if @error_rate > 1.0, do: "error", else: "success"}
        href={~p"/observability?#{%{tab: "traces", q: "in:otel_trace_summaries time:last_24h status_code:2 sort:timestamp:desc limit:100"}}"}
      />
      <.obs_stat
        title="Avg Duration"
        value={format_duration_ms(@avg_duration_ms)}
        subtitle={if @sample_size > 0, do: "sample (#{@sample_size})", else: "sample"}
        icon="hero-chart-bar"
        tone="info"
        href={~p"/observability?#{%{tab: "traces", q: "in:otel_trace_summaries time:last_24h sort:duration_ms:desc limit:100"}}"}
      />
      <.obs_stat
        title="P95 Duration"
        value={format_duration_ms(@p95_duration_ms)}
        subtitle={if @services_count > 0, do: "#{@services_count} services", else: "sample"}
        icon="hero-bolt"
        tone="warning"
        href={~p"/observability?#{%{tab: "traces", q: "in:otel_trace_summaries time:last_24h sort:duration_ms:desc limit:100"}}"}
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
      <.obs_stat
        title="Total Metrics"
        value={format_compact_int(@total)}
        icon="hero-chart-bar"
        href={~p"/observability?#{%{tab: "metrics", q: "in:otel_metrics time:last_24h sort:timestamp:desc limit:100"}}"}
      />
      <.obs_stat
        title="Slow Spans"
        value={format_compact_int(@slow_spans)}
        icon="hero-bolt"
        tone={if @slow_spans > 0, do: "warning", else: "success"}
        href={~p"/observability?#{%{tab: "metrics", q: "in:otel_metrics time:last_24h is_slow:true sort:duration_ms:desc limit:100"}}"}
      />
      <.obs_stat
        title="Errors"
        value={format_compact_int(@error_spans)}
        icon="hero-exclamation-triangle"
        tone={if @error_spans > 0, do: "error", else: "success"}
        href={~p"/observability?#{%{tab: "metrics", q: "in:otel_metrics time:last_24h http_status_code:5% sort:timestamp:desc limit:100"}}"}
      />
      <.obs_stat
        title="Error Rate"
        value={"#{format_pct(@error_rate)}%"}
        icon="hero-trending-up"
        tone={if @error_rate > 1.0, do: "error", else: "success"}
        href={~p"/observability?#{%{tab: "metrics", q: "in:otel_metrics time:last_24h http_status_code:5% sort:timestamp:desc limit:100"}}"}
      />
      <.obs_stat
        title="Avg Duration"
        value={format_duration_ms(@avg_duration_ms)}
        subtitle={if @sample_size > 0, do: "sample (#{@sample_size})", else: "sample"}
        icon="hero-clock"
        tone="info"
        href={~p"/observability?#{%{tab: "metrics", q: "in:otel_metrics time:last_24h sort:duration_ms:desc limit:100"}}"}
      />
      <.obs_stat
        title="P95 Duration"
        value={format_duration_ms(@p95_duration_ms)}
        subtitle="sample"
        icon="hero-chart-bar"
        tone="neutral"
        href={~p"/observability?#{%{tab: "metrics", q: "in:otel_metrics time:last_24h is_slow:true sort:duration_ms:desc limit:100"}}"}
      />
    </div>
    """
  end

  attr :title, :string, required: true
  attr :value, :string, required: true
  attr :subtitle, :string, default: nil
  attr :icon, :string, required: true
  attr :tone, :string, default: "neutral", values: ~w(neutral success warning error info)
  attr :href, :string, default: nil

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
    <%= if @href do %>
      <.link
        href={@href}
        class="rounded-xl border border-base-200 bg-base-100 shadow-sm p-3 block hover:border-primary/50 hover:shadow-md transition-all cursor-pointer"
      >
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
      </.link>
    <% else %>
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
    <% end %>
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
  attr :sparklines, :map, default: %{}

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
              Trend
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-base-content/70 bg-base-200/60 w-20 text-right">
              Logs
            </th>
          </tr>
        </thead>
        <tbody>
          <tr :if={@metrics == []}>
            <td colspan="7" class="text-sm text-base-content/60 py-8 text-center">
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
                <.metric_viz metric={metric} sparklines={@sparklines} />
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

  attr :metric, :map, required: true
  attr :sparklines, :map, default: %{}

  defp metric_viz(assigns) do
    metric_type = normalize_string(Map.get(assigns.metric, "metric_type")) || ""
    metric_name = Map.get(assigns.metric, "metric_name")

    # Get sparkline data for this metric
    sparkline_data = Map.get(assigns.sparklines, metric_name, [])

    assigns =
      assigns
      |> assign(:metric_type, metric_type)
      |> assign(:sparkline_data, sparkline_data)

    ~H"""
    <%= case @metric_type do %>
      <% "histogram" -> %>
        <.histogram_viz metric={@metric} />
      <% type when type in ["gauge", "counter"] -> %>
        <%= if length(@sparkline_data) >= 3 do %>
          <.sparkline data={@sparkline_data} />
        <% else %>
          <span class="text-base-content/30">—</span>
        <% end %>
      <% "span" -> %>
        <.span_duration_viz metric={@metric} />
      <% _ -> %>
        <span class="text-base-content/30">—</span>
    <% end %>
    """
  end

  attr :data, :list, required: true

  defp sparkline(assigns) do
    data = assigns.data
    min_val = Enum.min(data)
    max_val = Enum.max(data)
    range = max_val - min_val

    # Normalize to 0-100 range for SVG, with some padding
    points =
      data
      |> Enum.with_index()
      |> Enum.map(fn {val, idx} ->
        x = idx / max(length(data) - 1, 1) * 100
        y = if range > 0, do: 100 - (val - min_val) / range * 80 - 10, else: 50
        "#{Float.round(x, 1)},#{Float.round(y, 1)}"
      end)
      |> Enum.join(" ")

    # Determine trend color based on first vs last value
    first_val = List.first(data) || 0
    last_val = List.last(data) || 0
    trend_color = if last_val > first_val * 1.1, do: "stroke-warning", else: "stroke-info"

    assigns =
      assigns
      |> assign(:points, points)
      |> assign(:trend_color, trend_color)

    ~H"""
    <svg viewBox="0 0 100 100" class="w-20 h-6" preserveAspectRatio="none">
      <polyline
        points={@points}
        fill="none"
        class={[@trend_color, "opacity-70"]}
        stroke-width="2"
        stroke-linecap="round"
        stroke-linejoin="round"
      />
    </svg>
    """
  end

  attr :metric, :map, required: true

  # Duration visualization for span-type metrics
  defp span_duration_viz(assigns) do
    duration_ms = extract_duration_ms(assigns.metric)
    is_slow = Map.get(assigns.metric, "is_slow") == true

    # If no duration, show dash
    if is_nil(duration_ms) or duration_ms <= 0 do
      ~H"""
      <span class="text-base-content/30">—</span>
      """
    else
      # Scale 0-1500ms to 0-100% (threshold at 500ms = 33%)
      threshold_ms = 500
      max_display_ms = threshold_ms * 3
      pct = min(duration_ms / max_display_ms * 100, 100)
      threshold_pct = threshold_ms / max_display_ms * 100

      # Color based on duration relative to threshold
      bar_color =
        cond do
          duration_ms <= threshold_ms * 0.5 -> "bg-success"
          duration_ms <= threshold_ms -> "bg-success/70"
          duration_ms <= threshold_ms * 1.5 -> "bg-warning"
          duration_ms <= threshold_ms * 2 -> "bg-warning/80"
          true -> "bg-error"
        end

      assigns =
        assigns
        |> assign(:pct, pct)
        |> assign(:threshold_pct, threshold_pct)
        |> assign(:bar_color, bar_color)
        |> assign(:is_slow, is_slow)
        |> assign(:duration_ms, duration_ms)

      ~H"""
      <div class="flex items-center gap-2 min-w-[5rem]" title={"#{Float.round(@duration_ms * 1.0, 1)}ms"}>
        <div class="relative h-2 w-16 bg-base-200/60 rounded-sm overflow-visible">
          <div class={"h-full rounded-sm #{@bar_color}"} style={"width: #{@pct}%"} />
          <div
            class="absolute top-0 h-full w-px bg-base-content/40"
            style={"left: #{@threshold_pct}%"}
            title="500ms threshold"
          />
        </div>
        <span :if={@is_slow} class="text-[10px] text-warning font-semibold">SLOW</span>
      </div>
      """
    end
  end

  attr :metric, :map, required: true

  defp histogram_viz(assigns) do
    # For histograms with duration data, show a duration-based gauge bar
    # Most OTEL histograms are duration distributions
    duration_ms = extract_duration_value(assigns.metric)

    # Use reasonable bounds for duration visualization (0-1000ms as typical range)
    # Anything over 1s will show as full bar
    pct =
      cond do
        not is_number(duration_ms) or duration_ms <= 0 -> 0
        duration_ms >= 1000 -> 100
        true -> duration_ms / 10  # 0-1000ms maps to 0-100%
      end

    # Color based on duration
    bar_color =
      cond do
        not is_number(duration_ms) or duration_ms <= 0 -> "bg-base-content/20"
        duration_ms >= 500 -> "bg-error"
        duration_ms >= 100 -> "bg-warning"
        true -> "bg-success"
      end

    assigns =
      assigns
      |> assign(:pct, pct)
      |> assign(:bar_color, bar_color)
      |> assign(:duration_ms, duration_ms)

    ~H"""
    <div class="flex items-center gap-2 w-20" title={if is_number(@duration_ms) and @duration_ms > 0, do: "#{Float.round(@duration_ms * 1.0, 1)}ms", else: "no duration"}>
      <div class="flex-1 h-1.5 bg-base-200 rounded-full overflow-hidden">
        <div class={[@bar_color, "h-full rounded-full transition-all"]} style={"width: #{@pct}%"}></div>
      </div>
    </div>
    """
  end

  defp extract_histogram_count(metric) do
    cond do
      is_number(metric["count"]) -> trunc(metric["count"])
      is_binary(metric["count"]) -> trunc(extract_number(metric["count"]) || 0)
      is_number(metric["bucket_count"]) -> trunc(metric["bucket_count"])
      true -> 0
    end
  end

  defp extract_duration_ms(metric) do
    cond do
      is_number(metric["duration_ms"]) -> metric["duration_ms"]
      is_binary(metric["duration_ms"]) -> extract_number(metric["duration_ms"])
      is_number(metric["duration_seconds"]) -> metric["duration_seconds"] * 1000
      is_binary(metric["duration_seconds"]) ->
        case extract_number(metric["duration_seconds"]) do
          n when is_number(n) -> n * 1000
          _ -> nil
        end
      true -> nil
    end
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
    # Get metric name from multiple possible fields
    metric_name = get_metric_name(metric)
    metric_type = normalize_string(Map.get(metric, "metric_type"))
    # NEW: Check for explicit unit field from backend
    unit = normalize_string(Map.get(metric, "unit"))

    # PRIORITY 0: Histograms are distributions - show sample count, not a single value
    # Trying to show one number for a histogram is misleading
    if metric_type == "histogram" do
      format_histogram_value(metric)
    else
      # PRIORITY 0.5: If we have an explicit unit field, use it directly
      # This is the most reliable way to format metrics correctly
      cond do
        unit != nil ->
          format_with_explicit_unit(metric, unit)

        is_bytes_metric?(metric_name) ->
          format_bytes_value(metric)

        is_count_metric?(metric_name) or is_stats_metric?(metric_name) ->
          format_count_value(metric)

        # PRIORITY 2: Only format as duration if:
        # - Metric name explicitly suggests duration/latency/time, OR
        # - It's a span type (all spans should show duration if available)
        is_duration_metric?(metric_name) and has_duration_field?(metric) ->
          format_duration_value(metric)

        # Spans should always show duration_ms - that's their primary metric
        metric_type == "span" and has_duration_field?(metric) ->
          format_duration_value(metric)

        is_actual_timing_span?(metric) and has_duration_field?(metric) ->
          format_duration_value(metric)

        # PRIORITY 3: Raw value fallback - just show the number, no units
        has_any_value?(metric) ->
          format_raw_value(metric, metric_type)

        true ->
          "—"
      end
    end
  end

  # Format metric value using explicit unit field from backend
  defp format_with_explicit_unit(metric, unit) do
    value = extract_primary_value(metric)

    if is_nil(value) do
      "—"
    else
      case unit do
        # Duration units
        "ms" -> format_ms_value(value)
        "s" -> format_seconds_value(value)
        "ns" -> format_ns_value(value)
        "us" -> format_us_value(value)
        # Byte units
        "bytes" -> format_bytes_from_value(value)
        "By" -> format_bytes_from_value(value)
        "kb" -> format_bytes_from_value(value * 1024)
        "KiB" -> format_bytes_from_value(value * 1024)
        "mb" -> format_bytes_from_value(value * 1024 * 1024)
        "MiB" -> format_bytes_from_value(value * 1024 * 1024)
        "gb" -> format_bytes_from_value(value * 1024 * 1024 * 1024)
        "GiB" -> format_bytes_from_value(value * 1024 * 1024 * 1024)
        # Count/dimensionless
        "1" -> format_count_from_value(value)
        "{request}" -> format_count_from_value(value)
        "{connection}" -> format_count_from_value(value)
        "{thread}" -> format_count_from_value(value)
        "{goroutine}" -> format_count_from_value(value)
        # Percentage
        "%" -> "#{Float.round(value * 1.0, 1)}%"
        # Default: show value with unit suffix
        _ -> "#{format_compact_value(value)} #{unit}"
      end
    end
  end

  defp extract_primary_value(metric) do
    cond do
      is_number(metric["value"]) -> metric["value"]
      is_binary(metric["value"]) -> extract_number(metric["value"])
      is_number(metric["duration_ms"]) -> metric["duration_ms"]
      is_binary(metric["duration_ms"]) -> extract_number(metric["duration_ms"])
      is_number(metric["sum"]) -> metric["sum"]
      is_binary(metric["sum"]) -> extract_number(metric["sum"])
      is_number(metric["count"]) -> metric["count"]
      is_binary(metric["count"]) -> extract_number(metric["count"])
      true -> nil
    end
  end

  defp format_ms_value(ms) when is_number(ms) do
    cond do
      ms >= 60_000 -> "#{Float.round(ms / 60_000, 1)}m"
      ms >= 1000 -> "#{Float.round(ms / 1000, 2)}s"
      true -> "#{Float.round(ms * 1.0, 1)}ms"
    end
  end

  defp format_seconds_value(s) when is_number(s) do
    ms = s * 1000
    format_ms_value(ms)
  end

  defp format_ns_value(ns) when is_number(ns) do
    ms = ns / 1_000_000
    format_ms_value(ms)
  end

  defp format_us_value(us) when is_number(us) do
    ms = us / 1000
    format_ms_value(ms)
  end

  defp format_bytes_from_value(bytes) when is_number(bytes) do
    cond do
      bytes >= 1_099_511_627_776 -> "#{Float.round(bytes / 1_099_511_627_776 * 1.0, 1)} TB"
      bytes >= 1_073_741_824 -> "#{Float.round(bytes / 1_073_741_824 * 1.0, 1)} GB"
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576 * 1.0, 1)} MB"
      bytes >= 1024 -> "#{Float.round(bytes / 1024 * 1.0, 1)} KB"
      true -> "#{trunc(bytes)} B"
    end
  end

  defp format_count_from_value(count) when is_number(count) do
    cond do
      count >= 1_000_000 -> "#{Float.round(count / 1_000_000 * 1.0, 1)}M"
      count >= 1_000 -> "#{Float.round(count / 1_000 * 1.0, 1)}k"
      is_float(count) -> "#{trunc(count)}"
      true -> "#{count}"
    end
  end

  defp format_compact_value(value) when is_number(value) do
    cond do
      value >= 1_000_000 -> "#{Float.round(value / 1_000_000 * 1.0, 1)}M"
      value >= 1_000 -> "#{Float.round(value / 1_000 * 1.0, 1)}k"
      is_float(value) -> "#{Float.round(value, 2)}"
      true -> "#{value}"
    end
  end

  # Histograms are distributions - show duration if available, otherwise sample count
  defp format_histogram_value(metric) do
    # For gRPC/HTTP histograms, duration_ms is the most meaningful value
    duration_ms = extract_duration_value(metric)
    unit = normalize_string(Map.get(metric, "unit"))

    cond do
      # If we have a duration value, show it
      is_number(duration_ms) and duration_ms > 0 ->
        format_duration_ms(duration_ms)

      # If we have an explicit unit with a value, use that
      unit != nil ->
        value = extract_primary_value(metric)
        if is_number(value) and value > 0 do
          format_with_explicit_unit(metric, unit)
        else
          format_histogram_count_or_dash(metric)
        end

      # Fallback to sample count
      true ->
        format_histogram_count_or_dash(metric)
    end
  end

  defp format_histogram_count_or_dash(metric) do
    count = extract_histogram_count(metric)

    if count > 0 do
      "#{format_number(count)} samples"
    else
      "—"
    end
  end

  defp extract_duration_value(metric) do
    cond do
      is_number(metric["duration_ms"]) -> metric["duration_ms"]
      is_binary(metric["duration_ms"]) -> extract_number(metric["duration_ms"])
      is_number(metric["duration_seconds"]) -> metric["duration_seconds"] * 1000
      is_binary(metric["duration_seconds"]) ->
        case extract_number(metric["duration_seconds"]) do
          nil -> nil
          val -> val * 1000
        end
      true -> nil
    end
  end

  defp format_duration_ms(ms) when is_number(ms) do
    cond do
      ms >= 60_000 -> "#{Float.round(ms / 60_000, 1)}m"
      ms >= 1000 -> "#{Float.round(ms / 1000, 2)}s"
      ms >= 1 -> "#{Float.round(ms * 1.0, 1)}ms"
      ms > 0 -> "#{Float.round(ms * 1000, 0)}µs"
      true -> "0ms"
    end
  end

  defp format_number(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000 * 1.0, 1)}M"
  defp format_number(n) when n >= 1_000, do: "#{Float.round(n / 1_000 * 1.0, 1)}k"
  defp format_number(n) when is_float(n), do: "#{trunc(n)}"
  defp format_number(n), do: "#{n}"

  defp get_metric_name(metric) do
    # Check multiple fields where the metric name might be stored
    normalize_string(Map.get(metric, "span_name")) ||
      normalize_string(Map.get(metric, "metric_name")) ||
      normalize_string(Map.get(metric, "name")) ||
      ""
  end

  defp normalize_string(nil), do: nil
  defp normalize_string(""), do: nil
  defp normalize_string(s) when is_binary(s), do: String.trim(s)
  defp normalize_string(_), do: nil

  defp is_bytes_metric?(nil), do: false
  defp is_bytes_metric?(""), do: false

  defp is_bytes_metric?(name) when is_binary(name) do
    downcased = String.downcase(name)

    String.contains?(downcased, "bytes") or
      String.contains?(downcased, "memory") or
      String.contains?(downcased, "heap") or
      String.contains?(downcased, "alloc")
  end

  defp is_count_metric?(nil), do: false
  defp is_count_metric?(""), do: false

  defp is_count_metric?(name) when is_binary(name) do
    downcased = String.downcase(name)

    String.ends_with?(downcased, "_count") or
      String.ends_with?(downcased, "_total") or
      String.contains?(downcased, "goroutines") or
      String.contains?(downcased, "threads")
  end

  # Stats/counter-like metrics (processed, skipped, etc.)
  defp is_stats_metric?(nil), do: false
  defp is_stats_metric?(""), do: false

  defp is_stats_metric?(name) when is_binary(name) do
    downcased = String.downcase(name)

    String.contains?(downcased, "_stats_") or
      String.contains?(downcased, "processed") or
      String.contains?(downcased, "skipped") or
      String.contains?(downcased, "inferred") or
      String.contains?(downcased, "canonical") or
      String.contains?(downcased, "requests") or
      String.contains?(downcased, "connections") or
      String.contains?(downcased, "errors") or
      String.contains?(downcased, "failures")
  end

  # Check if metric name explicitly suggests it's a duration/timing metric
  defp is_duration_metric?(nil), do: false
  defp is_duration_metric?(""), do: false

  defp is_duration_metric?(name) when is_binary(name) do
    downcased = String.downcase(name)

    String.contains?(downcased, "duration") or
      String.contains?(downcased, "latency") or
      String.contains?(downcased, "_time") or
      String.ends_with?(downcased, "time") or
      String.contains?(downcased, "elapsed") or
      String.contains?(downcased, "response_ms") or
      String.contains?(downcased, "request_ms")
  end

  # Check if this is an actual timing span with real HTTP/gRPC context (not empty strings)
  defp is_actual_timing_span?(metric) do
    has_http =
      is_non_empty_string?(metric["http_route"]) or
        is_non_empty_string?(metric["http_method"])

    has_grpc =
      is_non_empty_string?(metric["grpc_service"]) or
        is_non_empty_string?(metric["grpc_method"])

    # Also check for span type
    is_span = normalize_string(Map.get(metric, "metric_type")) == "span"

    (has_http or has_grpc) and is_span
  end

  defp is_non_empty_string?(nil), do: false
  defp is_non_empty_string?(""), do: false
  defp is_non_empty_string?(s) when is_binary(s), do: String.trim(s) != ""
  defp is_non_empty_string?(_), do: false

  defp has_duration_field?(metric) do
    is_number(metric["duration_ms"]) or is_binary(metric["duration_ms"]) or
      is_number(metric["duration_seconds"]) or is_binary(metric["duration_seconds"])
  end

  defp has_any_value?(metric) do
    is_number(metric["value"]) or is_binary(metric["value"]) or
      is_number(metric["sum"]) or is_binary(metric["sum"]) or
      is_number(metric["count"]) or is_binary(metric["count"]) or
      is_number(metric["duration_ms"]) or is_binary(metric["duration_ms"])
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
    # Extract value from any available field (OTEL often puts values in unexpected places)
    bytes =
      cond do
        is_number(metric["value"]) -> metric["value"]
        is_binary(metric["value"]) -> extract_number(metric["value"]) || 0
        is_number(metric["sum"]) -> metric["sum"]
        is_binary(metric["sum"]) -> extract_number(metric["sum"]) || 0
        is_number(metric["duration_ms"]) -> metric["duration_ms"]
        is_binary(metric["duration_ms"]) -> extract_number(metric["duration_ms"]) || 0
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

  defp format_count_value(metric) do
    count =
      cond do
        is_number(metric["value"]) -> metric["value"]
        is_binary(metric["value"]) -> extract_number(metric["value"]) || 0
        is_number(metric["sum"]) -> metric["sum"]
        is_binary(metric["sum"]) -> extract_number(metric["sum"]) || 0
        is_number(metric["count"]) -> metric["count"]
        is_binary(metric["count"]) -> extract_number(metric["count"]) || 0
        is_number(metric["duration_ms"]) -> metric["duration_ms"]
        is_binary(metric["duration_ms"]) -> extract_number(metric["duration_ms"]) || 0
        true -> 0
      end

    cond do
      count >= 1_000_000 -> "#{Float.round(count / 1_000_000 * 1.0, 1)}M"
      count >= 1_000 -> "#{Float.round(count / 1_000 * 1.0, 1)}k"
      is_float(count) -> "#{Float.round(count, 0) |> trunc()}"
      true -> "#{trunc(count)}"
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
        is_number(metric["duration_ms"]) -> metric["duration_ms"]
        is_binary(metric["duration_ms"]) -> extract_number(metric["duration_ms"])
        true -> nil
      end

    if is_number(value) do
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

  defp load_summary(_srql_module, current_query) do
    # For unfiltered queries (default view), use the fast continuous aggregate
    if is_nil(current_query) or current_query == "" or
         String.starts_with?(String.trim(current_query || ""), "in:logs") do
      load_summary_from_cagg()
    else
      # For filtered queries, fall back to SRQL stats (slower but accurate)
      load_summary_from_srql(current_query)
    end
  end

  # Load log summary from continuous aggregate (fast path)
  defp load_summary_from_cagg do
    srql_module = srql_module()

    case srql_module.query("in:logs_hourly_stats time:last_24h") do
      {:ok, %{"results" => rows}} when is_list(rows) and length(rows) > 0 ->
        aggregate_logs_summary(rows)

      {:ok, _} ->
        %{total: 0, fatal: 0, error: 0, warning: 0, info: 0, debug: 0}

      {:error, reason} ->
        require Logger
        Logger.warning("Failed to load logs summary from cagg: #{inspect(reason)}")
        %{total: 0, fatal: 0, error: 0, warning: 0, info: 0, debug: 0}
    end
  rescue
    e ->
      require Logger
      Logger.warning("Failed to load logs summary from cagg: #{inspect(e)}")
      %{total: 0, fatal: 0, error: 0, warning: 0, info: 0, debug: 0}
  end

  defp aggregate_logs_summary(rows) when is_list(rows) do
    initial = %{total: 0, fatal: 0, error: 0, warning: 0, info: 0, debug: 0}

    rows
    |> Enum.filter(&is_map/1)
    |> Enum.reduce(initial, fn row, acc ->
      %{
        total: acc.total + to_int(row["total_count"]),
        fatal: acc.fatal + to_int(row["fatal_count"]),
        error: acc.error + to_int(row["error_count"]),
        warning: acc.warning + to_int(row["warning_count"]),
        info: acc.info + to_int(row["info_count"]),
        debug: acc.debug + to_int(row["debug_count"])
      }
    end)
  end

  # Load log summary from SRQL stats (slow path for filtered queries)
  defp load_summary_from_srql(current_query) do
    srql_module = srql_module()
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
        ~s|stats:"count() as total, sum(if(status_code = 2, 1, 0)) as error_traces, sum(if(duration_ms > 100, 1, 0)) as slow_traces"|

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

  # Load duration stats from the continuous aggregation for full 24h data
  # Only uses 'span' metric_type since histograms/gauges have invalid duration data
  defp load_duration_stats_from_cagg do
    srql_module = srql_module()

    # Query otel_metrics_hourly_stats filtered to span metric_type only
    case srql_module.query("in:otel_metrics_hourly_stats time:last_24h metric_type:span") do
      {:ok, %{"results" => rows}} when is_list(rows) and length(rows) > 0 ->
        aggregate_duration_stats(rows)

      {:ok, _} ->
        %{avg_duration_ms: 0.0, p95_duration_ms: 0.0, sample_size: 0}

      {:error, reason} ->
        require Logger
        Logger.warning("Failed to load duration stats from cagg: #{inspect(reason)}")
        %{avg_duration_ms: 0.0, p95_duration_ms: 0.0, sample_size: 0}
    end
  rescue
    e ->
      require Logger
      Logger.warning("Failed to load duration stats from cagg: #{inspect(e)}")
      %{avg_duration_ms: 0.0, p95_duration_ms: 0.0, sample_size: 0}
  end

  defp aggregate_duration_stats(rows) when is_list(rows) do
    initial = %{total_count: 0, weighted_duration: 0.0, p95_max: 0.0}

    agg =
      rows
      |> Enum.filter(&is_map/1)
      |> Enum.reduce(initial, fn row, acc ->
        total = to_int(row["total_count"])
        avg_ms = to_float_val(row["avg_duration_ms"])
        p95_ms = to_float_val(row["p95_duration_ms"])

        if total > 0 do
          %{
            total_count: acc.total_count + total,
            weighted_duration: acc.weighted_duration + avg_ms * total,
            p95_max: max(acc.p95_max, p95_ms)
          }
        else
          acc
        end
      end)

    avg_duration =
      if agg.total_count > 0 do
        agg.weighted_duration / agg.total_count
      else
        0.0
      end

    %{
      avg_duration_ms: avg_duration,
      p95_duration_ms: agg.p95_max,
      sample_size: agg.total_count
    }
  end

  defp to_float_val(nil), do: 0.0
  defp to_float_val(%Decimal{} = d), do: Decimal.to_float(d)
  defp to_float_val(v) when is_float(v), do: v
  defp to_float_val(v) when is_integer(v), do: v * 1.0

  defp to_float_val(v) when is_binary(v) do
    case Float.parse(v) do
      {n, _} -> n
      :error -> 0.0
    end
  end

  defp to_float_val(_), do: 0.0

  # Load sparkline data for gauge/counter metrics via SRQL downsample
  # Returns a map of metric_name -> list of values for sparkline visualization
  # Uses 5-minute buckets over the last 2 hours (24 data points)
  defp load_sparklines(metrics) when is_list(metrics) do
    # Extract unique metric names for gauges and counters
    metric_names =
      metrics
      |> Enum.filter(fn m ->
        type = normalize_string(Map.get(m, "metric_type"))
        type in ["gauge", "counter"]
      end)
      |> Enum.map(fn m -> Map.get(m, "metric_name") end)
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    if metric_names == [] do
      %{}
    else
      load_sparklines_via_srql(metric_names)
    end
  end

  defp load_sparklines(_), do: %{}

  # Query SRQL for sparkline data using downsample
  defp load_sparklines_via_srql(metric_names) when is_list(metric_names) do
    srql_module = srql_module()

    # Build filter for metric names - quote special characters and join with comma
    metric_filter =
      metric_names
      |> Enum.map(&quote_srql_filter_value/1)
      |> Enum.join(",")

    # Query: 2 hour time range, 5 minute buckets, grouped by metric_name, avg aggregation
    query = "in:otel_metrics time:last_2h metric_type:(gauge,counter) metric_name:(#{metric_filter}) bucket:5m series:metric_name agg:avg"

    case srql_module.query(query) do
      {:ok, %{"results" => rows}} when is_list(rows) ->
        # Group results by series (metric_name) and extract values
        rows
        |> Enum.filter(&is_map/1)
        |> Enum.group_by(
          fn row -> row["series"] end,
          fn row -> to_float_val(row["value"]) end
        )
        |> Enum.reject(fn {k, _v} -> is_nil(k) or k == "" end)
        |> Map.new()

      {:ok, _} ->
        %{}

      {:error, reason} ->
        require Logger
        Logger.warning("Failed to load sparklines via SRQL: #{inspect(reason)}")
        %{}
    end
  rescue
    e ->
      require Logger
      Logger.warning("Failed to load sparklines: #{inspect(e)}")
      %{}
  end

  # Quote SRQL filter values that contain special characters
  defp quote_srql_filter_value(value) when is_binary(value) do
    # If value contains special chars, wrap in quotes and escape inner quotes
    if String.contains?(value, [" ", ",", ":", "(", ")", "\"", "'"]) do
      "\"" <> escape_srql_value(value) <> "\""
    else
      value
    end
  end

  defp quote_srql_filter_value(value), do: to_string(value)

  defp compute_error_rate(total, errors) when is_integer(total) and total > 0 do
    Float.round(errors / total * 100.0, 1)
  end

  defp compute_error_rate(_total, _errors), do: 0.0

  defp compute_trace_latency(rows) do
    # For trace summaries, don't filter by is_timing_metric since traces are inherently timing data
    duration_stats = compute_trace_duration_stats(rows)
    services = unique_services_from_traces(rows)
    Map.put(duration_stats, :service_count, map_size(services))
  end

  # Compute duration stats specifically for trace summaries (no HTTP/gRPC filter needed)
  defp compute_trace_duration_stats(rows) when is_list(rows) do
    durations =
      rows
      |> Enum.filter(&is_map/1)
      |> Enum.map(fn row -> extract_number(Map.get(row, "duration_ms")) end)
      |> Enum.filter(&is_number/1)
      |> Enum.filter(fn ms -> ms >= 0 and ms < 3_600_000 end)

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

  defp compute_trace_duration_stats(_), do: %{avg_duration_ms: 0.0, p95_duration_ms: 0.0, sample_size: 0}

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
