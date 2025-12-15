defmodule ServiceRadarWebNGWeb.AnalyticsLive.Index do
  use ServiceRadarWebNGWeb, :live_view

  @default_events_limit 500
  @default_logs_limit 500

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
     |> assign(:loading, true)
     |> assign(:error, nil)
     |> assign(:refreshed_at, nil)
     |> assign(:stats, %{})
     |> assign(:device_availability, %{})
     |> assign(:events_summary, %{})
     |> assign(:logs_summary, %{})}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, load_analytics(socket)}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, load_analytics(assign(socket, :loading, true))}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp load_analytics(socket) do
    srql_module = srql_module()

    queries = %{
      devices_total: "in:devices stats:count() as total",
      devices_online: "in:devices is_available:true stats:count() as online",
      devices_offline: "in:devices is_available:false stats:count() as offline",
      services_failing: "in:services available:false time:last_24h stats:count() as failing",
      services_high_latency:
        "in:services type:icmp response_time:[100000000,] time:last_24h stats:count() as high_latency",
      events: "in:events time:last_24h sort:event_timestamp:desc limit:#{@default_events_limit}",
      logs: "in:logs time:last_24h sort:timestamp:desc limit:#{@default_logs_limit}"
    }

    results =
      queries
      |> Task.async_stream(
        fn {key, query} -> {key, srql_module.query(query)} end,
        ordered: false,
        timeout: 30_000
      )
      |> Enum.reduce(%{}, fn
        {:ok, {key, result}}, acc -> Map.put(acc, key, result)
        {:exit, reason}, acc -> Map.put(acc, :error, "query task exit: #{inspect(reason)}")
      end)

    {stats, device_availability, events_summary, logs_summary, error} = build_assigns(results)

    socket
    |> assign(:stats, stats)
    |> assign(:device_availability, device_availability)
    |> assign(:events_summary, events_summary)
    |> assign(:logs_summary, logs_summary)
    |> assign(:refreshed_at, DateTime.utc_now())
    |> assign(:error, error)
    |> assign(:loading, false)
  end

  defp build_assigns(results) do
    total_devices = extract_count(results[:devices_total])
    online_devices = extract_count(results[:devices_online])
    offline_devices = extract_count(results[:devices_offline])
    failing_services = extract_count(results[:services_failing])
    high_latency_services = extract_count(results[:services_high_latency])

    stats = %{
      total_devices: total_devices,
      offline_devices: offline_devices,
      high_latency_services: high_latency_services,
      failing_services: failing_services
    }

    availability_pct =
      if total_devices > 0 do
        Float.round(online_devices / total_devices * 100, 1)
      else
        100.0
      end

    device_availability = %{
      online: online_devices,
      offline: offline_devices,
      total: total_devices,
      availability_pct: availability_pct
    }

    events_rows = extract_rows(results[:events])
    logs_rows = extract_rows(results[:logs])

    events_summary = build_events_summary(events_rows)
    logs_summary = build_logs_summary(logs_rows)

    error =
      Enum.find_value(results, fn
        {:error, reason} -> format_error(reason)
        {_key, {:error, reason}} -> format_error(reason)
        _ -> nil
      end)

    {stats, device_availability, events_summary, logs_summary, error}
  end

  defp extract_rows({:ok, %{"results" => rows}}) when is_list(rows), do: rows
  defp extract_rows(_), do: []

  defp extract_count({:ok, %{"results" => [value | _]}}) do
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
          v when is_integer(v) -> v
          v when is_float(v) -> trunc(v)
          v when is_binary(v) ->
            case Integer.parse(String.trim(v)) do
              {parsed, ""} -> parsed
              _ -> 0
            end
          _ -> 0
        end

      _ ->
        0
    end
  end

  defp extract_count(_), do: 0

  defp build_events_summary(rows) when is_list(rows) do
    counts =
      rows
      |> Enum.filter(&is_map/1)
      |> Enum.reduce(%{critical: 0, high: 0, medium: 0, low: 0}, fn row, acc ->
        severity = row |> Map.get("severity") |> normalize_severity()

        case severity do
          "Critical" -> Map.update!(acc, :critical, &(&1 + 1))
          "High" -> Map.update!(acc, :high, &(&1 + 1))
          "Medium" -> Map.update!(acc, :medium, &(&1 + 1))
          "Low" -> Map.update!(acc, :low, &(&1 + 1))
          _ -> acc
        end
      end)

    recent =
      rows
      |> Enum.filter(&is_map/1)
      |> Enum.filter(fn row ->
        severity = row |> Map.get("severity") |> normalize_severity()
        severity in ["Critical", "High"]
      end)
      |> Enum.take(5)

    Map.merge(counts, %{total: length(rows), recent: recent})
  end

  defp build_events_summary(_), do: %{critical: 0, high: 0, medium: 0, low: 0, total: 0, recent: []}

  defp build_logs_summary(rows) when is_list(rows) do
    counts =
      rows
      |> Enum.filter(&is_map/1)
      |> Enum.reduce(%{fatal: 0, error: 0, warning: 0, info: 0, debug: 0}, fn row, acc ->
        severity = row |> Map.get("severity_text") |> normalize_log_level()

        case severity do
          "Fatal" -> Map.update!(acc, :fatal, &(&1 + 1))
          "Error" -> Map.update!(acc, :error, &(&1 + 1))
          "Warning" -> Map.update!(acc, :warning, &(&1 + 1))
          "Info" -> Map.update!(acc, :info, &(&1 + 1))
          "Debug" -> Map.update!(acc, :debug, &(&1 + 1))
          _ -> acc
        end
      end)

    recent =
      rows
      |> Enum.filter(&is_map/1)
      |> Enum.filter(fn row ->
        severity = row |> Map.get("severity_text") |> normalize_log_level()
        severity in ["Fatal", "Error"]
      end)
      |> Enum.take(5)

    Map.merge(counts, %{total: length(rows), recent: recent})
  end

  defp build_logs_summary(_), do: %{fatal: 0, error: 0, warning: 0, info: 0, debug: 0, total: 0, recent: []}

  defp normalize_severity(nil), do: ""

  defp normalize_severity(value) do
    case value |> to_string() |> String.trim() |> String.downcase() do
      "critical" -> "Critical"
      "high" -> "High"
      "medium" -> "Medium"
      "low" -> "Low"
      _ -> ""
    end
  end

  defp normalize_log_level(nil), do: ""

  defp normalize_log_level(value) do
    case value |> to_string() |> String.trim() |> String.downcase() do
      "fatal" -> "Fatal"
      "error" -> "Error"
      "warn" -> "Warning"
      "warning" -> "Warning"
      "info" -> "Info"
      "debug" -> "Debug"
      "trace" -> "Debug"
      _ -> ""
    end
  end

  defp format_error(%Jason.DecodeError{} = err), do: Exception.message(err)
  defp format_error(%ArgumentError{} = err), do: Exception.message(err)
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

  defp srql_module do
    Application.get_env(:serviceradar_web_ng, :srql_module, ServiceRadarWebNG.SRQL)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} srql={@srql}>
      <div class="mx-auto max-w-7xl">
        <div class="flex items-start justify-between gap-4 flex-wrap mb-6">
          <div class="min-w-0">
            <h1 class="text-2xl font-semibold tracking-tight">Analytics</h1>
            <p class="text-sm text-base-content/70 mt-1">
              Network health overview with drill-down into details.
            </p>
          </div>

          <.ui_button variant="primary" size="sm" phx-click="refresh" class="gap-2">
            <span :if={@loading} class="loading loading-spinner loading-xs" />
            <.icon name="hero-arrow-path" class="size-4 opacity-80" /> Refresh
          </.ui_button>
        </div>

        <div :if={is_binary(@error)} class="mb-6">
          <div role="alert" class="alert alert-error">
            <.icon name="hero-exclamation-triangle" class="size-5" />
            <span class="text-sm">{@error}</span>
          </div>
        </div>

        <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-4 mb-6">
          <.stat_card
            title="Total Devices"
            value={Map.get(@stats, :total_devices, 0)}
            icon="hero-server"
            href={~p"/devices"}
          />
          <.stat_card
            title="Offline Devices"
            value={Map.get(@stats, :offline_devices, 0)}
            icon="hero-signal-slash"
            tone="error"
            href={~p"/devices?#{%{q: "in:devices is_available:false sort:last_seen:desc limit:100"}}"}
          />
          <.stat_card
            title="High Latency Services"
            value={Map.get(@stats, :high_latency_services, 0)}
            subtitle="> 100ms"
            icon="hero-clock"
            tone={if Map.get(@stats, :high_latency_services, 0) > 0, do: "warning", else: "neutral"}
            href={~p"/services?#{%{q: "in:services type:icmp response_time:[100000000,] sort:timestamp:desc limit:100"}}"}
          />
          <.stat_card
            title="Failing Services"
            value={Map.get(@stats, :failing_services, 0)}
            icon="hero-exclamation-triangle"
            tone="error"
            href={~p"/services?#{%{q: "in:services available:false sort:timestamp:desc limit:100"}}"}
          />
        </div>

        <h2 class="text-lg font-semibold mb-4">Network & Performance Analytics</h2>

        <div class="grid grid-cols-1 lg:grid-cols-2 xl:grid-cols-3 gap-6">
          <.device_availability_widget availability={@device_availability} loading={@loading} />
          <.critical_events_widget summary={@events_summary} loading={@loading} />
          <.critical_logs_widget summary={@logs_summary} loading={@loading} />
        </div>

        <div class="mt-6 text-xs text-base-content/60 flex items-center justify-between gap-3 flex-wrap">
          <div>
            <span class="font-semibold">Updated:</span>
            <span :if={is_struct(@refreshed_at, DateTime)} class="font-mono">
              {Calendar.strftime(@refreshed_at, "%Y-%m-%d %H:%M:%S UTC")}
            </span>
            <span :if={not is_struct(@refreshed_at, DateTime)}>—</span>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :title, :string, required: true
  attr :value, :any, required: true
  attr :subtitle, :string, default: nil
  attr :href, :string, required: true
  attr :icon, :string, default: nil
  attr :tone, :string, default: "neutral"

  def stat_card(assigns) do
    ~H"""
    <.link href={@href} class="block group">
      <div class={[
        "rounded-xl border bg-base-100 p-4 flex items-center gap-4",
        "hover:shadow-md transition-shadow cursor-pointer",
        tone_border(@tone)
      ]}>
        <div class={["p-3 rounded-lg", tone_bg(@tone)]}>
          <.icon :if={@icon} name={@icon} class={["size-6", tone_icon(@tone)]} />
        </div>
        <div class="flex-1 min-w-0">
          <div class={["text-2xl font-bold", tone_value(@tone)]}>
            {format_number(@value)}
          </div>
          <div class="text-sm text-base-content/60">
            {@title}
            <span :if={@subtitle} class="text-base-content/40"> | {@subtitle}</span>
          </div>
        </div>
      </div>
    </.link>
    """
  end

  defp tone_border("error"), do: "border-error/30"
  defp tone_border("warning"), do: "border-warning/30"
  defp tone_border("success"), do: "border-success/30"
  defp tone_border(_), do: "border-base-200"

  defp tone_bg("error"), do: "bg-error/10"
  defp tone_bg("warning"), do: "bg-warning/10"
  defp tone_bg("success"), do: "bg-success/10"
  defp tone_bg(_), do: "bg-primary/10"

  defp tone_icon("error"), do: "text-error"
  defp tone_icon("warning"), do: "text-warning"
  defp tone_icon("success"), do: "text-success"
  defp tone_icon(_), do: "text-primary"

  defp tone_value("error"), do: "text-error"
  defp tone_value("warning"), do: "text-warning"
  defp tone_value("success"), do: "text-success"
  defp tone_value(_), do: "text-base-content"

  defp format_number(n) when is_integer(n) and n >= 1000 do
    n |> Integer.to_string() |> add_commas()
  end

  defp format_number(n) when is_integer(n), do: Integer.to_string(n)
  defp format_number(n) when is_float(n), do: n |> trunc() |> format_number()
  defp format_number(_), do: "0"

  defp add_commas(str) do
    str
    |> String.reverse()
    |> String.graphemes()
    |> Enum.chunk_every(3)
    |> Enum.join(",")
    |> String.reverse()
  end

  attr :availability, :map, required: true
  attr :loading, :boolean, default: false

  def device_availability_widget(assigns) do
    total = Map.get(assigns.availability, :total, 0)
    online = Map.get(assigns.availability, :online, 0)
    offline = Map.get(assigns.availability, :offline, 0)
    pct = Map.get(assigns.availability, :availability_pct, 100.0)

    online_pct = if total > 0, do: Float.round(online / total * 100, 0), else: 100
    offline_pct = if total > 0, do: Float.round(offline / total * 100, 0), else: 0

    assigns =
      assigns
      |> assign(:online, online)
      |> assign(:offline, offline)
      |> assign(:total, total)
      |> assign(:pct, pct)
      |> assign(:online_pct, online_pct)
      |> assign(:offline_pct, offline_pct)

    ~H"""
    <.ui_panel class="h-80">
      <:header>
        <.link href={~p"/devices"} class="hover:text-primary transition-colors">
          <div class="text-sm font-semibold">Device Availability</div>
        </.link>
        <.link
          href={~p"/devices?#{%{q: "in:devices is_available:false sort:last_seen:desc limit:100"}}"}
          class="text-base-content/60 hover:text-primary"
          title="View offline devices"
        >
          <.icon name="hero-arrow-top-right-on-square" class="size-4" />
        </.link>
      </:header>

      <div :if={@loading} class="flex-1 flex items-center justify-center">
        <span class="loading loading-spinner loading-md" />
      </div>

      <div :if={not @loading} class="flex items-center gap-6 h-full">
        <div class="flex-1">
          <div class="relative w-32 h-32 mx-auto">
            <svg viewBox="0 0 36 36" class="w-full h-full -rotate-90">
              <circle
                cx="18"
                cy="18"
                r="15.5"
                fill="none"
                stroke="currentColor"
                stroke-width="3"
                class="text-error/30"
              />
              <circle
                cx="18"
                cy="18"
                r="15.5"
                fill="none"
                stroke="currentColor"
                stroke-width="3"
                stroke-dasharray={~s(#{@online_pct} #{100 - @online_pct})}
                class="text-success"
              />
            </svg>
            <div class="absolute inset-0 flex flex-col items-center justify-center">
              <span class="text-2xl font-bold">{Float.round(@pct, 1)}%</span>
              <span class="text-xs text-base-content/60">Availability</span>
            </div>
          </div>
        </div>

        <div class="flex-1 space-y-3">
          <div class="flex items-center justify-between">
            <div class="flex items-center gap-2">
              <span class="w-3 h-3 rounded-full bg-success" />
              <span class="text-sm">Online</span>
            </div>
            <span class="font-semibold">{format_number(@online)}</span>
          </div>
          <div class="flex items-center justify-between">
            <div class="flex items-center gap-2">
              <span class="w-3 h-3 rounded-full bg-error" />
              <span class="text-sm">Offline</span>
            </div>
            <span class="font-semibold">{format_number(@offline)}</span>
          </div>

          <div :if={@offline > 0} class="mt-4 p-2 rounded-lg bg-error/10">
            <div class="flex items-center gap-2 text-error text-sm">
              <.icon name="hero-signal-slash" class="size-4" />
              <span>{@offline} device{if @offline != 1, do: "s", else: ""} offline</span>
            </div>
          </div>
        </div>
      </div>
    </.ui_panel>
    """
  end

  attr :summary, :map, required: true
  attr :loading, :boolean, default: false

  def critical_events_widget(assigns) do
    ~H"""
    <.ui_panel class="h-80 flex flex-col">
      <:header>
        <.link href={~p"/events"} class="hover:text-primary transition-colors">
          <div class="text-sm font-semibold">Critical Events</div>
        </.link>
        <.link
          href={~p"/events?#{%{q: "in:events severity:(Critical,High) time:last_24h sort:event_timestamp:desc limit:100"}}"}
          class="text-base-content/60 hover:text-primary"
          title="View critical events"
        >
          <.icon name="hero-arrow-top-right-on-square" class="size-4" />
        </.link>
      </:header>

      <div :if={@loading} class="flex-1 flex items-center justify-center">
        <span class="loading loading-spinner loading-md" />
      </div>

      <div :if={not @loading} class="flex-1 flex flex-col min-h-0">
        <table class="table table-xs mb-3">
          <thead>
            <tr class="border-b border-base-200">
              <th class="text-xs font-medium text-base-content/60">Severity</th>
              <th class="text-center text-xs font-medium text-base-content/60">Count</th>
              <th class="text-center text-xs font-medium text-base-content/60">%</th>
            </tr>
          </thead>
          <tbody>
            <.severity_row
              label="Critical"
              count={Map.get(@summary, :critical, 0)}
              total={Map.get(@summary, :total, 0)}
              color="error"
              href={~p"/events?#{%{q: "in:events severity:Critical time:last_24h sort:event_timestamp:desc limit:100"}}"}
            />
            <.severity_row
              label="High"
              count={Map.get(@summary, :high, 0)}
              total={Map.get(@summary, :total, 0)}
              color="warning"
              href={~p"/events?#{%{q: "in:events severity:High time:last_24h sort:event_timestamp:desc limit:100"}}"}
            />
            <.severity_row
              label="Medium"
              count={Map.get(@summary, :medium, 0)}
              total={Map.get(@summary, :total, 0)}
              color="info"
              href={~p"/events?#{%{q: "in:events severity:Medium time:last_24h sort:event_timestamp:desc limit:100"}}"}
            />
            <.severity_row
              label="Low"
              count={Map.get(@summary, :low, 0)}
              total={Map.get(@summary, :total, 0)}
              color="primary"
              href={~p"/events?#{%{q: "in:events severity:Low time:last_24h sort:event_timestamp:desc limit:100"}}"}
            />
          </tbody>
        </table>

        <div :if={Map.get(@summary, :recent, []) == []} class="flex-1 flex items-center justify-center text-center">
          <div>
            <.icon name="hero-shield-check" class="size-8 mx-auto mb-2 text-success" />
            <p class="text-sm text-base-content/60">No critical events</p>
            <p class="text-xs text-base-content/40 mt-1">All systems reporting normally</p>
          </div>
        </div>

        <div :if={Map.get(@summary, :recent, []) != []} class="flex-1 overflow-y-auto space-y-2">
          <%= for event <- Map.get(@summary, :recent, []) do %>
            <.event_entry event={event} />
          <% end %>
        </div>
      </div>
    </.ui_panel>
    """
  end

  attr :summary, :map, required: true
  attr :loading, :boolean, default: false

  def critical_logs_widget(assigns) do
    ~H"""
    <.ui_panel class="h-80 flex flex-col">
      <:header>
        <.link href={~p"/logs"} class="hover:text-primary transition-colors">
          <div class="text-sm font-semibold">Critical Logs</div>
        </.link>
        <.link
          href={~p"/logs?#{%{q: "in:logs severity_text:(fatal,error,FATAL,ERROR) time:last_24h sort:timestamp:desc limit:100"}}"}
          class="text-base-content/60 hover:text-primary"
          title="View critical logs"
        >
          <.icon name="hero-arrow-top-right-on-square" class="size-4" />
        </.link>
      </:header>

      <div :if={@loading} class="flex-1 flex items-center justify-center">
        <span class="loading loading-spinner loading-md" />
      </div>

      <div :if={not @loading} class="flex-1 flex flex-col min-h-0">
        <table class="table table-xs mb-3">
          <thead>
            <tr class="border-b border-base-200">
              <th class="text-xs font-medium text-base-content/60">Level</th>
              <th class="text-center text-xs font-medium text-base-content/60">Count</th>
              <th class="text-center text-xs font-medium text-base-content/60">%</th>
            </tr>
          </thead>
          <tbody>
            <.severity_row
              label="Fatal"
              count={Map.get(@summary, :fatal, 0)}
              total={Map.get(@summary, :total, 0)}
              color="error"
              href={~p"/logs?#{%{q: "in:logs severity_text:(fatal,FATAL) time:last_24h sort:timestamp:desc limit:100"}}"}
            />
            <.severity_row
              label="Error"
              count={Map.get(@summary, :error, 0)}
              total={Map.get(@summary, :total, 0)}
              color="warning"
              href={~p"/logs?#{%{q: "in:logs severity_text:(error,ERROR) time:last_24h sort:timestamp:desc limit:100"}}"}
            />
            <.severity_row
              label="Warning"
              count={Map.get(@summary, :warning, 0)}
              total={Map.get(@summary, :total, 0)}
              color="info"
              href={~p"/logs?#{%{q: "in:logs severity_text:(warning,warn,WARNING,WARN) time:last_24h sort:timestamp:desc limit:100"}}"}
            />
            <.severity_row
              label="Info"
              count={Map.get(@summary, :info, 0)}
              total={Map.get(@summary, :total, 0)}
              color="primary"
              href={~p"/logs?#{%{q: "in:logs severity_text:(info,INFO) time:last_24h sort:timestamp:desc limit:100"}}"}
            />
            <.severity_row
              label="Debug"
              count={Map.get(@summary, :debug, 0)}
              total={Map.get(@summary, :total, 0)}
              color="neutral"
              href={~p"/logs?#{%{q: "in:logs severity_text:(debug,trace,DEBUG,TRACE) time:last_24h sort:timestamp:desc limit:100"}}"}
            />
          </tbody>
        </table>

        <div :if={Map.get(@summary, :recent, []) == []} class="flex-1 flex items-center justify-center text-center">
          <div>
            <.icon name="hero-document-check" class="size-8 mx-auto mb-2 text-success" />
            <p class="text-sm text-base-content/60">No fatal or error logs</p>
            <p class="text-xs text-base-content/40 mt-1">All systems logging normally</p>
          </div>
        </div>

        <div :if={Map.get(@summary, :recent, []) != []} class="flex-1 overflow-y-auto space-y-2">
          <%= for log <- Map.get(@summary, :recent, []) do %>
            <.log_entry log={log} />
          <% end %>
        </div>
      </div>
    </.ui_panel>
    """
  end

  attr :label, :string, required: true
  attr :count, :integer, required: true
  attr :total, :integer, required: true
  attr :color, :string, required: true
  attr :href, :string, required: true

  def severity_row(assigns) do
    pct = if assigns.total > 0, do: round(assigns.count / assigns.total * 100), else: 0
    assigns = assign(assigns, :pct, pct)

    ~H"""
    <tr class="hover:bg-base-200/50 cursor-pointer" onclick={"window.location.href='#{@href}'"}>
      <td class={severity_text_class(@color)}>{@label}</td>
      <td class={["text-center font-bold", severity_text_class(@color)]}>{format_number(@count)}</td>
      <td class={["text-center text-xs", severity_text_class(@color)]}>{@pct}%</td>
    </tr>
    """
  end

  defp severity_text_class("error"), do: "text-error"
  defp severity_text_class("warning"), do: "text-warning"
  defp severity_text_class("info"), do: "text-info"
  defp severity_text_class("primary"), do: "text-primary"
  defp severity_text_class(_), do: "text-base-content/60"

  attr :event, :map, required: true

  def event_entry(assigns) do
    ~H"""
    <div class="p-2 rounded-lg bg-base-200/50 hover:bg-base-200 transition-colors">
      <div class="flex items-start gap-2">
        <.icon name={severity_icon(@event["severity"])} class={["size-4 mt-0.5", severity_text_class(severity_color(@event["severity"]))]} />
        <div class="flex-1 min-w-0">
          <div class="text-sm font-medium truncate">{@event["host"] || "Unknown"}</div>
          <div class="text-xs text-base-content/60 truncate">{@event["short_message"] || "No details"}</div>
          <div class={["text-xs", severity_text_class(severity_color(@event["severity"]))]}>
            {@event["severity"] || "Unknown"} · {format_relative_time(@event["event_timestamp"])}
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :log, :map, required: true

  def log_entry(assigns) do
    ~H"""
    <div class="p-2 rounded-lg bg-base-200/50 hover:bg-base-200 transition-colors">
      <div class="flex items-start gap-2">
        <.icon name={log_level_icon(@log["severity_text"])} class={["size-4 mt-0.5", severity_text_class(log_level_color(@log["severity_text"]))]} />
        <div class="flex-1 min-w-0">
          <div class="text-sm font-medium truncate">{@log["service_name"] || "Unknown Service"}</div>
          <div class="text-xs text-base-content/60 truncate">{truncate_message(@log["body"])}</div>
          <div class={["text-xs", severity_text_class(log_level_color(@log["severity_text"]))]}>
            {normalize_log_level(@log["severity_text"])} · {format_relative_time(@log["timestamp"])}
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp severity_icon(severity) do
    case normalize_severity(severity) do
      "Critical" -> "hero-shield-exclamation"
      "High" -> "hero-exclamation-triangle"
      "Medium" -> "hero-exclamation-circle"
      "Low" -> "hero-information-circle"
      _ -> "hero-exclamation-circle"
    end
  end

  defp severity_color(severity) do
    case normalize_severity(severity) do
      "Critical" -> "error"
      "High" -> "warning"
      "Medium" -> "info"
      "Low" -> "primary"
      _ -> "neutral"
    end
  end

  defp log_level_icon(level) do
    case normalize_log_level(level) do
      "Fatal" -> "hero-x-circle"
      "Error" -> "hero-exclamation-circle"
      "Warning" -> "hero-exclamation-triangle"
      "Info" -> "hero-information-circle"
      "Debug" -> "hero-document-text"
      _ -> "hero-document-text"
    end
  end

  defp log_level_color(level) do
    case normalize_log_level(level) do
      "Fatal" -> "error"
      "Error" -> "warning"
      "Warning" -> "info"
      "Info" -> "primary"
      _ -> "neutral"
    end
  end

  defp truncate_message(nil), do: ""
  defp truncate_message(msg) when is_binary(msg) do
    if String.length(msg) > 80 do
      String.slice(msg, 0, 80) <> "..."
    else
      msg
    end
  end
  defp truncate_message(_), do: ""

  defp format_relative_time(nil), do: "Unknown"

  defp format_relative_time(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, dt, _offset} ->
        now = DateTime.utc_now()
        diff_seconds = DateTime.diff(now, dt, :second)

        cond do
          diff_seconds < 60 -> "Just now"
          diff_seconds < 3600 -> "#{div(diff_seconds, 60)}m ago"
          diff_seconds < 86400 -> "#{div(diff_seconds, 3600)}h ago"
          diff_seconds < 604_800 -> "#{div(diff_seconds, 86400)}d ago"
          true -> Calendar.strftime(dt, "%b %d")
        end

      _ ->
        "Unknown"
    end
  end

  defp format_relative_time(_), do: "Unknown"
end
