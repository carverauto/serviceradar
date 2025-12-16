defmodule ServiceRadarWebNGWeb.AnalyticsLive.Index do
  use ServiceRadarWebNGWeb, :live_view

  @default_events_limit 500
  @default_logs_limit 500
  @default_metrics_limit 100
  @refresh_interval_ms :timer.seconds(30)

  @impl true
  def mount(_params, _session, socket) do
    srql = %{
      enabled: false,
      page_path: "/analytics"
    }

    # Schedule auto-refresh if connected
    if connected?(socket), do: schedule_refresh()

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
     |> assign(:logs_summary, %{})
     |> assign(:observability, %{})
     |> assign(:high_utilization, %{})
     |> assign(:bandwidth, %{})}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, load_analytics(socket)}
  end

  @impl true
  def handle_info(:refresh_data, socket) do
    schedule_refresh()
    {:noreply, load_analytics(socket)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp schedule_refresh do
    Process.send_after(self(), :refresh_data, @refresh_interval_ms)
  end

  defp load_analytics(socket) do
    srql_module = srql_module()

    queries = %{
      devices_total: ~s|in:devices stats:"count() as total"|,
      devices_online: ~s|in:devices is_available:true stats:"count() as online"|,
      devices_offline: ~s|in:devices is_available:false stats:"count() as offline"|,
      # Get unique services by service_name in the last hour (most recent status)
      services_list: "in:services time:last_1h sort:timestamp:desc limit:500",
      events: "in:events time:last_24h sort:event_timestamp:desc limit:#{@default_events_limit}",
      logs_recent: "in:logs time:last_24h sort:timestamp:desc limit:#{@default_logs_limit}",
      logs_total: ~s|in:logs time:last_24h stats:"count() as total"|,
      logs_fatal: ~s|in:logs time:last_24h severity_text:(fatal,FATAL) stats:"count() as fatal"|,
      logs_error: ~s|in:logs time:last_24h severity_text:(error,ERROR) stats:"count() as error"|,
      logs_warning:
        ~s|in:logs time:last_24h severity_text:(warning,warn,WARNING,WARN) stats:"count() as warning"|,
      logs_info: ~s|in:logs time:last_24h severity_text:(info,INFO) stats:"count() as info"|,
      logs_debug:
        ~s|in:logs time:last_24h severity_text:(debug,trace,DEBUG,TRACE) stats:"count() as debug"|,
      # Observability summary (match legacy UI: last_24h window, trace summaries not raw spans)
      metrics_count: ~s|in:otel_metrics time:last_24h stats:"count() as total"|,
      trace_stats:
        "in:otel_trace_summaries time:last_24h " <>
          ~s|stats:"count() as total, sum(if(status_code != 1, 1, 0)) as error_traces, sum(if(duration_ms > 100, 1, 0)) as slow_traces"|,
      slow_traces: "in:otel_trace_summaries time:last_24h sort:duration_ms:desc limit:25",
      # High utilization - get recent CPU metrics
      cpu_metrics:
        "in:cpu_metrics time:last_1h sort:timestamp:desc limit:#{@default_metrics_limit}",
      # High utilization - get recent Memory metrics
      memory_metrics:
        "in:memory_metrics time:last_1h sort:timestamp:desc limit:#{@default_metrics_limit}",
      # High utilization - get recent Disk metrics
      disk_metrics:
        "in:disk_metrics time:last_1h sort:timestamp:desc limit:#{@default_metrics_limit}"
      # TODO: Re-enable when backend supports rperf_targets entity
      # rperf_targets: "in:rperf_targets time:last_1h sort:timestamp:desc limit:50"
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

    {stats, device_availability, events_summary, logs_summary, observability, high_utilization,
     bandwidth, error} =
      build_assigns(results)

    socket
    |> assign(:stats, stats)
    |> assign(:device_availability, device_availability)
    |> assign(:events_summary, events_summary)
    |> assign(:logs_summary, logs_summary)
    |> assign(:observability, observability)
    |> assign(:high_utilization, high_utilization)
    |> assign(:bandwidth, bandwidth)
    |> assign(:refreshed_at, DateTime.utc_now())
    |> assign(:error, error)
    |> assign(:loading, false)
  end

  defp build_assigns(results) do
    total_devices = extract_count(results[:devices_total])
    online_devices = extract_count(results[:devices_online])
    offline_devices = extract_count(results[:devices_offline])

    # Calculate unique services from the services list
    services_rows = extract_rows(results[:services_list])
    {unique_services, failing_services} = count_unique_services(services_rows)

    stats = %{
      total_devices: total_devices,
      offline_devices: offline_devices,
      total_services: unique_services,
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
    events_summary = build_events_summary(events_rows)

    logs_rows = extract_rows(results[:logs_recent])

    logs_counts = %{
      total: extract_count(results[:logs_total]),
      fatal: extract_count(results[:logs_fatal]),
      error: extract_count(results[:logs_error]),
      warning: extract_count(results[:logs_warning]),
      info: extract_count(results[:logs_info]),
      debug: extract_count(results[:logs_debug])
    }

    logs_summary = build_logs_summary(logs_rows, logs_counts)

    # Build observability summary with real counts from stats queries
    metrics_total = extract_count(results[:metrics_count])
    trace_stats = extract_map(results[:trace_stats])
    slow_traces_rows = extract_rows(results[:slow_traces])
    observability = build_observability_summary(metrics_total, trace_stats, slow_traces_rows)

    # Build high utilization summary from CPU, Memory, and Disk metrics
    cpu_metrics_rows = extract_rows(results[:cpu_metrics])
    memory_metrics_rows = extract_rows(results[:memory_metrics])
    disk_metrics_rows = extract_rows(results[:disk_metrics])

    high_utilization =
      build_high_utilization_summary(cpu_metrics_rows, memory_metrics_rows, disk_metrics_rows)

    # Bandwidth summary (disabled until rperf_targets entity is supported)
    bandwidth = %{
      targets: [],
      total_download: 0.0,
      total_upload: 0.0,
      avg_latency: 0.0,
      target_count: 0
    }

    error =
      Enum.find_value(results, fn
        {:error, reason} -> format_error(reason)
        {_key, {:error, reason}} -> format_error(reason)
        _ -> nil
      end)

    {stats, device_availability, events_summary, logs_summary, observability, high_utilization,
     bandwidth, error}
  end

  defp extract_rows({:ok, %{"results" => rows}}) when is_list(rows), do: rows
  defp extract_rows(_), do: []

  defp extract_map({:ok, %{"results" => [%{} = row | _]}}), do: row
  defp extract_map(_), do: %{}

  defp count_unique_services(rows) when is_list(rows) do
    # Group by service_name and get most recent status for each
    services_by_name =
      rows
      |> Enum.filter(&is_map/1)
      |> Enum.reduce(%{}, fn row, acc ->
        service_name = Map.get(row, "service_name")
        device_id = Map.get(row, "device_id")
        # Use composite key of device_id + service_name to identify unique service instances
        key = "#{device_id}:#{service_name}"

        if is_binary(service_name) and service_name != "" do
          # Keep most recent entry per service (rows are sorted by timestamp desc)
          Map.put_new(acc, key, row)
        else
          acc
        end
      end)

    unique_count = map_size(services_by_name)

    failing_count =
      services_by_name
      |> Map.values()
      |> Enum.count(fn row ->
        Map.get(row, "available") == false
      end)

    {unique_count, failing_count}
  end

  defp count_unique_services(_), do: {0, 0}

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

  defp build_events_summary(_),
    do: %{critical: 0, high: 0, medium: 0, low: 0, total: 0, recent: []}

  defp build_logs_summary(rows, %{} = counts) when is_list(rows) do
    recent =
      rows
      |> Enum.filter(&is_map/1)
      |> Enum.filter(fn row ->
        severity = row |> Map.get("severity_text") |> normalize_log_level()
        severity in ["Fatal", "Error"]
      end)
      |> Enum.take(5)

    counts
    |> Map.take([:total, :fatal, :error, :warning, :info, :debug])
    |> Map.put(:recent, recent)
  end

  defp build_logs_summary(_rows, _counts),
    do: %{fatal: 0, error: 0, warning: 0, info: 0, debug: 0, total: 0, recent: []}

  defp build_observability_summary(metrics_count, trace_stats, slow_traces)
       when is_integer(metrics_count) and is_map(trace_stats) and is_list(slow_traces) do
    trace_stats =
      case Map.get(trace_stats, "payload") do
        %{} = payload -> payload
        _ -> trace_stats
      end

    traces_count =
      extract_numeric(Map.get(trace_stats, "total") || Map.get(trace_stats, "count")) |> to_int()

    error_traces =
      extract_numeric(Map.get(trace_stats, "error_traces") || Map.get(trace_stats, "errors"))
      |> to_int()

    slow_traces_count =
      extract_numeric(Map.get(trace_stats, "slow_traces") || Map.get(trace_stats, "slow"))
      |> to_int()

    error_rate =
      if traces_count > 0 do
        Float.round(error_traces / traces_count * 100.0, 1)
      else
        0.0
      end

    # Trace summary stats don't currently support avg() in SRQL.
    avg_duration = 0

    slow_spans =
      slow_traces
      |> Enum.filter(&is_map/1)
      |> Enum.take(5)

    %{
      metrics_count: metrics_count,
      traces_count: traces_count,
      avg_duration: avg_duration,
      error_rate: error_rate,
      slow_spans_count: slow_traces_count,
      slow_spans: slow_spans
    }
  end

  defp build_observability_summary(_, _, _),
    do: %{
      metrics_count: 0,
      traces_count: 0,
      avg_duration: 0,
      error_rate: 0.0,
      slow_spans_count: 0,
      slow_spans: []
    }

  defp to_int(value) when is_integer(value), do: value
  defp to_int(value) when is_float(value), do: trunc(value)
  defp to_int(_), do: 0

  defp build_high_utilization_summary(cpu_rows, memory_rows, disk_rows)
       when is_list(cpu_rows) and is_list(memory_rows) and is_list(disk_rows) do
    # Deduplicate CPU by host, keeping most recent
    unique_cpu_hosts =
      cpu_rows
      |> Enum.filter(&is_map/1)
      |> Enum.reduce(%{}, fn row, acc ->
        host = Map.get(row, "host") || Map.get(row, "device_id") || ""
        if host != "", do: Map.put_new(acc, host, row), else: acc
      end)
      |> Map.values()

    # Deduplicate Memory by host, keeping most recent
    unique_memory_hosts =
      memory_rows
      |> Enum.filter(&is_map/1)
      |> Enum.reduce(%{}, fn row, acc ->
        host = Map.get(row, "host") || Map.get(row, "device_id") || ""
        if host != "", do: Map.put_new(acc, host, row), else: acc
      end)
      |> Map.values()

    # Deduplicate Disk by host+mount, keeping most recent
    unique_disks =
      disk_rows
      |> Enum.filter(&is_map/1)
      |> Enum.reduce(%{}, fn row, acc ->
        host = Map.get(row, "host") || Map.get(row, "device_id") || ""
        mount = Map.get(row, "mount_point") || Map.get(row, "mount") || ""
        key = "#{host}:#{mount}"
        if host != "", do: Map.put_new(acc, key, row), else: acc
      end)
      |> Map.values()

    # Categorize CPU by utilization level
    cpu_categorized =
      unique_cpu_hosts
      |> Enum.reduce(%{warning: [], critical: []}, fn row, acc ->
        cpu_usage =
          extract_numeric(
            Map.get(row, "value") || Map.get(row, "cpu_usage") || Map.get(row, "usage_percent") ||
              Map.get(row, "user") || 0
          )

        cond do
          cpu_usage >= 90 -> Map.update!(acc, :critical, &[row | &1])
          cpu_usage >= 80 -> Map.update!(acc, :warning, &[row | &1])
          true -> acc
        end
      end)

    # Categorize Memory by utilization level
    memory_categorized =
      unique_memory_hosts
      |> Enum.reduce(%{warning: [], critical: []}, fn row, acc ->
        mem_usage =
          extract_numeric(
            Map.get(row, "percent") || Map.get(row, "value") || Map.get(row, "used_percent") || 0
          )

        cond do
          mem_usage >= 90 -> Map.update!(acc, :critical, &[row | &1])
          mem_usage >= 85 -> Map.update!(acc, :warning, &[row | &1])
          true -> acc
        end
      end)

    # Categorize Disk by utilization level
    disk_categorized =
      unique_disks
      |> Enum.reduce(%{warning: [], critical: []}, fn row, acc ->
        disk_usage = extract_numeric(Map.get(row, "percent") || Map.get(row, "value") || 0)

        cond do
          disk_usage >= 90 -> Map.update!(acc, :critical, &[row | &1])
          disk_usage >= 85 -> Map.update!(acc, :warning, &[row | &1])
          true -> acc
        end
      end)

    # Get top high CPU utilization hosts
    high_cpu_services =
      unique_cpu_hosts
      |> Enum.filter(fn row ->
        cpu =
          extract_numeric(
            Map.get(row, "value") || Map.get(row, "cpu_usage") || Map.get(row, "usage_percent") ||
              Map.get(row, "user") || 0
          )

        cpu >= 70
      end)
      |> Enum.sort_by(fn row ->
        cpu =
          extract_numeric(
            Map.get(row, "value") || Map.get(row, "cpu_usage") || Map.get(row, "usage_percent") ||
              Map.get(row, "user") || 0
          )

        -cpu
      end)
      |> Enum.take(3)

    # Get top high memory utilization hosts
    high_memory_services =
      unique_memory_hosts
      |> Enum.filter(fn row ->
        mem =
          extract_numeric(
            Map.get(row, "percent") || Map.get(row, "value") || Map.get(row, "used_percent") || 0
          )

        mem >= 70
      end)
      |> Enum.sort_by(fn row ->
        mem =
          extract_numeric(
            Map.get(row, "percent") || Map.get(row, "value") || Map.get(row, "used_percent") || 0
          )

        -mem
      end)
      |> Enum.take(3)

    # Get top high disk utilization
    high_disk_services =
      unique_disks
      |> Enum.filter(fn row ->
        disk = extract_numeric(Map.get(row, "percent") || Map.get(row, "value") || 0)
        disk >= 70
      end)
      |> Enum.sort_by(fn row ->
        disk = extract_numeric(Map.get(row, "percent") || Map.get(row, "value") || 0)
        -disk
      end)
      |> Enum.take(3)

    %{
      cpu_warning: length(cpu_categorized.warning),
      cpu_critical: length(cpu_categorized.critical),
      memory_warning: length(memory_categorized.warning),
      memory_critical: length(memory_categorized.critical),
      disk_warning: length(disk_categorized.warning),
      disk_critical: length(disk_categorized.critical),
      cpu_services: high_cpu_services,
      memory_services: high_memory_services,
      disk_services: high_disk_services,
      total_cpu_hosts: length(unique_cpu_hosts),
      total_memory_hosts: length(unique_memory_hosts),
      total_disk_mounts: length(unique_disks)
    }
  end

  defp build_high_utilization_summary(_, _, _),
    do: %{
      cpu_warning: 0,
      cpu_critical: 0,
      memory_warning: 0,
      memory_critical: 0,
      disk_warning: 0,
      disk_critical: 0,
      cpu_services: [],
      memory_services: [],
      disk_services: [],
      total_cpu_hosts: 0,
      total_memory_hosts: 0,
      total_disk_mounts: 0
    }

  defp extract_numeric(value) when is_number(value), do: value

  defp extract_numeric(value) when is_binary(value) do
    case Float.parse(value) do
      {num, _} -> num
      :error -> 0
    end
  end

  defp extract_numeric(_), do: 0

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
        <div :if={is_binary(@error)} class="mb-4">
          <div role="alert" class="alert alert-error">
            <.icon name="hero-exclamation-triangle" class="size-5" />
            <span class="text-sm">{@error}</span>
          </div>
        </div>

        <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-3 mb-4">
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
            tone={if Map.get(@stats, :offline_devices, 0) > 0, do: "error", else: "success"}
            href={~p"/devices?#{%{q: "in:devices is_available:false sort:last_seen:desc limit:100"}}"}
          />
          <.stat_card
            title="Active Services"
            value={Map.get(@stats, :total_services, 0)}
            subtitle="unique"
            icon="hero-wrench-screwdriver"
            href={~p"/services"}
          />
          <.stat_card
            title="Failing Services"
            value={Map.get(@stats, :failing_services, 0)}
            subtitle="unique"
            icon="hero-exclamation-triangle"
            tone={if Map.get(@stats, :failing_services, 0) > 0, do: "error", else: "success"}
            href={
              ~p"/services?#{%{q: "in:services available:false time:last_1h sort:timestamp:desc limit:100"}}"
            }
          />
        </div>

        <div class="grid grid-cols-1 lg:grid-cols-2 xl:grid-cols-3 gap-4">
          <.device_availability_widget availability={@device_availability} loading={@loading} />
          <.high_utilization_widget data={@high_utilization} loading={@loading} />
          <.bandwidth_widget data={@bandwidth} loading={@loading} />
          <.critical_logs_widget summary={@logs_summary} loading={@loading} />
          <.observability_widget data={@observability} loading={@loading} />
          <.critical_events_widget summary={@events_summary} loading={@loading} />
        </div>

        <div class="mt-3 text-xs text-base-content/40 flex items-center gap-2">
          <span :if={@loading} class="loading loading-spinner loading-xs" />
          <span :if={is_struct(@refreshed_at, DateTime)} class="font-mono">
            Updated {Calendar.strftime(@refreshed_at, "%H:%M:%S")}
          </span>
          <span class="text-base-content/30">·</span>
          <span>Auto-refresh 30s</span>
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
            <span :if={@subtitle} class="text-base-content/40">
              {" | "}
              {@subtitle}
            </span>
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

    # Ensure pct is a float for display
    pct_display = if is_number(pct), do: Float.round(pct * 1.0, 1), else: 100.0

    online_pct = if total > 0, do: Float.round(online / total * 100.0, 0), else: 100.0
    offline_pct = if total > 0, do: Float.round(offline / total * 100.0, 0), else: 0.0

    assigns =
      assigns
      |> assign(:online, online)
      |> assign(:offline, offline)
      |> assign(:total, total)
      |> assign(:pct, pct_display)
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
              <span class="text-2xl font-bold">{@pct}%</span>
              <span class="text-xs text-base-content/60">Availability</span>
            </div>
          </div>
        </div>

        <div class="flex-1 space-y-3">
          <.link
            href={~p"/devices?#{%{q: "in:devices is_available:true sort:last_seen:desc limit:20"}}"}
            class="flex items-center justify-between hover:bg-base-200/50 rounded-lg p-2 -m-2 transition-colors"
          >
            <div class="flex items-center gap-2">
              <span class="w-3 h-3 rounded-full bg-success" />
              <span class="text-sm">Online</span>
            </div>
            <span class="font-semibold">{format_number(@online)}</span>
          </.link>
          <.link
            href={~p"/devices?#{%{q: "in:devices is_available:false sort:last_seen:desc limit:20"}}"}
            class="flex items-center justify-between hover:bg-base-200/50 rounded-lg p-2 -m-2 transition-colors"
          >
            <div class="flex items-center gap-2">
              <span class="w-3 h-3 rounded-full bg-error" />
              <span class="text-sm">Offline</span>
            </div>
            <span class="font-semibold">{format_number(@offline)}</span>
          </.link>

          <.link
            :if={@offline > 0}
            href={~p"/devices?#{%{q: "in:devices is_available:false sort:last_seen:desc limit:20"}}"}
            class="block mt-4 p-2 rounded-lg bg-error/10 hover:bg-error/20 transition-colors"
          >
            <div class="flex items-center gap-2 text-error text-sm">
              <.icon name="hero-signal-slash" class="size-4" />
              <span>{@offline} device{if @offline != 1, do: "s", else: ""} offline</span>
            </div>
          </.link>
        </div>
      </div>
    </.ui_panel>
    """
  end

  attr :summary, :map, required: true
  attr :loading, :boolean, default: false

  def critical_events_widget(assigns) do
    ~H"""
    <div class="h-80 rounded-xl border border-base-200 bg-base-100 shadow-sm flex flex-col overflow-hidden">
      <header class="px-4 py-3 bg-base-200/40 flex items-start justify-between gap-3 shrink-0">
        <.link href={~p"/events"} class="hover:text-primary transition-colors">
          <div class="text-sm font-semibold">Critical Events</div>
        </.link>
        <.link
          href={
            ~p"/events?#{%{q: "in:events severity:(Critical,High) time:last_24h sort:event_timestamp:desc limit:100"}}"
          }
          class="text-base-content/60 hover:text-primary"
          title="View critical events"
        >
          <.icon name="hero-arrow-top-right-on-square" class="size-4" />
        </.link>
      </header>

      <div :if={@loading} class="flex-1 flex items-center justify-center">
        <span class="loading loading-spinner loading-md" />
      </div>

      <div :if={not @loading} class="flex-1 flex flex-col min-h-0 px-4 py-4">
        <table class="table table-xs mb-3 shrink-0">
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
              href={
                ~p"/events?#{%{q: "in:events severity:Critical time:last_24h sort:event_timestamp:desc limit:100"}}"
              }
            />
            <.severity_row
              label="High"
              count={Map.get(@summary, :high, 0)}
              total={Map.get(@summary, :total, 0)}
              color="warning"
              href={
                ~p"/events?#{%{q: "in:events severity:High time:last_24h sort:event_timestamp:desc limit:100"}}"
              }
            />
            <.severity_row
              label="Medium"
              count={Map.get(@summary, :medium, 0)}
              total={Map.get(@summary, :total, 0)}
              color="info"
              href={
                ~p"/events?#{%{q: "in:events severity:Medium time:last_24h sort:event_timestamp:desc limit:100"}}"
              }
            />
            <.severity_row
              label="Low"
              count={Map.get(@summary, :low, 0)}
              total={Map.get(@summary, :total, 0)}
              color="primary"
              href={
                ~p"/events?#{%{q: "in:events severity:Low time:last_24h sort:event_timestamp:desc limit:100"}}"
              }
            />
          </tbody>
        </table>

        <div
          :if={Map.get(@summary, :recent, []) == []}
          class="flex-1 flex items-center justify-center text-center"
        >
          <div>
            <.icon name="hero-shield-check" class="size-8 mx-auto mb-2 text-success" />
            <p class="text-sm text-base-content/60">No critical events</p>
            <p class="text-xs text-base-content/40 mt-1">All systems reporting normally</p>
          </div>
        </div>

        <div
          :if={Map.get(@summary, :recent, []) != []}
          class="flex-1 overflow-y-auto space-y-2 min-h-0"
        >
          <%= for event <- Map.get(@summary, :recent, []) do %>
            <.event_entry event={event} />
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  attr :summary, :map, required: true
  attr :loading, :boolean, default: false

  def critical_logs_widget(assigns) do
    ~H"""
    <div class="h-80 rounded-xl border border-base-200 bg-base-100 shadow-sm flex flex-col overflow-hidden">
      <header class="px-4 py-3 bg-base-200/40 flex items-start justify-between gap-3 shrink-0">
        <.link
          href={~p"/observability?#{%{tab: "logs"}}"}
          class="hover:text-primary transition-colors"
        >
          <div class="text-sm font-semibold">Critical Logs</div>
        </.link>
        <.link
          href={
            ~p"/observability?#{%{tab: "logs", q: "in:logs severity_text:(fatal,error,FATAL,ERROR) time:last_24h sort:timestamp:desc limit:100"}}"
          }
          class="text-base-content/60 hover:text-primary"
          title="View critical logs"
        >
          <.icon name="hero-arrow-top-right-on-square" class="size-4" />
        </.link>
      </header>

      <div :if={@loading} class="flex-1 flex items-center justify-center">
        <span class="loading loading-spinner loading-md" />
      </div>

      <div :if={not @loading} class="flex-1 flex flex-col min-h-0 px-4 py-4">
        <table class="table table-xs mb-3 shrink-0">
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
              href={
                ~p"/observability?#{%{tab: "logs", q: "in:logs severity_text:(fatal,FATAL) time:last_24h sort:timestamp:desc limit:100"}}"
              }
            />
            <.severity_row
              label="Error"
              count={Map.get(@summary, :error, 0)}
              total={Map.get(@summary, :total, 0)}
              color="warning"
              href={
                ~p"/observability?#{%{tab: "logs", q: "in:logs severity_text:(error,ERROR) time:last_24h sort:timestamp:desc limit:100"}}"
              }
            />
            <.severity_row
              label="Warning"
              count={Map.get(@summary, :warning, 0)}
              total={Map.get(@summary, :total, 0)}
              color="info"
              href={
                ~p"/observability?#{%{tab: "logs", q: "in:logs severity_text:(warning,warn,WARNING,WARN) time:last_24h sort:timestamp:desc limit:100"}}"
              }
            />
            <.severity_row
              label="Info"
              count={Map.get(@summary, :info, 0)}
              total={Map.get(@summary, :total, 0)}
              color="primary"
              href={
                ~p"/observability?#{%{tab: "logs", q: "in:logs severity_text:(info,INFO) time:last_24h sort:timestamp:desc limit:100"}}"
              }
            />
            <.severity_row
              label="Debug"
              count={Map.get(@summary, :debug, 0)}
              total={Map.get(@summary, :total, 0)}
              color="neutral"
              href={
                ~p"/observability?#{%{tab: "logs", q: "in:logs severity_text:(debug,trace,DEBUG,TRACE) time:last_24h sort:timestamp:desc limit:100"}}"
              }
            />
          </tbody>
        </table>

        <div
          :if={Map.get(@summary, :recent, []) == []}
          class="flex-1 flex items-center justify-center text-center"
        >
          <div>
            <.icon name="hero-document-check" class="size-8 mx-auto mb-2 text-success" />
            <p class="text-sm text-base-content/60">No fatal or error logs</p>
            <p class="text-xs text-base-content/40 mt-1">All systems logging normally</p>
          </div>
        </div>

        <div
          :if={Map.get(@summary, :recent, []) != []}
          class="flex-1 overflow-y-auto space-y-2 min-h-0"
        >
          <%= for log <- Map.get(@summary, :recent, []) do %>
            <.log_entry log={log} />
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  attr :data, :map, required: true
  attr :loading, :boolean, default: false

  def observability_widget(assigns) do
    data = assigns.data || %{}
    metrics_count = Map.get(data, :metrics_count, 0)
    traces_count = Map.get(data, :traces_count, 0)
    avg_duration = Map.get(data, :avg_duration, 0)
    error_rate = Map.get(data, :error_rate, 0.0)
    slow_spans_count = Map.get(data, :slow_spans_count, 0)
    slow_spans = Map.get(data, :slow_spans, [])

    assigns =
      assigns
      |> assign(:metrics_count, metrics_count)
      |> assign(:traces_count, traces_count)
      |> assign(:avg_duration, avg_duration)
      |> assign(:error_rate, error_rate)
      |> assign(:slow_spans_count, slow_spans_count)
      |> assign(:slow_spans, slow_spans)

    ~H"""
    <.ui_panel class="h-80">
      <:header>
        <.link href={~p"/observability"} class="hover:text-primary transition-colors">
          <div class="text-sm font-semibold">Observability</div>
        </.link>
        <.link
          href={
            ~p"/observability?#{%{tab: "traces", q: "in:otel_trace_summaries time:last_24h sort:timestamp:desc limit:100"}}"
          }
          class="text-base-content/60 hover:text-primary"
          title="View traces"
        >
          <.icon name="hero-arrow-top-right-on-square" class="size-4" />
        </.link>
      </:header>

      <div :if={@loading} class="flex-1 flex items-center justify-center">
        <span class="loading loading-spinner loading-md" />
      </div>

      <div :if={not @loading} class="flex flex-col h-full">
        <div class="grid grid-cols-2 gap-3 mb-4">
          <div class="rounded-lg bg-base-200/50 p-3 text-center">
            <div class="text-xl font-bold text-primary">{format_number(@metrics_count)}</div>
            <div class="text-xs text-base-content/60">Metrics</div>
          </div>
          <div class="rounded-lg bg-base-200/50 p-3 text-center">
            <div class="text-xl font-bold text-secondary">{format_number(@traces_count)}</div>
            <div class="text-xs text-base-content/60">Traces</div>
          </div>
          <div class="rounded-lg bg-base-200/50 p-3 text-center">
            <div class="text-xl font-bold text-info">{format_duration(@avg_duration)}</div>
            <div class="text-xs text-base-content/60">Avg Duration</div>
          </div>
          <div class={[
            "rounded-lg p-3 text-center",
            (@error_rate > 5 && "bg-error/10") || "bg-base-200/50"
          ]}>
            <div class={["text-xl font-bold", (@error_rate > 5 && "text-error") || "text-success"]}>
              {@error_rate}%
            </div>
            <div class="text-xs text-base-content/60">Error Rate</div>
          </div>
        </div>

        <div class="flex-1 min-h-0">
          <div class="flex items-center justify-between mb-2">
            <span class="text-xs font-medium text-base-content/70">Slow Traces (&gt;100ms)</span>
            <span class={[
              "text-xs font-bold",
              (@slow_spans_count > 0 && "text-warning") || "text-base-content/50"
            ]}>
              {@slow_spans_count}
            </span>
          </div>

          <div :if={@slow_spans == []} class="flex items-center justify-center py-4">
            <div class="text-center">
              <.icon name="hero-bolt" class="size-6 mx-auto mb-1 text-success" />
              <p class="text-xs text-base-content/60">No slow spans</p>
            </div>
          </div>

          <div :if={@slow_spans != []} class="space-y-1 overflow-y-auto max-h-24">
            <%= for span <- @slow_spans do %>
              <div class="flex items-center justify-between text-xs p-1.5 rounded bg-warning/10">
                <span class="truncate max-w-[60%]" title={span_name(span)}>{span_name(span)}</span>
                <span class="font-mono text-warning">{format_duration(span_duration(span))}</span>
              </div>
            <% end %>
          </div>
        </div>
      </div>
    </.ui_panel>
    """
  end

  attr :data, :map, required: true
  attr :loading, :boolean, default: false

  def high_utilization_widget(assigns) do
    data = assigns.data || %{}
    cpu_warning = Map.get(data, :cpu_warning, 0)
    cpu_critical = Map.get(data, :cpu_critical, 0)
    memory_warning = Map.get(data, :memory_warning, 0)
    memory_critical = Map.get(data, :memory_critical, 0)
    disk_warning = Map.get(data, :disk_warning, 0)
    disk_critical = Map.get(data, :disk_critical, 0)
    cpu_services = Map.get(data, :cpu_services, [])
    memory_services = Map.get(data, :memory_services, [])
    disk_services = Map.get(data, :disk_services, [])
    total_cpu_hosts = Map.get(data, :total_cpu_hosts, 0)
    total_memory_hosts = Map.get(data, :total_memory_hosts, 0)
    total_disk_mounts = Map.get(data, :total_disk_mounts, 0)

    assigns =
      assigns
      |> assign(:cpu_warning, cpu_warning)
      |> assign(:cpu_critical, cpu_critical)
      |> assign(:memory_warning, memory_warning)
      |> assign(:memory_critical, memory_critical)
      |> assign(:disk_warning, disk_warning)
      |> assign(:disk_critical, disk_critical)
      |> assign(:cpu_services, cpu_services)
      |> assign(:memory_services, memory_services)
      |> assign(:disk_services, disk_services)
      |> assign(:total_cpu_hosts, total_cpu_hosts)
      |> assign(:total_memory_hosts, total_memory_hosts)
      |> assign(:total_disk_mounts, total_disk_mounts)

    ~H"""
    <.ui_panel class="h-80">
      <:header>
        <.link
          href={~p"/dashboard?#{%{q: "in:cpu_metrics time:last_1h sort:timestamp:desc"}}"}
          class="hover:text-primary transition-colors"
        >
          <div class="text-sm font-semibold">High Utilization</div>
        </.link>
        <.link
          href={~p"/dashboard?#{%{q: "in:cpu_metrics time:last_1h sort:timestamp:desc limit:100"}}"}
          class="text-base-content/60 hover:text-primary"
          title="View metrics"
        >
          <.icon name="hero-arrow-top-right-on-square" class="size-4" />
        </.link>
      </:header>

      <div :if={@loading} class="flex-1 flex items-center justify-center">
        <span class="loading loading-spinner loading-md" />
      </div>

      <div :if={not @loading} class="flex flex-col h-full">
        <div class="grid grid-cols-3 gap-2 mb-3">
          <div class="rounded-lg bg-base-200/50 p-2">
            <div class="flex items-center gap-1 text-[10px] text-base-content/60 mb-1">
              <.icon name="hero-cpu-chip" class="size-3" /> CPU
            </div>
            <div class="flex flex-wrap items-center gap-1">
              <span :if={@cpu_critical > 0} class="badge badge-error badge-xs">{@cpu_critical}</span>
              <span :if={@cpu_warning > 0} class="badge badge-warning badge-xs">{@cpu_warning}</span>
              <span
                :if={@cpu_critical == 0 and @cpu_warning == 0}
                class="badge badge-success badge-xs"
              >
                OK
              </span>
            </div>
          </div>
          <div class="rounded-lg bg-base-200/50 p-2">
            <div class="flex items-center gap-1 text-[10px] text-base-content/60 mb-1">
              <.icon name="hero-circle-stack" class="size-3" /> Memory
            </div>
            <div class="flex flex-wrap items-center gap-1">
              <span :if={@memory_critical > 0} class="badge badge-error badge-xs">
                {@memory_critical}
              </span>
              <span :if={@memory_warning > 0} class="badge badge-warning badge-xs">
                {@memory_warning}
              </span>
              <span
                :if={@memory_critical == 0 and @memory_warning == 0}
                class="badge badge-success badge-xs"
              >
                OK
              </span>
            </div>
          </div>
          <div class="rounded-lg bg-base-200/50 p-2">
            <div class="flex items-center gap-1 text-[10px] text-base-content/60 mb-1">
              <.icon name="hero-server-stack" class="size-3" /> Disk
            </div>
            <div class="flex flex-wrap items-center gap-1">
              <span :if={@disk_critical > 0} class="badge badge-error badge-xs">
                {@disk_critical}
              </span>
              <span :if={@disk_warning > 0} class="badge badge-warning badge-xs">
                {@disk_warning}
              </span>
              <span
                :if={@disk_critical == 0 and @disk_warning == 0}
                class="badge badge-success badge-xs"
              >
                OK
              </span>
            </div>
          </div>
        </div>

        <div class="text-[10px] text-base-content/50 mb-2">
          {@total_cpu_hosts} CPU · {@total_memory_hosts} MEM · {@total_disk_mounts} disks
        </div>

        <div
          :if={@cpu_services == [] and @memory_services == [] and @disk_services == []}
          class="flex-1 flex items-center justify-center"
        >
          <div class="text-center">
            <.icon name="hero-cpu-chip" class="size-6 mx-auto mb-1 text-success" />
            <p class="text-xs text-base-content/60">No high utilization</p>
          </div>
        </div>

        <div
          :if={@cpu_services != [] or @memory_services != [] or @disk_services != []}
          class="flex-1 overflow-y-auto space-y-1 min-h-0"
        >
          <%= for svc <- @cpu_services do %>
            <.utilization_row service={svc} type="cpu" />
          <% end %>
          <%= for svc <- @memory_services do %>
            <.memory_utilization_row service={svc} />
          <% end %>
          <%= for svc <- @disk_services do %>
            <.disk_utilization_row service={svc} />
          <% end %>
        </div>
      </div>
    </.ui_panel>
    """
  end

  attr :data, :map, required: true
  attr :loading, :boolean, default: false

  def bandwidth_widget(assigns) do
    data = assigns.data || %{}
    targets = Map.get(data, :targets, [])
    total_download = Map.get(data, :total_download, 0.0)
    total_upload = Map.get(data, :total_upload, 0.0)
    avg_latency = Map.get(data, :avg_latency, 0.0)
    target_count = Map.get(data, :target_count, 0)

    assigns =
      assigns
      |> assign(:targets, targets)
      |> assign(:total_download, total_download)
      |> assign(:total_upload, total_upload)
      |> assign(:avg_latency, avg_latency)
      |> assign(:target_count, target_count)

    ~H"""
    <.ui_panel class="h-80">
      <:header>
        <.link
          href={~p"/dashboard?#{%{q: "in:rperf_targets time:last_1h sort:timestamp:desc"}}"}
          class="hover:text-primary transition-colors"
        >
          <div class="text-sm font-semibold">Bandwidth Tracker</div>
        </.link>
        <.link
          href={~p"/dashboard?#{%{q: "in:rperf_targets time:last_1h sort:timestamp:desc limit:50"}}"}
          class="text-base-content/60 hover:text-primary"
          title="View bandwidth data"
        >
          <.icon name="hero-arrow-top-right-on-square" class="size-4" />
        </.link>
      </:header>

      <div :if={@loading} class="flex-1 flex items-center justify-center">
        <span class="loading loading-spinner loading-md" />
      </div>

      <div :if={not @loading} class="flex flex-col h-full">
        <div class="grid grid-cols-3 gap-2 mb-4">
          <div class="rounded-lg bg-success/10 p-2 text-center">
            <div class="text-lg font-bold text-success">{format_mbps(@total_download)}</div>
            <div class="text-[10px] text-base-content/60">Download</div>
          </div>
          <div class="rounded-lg bg-primary/10 p-2 text-center">
            <div class="text-lg font-bold text-primary">{format_mbps(@total_upload)}</div>
            <div class="text-[10px] text-base-content/60">Upload</div>
          </div>
          <div class="rounded-lg bg-base-200/50 p-2 text-center">
            <div class="text-lg font-bold">{@avg_latency}ms</div>
            <div class="text-[10px] text-base-content/60">Avg Latency</div>
          </div>
        </div>

        <div class="text-xs text-base-content/50 mb-2">{@target_count} targets</div>

        <div :if={@targets == []} class="flex-1 flex items-center justify-center">
          <div class="text-center">
            <.icon name="hero-signal" class="size-6 mx-auto mb-1 text-base-content/40" />
            <p class="text-xs text-base-content/60">No bandwidth data</p>
          </div>
        </div>

        <div :if={@targets != []} class="flex-1 overflow-y-auto min-h-0">
          <table class="table table-xs w-full">
            <thead>
              <tr class="text-[10px]">
                <th class="text-base-content/60">Target</th>
                <th class="text-right text-base-content/60">DL</th>
                <th class="text-right text-base-content/60">UL</th>
                <th class="text-right text-base-content/60">Lat</th>
              </tr>
            </thead>
            <tbody>
              <%= for target <- @targets do %>
                <tr class="hover:bg-base-200/50">
                  <td class="truncate max-w-[100px] text-xs" title={target.name}>{target.name}</td>
                  <td class="text-right text-xs text-success">{format_mbps(target.download_mbps)}</td>
                  <td class="text-right text-xs text-primary">{format_mbps(target.upload_mbps)}</td>
                  <td class="text-right text-xs font-mono">{round(target.latency_ms)}ms</td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      </div>
    </.ui_panel>
    """
  end

  attr :service, :map, required: true
  attr :type, :string, default: "cpu"

  defp utilization_row(assigns) do
    svc = assigns.service

    cpu =
      extract_numeric(
        Map.get(svc, "value") || Map.get(svc, "cpu_usage") || Map.get(svc, "usage_percent") ||
          Map.get(svc, "user") || 0
      )

    mem = extract_numeric(Map.get(svc, "memory_usage") || Map.get(svc, "mem_percent") || 0)
    host = Map.get(svc, "host") || Map.get(svc, "device_id") || "Unknown"

    assigns =
      assigns
      |> assign(:cpu, cpu)
      |> assign(:mem, mem)
      |> assign(:host, host)

    ~H"""
    <div class="flex items-center gap-2 p-1.5 rounded bg-base-200/50 text-xs">
      <div class="truncate flex-1 font-medium" title={@host}>{@host}</div>
      <div class="flex items-center gap-2 shrink-0">
        <span class={["badge badge-xs", cpu_badge_class(@cpu)]}>CPU {@cpu |> round()}%</span>
        <span :if={@mem > 0} class={["badge badge-xs", cpu_badge_class(@mem)]}>
          MEM {@mem |> round()}%
        </span>
      </div>
    </div>
    """
  end

  attr :service, :map, required: true

  defp memory_utilization_row(assigns) do
    svc = assigns.service

    percent =
      extract_numeric(
        Map.get(svc, "percent") || Map.get(svc, "value") || Map.get(svc, "used_percent") || 0
      )

    host = Map.get(svc, "host") || Map.get(svc, "device_id") || "Unknown"

    assigns =
      assigns
      |> assign(:percent, percent)
      |> assign(:host, host)

    ~H"""
    <div class="flex items-center gap-2 p-1.5 rounded bg-base-200/50 text-xs">
      <div class="truncate flex-1 font-medium" title={@host}>{@host}</div>
      <div class="shrink-0">
        <span class={["badge badge-xs", memory_badge_class(@percent)]}>
          MEM {@percent |> round()}%
        </span>
      </div>
    </div>
    """
  end

  attr :service, :map, required: true

  defp disk_utilization_row(assigns) do
    svc = assigns.service
    percent = extract_numeric(Map.get(svc, "percent") || Map.get(svc, "value") || 0)
    host = Map.get(svc, "host") || Map.get(svc, "device_id") || "Unknown"
    mount = Map.get(svc, "mount_point") || Map.get(svc, "mount") || "/"

    assigns =
      assigns
      |> assign(:percent, percent)
      |> assign(:host, host)
      |> assign(:mount, mount)

    ~H"""
    <div class="flex items-center gap-2 p-1.5 rounded bg-base-200/50 text-xs">
      <div class="truncate flex-1 min-w-0">
        <span class="font-medium" title={@host}>{@host}</span>
        <span class="text-base-content/50 ml-1" title={@mount}>{@mount}</span>
      </div>
      <div class="shrink-0">
        <span class={["badge badge-xs", disk_badge_class(@percent)]}>
          DISK {@percent |> round()}%
        </span>
      </div>
    </div>
    """
  end

  defp cpu_badge_class(value) when value >= 90, do: "badge-error"
  defp cpu_badge_class(value) when value >= 80, do: "badge-warning"
  defp cpu_badge_class(value) when value >= 70, do: "badge-info"
  defp cpu_badge_class(_), do: "badge-ghost"

  defp memory_badge_class(value) when value >= 90, do: "badge-error"
  defp memory_badge_class(value) when value >= 85, do: "badge-warning"
  defp memory_badge_class(value) when value >= 70, do: "badge-info"
  defp memory_badge_class(_), do: "badge-ghost"

  defp disk_badge_class(value) when value >= 90, do: "badge-error"
  defp disk_badge_class(value) when value >= 85, do: "badge-warning"
  defp disk_badge_class(value) when value >= 70, do: "badge-info"
  defp disk_badge_class(_), do: "badge-ghost"

  defp span_name(span) when is_map(span) do
    name =
      Map.get(span, "name") ||
        Map.get(span, "span_name") ||
        Map.get(span, "root_span_name") ||
        Map.get(span, "operation")

    service = Map.get(span, "service_name") || Map.get(span, "root_service_name")

    case {name, service} do
      {nil, nil} -> "Unknown"
      {nil, svc} -> svc
      {n, nil} -> n
      {n, svc} -> "#{svc}: #{n}"
    end
  end

  defp span_name(_), do: "Unknown"

  defp span_duration(span) when is_map(span) do
    # Use pre-calculated duration_ms if available, otherwise calculate
    case Map.get(span, "duration_ms") do
      ms when is_number(ms) ->
        ms

      _ ->
        start_nano = extract_numeric(Map.get(span, "start_time_unix_nano"))
        end_nano = extract_numeric(Map.get(span, "end_time_unix_nano"))

        if is_number(start_nano) and is_number(end_nano) and end_nano > start_nano do
          (end_nano - start_nano) / 1_000_000
        else
          0
        end
    end
  end

  defp span_duration(_), do: 0

  defp format_duration(ms) when is_number(ms) do
    cond do
      ms >= 60_000 -> "#{Float.round(ms / 60_000, 1)}m"
      ms >= 1000 -> "#{Float.round(ms / 1000, 1)}s"
      true -> "#{round(ms)}ms"
    end
  end

  defp format_duration(_), do: "0ms"

  defp format_mbps(value) when is_number(value) do
    cond do
      value >= 1000 -> "#{Float.round(value / 1000, 1)} Gbps"
      value >= 1 -> "#{Float.round(value, 1)} Mbps"
      value > 0 -> "#{round(value * 1000)} Kbps"
      true -> "0"
    end
  end

  defp format_mbps(_), do: "0"

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
        <.icon
          name={severity_icon(@event["severity"])}
          class={["size-4 mt-0.5", severity_text_class(severity_color(@event["severity"]))]}
        />
        <div class="flex-1 min-w-0">
          <div class="text-sm font-medium truncate">{@event["host"] || "Unknown"}</div>
          <div class="text-xs text-base-content/60 truncate">
            {@event["short_message"] || "No details"}
          </div>
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
        <.icon
          name={log_level_icon(@log["severity_text"])}
          class={["size-4 mt-0.5", severity_text_class(log_level_color(@log["severity_text"]))]}
        />
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
