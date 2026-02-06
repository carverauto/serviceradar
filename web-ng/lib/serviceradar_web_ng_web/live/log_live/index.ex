defmodule ServiceRadarWebNGWeb.LogLive.Index do
  use ServiceRadarWebNGWeb, :live_view

  import Ecto.Query
  import ServiceRadarWebNGWeb.UIComponents

  alias Phoenix.LiveView.JS
  alias ServiceRadar.Events.PubSub, as: EventsPubSub
  alias ServiceRadar.Observability.FlowPubSub
  alias ServiceRadar.Observability.LogPubSub
  alias ServiceRadarWebNG.Repo
  alias ServiceRadarWebNGWeb.SRQL.Page, as: SRQLPage
  alias ServiceRadarWebNGWeb.Stats

  require Logger

  @default_limit 20
  @max_limit 100
  @default_stats_window "last_24h"
  @default_events_limit 20
  @max_events_limit 100
  @default_alerts_limit 25
  @max_alerts_limit 200
  @default_netflow_limit 50
  @max_netflow_limit 200

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(ServiceRadar.PubSub, LogPubSub.topic())
      Phoenix.PubSub.subscribe(ServiceRadar.PubSub, EventsPubSub.topic())
      Phoenix.PubSub.subscribe(ServiceRadar.PubSub, FlowPubSub.topic())
    end

    {:ok,
     socket
     |> assign(:page_title, "Observability")
     |> assign(:active_tab, "logs")
     |> assign(:logs, [])
     |> assign(:traces, [])
     |> assign(:metrics, [])
     |> assign(:events, [])
     |> assign(:alerts, [])
     |> assign(:netflows, [])
     |> assign(:selected_netflow, nil)
     |> assign(:netflow_top_talkers, [])
     |> assign(:netflow_top_ports, [])
     |> assign(:sparklines, %{})
     |> assign(:summary, %{total: 0, fatal: 0, error: 0, warning: 0, info: 0, debug: 0})
     |> assign(:event_summary, empty_event_summary())
     |> assign(:alert_summary, empty_alert_summary())
     |> assign(:netflow_summary, empty_netflow_summary())
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
     |> stream_configure(:logs, dom_id: &log_dom_id/1)
     |> stream_configure(:events, dom_id: &event_dom_id/1)
     |> stream(:logs, [])
     |> stream(:events, [])
     |> SRQLPage.init("logs", default_limit: @default_limit)}
  end

  @impl true
  def handle_params(params, uri, socket) do
    path = uri |> to_string() |> URI.parse() |> Map.get(:path)
    tab = normalize_tab(Map.get(params, "tab"), path)
    {entity, list_key} = tab_entity(tab)
    {default_limit, max_limit} = tab_limits(tab)

    socket =
      socket
      |> assign(:active_tab, tab)
      |> assign(:logs, [])
      |> assign(:traces, [])
      |> assign(:metrics, [])
      |> assign(:events, [])
      |> assign(:alerts, [])
      |> assign(:netflows, [])
      |> assign(:selected_netflow, nil)
      |> assign(:netflow_top_talkers, [])
      |> assign(:netflow_top_ports, [])
      |> ensure_srql_entity(entity, default_limit)
      |> SRQLPage.load_list(params, uri, list_key,
        default_limit: default_limit,
        max_limit: max_limit
      )

    socket =
      socket
      |> apply_tab_assigns(tab, srql_module())
      |> stream_active_tab(tab)

    {:noreply, socket}
  end

  @impl true
  def handle_event("srql_change", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_change", params)}
  end

  def handle_event("netflow_open", %{"idx" => idx}, socket) do
    selected =
      case Integer.parse(to_string(idx)) do
        {i, _} when i >= 0 -> Enum.at(socket.assigns.netflows, i)
        _ -> nil
      end

    {:noreply, assign(socket, :selected_netflow, selected)}
  end

  def handle_event("netflow_close", _params, socket) do
    {:noreply, assign(socket, :selected_netflow, nil)}
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
  def handle_info({:logs_ingested, _event}, socket) do
    {:noreply, maybe_refresh_tab(socket, "logs")}
  end

  @impl true
  def handle_info({:ocsf_event, _event}, socket) do
    {:noreply, maybe_refresh_tab(socket, "events")}
  end

  @impl true
  def handle_info({:flows_ingested, _event}, socket) do
    {:noreply, maybe_refresh_tab(socket, "netflows")}
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
          <.event_summary :if={@active_tab == "events"} summary={@event_summary} />
          <.alert_summary :if={@active_tab == "alerts"} summary={@alert_summary} />
          <.traces_summary
            :if={@active_tab == "traces"}
            stats={@trace_stats}
            latency={@trace_latency}
          />
          <.metrics_summary :if={@active_tab == "metrics"} stats={@metrics_stats} />
          <.netflow_summary
            :if={@active_tab == "netflows"}
            summary={@netflow_summary}
            top_talkers={@netflow_top_talkers}
            top_ports={@netflow_top_ports}
            base_path={Map.get(@srql, :page_path) || "/observability"}
            query={Map.get(@srql, :query, "")}
            limit={@limit}
          />

          <.ui_panel>
            <:header>
              <div class="min-w-0">
                <div class="text-sm font-semibold">{panel_title(@active_tab)}</div>
                <div class="text-xs text-base-content/70">
                  {panel_subtitle(@active_tab)}
                </div>
              </div>

              <.log_source_filters :if={@active_tab == "logs"} srql={@srql} limit={@limit} />
              <.netflow_presets :if={@active_tab == "netflows"} srql={@srql} limit={@limit} />
            </:header>

            <.logs_table
              :if={@active_tab == "logs"}
              id="logs"
              logs={@streams.logs}
              count={length(@logs)}
            />
            <.traces_table :if={@active_tab == "traces"} id="traces" traces={@traces} />
            <.metrics_table
              :if={@active_tab == "metrics"}
              id="metrics"
              metrics={@metrics}
              sparklines={@sparklines}
            />
            <.events_table
              :if={@active_tab == "events"}
              id="events"
              events={@streams.events}
              count={length(@events)}
            />
            <.alerts_table :if={@active_tab == "alerts"} id="alerts" alerts={@alerts} />
            <.netflows_table
              :if={@active_tab == "netflows"}
              flows={@netflows}
              base_path={Map.get(@srql, :page_path) || "/observability"}
              query={Map.get(@srql, :query, "")}
              limit={@limit}
            />

            <div class="mt-4 pt-4 border-t border-base-200">
              <.ui_pagination
                prev_cursor={Map.get(@pagination, "prev_cursor")}
                next_cursor={Map.get(@pagination, "next_cursor")}
                base_path={Map.get(@srql, :page_path) || "/observability"}
                query={Map.get(@srql, :query, "")}
                limit={@limit}
                result_count={
                  panel_result_count(
                    @active_tab,
                    @logs,
                    @traces,
                    @metrics,
                    @events,
                    @alerts,
                    @netflows
                  )
                }
                extra_params={%{tab: @active_tab}}
              />
            </div>
          </.ui_panel>

          <.netflow_details_modal
            :if={@active_tab == "netflows" and is_map(@selected_netflow)}
            flow={@selected_netflow}
            base_path={Map.get(@srql, :page_path) || "/observability"}
            query={Map.get(@srql, :query, "")}
            limit={@limit}
          />
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr(:summary, :map, required: true)

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
            {format_compact_int(@total)}
            <span class="text-xs font-normal text-base-content/60">total (24h)</span>
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

  attr(:label, :string, required: true)
  attr(:count, :integer, required: true)
  attr(:total, :integer, required: true)
  attr(:color, :string, required: true)
  attr(:level, :string, required: true)

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

  attr(:summary, :map, required: true)

  defp event_summary(assigns) do
    total = Map.get(assigns.summary, :total, 0)
    critical = Map.get(assigns.summary, :critical, 0)
    high = Map.get(assigns.summary, :high, 0)
    medium = Map.get(assigns.summary, :medium, 0)
    low = Map.get(assigns.summary, :low, 0)

    assigns =
      assigns
      |> assign(:total, total)
      |> assign(:critical, critical)
      |> assign(:high, high)
      |> assign(:medium, medium)
      |> assign(:low, low)

    ~H"""
    <div class="rounded-xl border border-base-200 bg-base-100 shadow-sm p-4">
      <div class="flex items-center justify-between mb-3">
        <div class="text-xs text-base-content/50 uppercase tracking-wider">
          Event Severity Breakdown
        </div>
        <div class="flex items-center gap-1">
          <.link patch={~p"/observability?#{%{tab: "events"}}"} class="btn btn-ghost btn-xs">
            All Events
          </.link>
          <.link
            patch={
              ~p"/observability?#{%{tab: "events", q: "in:events severity:(Critical,High) time:last_24h sort:time:desc"}}"
            }
            class="btn btn-ghost btn-xs text-error"
          >
            Critical/High
          </.link>
        </div>
      </div>
      <div class="grid grid-cols-2 sm:grid-cols-4 gap-3">
        <.event_severity_stat
          label="Critical"
          count={@critical}
          total={@total}
          color="error"
          severity="Critical"
        />
        <.event_severity_stat
          label="High"
          count={@high}
          total={@total}
          color="warning"
          severity="High"
        />
        <.event_severity_stat
          label="Medium"
          count={@medium}
          total={@total}
          color="info"
          severity="Medium"
        />
        <.event_severity_stat
          label="Low"
          count={@low}
          total={@total}
          color="success"
          severity="Low"
        />
      </div>
    </div>
    """
  end

  attr(:label, :string, required: true)
  attr(:count, :integer, required: true)
  attr(:total, :integer, required: true)
  attr(:color, :string, required: true)
  attr(:severity, :string, required: true)

  defp event_severity_stat(assigns) do
    pct = if assigns.total > 0, do: round(assigns.count / assigns.total * 100), else: 0
    query = "in:events severity:#{assigns.severity} time:last_24h sort:time:desc"

    assigns =
      assigns
      |> assign(:pct, pct)
      |> assign(:query, query)

    ~H"""
    <.link
      patch={~p"/observability?#{%{tab: "events", q: @query}}"}
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

  attr(:summary, :map, required: true)

  defp alert_summary(assigns) do
    assigns =
      assigns
      |> assign(:total, Map.get(assigns.summary, :total, 0))
      |> assign(:pending, Map.get(assigns.summary, :pending, 0))
      |> assign(:acknowledged, Map.get(assigns.summary, :acknowledged, 0))
      |> assign(:resolved, Map.get(assigns.summary, :resolved, 0))
      |> assign(:escalated, Map.get(assigns.summary, :escalated, 0))
      |> assign(:suppressed, Map.get(assigns.summary, :suppressed, 0))

    ~H"""
    <div class="rounded-xl border border-base-200 bg-base-100 shadow-sm p-4">
      <div class="flex items-center justify-between mb-3">
        <div class="text-xs text-base-content/50 uppercase tracking-wider">
          Alert Status Overview
        </div>
        <div class="flex items-center gap-1">
          <.link patch={~p"/observability?#{%{tab: "alerts"}}"} class="btn btn-ghost btn-xs">
            All Alerts
          </.link>
          <.link
            patch={
              ~p"/observability?#{%{tab: "alerts", q: "in:alerts status:pending time:last_7d sort:timestamp:desc"}}"
            }
            class="btn btn-ghost btn-xs text-warning"
          >
            Pending
          </.link>
        </div>
      </div>
      <div class="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-6 gap-3">
        <.status_stat label="Pending" count={@pending} tone="warning" />
        <.status_stat label="Acked" count={@acknowledged} tone="info" />
        <.status_stat label="Resolved" count={@resolved} tone="success" />
        <.status_stat label="Escalated" count={@escalated} tone="error" />
        <.status_stat label="Suppressed" count={@suppressed} tone="neutral" />
        <.status_stat label="Total" count={@total} tone="ghost" />
      </div>
    </div>
    """
  end

  attr(:summary, :map, required: true)
  attr(:top_talkers, :list, default: [])
  attr(:top_ports, :list, default: [])
  attr(:base_path, :string, required: true)
  attr(:query, :string, required: true)
  attr(:limit, :integer, required: true)

  defp netflow_summary(assigns) do
    summary = assigns.summary

    assigns =
      assigns
      |> assign(:total, Map.get(summary, :total, 0))
      |> assign(:tcp, Map.get(summary, :tcp, 0))
      |> assign(:udp, Map.get(summary, :udp, 0))
      |> assign(:other, Map.get(summary, :other, 0))
      |> assign(:total_bytes, Map.get(summary, :total_bytes, 0))

    ~H"""
    <div class="space-y-4">
      <div class="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-5">
        <.ui_panel class="p-4">
          <div class="flex items-center justify-between">
            <div>
              <p class="text-sm font-medium text-base-content/60">Total Flows</p>
              <p class="text-2xl font-bold">{@total}</p>
            </div>
            <.icon name="hero-arrow-trending-up" class="h-8 w-8 text-base-content/40" />
          </div>
        </.ui_panel>

        <.ui_panel class="p-4">
          <div class="flex items-center justify-between">
            <div>
              <p class="text-sm font-medium text-base-content/60">TCP Flows</p>
              <p class="text-2xl font-bold">{@tcp}</p>
            </div>
            <.ui_badge variant="success">TCP</.ui_badge>
          </div>
        </.ui_panel>

        <.ui_panel class="p-4">
          <div class="flex items-center justify-between">
            <div>
              <p class="text-sm font-medium text-base-content/60">UDP Flows</p>
              <p class="text-2xl font-bold">{@udp}</p>
            </div>
            <.ui_badge variant="info">UDP</.ui_badge>
          </div>
        </.ui_panel>

        <.ui_panel class="p-4">
          <div class="flex items-center justify-between">
            <div>
              <p class="text-sm font-medium text-base-content/60">Other</p>
              <p class="text-2xl font-bold">{@other}</p>
            </div>
            <.ui_badge variant="ghost">Other</.ui_badge>
          </div>
        </.ui_panel>

        <.ui_panel class="p-4">
          <div class="flex items-center justify-between">
            <div>
              <p class="text-sm font-medium text-base-content/60">Total Bytes</p>
              <p class="text-2xl font-bold">{format_netflow_bytes(@total_bytes)}</p>
            </div>
            <.icon name="hero-circle-stack" class="h-8 w-8 text-base-content/40" />
          </div>
        </.ui_panel>
      </div>

      <div class="grid grid-cols-1 gap-4 lg:grid-cols-2">
        <.ui_panel class="p-0" body_class="p-0">
          <div class="p-4 border-b border-base-200 bg-base-200/30 flex items-center justify-between">
            <div class="text-xs uppercase tracking-wider text-base-content/50">Top Talkers</div>
            <.ui_badge variant="ghost" size="xs">{length(@top_talkers)}</.ui_badge>
          </div>
          <div class="p-2">
            <div :if={@top_talkers == []} class="px-2 py-6 text-center text-sm text-base-content/60">
              No talker stats for this window.
            </div>
            <div :if={@top_talkers != []} class="space-y-1">
              <%= for row <- @top_talkers do %>
                <div class="flex items-center justify-between gap-3 rounded-lg px-3 py-2 hover:bg-base-200/40">
                  <div class="min-w-0">
                    <.link
                      patch={
                        netflow_filter_patch(
                          @base_path,
                          @query,
                          @limit,
                          "src_ip",
                          Map.get(row, :ip)
                        )
                      }
                      class="text-sm font-mono hover:underline"
                    >
                      {Map.get(row, :ip) || "—"}
                    </.link>
                    <div class="text-[10px] uppercase tracking-wider text-base-content/50">
                      Source
                    </div>
                  </div>
                  <div class="shrink-0 text-right">
                    <div class="text-sm font-mono">{format_netflow_bytes(Map.get(row, :bytes))}</div>
                    <div class="text-[10px] uppercase tracking-wider text-base-content/50">Bytes</div>
                  </div>
                </div>
              <% end %>
            </div>
          </div>
        </.ui_panel>

        <.ui_panel class="p-0" body_class="p-0">
          <div class="p-4 border-b border-base-200 bg-base-200/30 flex items-center justify-between">
            <div class="text-xs uppercase tracking-wider text-base-content/50">Top Ports</div>
            <.ui_badge variant="ghost" size="xs">{length(@top_ports)}</.ui_badge>
          </div>
          <div class="p-2">
            <div :if={@top_ports == []} class="px-2 py-6 text-center text-sm text-base-content/60">
              No port stats for this window.
            </div>
            <div :if={@top_ports != []} class="space-y-1">
              <%= for row <- @top_ports do %>
                <div class="flex items-center justify-between gap-3 rounded-lg px-3 py-2 hover:bg-base-200/40">
                  <div class="min-w-0">
                    <div class="flex items-center gap-2">
                      <.link
                        patch={
                          netflow_filter_patch(
                            @base_path,
                            @query,
                            @limit,
                            "dst_port",
                            to_string(Map.get(row, :port))
                          )
                        }
                        class="text-sm font-mono hover:underline"
                      >
                        {Map.get(row, :port) || "—"}
                      </.link>
                      <.ui_badge
                        :if={service = netflow_service_label(Map.get(row, :port))}
                        variant="ghost"
                        size="xs"
                        class="font-mono"
                      >
                        {service}
                      </.ui_badge>
                    </div>
                    <div class="text-[10px] uppercase tracking-wider text-base-content/50">
                      Destination port
                    </div>
                  </div>
                  <div class="shrink-0 text-right">
                    <div class="text-sm font-mono">{format_netflow_bytes(Map.get(row, :bytes))}</div>
                    <div class="text-[10px] uppercase tracking-wider text-base-content/50">Bytes</div>
                  </div>
                </div>
              <% end %>
            </div>
          </div>
        </.ui_panel>
      </div>
    </div>
    """
  end

  attr(:label, :string, required: true)
  attr(:count, :integer, required: true)
  attr(:tone, :string, required: true)

  defp status_stat(assigns) do
    assigns = assign(assigns, :tone, tone_class(assigns.tone))

    ~H"""
    <div class="rounded-lg border border-base-200 bg-base-200/40 p-3">
      <div class="text-xs text-base-content/60">{@label}</div>
      <div class={["text-xl font-bold", @tone]}>{@count}</div>
    </div>
    """
  end

  defp tone_class("warning"), do: "text-warning"
  defp tone_class("info"), do: "text-info"
  defp tone_class("success"), do: "text-success"
  defp tone_class("error"), do: "text-error"
  defp tone_class(_), do: "text-base-content"

  attr(:srql, :map, required: true)
  attr(:limit, :integer, required: true)

  defp log_source_filters(assigns) do
    query = Map.get(assigns.srql, :query) || ""

    active_source =
      query |> extract_filter_from_query("source") |> normalize_string() |> normalize_source()

    sources = [
      %{label: "All", value: nil},
      %{label: "Syslog", value: "syslog"},
      %{label: "OTel", value: "otel"},
      %{label: "SNMP", value: "snmp"},
      %{label: "Internal", value: "internal"}
    ]

    assigns =
      assigns
      |> assign(:query, query)
      |> assign(:active_source, active_source)
      |> assign(:sources, sources)

    ~H"""
    <div class="flex items-center justify-end gap-2">
      <div class="hidden sm:flex items-center gap-2">
        <span class="text-[10px] uppercase tracking-wider text-base-content/50">Source</span>
        <div class="flex flex-wrap gap-1">
          <%= for source <- @sources do %>
            <.log_source_chip
              label={source.label}
              value={source.value}
              active_source={@active_source}
              query={@query}
              limit={@limit}
            />
          <% end %>
        </div>
      </div>

      <div>
        <.ui_dropdown align="end">
          <:trigger>
            <.ui_button variant="ghost" size="xs" class="rounded-full">
              <.icon name="hero-funnel" class="size-4" />
              <span class="text-xs">Source</span>
            </.ui_button>
          </:trigger>
          <:item :for={source <- @sources}>
            <.link
              patch={log_source_patch(@query, source.value, @limit)}
              class={[
                "text-xs",
                source_active?(@active_source, source.value) && "font-semibold text-primary"
              ]}
            >
              {source.label}
            </.link>
          </:item>
        </.ui_dropdown>
      </div>
    </div>
    """
  end

  attr(:srql, :map, required: true)
  attr(:limit, :integer, required: true)

  defp netflow_presets(assigns) do
    query = Map.get(assigns.srql, :query) || ""

    presets = [
      %{label: "Recent", query: "in:flows time:last_24h sort:time:desc"},
      %{label: "Top Bytes", query: "in:flows time:last_24h sort:bytes_total:desc"},
      %{label: "Top Packets", query: "in:flows time:last_24h sort:packets_total:desc"},
      %{label: "TCP", query: "in:flows time:last_24h proto:6 sort:bytes_total:desc"},
      %{label: "UDP", query: "in:flows time:last_24h proto:17 sort:bytes_total:desc"}
    ]

    assigns =
      assigns
      |> assign(:query, query)
      |> assign(:presets, presets)
      |> assign(:base_path, Map.get(assigns.srql, :page_path) || "/observability")

    ~H"""
    <div class="flex items-center justify-end gap-2">
      <span class="text-[10px] uppercase tracking-wider text-base-content/50">Presets</span>
      <div class="flex flex-wrap gap-1">
        <%= for preset <- @presets do %>
          <.ui_button
            size="xs"
            variant="ghost"
            active={preset_active?(@query, preset.query)}
            class="rounded-full"
            patch={netflow_preset_patch(@base_path, preset.query, @limit)}
          >
            {preset.label}
          </.ui_button>
        <% end %>
      </div>
    </div>
    """
  end

  defp preset_active?(current, target) when is_binary(current) and is_binary(target) do
    String.trim(current) == target
  end

  defp preset_active?(_, _), do: false

  defp netflow_preset_patch(base_path, query, limit) do
    params =
      %{tab: "netflows", limit: limit}
      |> maybe_put_param(:q, query)

    base_path <> "?" <> URI.encode_query(params)
  end

  attr(:label, :string, required: true)
  attr(:value, :string, default: nil)
  attr(:active_source, :string, default: nil)
  attr(:query, :string, required: true)
  attr(:limit, :integer, required: true)

  defp log_source_chip(assigns) do
    active? = source_active?(assigns.active_source, assigns.value)
    href = log_source_patch(assigns.query, assigns.value, assigns.limit)

    assigns =
      assigns
      |> assign(:active?, active?)
      |> assign(:href, href)

    ~H"""
    <.ui_button
      patch={@href}
      size="xs"
      variant="ghost"
      active={@active?}
      class="rounded-full"
    >
      {@label}
    </.ui_button>
    """
  end

  defp normalize_source(nil), do: nil
  defp normalize_source(""), do: nil

  defp normalize_source(value) when is_binary(value),
    do: value |> String.trim() |> String.downcase()

  defp normalize_source(_), do: nil

  defp source_active?(current, value) do
    current = normalize_source(current)
    value = normalize_source(value)

    if is_nil(value) do
      is_nil(current)
    else
      current == value
    end
  end

  defp log_source_patch(query, source, limit) do
    new_query = log_source_query(query, source)

    params =
      %{tab: "logs", limit: limit}
      |> maybe_put_param(:q, new_query)

    "/observability?" <> URI.encode_query(params)
  end

  defp log_source_query(query, source) do
    cleaned = strip_filter(query, "source")

    cond do
      is_nil(source) or source == "" -> cleaned
      cleaned == "" -> "in:logs source:#{source} time:last_24h sort:timestamp:desc"
      true -> cleaned <> " source:#{source}"
    end
  end

  defp strip_filter(nil, _field), do: ""
  defp strip_filter("", _field), do: ""

  defp strip_filter(query, field) when is_binary(query) and is_binary(field) do
    pattern = ~r/(?:^|\s)#{Regex.escape(field)}:(?:"[^"]+"|\S+)/

    query
    |> then(&Regex.replace(pattern, &1, ""))
    |> then(&Regex.replace(~r/\s+/, &1, " "))
    |> String.trim()
  end

  defp maybe_put_param(params, _key, nil), do: params
  defp maybe_put_param(params, _key, ""), do: params
  defp maybe_put_param(params, key, value), do: Map.put(params, key, value)

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

  attr(:active, :string, required: true)

  defp observability_tabs(assigns) do
    ~H"""
    <div class="rounded-xl border border-base-200 bg-base-100 shadow-sm p-2">
      <div class="flex flex-wrap gap-2">
        <.tab_button id="logs" label="Logs" icon="hero-rectangle-stack" active={@active} />
        <.tab_button id="traces" label="Traces" icon="hero-clock" active={@active} />
        <.tab_button id="metrics" label="Metrics" icon="hero-chart-bar" active={@active} />
        <.tab_button id="events" label="Events" icon="hero-bell-alert" active={@active} />
        <.tab_button id="alerts" label="Alerts" icon="hero-exclamation-triangle" active={@active} />
        <.tab_button id="netflows" label="NetFlow" icon="hero-arrow-path" active={@active} />
      </div>
    </div>
    """
  end

  attr(:id, :string, required: true)
  attr(:label, :string, required: true)
  attr(:icon, :string, required: true)
  attr(:active, :string, required: true)

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

  attr(:stats, :map, required: true)
  attr(:latency, :map, required: true)

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

  attr(:stats, :map, required: true)

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

  attr(:title, :string, required: true)
  attr(:value, :string, required: true)
  attr(:subtitle, :string, default: nil)
  attr(:icon, :string, required: true)
  attr(:tone, :string, default: "neutral", values: ~w(neutral success warning error info))

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

  attr(:id, :string, required: true)
  attr(:logs, :any, required: true)
  attr(:count, :integer, required: true)

  defp logs_table(assigns) do
    ~H"""
    <div id={"#{@id}-local-time"} class="overflow-x-auto" phx-hook=".LocalTime">
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
        <tbody id={"#{@id}-rows"} phx-update="stream">
          <tr :if={@count == 0}>
            <td colspan="4" class="text-sm text-base-content/60 py-8 text-center">
              No log entries found.
            </td>
          </tr>

          <%= for {dom_id, log} <- @logs do %>
            <tr
              id={dom_id}
              class="hover:bg-base-200/40 cursor-pointer transition-colors"
              phx-click={JS.navigate(~p"/logs/#{log_id(log)}")}
            >
              <td class="whitespace-nowrap text-xs font-mono">
                <% time = timestamp_meta(log) %>
                <%= if is_binary(time.iso) do %>
                  <time data-iso={time.iso} data-utc={time.display} title={time.display}>
                    {time.display}
                  </time>
                <% else %>
                  {time.display}
                <% end %>
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

    <script :type={Phoenix.LiveView.ColocatedHook} name=".LocalTime">
      export default {
        mounted() {
          this.format()
        },
        updated() {
          this.format()
        },
        format() {
          const nodes = this.el.querySelectorAll("time[data-iso]")
          nodes.forEach((node) => {
            const iso = node.dataset.iso
            if (!iso) return
            const date = new Date(iso)
            if (Number.isNaN(date.getTime())) return
            node.textContent = this.formatLocal(date)
            const utc = node.dataset.utc
            if (utc) node.title = utc
          })
        },
        formatLocal(date) {
          const pad = (value) => String(value).padStart(2, "0")
          const year = date.getFullYear()
          const month = pad(date.getMonth() + 1)
          const day = pad(date.getDate())
          const hours = pad(date.getHours())
          const minutes = pad(date.getMinutes())
          const seconds = pad(date.getSeconds())
          return `${year}-${month}-${day} ${hours}:${minutes}:${seconds}`
        }
      }
    </script>
    """
  end

  attr(:id, :string, required: true)
  attr(:traces, :list, default: [])

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

  attr(:id, :string, required: true)
  attr(:metrics, :list, default: [])
  attr(:sparklines, :map, default: %{})

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

  attr(:id, :string, required: true)
  attr(:events, :any, required: true)
  attr(:count, :integer, required: true)

  defp events_table(assigns) do
    ~H"""
    <div class="overflow-x-auto">
      <table id={@id} class="table table-sm table-zebra w-full">
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
                {format_event_timestamp(event)}
              </td>
              <td class="whitespace-nowrap text-xs">
                <.event_severity_badge value={Map.get(event, "severity")} />
              </td>
              <td class="whitespace-nowrap text-xs truncate max-w-[12rem]" title={event_source(event)}>
                {event_source(event)}
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

  attr(:value, :any, default: nil)

  defp event_severity_badge(assigns) do
    variant = event_severity_variant(assigns.value)
    label = event_severity_label(assigns.value)

    assigns = assign(assigns, :variant, variant) |> assign(:label, label)

    ~H"""
    <.ui_badge variant={@variant} size="xs">{@label}</.ui_badge>
    """
  end

  defp event_severity_variant(value) do
    case normalize_event_severity(value) do
      s when s in ["critical", "fatal", "error"] -> "error"
      s when s in ["high", "warn", "warning"] -> "warning"
      s when s in ["medium", "info"] -> "info"
      s when s in ["low", "debug", "ok"] -> "success"
      _ -> "ghost"
    end
  end

  defp event_severity_label(nil), do: "—"
  defp event_severity_label(""), do: "—"
  defp event_severity_label(value) when is_binary(value), do: value
  defp event_severity_label(value), do: to_string(value)

  defp normalize_event_severity(nil), do: ""
  defp normalize_event_severity(v) when is_binary(v), do: v |> String.trim() |> String.downcase()
  defp normalize_event_severity(v), do: v |> to_string() |> normalize_event_severity()

  defp event_id(event) do
    Map.get(event, "id") || Map.get(event, "event_id") || "unknown"
  end

  defp event_dom_id(event) do
    id = event_id(event)

    if id == "unknown" do
      "event-" <> Integer.to_string(:erlang.phash2(event))
    else
      "event-" <> id
    end
  end

  defp format_event_timestamp(event) do
    ts =
      Map.get(event, "time") || Map.get(event, "event_timestamp") || Map.get(event, "timestamp")

    case parse_timestamp(ts) do
      {:ok, dt} -> Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
      _ -> ts || "—"
    end
  end

  defp event_source(event) do
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

  defp event_message(event) do
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

  attr(:id, :string, required: true)
  attr(:alerts, :list, default: [])

  defp alerts_table(assigns) do
    ~H"""
    <div class="overflow-x-auto">
      <table id={@id} class="table table-sm table-zebra w-full">
        <thead>
          <tr>
            <th class="whitespace-nowrap text-xs font-semibold text-base-content/70 bg-base-200/60 w-40">
              Time
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-base-content/70 bg-base-200/60 w-24">
              Severity
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-base-content/70 bg-base-200/60 w-28">
              Status
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-base-content/70 bg-base-200/60">
              Title
            </th>
          </tr>
        </thead>
        <tbody>
          <tr :if={@alerts == []}>
            <td colspan="4" class="text-sm text-base-content/60 py-8 text-center">
              No alerts found.
            </td>
          </tr>

          <%= for {alert, idx} <- Enum.with_index(@alerts) do %>
            <tr
              id={"#{@id}-row-#{idx}"}
              class="hover:bg-base-200/40 cursor-pointer transition-colors"
              phx-click={JS.navigate(~p"/alerts/#{alert_id(alert)}")}
            >
              <td class="whitespace-nowrap text-xs font-mono">{format_alert_timestamp(alert)}</td>
              <td class="whitespace-nowrap text-xs">
                <.alert_severity_badge value={Map.get(alert, "severity")} />
              </td>
              <td class="whitespace-nowrap text-xs">
                <.alert_status_badge value={Map.get(alert, "status")} />
              </td>
              <td class="text-xs truncate max-w-[36rem]" title={alert_title(alert)}>
                {alert_title(alert)}
              </td>
            </tr>
          <% end %>
        </tbody>
      </table>
    </div>
    """
  end

  attr(:value, :any, default: nil)

  defp alert_severity_badge(assigns) do
    variant = alert_severity_variant(assigns.value)
    label = alert_severity_label(assigns.value)

    assigns = assign(assigns, :variant, variant) |> assign(:label, label)

    ~H"""
    <.ui_badge variant={@variant} size="xs">{@label}</.ui_badge>
    """
  end

  defp alert_severity_variant(value) do
    case normalize_alert_severity(value) do
      s when s in ["emergency", "critical"] -> "error"
      s when s in ["warning"] -> "warning"
      s when s in ["info"] -> "info"
      _ -> "ghost"
    end
  end

  defp alert_severity_label(nil), do: "—"
  defp alert_severity_label(""), do: "—"
  defp alert_severity_label(value) when is_binary(value), do: value
  defp alert_severity_label(value), do: to_string(value)

  defp normalize_alert_severity(nil), do: ""
  defp normalize_alert_severity(v) when is_binary(v), do: v |> String.trim() |> String.downcase()
  defp normalize_alert_severity(v), do: v |> to_string() |> normalize_alert_severity()

  attr(:value, :any, default: nil)

  defp alert_status_badge(assigns) do
    variant = alert_status_variant(assigns.value)
    label = alert_status_label(assigns.value)

    assigns = assign(assigns, :variant, variant) |> assign(:label, label)

    ~H"""
    <.ui_badge variant={@variant} size="xs">{@label}</.ui_badge>
    """
  end

  defp alert_status_variant(value) do
    case normalize_alert_status(value) do
      "pending" -> "warning"
      "acknowledged" -> "info"
      "resolved" -> "success"
      "escalated" -> "error"
      "suppressed" -> "ghost"
      _ -> "ghost"
    end
  end

  defp alert_status_label(nil), do: "—"
  defp alert_status_label(""), do: "—"
  defp alert_status_label(value) when is_binary(value), do: String.capitalize(value)
  defp alert_status_label(value), do: value |> to_string() |> String.capitalize()

  defp normalize_alert_status(nil), do: ""
  defp normalize_alert_status(v) when is_binary(v), do: String.downcase(v)
  defp normalize_alert_status(v), do: v |> to_string() |> normalize_alert_status()

  defp alert_id(alert) do
    Map.get(alert, "id") || Map.get(alert, "alert_id") || "unknown"
  end

  defp alert_title(alert) do
    Map.get(alert, "title") || Map.get(alert, "description") || "Alert"
  end

  defp format_alert_timestamp(alert) do
    ts = Map.get(alert, "triggered_at") || Map.get(alert, "timestamp")

    case parse_timestamp(ts) do
      {:ok, dt} -> Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
      _ -> ts || "—"
    end
  end

  attr(:flows, :list, default: [])
  attr(:base_path, :string, required: true)
  attr(:query, :string, required: true)
  attr(:limit, :integer, required: true)

  defp netflows_table(assigns) do
    ~H"""
    <div class="overflow-x-auto">
      <table class="table table-sm table-zebra w-full">
        <thead>
          <tr>
            <th class="whitespace-nowrap text-xs font-semibold text-base-content/70 bg-base-200/60 w-40">
              Time
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-base-content/70 bg-base-200/60 w-40">
              Source
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-base-content/70 bg-base-200/60 w-40">
              Destination
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-base-content/70 bg-base-200/60 w-24">
              Protocol
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-base-content/70 bg-base-200/60 w-24">
              Version
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-base-content/70 bg-base-200/60 w-24 text-right">
              Packets
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-base-content/70 bg-base-200/60 w-24 text-right">
              Bytes
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-base-content/70 bg-base-200/60 w-10 text-right">
            </th>
          </tr>
        </thead>
        <tbody>
          <%= for {flow, idx} <- Enum.with_index(@flows) do %>
            <tr class="hover:bg-base-200/40">
              <td class="whitespace-nowrap text-xs font-mono">
                {format_netflow_timestamp(flow)}
              </td>
              <td class="whitespace-nowrap text-xs font-mono">
                {src_ip = netflow_addr(flow, :src)}
                <.link
                  :if={netflow_present?(src_ip)}
                  patch={netflow_filter_patch(@base_path, @query, @limit, "src_ip", src_ip)}
                  class="hover:underline"
                >
                  {src_ip}
                </.link>
                <span :if={not netflow_present?(src_ip)}>{src_ip}</span>
                {if netflow_port(flow, :src), do: ":#{netflow_port(flow, :src)}", else: ""}
              </td>
              <td class="whitespace-nowrap text-xs">
                <div class="flex items-center gap-2">
                  <div class="font-mono">
                    {dst_ip = netflow_addr(flow, :dst)}
                    <.link
                      :if={netflow_present?(dst_ip)}
                      patch={netflow_filter_patch(@base_path, @query, @limit, "dst_ip", dst_ip)}
                      class="hover:underline"
                    >
                      {dst_ip}
                    </.link>
                    <span :if={not netflow_present?(dst_ip)}>{dst_ip}</span>
                    {if netflow_port(flow, :dst), do: ":#{netflow_port(flow, :dst)}", else: ""}
                  </div>
                  <div
                    :if={service_label = netflow_service_label(netflow_port(flow, :dst))}
                    class="shrink-0"
                  >
                    <.ui_badge variant="ghost" size="xs" class="font-mono">
                      {service_label}
                    </.ui_badge>
                  </div>
                </div>
              </td>
              <td class="whitespace-nowrap text-xs">
                <.netflow_protocol_badge
                  protocol={netflow_protocol_num(flow)}
                  name={netflow_protocol_name(flow)}
                />
              </td>
              <td class="whitespace-nowrap text-xs">
                <.netflow_flow_type_badge flow_type={netflow_flow_type(flow)} />
              </td>
              <td class="whitespace-nowrap text-xs text-right font-mono">
                {format_netflow_number(netflow_packets(flow))}
              </td>
              <td class="whitespace-nowrap text-xs text-right font-mono">
                {format_netflow_bytes(netflow_bytes(flow))}
              </td>
              <td class="whitespace-nowrap text-xs text-right">
                <.ui_dropdown align="end">
                  <:trigger>
                    <.ui_icon_button variant="ghost" size="xs" aria-label="Flow actions">
                      <.icon name="hero-ellipsis-vertical" class="size-4" />
                    </.ui_icon_button>
                  </:trigger>
                  <:item>
                    <.link phx-click="netflow_open" phx-value-idx={idx} class="text-xs">
                      Open details
                    </.link>
                  </:item>
                  <:item>
                    <.link
                      patch={
                        netflow_filter_patch(
                          @base_path,
                          @query,
                          @limit,
                          "src_ip",
                          netflow_addr(flow, :src)
                        )
                      }
                      class="text-xs"
                    >
                      Filter source
                    </.link>
                  </:item>
                  <:item>
                    <.link
                      patch={
                        netflow_filter_patch(
                          @base_path,
                          @query,
                          @limit,
                          "dst_ip",
                          netflow_addr(flow, :dst)
                        )
                      }
                      class="text-xs"
                    >
                      Filter destination
                    </.link>
                  </:item>
                  <:item :if={
                    is_integer(to_int(netflow_port(flow, :dst))) and
                      to_int(netflow_port(flow, :dst)) > 0
                  }>
                    <.link
                      patch={
                        netflow_filter_patch(
                          @base_path,
                          @query,
                          @limit,
                          "dst_port",
                          to_string(netflow_port(flow, :dst))
                        )
                      }
                      class="text-xs"
                    >
                      Filter port
                    </.link>
                  </:item>
                </.ui_dropdown>
              </td>
            </tr>
          <% end %>
        </tbody>
      </table>

      <div :if={@flows == []} class="py-12 text-center text-base-content/60">
        No network flows found. Generate some NetFlow data to see it here!
      </div>
    </div>
    """
  end

  attr(:flow, :map, required: true)
  attr(:base_path, :string, required: true)
  attr(:query, :string, required: true)
  attr(:limit, :integer, required: true)

  defp netflow_details_modal(assigns) do
    assigns =
      assigns
      |> assign(:src_ip, netflow_addr(assigns.flow, :src))
      |> assign(:dst_ip, netflow_addr(assigns.flow, :dst))
      |> assign(:src_port, netflow_port(assigns.flow, :src))
      |> assign(:dst_port, netflow_port(assigns.flow, :dst))
      |> assign(:service_label, netflow_service_label(netflow_port(assigns.flow, :dst)))

    ~H"""
    <dialog class="modal modal-open" phx-window-keydown="netflow_close" phx-key="escape">
      <div class="modal-box max-w-4xl">
        <div class="flex items-start justify-between gap-4">
          <div class="min-w-0">
            <div class="text-sm font-semibold">Flow details</div>
            <div class="text-xs text-base-content/70 font-mono">
              {format_netflow_timestamp(@flow)}
            </div>
          </div>
          <.ui_icon_button variant="ghost" size="sm" phx-click="netflow_close" aria-label="Close">
            <.icon name="hero-x-mark" class="size-5" />
          </.ui_icon_button>
        </div>

        <div class="mt-4 grid grid-cols-1 lg:grid-cols-3 gap-4">
          <.ui_panel class="lg:col-span-2" body_class="p-0">
            <div class="divide-y divide-base-200">
              <div class="p-4">
                <div class="text-xs uppercase tracking-wider text-base-content/50">Endpoints</div>
                <div class="mt-2 grid grid-cols-1 sm:grid-cols-2 gap-3">
                  <div class="rounded-lg border border-base-200 bg-base-200/30 p-3">
                    <div class="text-[10px] uppercase tracking-wider text-base-content/50">
                      Source
                    </div>
                    <div class="mt-1 font-mono text-sm">
                      {@src_ip}{if @src_port, do: ":#{@src_port}", else: ""}
                    </div>
                    <div class="mt-2 flex flex-wrap gap-2">
                      <.ui_button
                        size="xs"
                        variant="ghost"
                        patch={netflow_filter_patch(@base_path, @query, @limit, "src_ip", @src_ip)}
                      >
                        Filter src
                      </.ui_button>
                    </div>
                  </div>

                  <div class="rounded-lg border border-base-200 bg-base-200/30 p-3">
                    <div class="text-[10px] uppercase tracking-wider text-base-content/50">
                      Destination
                    </div>
                    <div class="mt-1 font-mono text-sm">
                      {@dst_ip}{if @dst_port, do: ":#{@dst_port}", else: ""}
                    </div>
                    <div :if={@service_label} class="mt-1 text-xs text-base-content/60">
                      Service: <span class="font-mono">{@service_label}</span>
                    </div>
                    <div class="mt-2 flex flex-wrap gap-2">
                      <.ui_button
                        size="xs"
                        variant="ghost"
                        patch={netflow_filter_patch(@base_path, @query, @limit, "dst_ip", @dst_ip)}
                      >
                        Filter dst
                      </.ui_button>
                      <.ui_button
                        :if={@dst_port}
                        size="xs"
                        variant="ghost"
                        patch={
                          netflow_filter_patch(
                            @base_path,
                            @query,
                            @limit,
                            "dst_port",
                            to_string(@dst_port)
                          )
                        }
                      >
                        Filter port
                      </.ui_button>
                    </div>
                  </div>
                </div>
              </div>

              <div class="p-4">
                <div class="text-xs uppercase tracking-wider text-base-content/50">Traffic</div>
                <div class="mt-2 grid grid-cols-2 sm:grid-cols-4 gap-3">
                  <div class="rounded-lg border border-base-200 bg-base-200/30 p-3">
                    <div class="text-[10px] uppercase tracking-wider text-base-content/50">
                      Protocol
                    </div>
                    <div class="mt-1">
                      <.netflow_protocol_badge
                        protocol={netflow_protocol_num(@flow)}
                        name={netflow_protocol_name(@flow)}
                      />
                    </div>
                  </div>
                  <div class="rounded-lg border border-base-200 bg-base-200/30 p-3">
                    <div class="text-[10px] uppercase tracking-wider text-base-content/50">
                      Version
                    </div>
                    <div class="mt-1">
                      <.netflow_flow_type_badge flow_type={netflow_flow_type(@flow)} />
                    </div>
                  </div>
                  <div class="rounded-lg border border-base-200 bg-base-200/30 p-3">
                    <div class="text-[10px] uppercase tracking-wider text-base-content/50">
                      Packets
                    </div>
                    <div class="mt-1 font-mono text-sm">
                      {format_netflow_number(netflow_packets(@flow))}
                    </div>
                  </div>
                  <div class="rounded-lg border border-base-200 bg-base-200/30 p-3">
                    <div class="text-[10px] uppercase tracking-wider text-base-content/50">Bytes</div>
                    <div class="mt-1 font-mono text-sm">
                      {format_netflow_bytes(netflow_bytes(@flow))}
                    </div>
                  </div>
                </div>
              </div>
            </div>
          </.ui_panel>

          <.ui_panel class="lg:col-span-1">
            <div class="text-xs uppercase tracking-wider text-base-content/50">Quick pivots</div>
            <div class="mt-3 space-y-2">
              <.ui_button
                size="sm"
                variant="outline"
                class="w-full justify-start"
                patch={
                  netflow_filter_patch(
                    @base_path,
                    @query,
                    @limit,
                    "src_ip",
                    @src_ip
                  )
                }
              >
                <.icon name="hero-arrow-left-end-on-rectangle" class="size-4" /> Source traffic
              </.ui_button>
              <.ui_button
                size="sm"
                variant="outline"
                class="w-full justify-start"
                patch={
                  netflow_filter_patch(
                    @base_path,
                    @query,
                    @limit,
                    "dst_ip",
                    @dst_ip
                  )
                }
              >
                <.icon name="hero-arrow-right-end-on-rectangle" class="size-4" /> Destination traffic
              </.ui_button>
              <.ui_button
                :if={@dst_port}
                size="sm"
                variant="outline"
                class="w-full justify-start"
                patch={
                  netflow_filter_patch(
                    @base_path,
                    @query,
                    @limit,
                    "dst_port",
                    to_string(@dst_port)
                  )
                }
              >
                <.icon name="hero-funnel" class="size-4" /> Port {@dst_port}
              </.ui_button>
            </div>
          </.ui_panel>
        </div>
      </div>

      <form method="dialog" class="modal-backdrop">
        <button phx-click="netflow_close">close</button>
      </form>
    </dialog>
    """
  end

  attr(:protocol, :any, default: nil)
  attr(:name, :any, default: nil)

  defp netflow_protocol_badge(assigns) do
    protocol = assigns.protocol
    name = assigns.name
    protocol_num = to_int(protocol)

    {label, variant} = netflow_protocol_label_variant(protocol_num, protocol, name)

    assigns = assign(assigns, label: label, variant: variant)

    ~H"""
    <.ui_badge variant={@variant}>{@label}</.ui_badge>
    """
  end

  defp netflow_protocol_label_variant(6, _protocol, _name), do: {"TCP", "success"}
  defp netflow_protocol_label_variant(17, _protocol, _name), do: {"UDP", "info"}
  defp netflow_protocol_label_variant(1, _protocol, _name), do: {"ICMP", "ghost"}

  defp netflow_protocol_label_variant(_protocol_num, protocol, name) do
    label =
      cond do
        is_binary(name) and name != "" -> String.upcase(name)
        is_binary(protocol) and protocol != "" -> protocol
        true -> "Unknown"
      end

    {label, "ghost"}
  end

  defp netflow_flow_type_badge(assigns) do
    flow_type = assigns.flow_type

    {label, variant} =
      case flow_type do
        "NETFLOW_V5" -> {"v5", "warning"}
        "NETFLOW_V9" -> {"v9", "info"}
        "IPFIX" -> {"IPFIX", "success"}
        nil -> {"Unknown", "ghost"}
        other -> {other, "ghost"}
      end

    assigns = assign(assigns, label: label, variant: variant)

    ~H"""
    <.ui_badge variant={@variant}>{@label}</.ui_badge>
    """
  end

  defp netflow_addr(flow, :src),
    do: netflow_value(flow, ["src_endpoint_ip", "src_addr"]) || "—"

  defp netflow_addr(flow, :dst),
    do: netflow_value(flow, ["dst_endpoint_ip", "dst_addr"]) || "—"

  defp netflow_addr(_flow, _), do: "—"

  defp netflow_port(flow, :src), do: netflow_value(flow, ["src_endpoint_port", "src_port"])
  defp netflow_port(flow, :dst), do: netflow_value(flow, ["dst_endpoint_port", "dst_port"])
  defp netflow_port(_flow, _), do: nil

  defp netflow_protocol_num(flow), do: netflow_value(flow, ["protocol_num", "protocol"])
  defp netflow_protocol_name(flow), do: netflow_value(flow, ["protocol_name"])

  defp netflow_packets(flow), do: netflow_value(flow, ["packets_total", "packets"])
  defp netflow_bytes(flow), do: netflow_value(flow, ["bytes_total", "octets"])

  defp netflow_flow_type(flow) do
    payload =
      case Map.get(flow, "ocsf_payload") do
        %{} = data -> data
        _ -> nil
      end

    flow_type =
      if is_map(payload) do
        get_in(payload, ["unmapped", "flow_type"]) || get_in(payload, ["flow_type"])
      else
        nil
      end

    case flow_type do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp netflow_value(flow, keys) when is_map(flow) and is_list(keys) do
    Enum.find_value(keys, fn key ->
      value = Map.get(flow, key)
      if is_nil(value) or value == "", do: nil, else: value
    end)
  end

  defp netflow_value(_flow, _keys), do: nil

  defp format_netflow_timestamp(%{} = flow) do
    ts = Map.get(flow, "time") || Map.get(flow, "timestamp")

    case parse_timestamp(ts) do
      {:ok, dt} -> Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
      _ -> ts || "—"
    end
  end

  defp format_netflow_timestamp(nil), do: "—"
  defp format_netflow_timestamp(ts) when is_binary(ts), do: String.slice(ts, 0..18)
  defp format_netflow_timestamp(_), do: "—"

  defp netflow_present?(nil), do: false
  defp netflow_present?(""), do: false

  defp netflow_present?(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> false
      "—" -> false
      "-" -> false
      _ -> true
    end
  end

  defp netflow_present?(_), do: true

  defp netflow_filter_patch(base_path, query, limit, field, value) do
    value = to_string(value || "") |> String.trim()
    value = if value in ["—", "-"], do: "", else: value

    params =
      %{tab: "netflows", limit: limit}
      |> maybe_put_param(:q, upsert_query_filter(query || "", field, value))

    base_path <> "?" <> URI.encode_query(params)
  end

  defp upsert_query_filter(query, _field, ""), do: query

  defp upsert_query_filter(query, field, value) when is_binary(query) and is_binary(field) do
    pattern = ~r/(?:^|\s)#{Regex.escape(field)}:(?:"([^"]+)"|(\S+))/

    query =
      query
      |> String.replace(pattern, "")
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

    (query <> " " <> "#{field}:#{value}")
    |> String.trim()
  end

  defp netflow_service_label(nil), do: nil
  defp netflow_service_label(""), do: nil

  defp netflow_service_label(port) do
    port = to_int(port)

    case port do
      22 -> "SSH"
      25 -> "SMTP"
      53 -> "DNS"
      67 -> "DHCP"
      68 -> "DHCP"
      80 -> "HTTP"
      110 -> "POP3"
      123 -> "NTP"
      143 -> "IMAP"
      161 -> "SNMP"
      162 -> "SNMPTRAP"
      389 -> "LDAP"
      443 -> "HTTPS"
      445 -> "SMB"
      465 -> "SMTPS"
      514 -> "SYSLOG"
      587 -> "SMTP"
      636 -> "LDAPS"
      1433 -> "MSSQL"
      3306 -> "MYSQL"
      3389 -> "RDP"
      5432 -> "POSTGRES"
      6379 -> "REDIS"
      8080 -> "HTTP-ALT"
      8443 -> "HTTPS-ALT"
      9200 -> "ELASTIC"
      27017 -> "MONGO"
      _ -> nil
    end
  end

  defp format_netflow_bytes(nil), do: "0 B"

  defp format_netflow_bytes(bytes) when is_binary(bytes) do
    case Integer.parse(bytes) do
      {value, _} -> format_netflow_bytes(value)
      _ -> "—"
    end
  end

  defp format_netflow_bytes(bytes) when is_integer(bytes) and bytes < 1024, do: "#{bytes} B"

  defp format_netflow_bytes(bytes) when is_integer(bytes) and bytes < 1_048_576,
    do: "#{Float.round(bytes / 1024, 1)} KB"

  defp format_netflow_bytes(bytes) when is_integer(bytes) and bytes < 1_073_741_824,
    do: "#{Float.round(bytes / 1_048_576, 1)} MB"

  defp format_netflow_bytes(bytes) when is_integer(bytes),
    do: "#{Float.round(bytes / 1_073_741_824, 2)} GB"

  defp format_netflow_bytes(_), do: "—"

  defp format_netflow_number(nil), do: "0"

  defp format_netflow_number(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> Integer.to_string(int)
      _ -> "—"
    end
  end

  defp format_netflow_number(num) when is_integer(num), do: Integer.to_string(num)
  defp format_netflow_number(_), do: "—"

  attr(:metric, :map, required: true)
  attr(:sparklines, :map, default: %{})

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

  attr(:data, :list, required: true)

  defp sparkline(assigns) do
    data = assigns.data
    min_val = Enum.min(data)
    max_val = Enum.max(data)
    range = max_val - min_val

    # Normalize to 0-100 range for SVG, with some padding
    points =
      data
      |> Enum.with_index()
      |> Enum.map_join(" ", fn {val, idx} ->
        x = idx / max(length(data) - 1, 1) * 100
        y = if range > 0, do: 100 - (val - min_val) / range * 80 - 10, else: 50
        "#{Float.round(x, 1)},#{Float.round(y, 1)}"
      end)

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

  attr(:metric, :map, required: true)

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
      <div
        class="flex items-center gap-2 min-w-[5rem]"
        title={"#{Float.round(@duration_ms * 1.0, 1)}ms"}
      >
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

  attr(:metric, :map, required: true)

  defp histogram_viz(assigns) do
    # For histograms with duration data, show a duration-based gauge bar
    # Most OTEL histograms are duration distributions
    duration_ms = extract_duration_value(assigns.metric)

    # Use reasonable bounds for duration visualization (0-1000ms as typical range)
    # Anything over 1s will show as full bar
    pct = histogram_pct(duration_ms)
    bar_color = histogram_bar_color(duration_ms)
    title = histogram_title(duration_ms)

    assigns =
      assigns
      |> assign(:pct, pct)
      |> assign(:bar_color, bar_color)
      |> assign(:duration_ms, duration_ms)
      |> assign(:title, title)

    ~H"""
    <div
      class="flex items-center gap-2 w-20"
      title={@title}
    >
      <div class="flex-1 h-1.5 bg-base-200 rounded-full overflow-hidden">
        <div class={[@bar_color, "h-full rounded-full transition-all"]} style={"width: #{@pct}%"}>
        </div>
      </div>
    </div>
    """
  end

  defp histogram_pct(duration_ms) do
    cond do
      not is_number(duration_ms) or duration_ms <= 0 -> 0
      duration_ms >= 1000 -> 100
      true -> duration_ms / 10
    end
  end

  defp histogram_bar_color(duration_ms) do
    cond do
      not is_number(duration_ms) or duration_ms <= 0 -> "bg-base-content/20"
      duration_ms >= 500 -> "bg-error"
      duration_ms >= 100 -> "bg-warning"
      true -> "bg-success"
    end
  end

  defp histogram_title(duration_ms) do
    if is_number(duration_ms) and duration_ms > 0 do
      "#{Float.round(duration_ms * 1.0, 1)}ms"
    else
      "no duration"
    end
  end

  defp extract_histogram_count(metric) do
    cond do
      is_number(metric["count"]) -> trunc(metric["count"])
      is_binary(metric["count"]) -> trunc(extract_number(metric["count"]) || 0)
      is_number(metric["bucket_count"]) -> trunc(metric["bucket_count"])
      true -> 0
    end
  end

  defp extract_duration_ms(metric), do: duration_ms_from_metric(metric)

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
      format_non_histogram_metric(metric, metric_name, metric_type, unit)
    end
  end

  defp format_non_histogram_metric(metric, metric_name, metric_type, unit) do
    with {:error} <- explicit_unit_format(metric, unit),
         {:error} <- named_metric_format(metric, metric_name),
         {:error} <- duration_metric_format(metric, metric_name, metric_type) do
      raw_metric_format(metric, metric_type)
    else
      {:ok, formatted} -> formatted
    end
  end

  defp explicit_unit_format(_metric, nil), do: {:error}
  defp explicit_unit_format(metric, unit), do: {:ok, format_with_explicit_unit(metric, unit)}

  defp named_metric_format(metric, metric_name) do
    cond do
      bytes_metric?(metric_name) ->
        {:ok, format_bytes_value(metric)}

      count_metric?(metric_name) or stats_metric?(metric_name) ->
        {:ok, format_count_value(metric)}

      true ->
        {:error}
    end
  end

  defp duration_metric_format(metric, metric_name, metric_type) do
    cond do
      duration_metric?(metric_name) and has_duration_field?(metric) ->
        {:ok, format_duration_value(metric)}

      metric_type == "span" and has_duration_field?(metric) ->
        {:ok, format_duration_value(metric)}

      actual_timing_span?(metric) and has_duration_field?(metric) ->
        {:ok, format_duration_value(metric)}

      true ->
        {:error}
    end
  end

  defp raw_metric_format(metric, metric_type) do
    if has_any_value?(metric) do
      format_raw_value(metric, metric_type)
    else
      "—"
    end
  end

  # Format metric value using explicit unit field from backend
  defp format_with_explicit_unit(metric, unit) do
    case extract_primary_value(metric) do
      value when is_number(value) -> format_explicit_unit_value(value, unit)
      _ -> "—"
    end
  end

  defp format_explicit_unit_value(value, unit) do
    cond do
      unit in ["ms", "s", "ns", "us"] ->
        format_duration_unit(value, unit)

      unit in ["bytes", "By", "kb", "KiB", "mb", "MiB", "gb", "GiB"] ->
        format_bytes_unit(value, unit)

      unit in ["1", "{request}", "{connection}", "{thread}", "{goroutine}"] ->
        format_count_from_value(value)

      unit == "%" ->
        "#{Float.round(value * 1.0, 1)}%"

      true ->
        "#{format_compact_value(value)} #{unit}"
    end
  end

  defp format_duration_unit(value, "ms"), do: format_ms_value(value)
  defp format_duration_unit(value, "s"), do: format_seconds_value(value)
  defp format_duration_unit(value, "ns"), do: format_ns_value(value)
  defp format_duration_unit(value, "us"), do: format_us_value(value)

  defp format_bytes_unit(value, unit) do
    multiplier =
      case unit do
        "bytes" -> 1
        "By" -> 1
        "kb" -> 1024
        "KiB" -> 1024
        "mb" -> 1024 * 1024
        "MiB" -> 1024 * 1024
        "gb" -> 1024 * 1024 * 1024
        "GiB" -> 1024 * 1024 * 1024
      end

    format_bytes_from_value(value * multiplier)
  end

  defp extract_primary_value(metric) do
    metric_numeric_value(metric, ["value", "duration_ms", "sum", "count"])
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

  defp extract_duration_value(metric), do: duration_ms_from_metric(metric)

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

  defp bytes_metric?(nil), do: false
  defp bytes_metric?(""), do: false

  defp bytes_metric?(name) when is_binary(name) do
    downcased = String.downcase(name)

    String.contains?(downcased, "bytes") or
      String.contains?(downcased, "memory") or
      String.contains?(downcased, "heap") or
      String.contains?(downcased, "alloc")
  end

  defp count_metric?(nil), do: false
  defp count_metric?(""), do: false

  defp count_metric?(name) when is_binary(name) do
    downcased = String.downcase(name)

    String.ends_with?(downcased, "_count") or
      String.ends_with?(downcased, "_total") or
      String.contains?(downcased, "goroutines") or
      String.contains?(downcased, "threads")
  end

  # Stats/counter-like metrics (processed, skipped, etc.)
  defp stats_metric?(nil), do: false
  defp stats_metric?(""), do: false

  defp stats_metric?(name) when is_binary(name) do
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
  defp duration_metric?(nil), do: false
  defp duration_metric?(""), do: false

  defp duration_metric?(name) when is_binary(name) do
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
  defp actual_timing_span?(metric) do
    has_http =
      non_empty_string?(metric["http_route"]) or
        non_empty_string?(metric["http_method"])

    has_grpc =
      non_empty_string?(metric["grpc_service"]) or
        non_empty_string?(metric["grpc_method"])

    # Also check for span type
    is_span = normalize_string(Map.get(metric, "metric_type")) == "span"

    (has_http or has_grpc) and is_span
  end

  defp non_empty_string?(nil), do: false
  defp non_empty_string?(""), do: false
  defp non_empty_string?(s) when is_binary(s), do: String.trim(s) != ""
  defp non_empty_string?(_), do: false

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
    ms = duration_ms_from_metric(metric) || 0.0

    if ms >= 1000 do
      "#{Float.round(ms / 1000.0, 2)}s"
    else
      "#{Float.round(ms * 1.0, 1)}ms"
    end
  end

  defp format_bytes_value(metric) do
    bytes = metric_numeric_value(metric, ["value", "sum", "duration_ms"]) || 0
    format_bytes_from_value(bytes)
  end

  defp format_count_value(metric) do
    count = metric_numeric_value(metric, ["value", "sum", "count", "duration_ms"]) || 0
    format_count_from_value(count)
  end

  defp format_raw_value(metric, _metric_type) do
    case metric_numeric_value(metric, ["value", "sum", "count", "duration_ms"]) do
      value when is_number(value) -> format_compact_value(value)
      _ -> "—"
    end
  end

  # Used for the visualization bar - extracts numeric value for comparison
  defp metric_value_ms(metric) when is_map(metric) do
    case duration_ms_from_metric(metric) do
      value when is_number(value) ->
        value * 1.0

      _ ->
        case metric_numeric_value(metric, ["value", "sum"]) do
          value when is_number(value) -> value * 1.0
          _ -> nil
        end
    end
  end

  defp metric_value_ms(_), do: nil

  attr(:value, :any, default: nil)

  defp severity_badge(assigns) do
    variant = severity_variant(assigns.value)
    label = severity_label(assigns.value)

    assigns = assign(assigns, :variant, variant) |> assign(:label, label)

    ~H"""
    <.ui_badge variant={@variant} size="xs">{@label}</.ui_badge>
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

  defp severity_label(value) when is_binary(value) do
    String.upcase(String.slice(value, 0, 5))
  end

  defp severity_label(value) do
    value
    |> to_string()
    |> String.upcase()
    |> String.slice(0, 5)
  end

  defp normalize_severity(nil), do: ""
  defp normalize_severity(v) when is_binary(v), do: v |> String.trim() |> String.downcase()
  defp normalize_severity(v), do: v |> to_string() |> normalize_severity()

  defp log_id(log) do
    # Use the UUID id field from the logs table
    case Map.get(log, "id") do
      nil -> "unknown"
      # Handle binary UUID (16 bytes) - convert to string format
      <<_::binary-size(16)>> = bin -> uuid_to_string(bin)
      # Already a string UUID
      id when is_binary(id) -> id
      _ -> "unknown"
    end
  end

  defp log_dom_id(log) do
    id = log_id(log)

    if id == "unknown" do
      "log-" <> Integer.to_string(:erlang.phash2(log))
    else
      "log-" <> id
    end
  end

  # Convert raw 16-byte binary UUID to string format
  defp uuid_to_string(<<a::32, b::16, c::16, d::16, e::48>>) do
    [a, b, c, d, e]
    |> Enum.map(&Integer.to_string(&1, 16))
    |> Enum.map(&String.downcase/1)
    |> Enum.zip([8, 4, 4, 4, 12])
    |> Enum.map_join("-", fn {hex, len} -> String.pad_leading(hex, len, "0") end)
  end

  defp uuid_to_string(_), do: "unknown"

  defp format_timestamp(log) do
    ts = Map.get(log, "timestamp") || Map.get(log, "observed_timestamp")

    case parse_timestamp(ts) do
      {:ok, dt} -> Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
      _ -> ts || "—"
    end
  end

  defp timestamp_meta(log) do
    ts = Map.get(log, "timestamp") || Map.get(log, "observed_timestamp")

    case parse_timestamp(ts) do
      {:ok, dt} ->
        %{
          iso: DateTime.to_iso8601(dt),
          display: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
        }

      _ ->
        %{iso: nil, display: ts || "—"}
    end
  end

  # Use pre-computed CAGG via rollup_stats pattern for accurate counts
  defp load_summary(srql_module, current_query, scope) do
    opts = build_summary_opts(current_query, srql_module, scope)
    Stats.logs_severity(opts)
  end

  defp build_summary_opts(current_query, srql_module, scope) do
    base_opts = [srql_module: srql_module, scope: scope]

    # Extract time range from query if present, otherwise use default
    time = extract_time_from_query(current_query) || @default_stats_window

    # Extract service_name filter if present
    service_name = extract_filter_from_query(current_query, "service_name")
    source = extract_filter_from_query(current_query, "source")

    base_opts
    |> Keyword.put(:time, time)
    |> maybe_put(:service_name, service_name)
    |> maybe_put(:source, source)
  end

  defp extract_time_from_query(nil), do: nil
  defp extract_time_from_query(""), do: nil

  defp extract_time_from_query(query) when is_binary(query) do
    case Regex.run(~r/(?:^|\s)time:(\S+)/, query) do
      [_, time] -> time
      _ -> nil
    end
  end

  defp extract_filter_from_query(nil, _field), do: nil
  defp extract_filter_from_query("", _field), do: nil

  defp extract_filter_from_query(query, field) when is_binary(query) and is_binary(field) do
    # Match both service_name:value and service_name:"quoted value"
    pattern = ~r/(?:^|\s)#{Regex.escape(field)}:(?:"([^"]+)"|(\S+))/

    case Regex.run(pattern, query) do
      [_, quoted, ""] -> quoted
      [_, "", unquoted] -> unquoted
      [_, value] -> value
      _ -> nil
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, _key, ""), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp to_int(value) when is_integer(value), do: value
  defp to_int(value) when is_float(value), do: trunc(value)

  defp to_int(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> 0
    end
  end

  defp to_int(_), do: 0

  defp numeric_to_float(%Decimal{} = value), do: Decimal.to_float(value)
  defp numeric_to_float(value) when is_number(value), do: value * 1.0
  defp numeric_to_float(_), do: 0.0

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

  defp compute_event_summary(events) when is_list(events) do
    initial = %{total: 0, critical: 0, high: 0, medium: 0, low: 0}

    Enum.reduce(events, initial, fn event, acc ->
      severity = normalize_event_severity(Map.get(event, "severity"))

      updated =
        case severity do
          s when s in ["critical", "fatal", "error"] -> Map.update!(acc, :critical, &(&1 + 1))
          s when s in ["high", "warn", "warning"] -> Map.update!(acc, :high, &(&1 + 1))
          s when s in ["medium", "info"] -> Map.update!(acc, :medium, &(&1 + 1))
          s when s in ["low", "debug", "ok"] -> Map.update!(acc, :low, &(&1 + 1))
          _ -> acc
        end

      Map.update!(updated, :total, &(&1 + 1))
    end)
  end

  defp compute_event_summary(_), do: empty_event_summary()

  defp compute_alert_summary(alerts) when is_list(alerts) do
    Enum.reduce(
      alerts,
      %{total: 0, pending: 0, acknowledged: 0, resolved: 0, escalated: 0, suppressed: 0},
      fn alert, acc ->
        status = normalize_alert_status(Map.get(alert, "status"))

        acc
        |> Map.update!(:total, &(&1 + 1))
        |> increment_alert_status(status)
      end
    )
  end

  defp compute_alert_summary(_), do: empty_alert_summary()

  defp increment_alert_status(acc, "pending"), do: Map.update!(acc, :pending, &(&1 + 1))
  defp increment_alert_status(acc, "acknowledged"), do: Map.update!(acc, :acknowledged, &(&1 + 1))
  defp increment_alert_status(acc, "resolved"), do: Map.update!(acc, :resolved, &(&1 + 1))
  defp increment_alert_status(acc, "escalated"), do: Map.update!(acc, :escalated, &(&1 + 1))
  defp increment_alert_status(acc, "suppressed"), do: Map.update!(acc, :suppressed, &(&1 + 1))
  defp increment_alert_status(acc, _), do: acc

  defp compute_netflow_summary(flows) when is_list(flows) do
    Enum.reduce(
      flows,
      %{total: 0, tcp: 0, udp: 0, other: 0, total_bytes: 0, v5: 0, v9: 0, ipfix: 0},
      fn flow, acc ->
        protocol = flow |> netflow_protocol_num() |> to_int()
        bytes = flow |> netflow_bytes() |> to_int()
        flow_type = netflow_flow_type(flow)

        updated =
          case protocol do
            6 -> Map.update!(acc, :tcp, &(&1 + 1))
            17 -> Map.update!(acc, :udp, &(&1 + 1))
            _ -> Map.update!(acc, :other, &(&1 + 1))
          end

        updated =
          case flow_type do
            "NETFLOW_V5" -> Map.update!(updated, :v5, &(&1 + 1))
            "NETFLOW_V9" -> Map.update!(updated, :v9, &(&1 + 1))
            "IPFIX" -> Map.update!(updated, :ipfix, &(&1 + 1))
            _ -> updated
          end

        updated
        |> Map.update!(:total, &(&1 + 1))
        |> Map.update!(:total_bytes, &(&1 + bytes))
      end
    )
  end

  defp compute_netflow_summary(_), do: empty_netflow_summary()

  defp panel_title("traces"), do: "Traces"
  defp panel_title("metrics"), do: "Metrics"
  defp panel_title("events"), do: "Events"
  defp panel_title("alerts"), do: "Alerts"
  defp panel_title("netflows"), do: "NetFlow"
  defp panel_title(_), do: "Log Stream"

  defp panel_subtitle("traces"), do: "Click a trace to jump to correlated logs."

  defp panel_subtitle("metrics"),
    do: "Click a metric to jump to correlated logs (if trace_id is present)."

  defp panel_subtitle("events"), do: "Click any event to view full details."
  defp panel_subtitle("alerts"), do: "Click any alert to view full details."
  defp panel_subtitle("netflows"), do: "Network flow data from NetFlow collectors."
  defp panel_subtitle(_), do: "Click any log entry to view full details."

  defp panel_result_count("traces", _logs, traces, _metrics, _events, _alerts, _netflows),
    do: length(traces)

  defp panel_result_count("metrics", _logs, _traces, metrics, _events, _alerts, _netflows),
    do: length(metrics)

  defp panel_result_count("events", _logs, _traces, _metrics, events, _alerts, _netflows),
    do: length(events)

  defp panel_result_count("alerts", _logs, _traces, _metrics, _events, alerts, _netflows),
    do: length(alerts)

  defp panel_result_count("netflows", _logs, _traces, _metrics, _events, _alerts, netflows),
    do: length(netflows)

  defp panel_result_count(_, logs, _traces, _metrics, _events, _alerts, _netflows),
    do: length(logs)

  defp default_tab_for_path("/observability"), do: "logs"
  defp default_tab_for_path("/netflows"), do: "netflows"
  defp default_tab_for_path(_), do: "logs"

  defp normalize_tab("logs", _path), do: "logs"
  defp normalize_tab("traces", _path), do: "traces"
  defp normalize_tab("metrics", _path), do: "metrics"
  defp normalize_tab("events", _path), do: "events"
  defp normalize_tab("alerts", _path), do: "alerts"
  defp normalize_tab("netflows", _path), do: "netflows"
  defp normalize_tab(_tab, path), do: default_tab_for_path(path)

  defp tab_entity("traces"), do: {"otel_trace_summaries", :traces}
  defp tab_entity("metrics"), do: {"otel_metrics", :metrics}
  defp tab_entity("events"), do: {"events", :events}
  defp tab_entity("alerts"), do: {"alerts", :alerts}
  defp tab_entity("netflows"), do: {"flows", :netflows}
  defp tab_entity(_), do: {"logs", :logs}

  defp tab_limits("events"), do: {@default_events_limit, @max_events_limit}
  defp tab_limits("alerts"), do: {@default_alerts_limit, @max_alerts_limit}
  defp tab_limits("netflows"), do: {@default_netflow_limit, @max_netflow_limit}
  defp tab_limits(_), do: {@default_limit, @max_limit}

  defp apply_tab_assigns(socket, "traces", srql_module) do
    scope = Map.get(socket.assigns, :current_scope)
    trace_latency = compute_trace_latency(socket.assigns.traces)

    socket
    |> assign(:trace_stats, load_trace_stats(srql_module, scope))
    |> assign(:trace_latency, trace_latency)
    |> assign(:metrics_stats, empty_metrics_stats())
  end

  defp apply_tab_assigns(socket, "metrics", srql_module) do
    scope = Map.get(socket.assigns, :current_scope)
    metrics_stats = build_metrics_stats(srql_module, scope)
    sparklines = load_sparklines(socket.assigns.metrics, scope)

    socket
    |> assign(:metrics_stats, metrics_stats)
    |> assign(:sparklines, sparklines)
    |> assign(:trace_stats, empty_trace_stats())
    |> assign(:trace_latency, empty_trace_latency())
  end

  defp apply_tab_assigns(socket, "events", _srql_module) do
    summary = compute_event_summary(socket.assigns.events)

    socket
    |> assign(:event_summary, summary)
    |> assign(:alert_summary, empty_alert_summary())
    |> assign(:netflow_summary, empty_netflow_summary())
    |> assign(:trace_stats, empty_trace_stats())
    |> assign(:trace_latency, empty_trace_latency())
    |> assign(:metrics_stats, empty_metrics_stats())
  end

  defp apply_tab_assigns(socket, "alerts", _srql_module) do
    summary = compute_alert_summary(socket.assigns.alerts)

    socket
    |> assign(:alert_summary, summary)
    |> assign(:event_summary, empty_event_summary())
    |> assign(:netflow_summary, empty_netflow_summary())
    |> assign(:trace_stats, empty_trace_stats())
    |> assign(:trace_latency, empty_trace_latency())
    |> assign(:metrics_stats, empty_metrics_stats())
  end

  defp apply_tab_assigns(socket, "netflows", srql_module) do
    scope = Map.get(socket.assigns, :current_scope)
    summary = maybe_load_netflow_summary(socket, srql_module, scope)

    top_talkers =
      load_netflow_top_talkers(srql_module, Map.get(socket.assigns.srql, :query), scope)

    top_ports = load_netflow_top_ports(srql_module, Map.get(socket.assigns.srql, :query), scope)

    socket
    |> assign(:netflow_summary, summary)
    |> assign(:netflow_top_talkers, top_talkers)
    |> assign(:netflow_top_ports, top_ports)
    |> assign(:event_summary, empty_event_summary())
    |> assign(:alert_summary, empty_alert_summary())
    |> assign(:trace_stats, empty_trace_stats())
    |> assign(:trace_latency, empty_trace_latency())
    |> assign(:metrics_stats, empty_metrics_stats())
  end

  defp apply_tab_assigns(socket, _tab, srql_module) do
    scope = Map.get(socket.assigns, :current_scope)
    summary = maybe_load_log_summary(socket, srql_module, scope)

    socket
    |> assign(:summary, summary)
    |> assign(:event_summary, empty_event_summary())
    |> assign(:alert_summary, empty_alert_summary())
    |> assign(:netflow_summary, empty_netflow_summary())
    |> assign(:trace_stats, empty_trace_stats())
    |> assign(:trace_latency, empty_trace_latency())
    |> assign(:metrics_stats, empty_metrics_stats())
  end

  defp maybe_refresh_tab(socket, tab) do
    if socket.assigns.active_tab == tab do
      refresh_tab(socket, tab)
    else
      socket
    end
  end

  defp refresh_tab(socket, tab) do
    {entity, list_key} = tab_entity(tab)
    {default_limit, max_limit} = tab_limits(tab)
    srql = Map.get(socket.assigns, :srql, %{})
    query = Map.get(srql, :query, "")
    limit = Map.get(socket.assigns, :limit, default_limit)
    params = %{"q" => query, "limit" => limit}
    uri = Map.get(srql, :page_path, "/observability")

    socket
    |> ensure_srql_entity(entity, default_limit)
    |> SRQLPage.load_list(params, uri, list_key,
      default_limit: default_limit,
      max_limit: max_limit
    )
    |> apply_tab_assigns(tab, srql_module())
    |> stream_active_tab(tab)
  end

  defp stream_active_tab(socket, "logs") do
    stream(socket, :logs, socket.assigns.logs, reset: true, dom_id: &log_dom_id/1)
  end

  defp stream_active_tab(socket, "events") do
    stream(socket, :events, socket.assigns.events, reset: true, dom_id: &event_dom_id/1)
  end

  defp stream_active_tab(socket, _tab), do: socket

  defp build_metrics_stats(srql_module, scope) do
    metrics_counts = load_metrics_counts(srql_module, scope)
    duration_stats = load_duration_stats_from_cagg(scope)

    metrics_counts
    |> Map.merge(duration_stats)
    |> Map.put(:error_rate, compute_error_rate(metrics_counts.total, metrics_counts.error_spans))
  end

  defp maybe_load_log_summary(socket, srql_module, scope) do
    summary = load_summary(srql_module, Map.get(socket.assigns.srql, :query), scope)

    case summary do
      %{total: 0} when is_list(socket.assigns.logs) and socket.assigns.logs != [] ->
        compute_summary(socket.assigns.logs)

      other ->
        other
    end
  end

  defp maybe_load_netflow_summary(socket, srql_module, scope) do
    summary = load_netflow_summary(srql_module, Map.get(socket.assigns.srql, :query), scope)

    case summary do
      %{total: 0} when is_list(socket.assigns.netflows) and socket.assigns.netflows != [] ->
        compute_netflow_summary(socket.assigns.netflows)

      other ->
        other
    end
  end

  defp empty_trace_stats do
    %{total: 0, error_traces: 0, slow_traces: 0}
  end

  defp empty_trace_latency do
    %{avg_duration_ms: 0.0, p95_duration_ms: 0.0, service_count: 0, sample_size: 0}
  end

  defp empty_metrics_stats do
    %{
      total: 0,
      slow_spans: 0,
      error_spans: 0,
      error_rate: 0.0,
      avg_duration_ms: 0.0,
      p95_duration_ms: 0.0,
      sample_size: 0
    }
  end

  defp empty_event_summary do
    %{total: 0, critical: 0, high: 0, medium: 0, low: 0}
  end

  defp empty_alert_summary do
    %{total: 0, pending: 0, acknowledged: 0, resolved: 0, escalated: 0, suppressed: 0}
  end

  defp empty_netflow_summary do
    %{total: 0, tcp: 0, udp: 0, other: 0, total_bytes: 0, v5: 0, v9: 0, ipfix: 0}
  end

  defp ensure_srql_entity(socket, entity, default_limit) when is_binary(entity) do
    current = socket.assigns |> Map.get(:srql, %{}) |> Map.get(:entity)

    if current == entity do
      socket
    else
      SRQLPage.init(socket, entity, default_limit: default_limit)
    end
  end

  defp current_entity(socket) do
    socket.assigns |> Map.get(:srql, %{}) |> Map.get(:entity) || "logs"
  end

  # Use pre-computed CAGG via rollup_stats pattern for traces stats
  defp load_trace_stats(srql_module, scope) do
    summary = Stats.traces_summary(srql_module: srql_module, scope: scope)

    # Map the rollup_stats fields to the expected structure
    # Note: slow_traces is not available from CAGG, so we use 0 for now
    # A future enhancement could add slow_count to the CAGG
    %{
      total: Map.get(summary, :total, 0),
      error_traces: Map.get(summary, :errors, 0),
      slow_traces: 0
    }
  end

  defp load_metrics_counts(srql_module, scope) do
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

    total = extract_stats_count(srql_module.query(total_query, %{scope: scope}), "total")
    slow_spans = extract_stats_count(srql_module.query(slow_query, %{scope: scope}), "total")

    error_level =
      extract_stats_count(srql_module.query(error_level_query, %{scope: scope}), "total")

    error_spans =
      if error_level > 0 do
        error_level
      else
        error_http4 =
          extract_stats_count(srql_module.query(error_http4_query, %{scope: scope}), "total")

        error_http5 =
          extract_stats_count(srql_module.query(error_http5_query, %{scope: scope}), "total")

        error_grpc =
          extract_stats_count(srql_module.query(error_grpc_query, %{scope: scope}), "total")

        error_http4 + error_http5 + error_grpc
      end

    %{total: total, slow_spans: slow_spans, error_spans: error_spans}
  end

  defp load_netflow_summary(srql_module, current_query, scope) do
    base_query =
      current_query
      |> netflow_base_query()
      |> sanitize_srql_for_stats()

    total_query = ~s|#{base_query} stats:"count(*) as total" limit:1|
    bytes_query = ~s|#{base_query} stats:"sum(bytes_total) as total_bytes" limit:1|

    proto_query =
      ~s|#{base_query} stats:"count(*) as total by protocol_num" sort:total:desc limit:50|

    total = extract_stats_count(srql_module.query(total_query, %{scope: scope}), "total")

    total_bytes =
      extract_stats_count(srql_module.query(bytes_query, %{scope: scope}), "total_bytes")

    proto_rows = extract_stats_rows(srql_module.query(proto_query, %{scope: scope}))

    tcp =
      proto_rows
      |> Enum.find_value(0, fn row ->
        if to_int(Map.get(row, "protocol_num")) == 6, do: to_int(row["total"])
      end)

    udp =
      proto_rows
      |> Enum.find_value(0, fn row ->
        if to_int(Map.get(row, "protocol_num")) == 17, do: to_int(row["total"])
      end)

    other = max(total - tcp - udp, 0)

    %{total: total, tcp: tcp, udp: udp, other: other, total_bytes: total_bytes}
  rescue
    e ->
      Logger.warning("Failed to load netflow summary stats: #{inspect(e)}")
      empty_netflow_summary()
  end

  defp load_netflow_top_talkers(srql_module, current_query, scope, limit \\ 10) do
    base_query =
      current_query
      |> netflow_base_query()
      |> sanitize_srql_for_stats()

    query =
      ~s|#{base_query} stats:"sum(bytes_total) as total_bytes by src_endpoint_ip" sort:total_bytes:desc limit:#{limit}|

    srql_module
    |> apply(:query, [query, %{scope: scope}])
    |> extract_stats_rows()
    |> Enum.map(fn row ->
      %{
        ip: Map.get(row, "src_endpoint_ip"),
        bytes: to_int(Map.get(row, "total_bytes"))
      }
    end)
  rescue
    _ ->
      []
  end

  defp load_netflow_top_ports(srql_module, current_query, scope, limit \\ 10) do
    base_query =
      current_query
      |> netflow_base_query()
      |> sanitize_srql_for_stats()

    query =
      ~s|#{base_query} stats:"sum(bytes_total) as total_bytes by dst_endpoint_port" sort:total_bytes:desc limit:#{limit}|

    srql_module
    |> apply(:query, [query, %{scope: scope}])
    |> extract_stats_rows()
    |> Enum.map(fn row ->
      %{
        port: to_int(Map.get(row, "dst_endpoint_port")),
        bytes: to_int(Map.get(row, "total_bytes"))
      }
    end)
    |> Enum.reject(fn row -> row.port == 0 end)
  rescue
    _ ->
      []
  end

  defp extract_stats_rows({:ok, %{"results" => results}}) when is_list(results) do
    Enum.map(results, fn
      %{"payload" => %{} = payload} -> payload
      %{} = row -> row
      _ -> %{}
    end)
  end

  defp extract_stats_rows(_), do: []

  defp netflow_base_query(nil), do: "in:flows time:last_24h"
  defp netflow_base_query(""), do: "in:flows time:last_24h"

  defp netflow_base_query(query) when is_binary(query) do
    query = String.trim(query)
    if query == "", do: "in:flows time:last_24h", else: query
  end

  defp sanitize_srql_for_stats(query) when is_binary(query) do
    query
    |> String.replace(~r/(?:^|\s)sort:\S+/, " ")
    |> String.replace(~r/(?:^|\s)limit:\S+/, " ")
    |> String.replace(~r/(?:^|\s)cursor:\S+/, " ")
    |> String.replace(~r/(?:^|\s)stats:\"[^\"]*\"/, " ")
    |> String.replace(~r/(?:^|\s)stats:\S+/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  # Load duration stats from the continuous aggregation for full 24h data
  defp load_duration_stats_from_cagg(_scope) do
    cutoff = DateTime.add(DateTime.utc_now(), -24, :hour)

    query =
      from(s in "otel_metrics_hourly_stats",
        where: s.bucket >= ^cutoff,
        select: %{
          total_count: sum(s.total_count),
          avg_duration_ms:
            fragment(
              "CASE WHEN SUM(?) > 0 THEN SUM(? * ?) / SUM(?) ELSE 0 END",
              s.total_count,
              s.avg_duration_ms,
              s.total_count,
              s.total_count
            ),
          p95_duration_ms: max(s.p95_duration_ms)
        }
      )

    case Repo.one(query) do
      %{total_count: total} = stats when not is_nil(total) and total > 0 ->
        %{
          avg_duration_ms: numeric_to_float(stats.avg_duration_ms),
          p95_duration_ms: numeric_to_float(stats.p95_duration_ms),
          sample_size: to_int(total)
        }

      _ ->
        %{avg_duration_ms: 0.0, p95_duration_ms: 0.0, sample_size: 0}
    end
  rescue
    e ->
      require Logger
      Logger.warning("Failed to load duration stats from cagg: #{inspect(e)}")
      %{avg_duration_ms: 0.0, p95_duration_ms: 0.0, sample_size: 0}
  end

  # Load sparkline data for gauge/counter metrics
  # Returns a map of metric_name -> list of {bucket, avg_value} tuples
  defp load_sparklines(metrics, scope) when is_list(metrics) do
    metric_names = sparkline_metric_names(metrics)

    if metric_names == [] do
      %{}
    else
      fetch_sparklines(metric_names, scope)
    end
  rescue
    e ->
      # Log error but don't crash - sparklines are nice-to-have
      require Logger
      Logger.warning("Failed to load sparklines: #{inspect(e)}")
      %{}
  end

  defp load_sparklines(_, _), do: %{}

  defp sparkline_metric_names(metrics) do
    metrics
    |> Enum.filter(fn metric ->
      type = normalize_string(Map.get(metric, "metric_type"))
      type in ["gauge", "counter"]
    end)
    |> Enum.map(&Map.get(&1, "metric_name"))
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp fetch_sparklines(metric_names, _scope) do
    cutoff = DateTime.add(DateTime.utc_now(), -2, :hour)

    query =
      from(m in "otel_metrics",
        where: m.metric_name in ^metric_names and m.timestamp >= ^cutoff,
        group_by: [m.metric_name, fragment("time_bucket('5 minutes', ?)", m.timestamp)],
        order_by: [m.metric_name, fragment("time_bucket('5 minutes', ?)", m.timestamp)],
        select: %{
          metric_name: m.metric_name,
          bucket: fragment("time_bucket('5 minutes', ?)", m.timestamp),
          avg_value: avg(m.value)
        }
      )

    query
    |> Repo.all()
    |> Enum.group_by(& &1.metric_name, fn row -> numeric_to_float(row.avg_value) end)
  end

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
      |> Enum.filter(fn ms -> is_number(ms) and ms >= 0 and ms < 3_600_000 end)

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

  defp compute_trace_duration_stats(_),
    do: %{avg_duration_ms: 0.0, p95_duration_ms: 0.0, sample_size: 0}

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
    grpc = grpc_operation(metric)
    http = http_operation(metric)

    cond do
      is_binary(grpc) -> grpc
      is_binary(http) -> http
      true -> Map.get(metric, "span_name") || "—"
    end
  end

  defp grpc_operation(metric) do
    grpc_service = Map.get(metric, "grpc_service")
    grpc_method = Map.get(metric, "grpc_method")

    if non_empty_string?(grpc_service) and non_empty_string?(grpc_method) do
      "#{grpc_service}/#{grpc_method}"
    else
      nil
    end
  end

  defp http_operation(metric) do
    http_route = Map.get(metric, "http_route")
    http_method = Map.get(metric, "http_method")

    cond do
      non_empty_string?(http_method) and non_empty_string?(http_route) ->
        "#{http_method} #{http_route}"

      non_empty_string?(http_route) ->
        http_route

      true ->
        nil
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

  defp metric_numeric_value(metric, keys) when is_map(metric) and is_list(keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(metric, key) do
        value when is_number(value) -> value
        value when is_binary(value) -> extract_number(value)
        _ -> nil
      end
    end)
  end

  defp duration_ms_from_metric(metric) when is_map(metric) do
    case metric_numeric_value(metric, ["duration_ms"]) do
      value when is_number(value) ->
        value * 1.0

      _ ->
        case metric_numeric_value(metric, ["duration_seconds"]) do
          value when is_number(value) -> value * 1000.0
          _ -> nil
        end
    end
  end

  defp duration_ms_from_metric(_), do: nil

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
