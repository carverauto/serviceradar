defmodule ServiceRadarWebNGWeb.AnalyticsLive.Index do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  import Ecto.Query

  alias Phoenix.LiveView.JS
  alias ServiceRadarWebNG.Repo
  alias ServiceRadarWebNGWeb.Stats

  require Logger

  @default_events_limit 500
  @default_events_recent_limit 50
  @default_metrics_limit 100
  @refresh_interval_ms to_timeout(second: 30)

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
     |> assign(:trace_rollup_status, Stats.empty_trace_rollup_status())
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

  # Query the continuous aggregation for efficient pre-computed stats
  defp get_hourly_metrics_stats(_scope) do
    cutoff = DateTime.add(DateTime.utc_now(), -24, :hour)

    query =
      from(s in "otel_metrics_hourly_stats",
        where: s.bucket >= ^cutoff,
        select: %{
          total_count: sum(s.total_count),
          error_count: sum(s.error_count),
          slow_count: sum(s.slow_count),
          http_4xx_count: sum(s.http_4xx_count),
          http_5xx_count: sum(s.http_5xx_count),
          grpc_error_count: sum(s.grpc_error_count),
          avg_duration_ms:
            fragment(
              "CASE WHEN SUM(?) > 0 THEN SUM(? * ?) / SUM(?) ELSE 0 END",
              s.total_count,
              s.avg_duration_ms,
              s.total_count,
              s.total_count
            ),
          p95_duration_ms: max(s.p95_duration_ms),
          max_duration_ms: max(s.max_duration_ms)
        }
      )

    case Repo.one(query) do
      %{total_count: total} = stats when not is_nil(total) ->
        %{
          total: to_int(total),
          error: to_int(stats.error_count),
          slow: to_int(stats.slow_count),
          http_4xx: to_int(stats.http_4xx_count),
          http_5xx: to_int(stats.http_5xx_count),
          grpc_error: to_int(stats.grpc_error_count),
          avg_duration_ms: to_float(stats.avg_duration_ms),
          p95_duration_ms: to_float(stats.p95_duration_ms),
          max_duration_ms: to_float(stats.max_duration_ms)
        }

      _ ->
        Logger.debug("Hourly metrics stats not available, falling back to SRQL queries")
        nil
    end
  rescue
    error ->
      Logger.warning("Failed to query hourly metrics stats: #{inspect(error)}")
      nil
  end

  defp get_hourly_event_stats(_scope) do
    cutoff = DateTime.add(DateTime.utc_now(), -24, :hour)

    query =
      from(s in "ocsf_events_hourly_stats",
        where: s.bucket >= ^cutoff,
        group_by: s.severity_id,
        select: {s.severity_id, sum(s.total_count)}
      )

    rows = Repo.all(query)

    merge_event_stats(%{total: 0, critical: 0, error: 0, warning: 0, info: 0}, rows)
  rescue
    error ->
      Logger.warning("Failed to query hourly event stats: #{inspect(error)}")
      nil
  end

  defp to_float(nil), do: 0.0
  defp to_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp to_float(v) when is_float(v), do: v
  defp to_float(v) when is_integer(v), do: v * 1.0
  defp to_float(_), do: 0.0

  defp load_analytics(socket) do
    srql_module = srql_module()
    scope = Map.get(socket.assigns, :current_scope)

    # Run CAGG/DB lookups in parallel (these were previously sequential)
    initial_tasks = [
      Task.async(fn -> {:hourly_stats, get_hourly_metrics_stats(scope)} end),
      Task.async(fn -> {:event_stats, get_hourly_event_stats(scope)} end),
      Task.async(fn -> {:service_counts, get_service_counts()} end),
      Task.async(fn -> {:logs_severity, Stats.logs_severity(scope: scope)} end),
      Task.async(fn -> {:traces_summary, Stats.traces_summary_with_computed(scope: scope)} end),
      Task.async(fn -> {:trace_rollup_status, Stats.trace_rollup_status()} end)
    ]

    initial =
      initial_tasks
      |> Task.await_many(15_000)
      |> Map.new()

    hourly_stats = initial.hourly_stats
    event_stats = initial.event_stats
    service_counts = initial.service_counts

    # Check if logs severity CAGG returned real data
    logs_severity_cagg =
      case initial.logs_severity do
        %{total: total} when total > 0 -> initial.logs_severity
        _ -> nil
      end

    queries = %{
      devices_total: ~s|in:devices stats:"count() as total"|,
      devices_online: ~s|in:devices is_available:true stats:"count() as online"|,
      devices_offline: ~s|in:devices is_available:false stats:"count() as offline"|,
      logs_critical_recent:
        "in:logs time:last_24h severity_text:(fatal,FATAL,critical,CRITICAL,emergency,EMERGENCY,alert,ALERT,error,ERROR,err,ERR) sort:timestamp:desc limit:5",
      slow_spans: "in:otel_metrics time:last_24h is_slow:true sort:duration_ms:desc limit:25",
      cpu_metrics: "in:cpu_metrics time:last_1h sort:timestamp:desc limit:#{@default_metrics_limit}",
      memory_metrics: "in:memory_metrics time:last_1h sort:timestamp:desc limit:#{@default_metrics_limit}",
      disk_metrics: "in:disk_metrics time:last_1h sort:timestamp:desc limit:#{@default_metrics_limit}"
    }

    queries =
      if is_nil(service_counts) do
        Map.put(
          queries,
          :services_list,
          "in:services time:last_1h sort:timestamp:desc limit:5000"
        )
      else
        queries
      end

    # Only add SRQL fallback queries if hourly stats failed
    queries =
      if is_nil(hourly_stats) do
        Map.merge(queries, %{
          metrics_total: ~s|in:otel_metrics time:last_24h stats:"count() as total"|,
          metrics_slow: ~s|in:otel_metrics time:last_24h is_slow:true stats:"count() as total"|,
          metrics_error_http4: ~s|in:otel_metrics time:last_24h http_status_code:4% stats:"count() as total"|,
          metrics_error_http5: ~s|in:otel_metrics time:last_24h http_status_code:5% stats:"count() as total"|,
          metrics_error_grpc:
            ~s|in:otel_metrics time:last_24h !grpc_status_code:0 !grpc_status_code:"" stats:"count() as total"|
        })
      else
        queries
      end

    # Fall back to individual SRQL count queries if CAGG didn't return data
    queries =
      if is_nil(logs_severity_cagg) do
        Map.merge(queries, %{
          logs_fatal_count:
            ~s|in:logs severity_text:(fatal,FATAL,critical,CRITICAL,emergency,EMERGENCY,alert,ALERT) time:last_24h stats:"count() as total"|,
          logs_error_count: ~s|in:logs severity_text:(error,ERROR,err,ERR) time:last_24h stats:"count() as total"|,
          logs_warning_count:
            ~s|in:logs severity_text:(warning,warn,WARNING,WARN) time:last_24h stats:"count() as total"|,
          logs_info_count:
            ~s|in:logs severity_text:(info,INFO,information,INFORMATION,informational,INFORMATIONAL,notice,NOTICE) time:last_24h stats:"count() as total"|,
          logs_debug_count: ~s|in:logs severity_text:(debug,trace,DEBUG,TRACE) time:last_24h stats:"count() as total"|
        })
      else
        queries
      end

    queries =
      if is_nil(event_stats) do
        Map.put(
          queries,
          :events,
          "in:events time:last_24h sort:time:desc limit:#{@default_events_limit}"
        )
      else
        Map.put(
          queries,
          :events_recent,
          "in:events log_level:(FATAL,fatal,CRITICAL,critical,ERROR,error) time:last_24h sort:time:desc limit:#{@default_events_recent_limit}"
        )
      end

    results =
      queries
      |> Task.async_stream(
        fn {key, query} -> {key, srql_module.query(query, %{scope: scope})} end,
        ordered: false,
        timeout: 30_000
      )
      |> Enum.reduce(%{}, fn
        {:ok, {key, result}}, acc -> Map.put(acc, key, result)
        {:exit, reason}, acc -> Map.put(acc, :error, "query task exit: #{inspect(reason)}")
      end)

    results =
      if hourly_stats do
        Map.put(results, :hourly_stats, hourly_stats)
      else
        results
      end

    results =
      if event_stats do
        Map.put(results, :event_stats, event_stats)
      else
        results
      end

    # Use CAGG data if available, otherwise build from individual count queries
    logs_severity =
      if logs_severity_cagg do
        logs_severity_cagg
      else
        %{
          total:
            extract_count(results[:logs_fatal_count]) +
              extract_count(results[:logs_error_count]) +
              extract_count(results[:logs_warning_count]) +
              extract_count(results[:logs_info_count]) +
              extract_count(results[:logs_debug_count]),
          fatal: extract_count(results[:logs_fatal_count]),
          error: extract_count(results[:logs_error_count]),
          warning: extract_count(results[:logs_warning_count]),
          info: extract_count(results[:logs_info_count]),
          debug: extract_count(results[:logs_debug_count])
        }
      end

    results =
      results
      |> Map.put(:service_counts, service_counts)
      |> Map.put(:logs_severity, logs_severity)
      |> Map.put(:traces_summary, Map.get(initial, :traces_summary))

    {stats, device_availability, events_summary, logs_summary, observability, high_utilization, bandwidth, error} =
      build_assigns(results)

    socket
    |> assign(:stats, stats)
    |> assign(:device_availability, device_availability)
    |> assign(:events_summary, events_summary)
    |> assign(:logs_summary, logs_summary)
    |> assign(:observability, observability)
    |> assign(
      :trace_rollup_status,
      Map.get(initial, :trace_rollup_status, Stats.empty_trace_rollup_status())
    )
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
    {unique_services, failing_services} =
      case results[:service_counts] do
        %{total: total, failing: failing} ->
          {to_int(total), to_int(failing)}

        _ ->
          services_rows = extract_rows(results[:services_list])
          count_unique_services(services_rows)
      end

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

    events_rows = extract_rows(results[:events_recent] || results[:events])
    events_summary = build_events_summary(events_rows, Map.get(results, :event_stats))

    logs_rows = extract_rows(results[:logs_critical_recent])

    logs_counts =
      case results[:logs_severity] do
        %{total: _} = counts ->
          Map.take(counts, [:total, :fatal, :error, :warning, :info, :debug])

        _ ->
          %{total: 0, fatal: 0, error: 0, warning: 0, info: 0, debug: 0}
      end

    logs_summary = build_logs_summary(logs_rows, logs_counts)

    # Build observability summary - prefer pre-computed hourly stats if available
    {metrics_total, _metrics_error, metrics_slow, _avg_duration} =
      case Map.get(results, :hourly_stats) do
        %{total: total, error: error, slow: slow, avg_duration_ms: avg_ms} ->
          # Use efficient pre-computed stats from continuous aggregation
          {total, error, slow, avg_ms}

        _ ->
          # Fallback to individual SRQL query results
          total = extract_count(results[:metrics_total])
          slow = extract_count(results[:metrics_slow])
          http4 = extract_count(results[:metrics_error_http4])
          http5 = extract_count(results[:metrics_error_http5])
          grpc = extract_count(results[:metrics_error_grpc])
          {total, http4 + http5 + grpc, slow, 0}
      end

    trace_summary =
      case Map.get(results, :traces_summary) do
        %{total: _total, errors: _errors, avg_duration_ms: _avg, error_rate: _rate} = summary ->
          summary

        _ ->
          Stats.empty_traces_summary()
          |> Map.put(:error_rate, 0.0)
          |> Map.put(:successful, 0)
      end

    slow_spans_rows = extract_rows(results[:slow_spans])

    observability =
      build_observability_summary(
        metrics_total,
        metrics_slow,
        trace_summary,
        slow_spans_rows
      )

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

    {stats, device_availability, events_summary, logs_summary, observability, high_utilization, bandwidth, error}
  end

  defp extract_rows({:ok, %{"results" => rows}}) when is_list(rows), do: rows
  defp extract_rows(_), do: []

  defp count_unique_services(rows) when is_list(rows) do
    # Group by service_name and get most recent status for each
    services_by_name =
      rows
      |> Enum.filter(&is_map/1)
      |> Enum.reduce(%{}, fn row, acc ->
        service_name = Map.get(row, "service_name")
        uid = Map.get(row, "uid") || Map.get(row, "device_id")
        # Use composite key of uid + service_name to identify unique service instances
        key = "#{uid}:#{service_name}"

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
    extract_count_value(value)
  end

  defp extract_count(_), do: 0

  defp extract_count_value(value) when is_integer(value), do: value
  defp extract_count_value(value) when is_float(value), do: trunc(value)
  defp extract_count_value(%Decimal{} = value), do: Decimal.to_integer(value)

  defp extract_count_value(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> 0
    end
  end

  defp extract_count_value(%{} = row) do
    row
    |> Map.values()
    |> Enum.find_value(&parse_count_value/1)
    |> case do
      nil -> 0
      count -> count
    end
  end

  defp extract_count_value(_), do: 0

  defp parse_count_value(value) when is_integer(value), do: value
  defp parse_count_value(value) when is_float(value), do: trunc(value)
  defp parse_count_value(%Decimal{} = value), do: Decimal.to_integer(value)

  defp parse_count_value(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp parse_count_value(_), do: nil

  defp build_events_summary(rows, %{} = stats) when is_list(rows) do
    recent =
      rows
      |> Enum.filter(fn row ->
        is_map(row) and event_summary_category(row) in [:critical, :error]
      end)
      |> Enum.take(5)

    %{critical: 0, error: 0, warning: 0, info: 0, total: 0}
    |> Map.merge(stats)
    |> Map.put(:recent, recent)
  end

  defp build_events_summary(rows, nil) when is_list(rows) do
    counts =
      rows
      |> Enum.filter(&is_map/1)
      |> Enum.reduce(%{critical: 0, error: 0, warning: 0, info: 0}, fn row, acc ->
        case event_summary_category(row) do
          :critical -> Map.update!(acc, :critical, &(&1 + 1))
          :error -> Map.update!(acc, :error, &(&1 + 1))
          :warning -> Map.update!(acc, :warning, &(&1 + 1))
          :info -> Map.update!(acc, :info, &(&1 + 1))
          _ -> acc
        end
      end)

    recent =
      rows
      |> Enum.filter(fn row ->
        is_map(row) and event_summary_category(row) in [:critical, :error]
      end)
      |> Enum.take(5)

    Map.merge(counts, %{total: length(rows), recent: recent})
  end

  defp build_events_summary(_, _), do: %{critical: 0, error: 0, warning: 0, info: 0, total: 0, recent: []}

  defp build_logs_summary(rows, %{} = counts) when is_list(rows) do
    recent =
      rows
      |> Enum.filter(fn row ->
        is_map(row) and
          (row |> Map.get("severity_text") |> normalize_log_level()) in [
            "Critical",
            "Fatal",
            "Error"
          ]
      end)
      |> Enum.take(5)

    counts
    |> Map.take([:total, :fatal, :error, :warning, :info, :debug])
    |> Map.put(:recent, recent)
  end

  defp build_logs_summary(_rows, _counts), do: %{fatal: 0, error: 0, warning: 0, info: 0, debug: 0, total: 0, recent: []}

  defp build_observability_summary(metrics_total, metrics_slow, trace_summary, slow_spans)
       when is_integer(metrics_total) and is_integer(metrics_slow) and is_map(trace_summary) and is_list(slow_spans) do
    traces_count = trace_summary |> Map.get(:total, 0) |> to_int()
    avg_duration_ms = trace_summary |> Map.get(:avg_duration_ms, 0.0) |> to_float()
    error_rate = trace_summary |> Map.get(:error_rate, 0.0) |> to_float() |> Float.round(1)

    slow_spans =
      slow_spans
      |> Enum.filter(&is_map/1)
      |> Enum.take(5)

    %{
      metrics_count: metrics_total,
      traces_count: traces_count,
      avg_duration: avg_duration_ms,
      error_rate: error_rate,
      slow_spans_count: metrics_slow,
      slow_spans: slow_spans
    }
  end

  defp build_observability_summary(_, _, _, _),
    do: %{metrics_count: 0, traces_count: 0, avg_duration: 0, error_rate: 0.0, slow_spans_count: 0, slow_spans: []}

  defp to_int(nil), do: 0
  defp to_int(value) when is_integer(value), do: value
  defp to_int(value) when is_float(value), do: trunc(value)
  defp to_int(%Decimal{} = d), do: Decimal.to_integer(d)
  defp to_int(_), do: 0

  defp merge_event_stats(base, rows) when is_list(rows) do
    Enum.reduce(rows, base, fn {severity_id, total_count}, acc ->
      count = to_int(total_count)
      acc = Map.update!(acc, :total, &(&1 + count))

      case to_int(severity_id) do
        6 -> Map.update!(acc, :critical, &(&1 + count))
        5 -> Map.update!(acc, :critical, &(&1 + count))
        4 -> Map.update!(acc, :error, &(&1 + count))
        3 -> Map.update!(acc, :warning, &(&1 + count))
        2 -> Map.update!(acc, :info, &(&1 + count))
        1 -> Map.update!(acc, :info, &(&1 + count))
        _ -> acc
      end
    end)
  end

  defp merge_event_stats(base, _), do: base

  defp get_service_counts do
    cutoff = DateTime.add(DateTime.utc_now(), -1, :hour)

    query =
      from(s in "service_status",
        where: s.timestamp >= ^cutoff,
        select: %{
          total: fragment("COUNT(DISTINCT ?)", s.service_name),
          failing:
            fragment(
              "COUNT(DISTINCT ?) FILTER (WHERE ? = false)",
              s.service_name,
              s.available
            )
        }
      )

    Repo.one(query)
  rescue
    error ->
      Logger.warning("Failed to query service counts: #{inspect(error)}")
      nil
  end

  defp build_high_utilization_summary(cpu_rows, memory_rows, disk_rows)
       when is_list(cpu_rows) and is_list(memory_rows) and is_list(disk_rows) do
    unique_cpu_hosts = dedupe_by_key(cpu_rows, &host_key/1)
    unique_memory_hosts = dedupe_by_key(memory_rows, &host_key/1)
    unique_disks = dedupe_by_key(disk_rows, &disk_key/1)

    cpu_categorized = categorize_utilization(unique_cpu_hosts, &cpu_usage/1, 80, 90)
    memory_categorized = categorize_utilization(unique_memory_hosts, &memory_usage/1, 85, 90)
    disk_categorized = categorize_utilization(unique_disks, &disk_usage/1, 85, 90)

    high_cpu_services = top_utilization(unique_cpu_hosts, &cpu_usage/1, 70, 3)
    high_memory_services = top_utilization(unique_memory_hosts, &memory_usage/1, 70, 3)
    high_disk_services = top_utilization(unique_disks, &disk_usage/1, 70, 3)

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

  defp utilization_cpu(svc) do
    svc
    |> first_present(["value", "cpu_usage", "usage_percent", "user"], 0)
    |> extract_numeric()
  end

  defp utilization_mem(svc) do
    svc
    |> first_present(["memory_usage", "mem_percent"], 0)
    |> extract_numeric()
  end

  defp utilization_host(svc), do: first_present(svc, ["host", "uid"], "Unknown")

  defp first_present(map, keys, default) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, default, &Map.get(map, &1))
  end

  defp dedupe_by_key(rows, key_fun) do
    rows
    |> Enum.filter(&is_map/1)
    |> Enum.reduce(%{}, fn row, acc ->
      key = key_fun.(row)

      if is_binary(key) and key != "" do
        Map.put_new(acc, key, row)
      else
        acc
      end
    end)
    |> Map.values()
  end

  defp host_key(row) do
    Map.get(row, "host") || Map.get(row, "uid") || Map.get(row, "device_id") || ""
  end

  defp disk_key(row) do
    host = host_key(row)
    mount = Map.get(row, "mount_point") || Map.get(row, "mount") || ""

    if host == "" do
      ""
    else
      "#{host}:#{mount}"
    end
  end

  defp categorize_utilization(rows, value_fun, warning_threshold, critical_threshold) do
    Enum.reduce(rows, %{warning: [], critical: []}, fn row, acc ->
      value = value_fun.(row)

      cond do
        value >= critical_threshold -> Map.update!(acc, :critical, &[row | &1])
        value >= warning_threshold -> Map.update!(acc, :warning, &[row | &1])
        true -> acc
      end
    end)
  end

  defp top_utilization(rows, value_fun, min_threshold, limit) do
    rows
    |> Enum.map(fn row -> {value_fun.(row), row} end)
    |> Enum.filter(fn {value, _row} -> value >= min_threshold end)
    |> Enum.sort_by(fn {value, _row} -> -value end)
    |> Enum.take(limit)
    |> Enum.map(fn {_value, row} -> row end)
  end

  defp cpu_usage(row) do
    extract_numeric(
      Map.get(row, "value") || Map.get(row, "cpu_usage") || Map.get(row, "usage_percent") ||
        Map.get(row, "user") || 0
    )
  end

  defp memory_usage(row) do
    extract_numeric(Map.get(row, "percent") || Map.get(row, "value") || Map.get(row, "used_percent") || 0)
  end

  defp disk_usage(row) do
    extract_numeric(Map.get(row, "percent") || Map.get(row, "value") || 0)
  end

  defp normalize_severity(nil), do: ""

  defp normalize_severity(value) do
    case value |> to_string() |> String.trim() |> String.downcase() do
      "critical" -> "Critical"
      "fatal" -> "Fatal"
      "high" -> "High"
      "medium" -> "Medium"
      "low" -> "Low"
      "informational" -> "Informational"
      "info" -> "Informational"
      _ -> ""
    end
  end

  defp event_summary_category(row) do
    case normalize_log_level(Map.get(row, "log_level")) do
      "Fatal" -> :critical
      "Error" -> :error
      "Warning" -> :warning
      "Info" -> :info
      "Debug" -> :info
      _ -> event_category_from_severity(Map.get(row, "severity"))
    end
  end

  defp event_category_from_severity(severity) do
    case normalize_severity(severity) do
      "Critical" -> :critical
      "Fatal" -> :critical
      "High" -> :error
      "Medium" -> :warning
      "Low" -> :info
      "Informational" -> :info
      _ -> :unknown
    end
  end

  defp normalize_log_level(nil), do: ""

  defp normalize_log_level(value) do
    case value |> to_string() |> String.trim() |> String.downcase() do
      "critical" -> "Critical"
      "emergency" -> "Critical"
      "alert" -> "Critical"
      "fatal" -> "Fatal"
      "error" -> "Error"
      "err" -> "Error"
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

  defp trace_rollup_warning?(%{healthy?: false}), do: true
  defp trace_rollup_warning?(_), do: false

  defp trace_rollup_warning_text(%{messages: messages}) when is_list(messages) do
    messages
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
  end

  defp trace_rollup_warning_text(_), do: "Trace observability data may be stale."

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

        <div :if={trace_rollup_warning?(@trace_rollup_status)} class="mb-4">
          <div role="alert" class="alert alert-warning">
            <.icon name="hero-exclamation-triangle" class="size-5" />
            <div class="text-sm">
              <div class="font-semibold">Trace rollups need attention</div>
              <div>{trace_rollup_warning_text(@trace_rollup_status)}</div>
            </div>
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
            {format_compact_number(@value)}
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

  defp format_compact_number(n) when is_float(n), do: n |> trunc() |> format_compact_number()

  defp format_compact_number(n) when is_integer(n) do
    sign = if n < 0, do: "-", else: ""
    abs_n = abs(n)

    formatted =
      cond do
        abs_n >= 1_000_000_000 ->
          compact_decimal(abs_n / 1_000_000_000.0, 1) <> "B"

        abs_n >= 1_000_000 ->
          compact_decimal(abs_n / 1_000_000.0, 1) <> "M"

        abs_n >= 100_000 ->
          Integer.to_string(div(abs_n, 1000)) <> "k"

        abs_n >= 1_000 ->
          compact_decimal(abs_n / 1000.0, 1) <> "k"

        true ->
          Integer.to_string(abs_n)
      end

    sign <> formatted
  end

  defp format_compact_number(_), do: "0"

  defp compact_decimal(value, decimals) when is_number(value) and is_integer(decimals) do
    value
    |> :erlang.float_to_binary(decimals: decimals)
    |> String.trim_trailing("0")
    |> String.trim_trailing(".")
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
            <span class="font-semibold">{format_compact_number(@online)}</span>
          </.link>
          <.link
            href={~p"/devices?#{%{q: "in:devices is_available:false sort:last_seen:desc limit:20"}}"}
            class="flex items-center justify-between hover:bg-base-200/50 rounded-lg p-2 -m-2 transition-colors"
          >
            <div class="flex items-center gap-2">
              <span class="w-3 h-3 rounded-full bg-error" />
              <span class="text-sm">Offline</span>
            </div>
            <span class="font-semibold">{format_compact_number(@offline)}</span>
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
    <div class="h-80 rounded-xl border border-base-200 bg-base-100 flex flex-col overflow-hidden">
      <header class="px-4 py-3 bg-base-200/40 flex items-start justify-between gap-3 shrink-0">
        <.link href={~p"/events"} class="hover:text-primary transition-colors">
          <div class="text-sm font-semibold">Event Levels</div>
        </.link>
        <.link
          href={
            ~p"/events?#{%{q: "in:events log_level:(FATAL,fatal,CRITICAL,critical,ERROR,error) time:last_24h sort:time:desc limit:100"}}"
          }
          class="text-base-content/60 hover:text-primary"
          title="View high severity events"
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
              label="Critical/Fatal"
              count={Map.get(@summary, :critical, 0)}
              total={Map.get(@summary, :total, 0)}
              color="error"
              href={
                ~p"/events?#{%{q: "in:events log_level:(FATAL,fatal,CRITICAL,critical) time:last_24h sort:time:desc limit:100"}}"
              }
            />
            <.severity_row
              label="Error"
              count={Map.get(@summary, :error, 0)}
              total={Map.get(@summary, :total, 0)}
              color="warning"
              href={
                ~p"/events?#{%{q: "in:events log_level:(ERROR,error) time:last_24h sort:time:desc limit:100"}}"
              }
            />
            <.severity_row
              label="Warning"
              count={Map.get(@summary, :warning, 0)}
              total={Map.get(@summary, :total, 0)}
              color="info"
              href={
                ~p"/events?#{%{q: "in:events log_level:(WARNING,warning,WARN,warn) time:last_24h sort:time:desc limit:100"}}"
              }
            />
            <.severity_row
              label="Info"
              count={Map.get(@summary, :info, 0)}
              total={Map.get(@summary, :total, 0)}
              color="primary"
              href={
                ~p"/events?#{%{q: "in:events log_level:(INFO,info,DEBUG,debug,TRACE,trace) time:last_24h sort:time:desc limit:100"}}"
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
            <p class="text-sm text-base-content/60">No high-severity events</p>
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
    <div class="h-80 rounded-xl border border-base-200 bg-base-100 flex flex-col overflow-hidden">
      <header class="px-4 py-3 bg-base-200/40 flex items-start justify-between gap-3 shrink-0">
        <.link
          href={~p"/observability?#{%{tab: "logs"}}"}
          class="hover:text-primary transition-colors"
        >
          <div class="text-sm font-semibold">Critical Logs</div>
        </.link>
        <.link
          href={
            ~p"/observability?#{%{tab: "logs", q: "in:logs severity_text:(fatal,FATAL,critical,CRITICAL,emergency,EMERGENCY,alert,ALERT,error,ERROR,err,ERR) time:last_24h sort:timestamp:desc limit:100"}}"
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
                ~p"/observability?#{%{tab: "logs", q: "in:logs severity_text:(fatal,FATAL,critical,CRITICAL,emergency,EMERGENCY,alert,ALERT) time:last_24h sort:timestamp:desc limit:100"}}"
              }
            />
            <.severity_row
              label="Error"
              count={Map.get(@summary, :error, 0)}
              total={Map.get(@summary, :total, 0)}
              color="warning"
              href={
                ~p"/observability?#{%{tab: "logs", q: "in:logs severity_text:(error,ERROR,err,ERR) time:last_24h sort:timestamp:desc limit:100"}}"
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
                ~p"/observability?#{%{tab: "logs", q: "in:logs severity_text:(info,INFO,information,INFORMATION,informational,INFORMATIONAL,notice,NOTICE) time:last_24h sort:timestamp:desc limit:100"}}"
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
            <p class="text-sm text-base-content/60">No critical, fatal, or error logs</p>
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
            <div class="text-xl font-bold text-primary">{format_compact_number(@metrics_count)}</div>
            <div class="text-xs text-base-content/60">Metrics</div>
          </div>
          <div class="rounded-lg bg-base-200/50 p-3 text-center">
            <div class="text-xl font-bold text-secondary">{format_compact_number(@traces_count)}</div>
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
            <span class="text-xs font-medium text-base-content/70">Slow Spans</span>
            <span class={[
              "text-xs font-bold",
              (@slow_spans_count > 0 && "text-warning") || "text-base-content/50"
            ]}>
              {format_compact_number(@slow_spans_count)}
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

    assigns =
      assigns
      |> assign(:cpu, utilization_cpu(svc))
      |> assign(:mem, utilization_mem(svc))
      |> assign(:host, utilization_host(svc))

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
      extract_numeric(Map.get(svc, "percent") || Map.get(svc, "value") || Map.get(svc, "used_percent") || 0)

    host = utilization_host(svc)

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
    host = Map.get(svc, "host") || Map.get(svc, "uid") || Map.get(svc, "device_id") || "Unknown"
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
    <tr
      class="hover:bg-base-200/50 cursor-pointer"
      tabindex="0"
      role="link"
      phx-click={JS.navigate(@href)}
    >
      <td class={severity_text_class(@color)}>{@label}</td>
      <td class={["text-center font-bold", severity_text_class(@color)]}>
        {format_compact_number(@count)}
      </td>
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
          name={severity_icon(event_entry_severity(@event))}
          class={[
            "size-4 mt-0.5",
            severity_text_class(severity_color(event_entry_severity(@event)))
          ]}
        />
        <div class="flex-1 min-w-0">
          <div class="text-sm font-medium truncate">{event_entry_host(@event)}</div>
          <div class="text-xs text-base-content/60 truncate">
            {event_entry_message(@event)}
          </div>
          <div class={[
            "text-xs",
            severity_text_class(severity_color(event_entry_severity(@event)))
          ]}>
            {event_entry_severity(@event)} · {format_relative_time(event_entry_timestamp(@event))}
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
      "Fatal" -> "hero-x-circle"
      "Critical" -> "hero-shield-exclamation"
      "High" -> "hero-exclamation-triangle"
      "Medium" -> "hero-exclamation-circle"
      "Low" -> "hero-information-circle"
      "Informational" -> "hero-information-circle"
      _ -> "hero-exclamation-circle"
    end
  end

  defp severity_color(severity) do
    case normalize_severity(severity) do
      "Fatal" -> "error"
      "Critical" -> "error"
      "High" -> "warning"
      "Medium" -> "info"
      "Low" -> "primary"
      "Informational" -> "primary"
      _ -> "neutral"
    end
  end

  defp log_level_icon(level) do
    case normalize_log_level(level) do
      "Critical" -> "hero-exclamation-triangle"
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
      "Critical" -> "error"
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
          diff_seconds < 86_400 -> "#{div(diff_seconds, 3600)}h ago"
          diff_seconds < 604_800 -> "#{div(diff_seconds, 86_400)}d ago"
          true -> Calendar.strftime(dt, "%b %d")
        end

      _ ->
        "Unknown"
    end
  end

  defp format_relative_time(_), do: "Unknown"

  defp event_entry_host(%{} = event) do
    first_non_blank([
      Map.get(event, "host"),
      get_in(event, ["device", "name"]),
      Map.get(event, "source"),
      Map.get(event, "uid"),
      Map.get(event, "device_id"),
      Map.get(event, "subject")
    ]) || "Unknown"
  end

  defp event_entry_host(_), do: "Unknown"

  defp event_entry_message(%{} = event) do
    message =
      Map.get(event, "short_message") ||
        Map.get(event, "message") ||
        Map.get(event, "subject") ||
        Map.get(event, "description")

    case message do
      value when is_binary(value) and value != "" -> String.slice(value, 0, 200)
      value when not is_nil(value) -> value |> to_string() |> String.slice(0, 200)
      _ -> "No details"
    end
  end

  defp event_entry_message(_), do: "No details"

  defp event_entry_severity(%{} = event) do
    first_non_blank([
      Map.get(event, "severity"),
      normalize_log_level(Map.get(event, "log_level")),
      severity_label_from_id(Map.get(event, "severity_id"))
    ]) || "Unknown"
  end

  defp event_entry_severity(_), do: "Unknown"

  defp event_entry_timestamp(%{} = event) do
    Map.get(event, "time") || Map.get(event, "event_timestamp") || Map.get(event, "created_at")
  end

  defp event_entry_timestamp(_), do: nil

  defp severity_label_from_id(nil), do: nil

  defp severity_label_from_id(value) do
    case to_int(value) do
      6 -> "Fatal"
      5 -> "Critical"
      4 -> "High"
      3 -> "Medium"
      2 -> "Low"
      1 -> "Informational"
      _ -> nil
    end
  end

  defp first_non_blank(values) when is_list(values) do
    Enum.find_value(values, fn
      value when is_binary(value) ->
        trimmed = String.trim(value)
        if trimmed == "", do: nil, else: trimmed

      nil ->
        nil

      value ->
        value
    end)
  end
end
