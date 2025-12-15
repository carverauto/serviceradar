defmodule ServiceRadarWebNGWeb.AnalyticsLive.Index do
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadarWebNGWeb.Dashboard.Engine
  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Table, as: TablePlugin

  @default_limit 200
  @default_logs_limit 500
  @default_events_limit 500

  @impl true
  def mount(_params, _session, socket) do
    srql = %{
      enabled: false,
      page_path: "/analytics"
    }

    {:ok,
     socket
     |> assign(:page_title, "Analytics")
     |> assign(:srql, srql)
     |> assign(:range, "24h")
     |> assign(:loading, true)
     |> assign(:error, nil)
     |> assign(:refreshed_at, nil)
     |> assign(:kpis, %{})
     |> assign(:charts, %{})
     |> assign(:summaries, %{})}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    range = normalize_range(Map.get(params, "range"))
    srql_module = srql_module()

    socket =
      socket
      |> assign(:range, range)
      |> assign(:loading, true)
      |> assign(:error, nil)

    {:noreply, load_analytics(socket, srql_module, range)}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply,
     load_analytics(assign(socket, :loading, true), srql_module(), socket.assigns.range)}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp load_analytics(socket, srql_module, range) do
    time_token = time_token_for_range(range)
    cpu_query = "in:cpu_metrics time:#{time_token} bucket:10m agg:avg limit:#{@default_limit}"
    mem_query = "in:memory_metrics time:#{time_token} bucket:10m agg:avg limit:#{@default_limit}"

    icmp_query =
      "in:timeseries_metrics metric_type:icmp time:last_1h bucket:5m agg:avg series:device_id limit:#{@default_limit}"

    devices_total_query = "in:devices stats:count() as total"
    devices_offline_query = "in:devices is_available:false stats:count() as offline"

    services_failing_query =
      "in:services available:false time:#{time_token} stats:count() as failing"

    logs_query =
      "in:logs time:#{time_token} sort:timestamp:desc limit:#{@default_logs_limit}"

    events_query =
      "in:events time:#{time_token} sort:event_timestamp:desc limit:#{@default_events_limit}"

    queries = %{
      devices_total: devices_total_query,
      devices_offline: devices_offline_query,
      services_failing: services_failing_query,
      cpu: cpu_query,
      memory: mem_query,
      icmp: icmp_query,
      logs: logs_query,
      events: events_query
    }

    results =
      queries
      |> Task.async_stream(
        fn {key, query} -> {key, query, srql_module.query(query)} end,
        ordered: false,
        timeout: 30_000
      )
      |> Enum.reduce(%{}, fn
        {:ok, {key, query, result}}, acc ->
          Map.put(acc, key, %{query: query, result: result})

        {:exit, reason}, acc ->
          Map.put(acc, :error, "analytics query task exit: #{inspect(reason)}")
      end)

    {kpis, charts, summaries, error} = build_assigns(results)

    socket
    |> assign(:kpis, kpis)
    |> assign(:charts, charts)
    |> assign(:summaries, summaries)
    |> assign(:refreshed_at, DateTime.utc_now())
    |> assign(:error, error)
    |> assign(:loading, false)
  end

  defp build_assigns(results) do
    total_devices = extract_count(results[:devices_total])
    offline_devices = extract_count(results[:devices_offline])
    failing_services = extract_count(results[:services_failing])

    logs_rows = extract_rows(results[:logs])
    events_rows = extract_rows(results[:events])

    logs_severity = severity_counts(logs_rows, "severity_text")
    events_severity = severity_counts(events_rows, "severity")

    high_latency_devices =
      count_unique_high_latency_devices(metric_resp: results[:icmp], threshold_ms: 100.0)

    kpis = %{
      total_devices: total_devices,
      offline_devices: offline_devices,
      failing_services: failing_services,
      high_latency_devices: high_latency_devices
    }

    charts = %{
      cpu: build_panels(results[:cpu]),
      memory: build_panels(results[:memory]),
      icmp: build_panels(results[:icmp])
    }

    summaries = %{
      logs_severity: logs_severity,
      events_severity: events_severity,
      logs_sample: Enum.take(logs_rows, 8),
      events_sample: Enum.take(events_rows, 8)
    }

    error =
      Enum.find_value(results, fn
        {_key, %{result: {:error, reason}}} -> format_error(reason)
        _ -> nil
      end)

    {kpis, charts, summaries, error}
  end

  defp extract_rows(%{result: {:ok, %{"results" => rows}}}) when is_list(rows), do: rows
  defp extract_rows(_), do: []

  defp extract_count(%{result: {:ok, %{"results" => [value | _]}}}) do
    case value do
      v when is_integer(v) ->
        v

      v when is_float(v) ->
        trunc(v)

      v when is_binary(v) ->
        case Integer.parse(String.trim(v)) do
          {parsed, ""} -> parsed
          _ -> 0
        end

      %{} = row ->
        row
        |> Map.values()
        |> Enum.find(fn v -> is_integer(v) or is_float(v) or (is_binary(v) and v != "") end)
        |> case do
          v when is_integer(v) ->
            v

          v when is_float(v) ->
            trunc(v)

          v when is_binary(v) ->
            case Integer.parse(String.trim(v)) do
              {parsed, ""} -> parsed
              _ -> 0
            end

          _ ->
            0
        end

      _ ->
        0
    end
  end

  defp extract_count(_), do: 0

  defp build_panels(%{query: query, result: {:ok, %{"results" => rows} = resp}})
       when is_list(rows) do
    viz =
      case Map.get(resp, "viz") do
        value when is_map(value) -> value
        _ -> nil
      end

    srql_response = %{"results" => rows, "viz" => viz}

    panels =
      srql_response
      |> Engine.build_panels()
      |> prefer_visual_panels(rows)

    %{query: query, panels: panels, rows: rows, error: nil}
  end

  defp build_panels(%{query: query, result: {:error, reason}}),
    do: %{query: query, panels: [], rows: [], error: format_error(reason)}

  defp build_panels(%{query: query, result: {:ok, other}}),
    do: %{
      query: query,
      panels: [],
      rows: [],
      error: "unexpected SRQL response: #{inspect(other)}"
    }

  defp build_panels(_), do: %{query: nil, panels: [], rows: [], error: nil}

  defp prefer_visual_panels(panels, results) when is_list(panels) do
    has_non_table? = Enum.any?(panels, &(&1.plugin != TablePlugin))

    if results != [] and has_non_table? do
      Enum.reject(panels, &(&1.plugin == TablePlugin))
    else
      panels
    end
  end

  defp prefer_visual_panels(panels, _results), do: panels

  defp severity_counts(rows, field) when is_list(rows) and is_binary(field) do
    rows
    |> Enum.filter(&is_map/1)
    |> Enum.reduce(%{}, fn row, acc ->
      key =
        row
        |> Map.get(field)
        |> normalize_severity()

      if key == "" do
        acc
      else
        Map.update(acc, key, 1, &(&1 + 1))
      end
    end)
    |> Enum.sort_by(fn {_k, v} -> -v end)
  end

  defp severity_counts(_rows, _field), do: []

  defp normalize_severity(nil), do: ""

  defp normalize_severity(value) do
    value
    |> to_string()
    |> String.trim()
    |> case do
      "" -> ""
      other -> other |> String.downcase() |> String.capitalize()
    end
  end

  defp count_unique_high_latency_devices(opts) when is_list(opts) do
    metric_resp = Keyword.get(opts, :metric_resp)
    threshold_ms = Keyword.get(opts, :threshold_ms, 100.0)

    rows =
      case metric_resp do
        %{result: {:ok, %{"results" => rows}}} when is_list(rows) -> rows
        _ -> []
      end

    rows
    |> Enum.filter(&is_map/1)
    |> Enum.reduce(MapSet.new(), fn row, acc ->
      device_id = Map.get(row, "series") || Map.get(row, "device_id")
      value = Map.get(row, "value")

      if is_binary(device_id) and latency_ms(value) >= threshold_ms do
        MapSet.put(acc, device_id)
      else
        acc
      end
    end)
    |> MapSet.size()
  end

  defp latency_ms(value) when is_float(value) or is_integer(value) do
    raw = if is_integer(value), do: value * 1.0, else: value
    if raw > 1_000_000.0, do: raw / 1_000_000.0, else: raw
  end

  defp latency_ms(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {parsed, ""} -> latency_ms(parsed)
      _ -> 0.0
    end
  end

  defp latency_ms(_), do: 0.0

  defp normalize_range(nil), do: "24h"

  defp normalize_range(range) when is_binary(range) do
    case range |> String.trim() |> String.downcase() do
      "1h" -> "1h"
      "24h" -> "24h"
      "7d" -> "7d"
      _ -> "24h"
    end
  end

  defp normalize_range(_), do: "24h"

  defp time_token_for_range("1h"), do: "last_1h"
  defp time_token_for_range("7d"), do: "last_7d"
  defp time_token_for_range(_), do: "last_24h"

  defp range_label("1h"), do: "Last 1h"
  defp range_label("7d"), do: "Last 7d"
  defp range_label(_), do: "Last 24h"

  defp format_error(%Jason.DecodeError{} = err), do: Exception.message(err)
  defp format_error(%ArgumentError{} = err), do: Exception.message(err)
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

  defp srql_module do
    Application.get_env(:serviceradar_web_ng, :srql_module, ServiceRadarWebNG.SRQL)
  end

  @impl true
  def render(assigns) do
    kpis = assigns.kpis || %{}
    charts = assigns.charts || %{}
    summaries = assigns.summaries || %{}

    assigns =
      assigns
      |> assign(:kpis, kpis)
      |> assign(:charts, charts)
      |> assign(:summaries, summaries)

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} srql={@srql}>
      <div class="mx-auto max-w-7xl">
        <div class="flex items-start justify-between gap-4 flex-wrap mb-6">
          <div class="min-w-0">
            <h1 class="text-2xl font-semibold tracking-tight">Analytics</h1>
            <p class="text-sm text-base-content/70 mt-1">
              A quick health overview with drill-down into details.
            </p>
          </div>

          <div class="flex items-center gap-2">
            <.ui_dropdown>
              <:trigger>
                <.ui_button variant="outline" size="sm" class="gap-2">
                  <.icon name="hero-clock" class="size-4 opacity-80" /> {range_label(@range)}
                </.ui_button>
              </:trigger>
              <:item>
                <.link patch={~p"/analytics?#{%{range: "1h"}}"} class="w-full">
                  Last 1h
                </.link>
              </:item>
              <:item>
                <.link patch={~p"/analytics?#{%{range: "24h"}}"} class="w-full">
                  Last 24h
                </.link>
              </:item>
              <:item>
                <.link patch={~p"/analytics?#{%{range: "7d"}}"} class="w-full">
                  Last 7d
                </.link>
              </:item>
            </.ui_dropdown>

            <.ui_button variant="primary" size="sm" phx-click="refresh" class="gap-2">
              <span :if={@loading} class="loading loading-spinner loading-xs" />
              <.icon name="hero-arrow-path" class="size-4 opacity-80" /> Refresh
            </.ui_button>
          </div>
        </div>

        <div :if={is_binary(@error)} class="mb-6">
          <div role="alert" class="alert alert-error">
            <.icon name="hero-exclamation-triangle" class="size-5" />
            <span class="text-sm">{@error}</span>
          </div>
        </div>

        <div class="grid grid-cols-1 lg:grid-cols-4 gap-4 mb-6">
          <.kpi_card
            title="Total devices"
            value={Map.get(@kpis, :total_devices, 0)}
            desc="Inventory size"
            href={~p"/devices"}
            icon="hero-computer-desktop"
          />
          <.kpi_card
            title="Offline devices"
            value={Map.get(@kpis, :offline_devices, 0)}
            desc="Availability"
            href={
              ~p"/devices?#{%{q: "in:devices is_available:false time:last_7d sort:last_seen:desc", limit: 100}}"
            }
            icon="hero-signal-slash"
            tone="warning"
          />
          <.kpi_card
            title="Failing services"
            value={Map.get(@kpis, :failing_services, 0)}
            desc={range_label(@range)}
            href={
              ~p"/services?#{%{q: "in:services available:false time:#{time_token_for_range(@range)} sort:timestamp:desc", limit: 100}}"
            }
            icon="hero-wrench-screwdriver"
            tone="error"
          />
          <.kpi_card
            title="High latency ICMP"
            value={Map.get(@kpis, :high_latency_devices, 0)}
            desc="> 100ms (last 1h)"
            href={
              ~p"/dashboard?#{%{q: "in:timeseries_metrics metric_type:icmp value:>100000000 time:last_1h sort:timestamp:desc limit:200", limit: 200}}"
            }
            icon="hero-wifi"
            tone="warning"
          />
        </div>

        <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
          <.chart_panel title="CPU usage" chart={Map.get(@charts, :cpu)} />
          <.chart_panel title="Memory usage" chart={Map.get(@charts, :memory)} />
          <.chart_panel title="ICMP latency" chart={Map.get(@charts, :icmp)} />

          <.ui_panel>
            <:header>
              <div class="min-w-0">
                <div class="text-sm font-semibold">Recent signals</div>
                <div class="text-xs text-base-content/70">
                  Severity breakdown from the latest sample window.
                </div>
              </div>
              <div class="shrink-0 flex items-center gap-2">
                <.ui_button
                  variant="ghost"
                  size="sm"
                  href={
                    ~p"/events?#{%{q: "in:events time:#{time_token_for_range(@range)} sort:event_timestamp:desc", limit: 100}}"
                  }
                >
                  Events →
                </.ui_button>
                <.ui_button
                  variant="ghost"
                  size="sm"
                  href={
                    ~p"/logs?#{%{q: "in:logs time:#{time_token_for_range(@range)} sort:timestamp:desc", limit: 100}}"
                  }
                >
                  Logs →
                </.ui_button>
              </div>
            </:header>

            <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
              <.severity_panel title="Events" items={Map.get(@summaries, :events_severity, [])} />
              <.severity_panel title="Logs" items={Map.get(@summaries, :logs_severity, [])} />
            </div>
          </.ui_panel>
        </div>

        <div class="mt-6 text-xs text-base-content/60 flex items-center justify-between gap-3 flex-wrap">
          <div>
            <span class="font-semibold">Updated:</span>
            <span :if={is_struct(@refreshed_at, DateTime)} class="font-mono">
              {Calendar.strftime(@refreshed_at, "%Y-%m-%d %H:%M:%S UTC")}
            </span>
            <span :if={not is_struct(@refreshed_at, DateTime)}>—</span>
          </div>
          <div class="font-mono opacity-60">SRQL-powered</div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :title, :string, required: true
  attr :value, :any, required: true
  attr :desc, :string, default: nil
  attr :href, :string, required: true
  attr :icon, :string, default: nil
  attr :tone, :string, default: "neutral"

  def kpi_card(assigns) do
    assigns =
      assigns
      |> assign_new(:tone, fn -> "neutral" end)
      |> assign(:tone_class, tone_class(assigns.tone))

    ~H"""
    <.link href={@href} class="block">
      <div class={[
        "rounded-xl border bg-base-100 shadow-sm hover:shadow-md transition-shadow",
        "border-base-200 hover:border-base-300"
      ]}>
        <div class="p-4 flex items-start justify-between gap-3">
          <div class="min-w-0">
            <div class="text-xs font-semibold text-base-content/60">{@title}</div>
            <div class="text-3xl font-semibold tracking-tight mt-1">{format_int(@value)}</div>
            <div :if={is_binary(@desc)} class="text-xs text-base-content/60 mt-1">{@desc}</div>
          </div>
          <div class={["shrink-0 rounded-lg p-2 border", @tone_class]}>
            <.icon :if={@icon} name={@icon} class="size-5" />
          </div>
        </div>
      </div>
    </.link>
    """
  end

  defp tone_class("warning"), do: "border-warning/30 bg-warning/10 text-warning"
  defp tone_class("error"), do: "border-error/30 bg-error/10 text-error"
  defp tone_class("success"), do: "border-success/30 bg-success/10 text-success"
  defp tone_class(_), do: "border-base-200 bg-base-200/30 text-base-content/70"

  defp format_int(v) when is_integer(v), do: Integer.to_string(v)
  defp format_int(v) when is_float(v), do: v |> trunc() |> Integer.to_string()
  defp format_int(v) when is_binary(v), do: v
  defp format_int(_), do: "0"

  attr :title, :string, required: true
  attr :chart, :map, required: true

  def chart_panel(assigns) do
    chart = assigns.chart || %{}
    assigns = assign(assigns, :chart, chart)

    ~H"""
    <.ui_panel>
      <:header>
        <div class="min-w-0">
          <div class="text-sm font-semibold">{@title}</div>
          <div class="text-xs text-base-content/60 font-mono truncate">{Map.get(@chart, :query)}</div>
        </div>
      </:header>

      <div :if={is_binary(Map.get(@chart, :error))} class="text-sm text-base-content/70">
        {Map.get(@chart, :error)}
      </div>

      <div
        :if={not is_binary(Map.get(@chart, :error)) and Map.get(@chart, :panels, []) == []}
        class="text-sm text-base-content/70"
      >
        No data.
      </div>

      <div :if={Map.get(@chart, :panels, []) != []} class="grid grid-cols-1 gap-4">
        <%= for panel <- Map.get(@chart, :panels, []) do %>
          <.live_component
            module={panel.plugin}
            id={"analytics-#{@title}-#{panel.id}"}
            title={panel.title}
            panel_assigns={panel.assigns}
          />
        <% end %>
      </div>
    </.ui_panel>
    """
  end

  attr :title, :string, required: true
  attr :items, :list, default: []

  def severity_panel(assigns) do
    assigns = assign_new(assigns, :items, fn -> [] end)

    ~H"""
    <div class="rounded-xl border border-base-200 bg-base-100 p-4">
      <div class="text-xs font-semibold text-base-content/60 mb-3">{@title}</div>

      <div :if={@items == []} class="text-sm text-base-content/70">No data.</div>

      <div :if={@items != []} class="space-y-2">
        <%= for {label, count} <- @items do %>
          <div class="flex items-center justify-between gap-3">
            <div class="min-w-0 flex items-center gap-2">
              <.ui_badge variant={severity_variant(label)} size="xs">{label}</.ui_badge>
            </div>
            <div class="font-mono text-xs opacity-70">{count}</div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp severity_variant(label) when is_binary(label) do
    case label |> String.trim() |> String.downcase() do
      "critical" -> "error"
      "fatal" -> "error"
      "error" -> "error"
      "warn" -> "warning"
      "warning" -> "warning"
      "high" -> "warning"
      "info" -> "info"
      "medium" -> "info"
      "debug" -> "ghost"
      "low" -> "ghost"
      _ -> "ghost"
    end
  end

  defp severity_variant(_), do: "ghost"
end
