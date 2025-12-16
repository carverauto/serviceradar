defmodule ServiceRadarWebNGWeb.MetricLive.Show do
  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.UIComponents

  @recent_window "last_1h"
  @recent_limit 60

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Metric")
     |> assign(:span_id, nil)
     |> assign(:metric, nil)
     |> assign(:recent, [])
     |> assign(:histogram, nil)
     |> assign(:error, nil)}
  end

  @impl true
  def handle_params(%{"span_id" => span_id}, _uri, socket) do
    srql = srql_module()
    span_id = span_id |> to_string() |> String.trim()

    socket =
      socket
      |> assign(:span_id, span_id)
      |> load_metric(srql, span_id)

    {:noreply, socket}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, assign(socket, :error, "Missing metric span_id")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-7xl p-6">
        <.header>
          Metric
          <:subtitle>
            <span class="font-mono text-xs">{@span_id || "—"}</span>
          </:subtitle>
          <:actions>
            <.ui_button href={~p"/observability?#{%{tab: "metrics"}}"} variant="ghost" size="sm">
              Back to Observability
            </.ui_button>
          </:actions>
        </.header>

        <div :if={is_binary(@error)} class="alert alert-error mb-4">
          <.icon name="hero-exclamation-triangle" class="size-5" />
          <span class="text-sm">{@error}</span>
        </div>

        <div :if={is_map(@metric)} class="grid grid-cols-1 lg:grid-cols-3 gap-4">
          <.ui_panel class="lg:col-span-2">
            <:header>
              <div class="min-w-0">
                <div class="text-sm font-semibold">Details</div>
                <div class="text-xs text-base-content/60 truncate">
                  {Map.get(@metric, "service_name") || "—"} · {metric_operation(@metric)}
                </div>
              </div>
              <div class="flex items-center gap-2">
                <.link
                  :if={is_binary(Map.get(@metric, "trace_id")) and Map.get(@metric, "trace_id") != ""}
                  href={correlated_logs_href(@metric)}
                  class="btn btn-xs btn-outline"
                >
                  Logs
                </.link>
                <.link
                  :if={is_binary(Map.get(@metric, "trace_id")) and Map.get(@metric, "trace_id") != ""}
                  href={correlated_trace_href(@metric)}
                  class="btn btn-xs btn-outline"
                >
                  Trace
                </.link>
              </div>
            </:header>

            <div class="grid grid-cols-1 md:grid-cols-2 gap-3">
              <.kv label="Time" value={format_timestamp(@metric)} mono />
              <.kv label="Service" value={Map.get(@metric, "service_name")} />
              <.kv label="Type" value={Map.get(@metric, "metric_type")} />
              <.kv label="Operation" value={metric_operation(@metric)} />
              <.kv label="Value" value={format_metric_value(@metric)} mono />
              <.kv
                label="Slow"
                value={if Map.get(@metric, "is_slow") == true, do: "true", else: "false"}
                mono
              />
              <.kv label="HTTP" value={http_summary(@metric)} />
              <.kv label="gRPC" value={grpc_summary(@metric)} />
              <.kv label="Trace ID" value={Map.get(@metric, "trace_id")} mono />
              <.kv label="Span ID" value={Map.get(@metric, "span_id")} mono />
              <.kv label="Component" value={Map.get(@metric, "component")} />
              <.kv label="Level" value={Map.get(@metric, "level")} />
            </div>
          </.ui_panel>

          <.ui_panel>
            <:header>
              <div class="min-w-0">
                <div class="text-sm font-semibold">Visualization</div>
                <div class="text-xs text-base-content/60">
                  Sample from {@recent_window} ({length(@recent)} points)
                </div>
              </div>
            </:header>

            <div :if={@recent == []} class="text-sm text-base-content/60">
              No recent samples found for this metric.
            </div>

            <div :if={is_map(@histogram)} class="space-y-3">
              <div class="text-xs text-base-content/60">
                Histogram of recent values (sample-based)
              </div>
              <.histogram bins={Map.get(@histogram, :bins, [])} />
              <div class="text-xs text-base-content/50 font-mono">
                min={format_ms_number(Map.get(@histogram, :min, 0.0))}ms · p50={format_ms_number(
                  Map.get(@histogram, :p50, 0.0)
                )}ms · p95={format_ms_number(Map.get(@histogram, :p95, 0.0))}ms · max={format_ms_number(
                  Map.get(@histogram, :max, 0.0)
                )}ms
              </div>
            </div>

            <div :if={is_list(@recent) and @recent != [] and is_nil(@histogram)} class="space-y-3">
              <div class="text-xs text-base-content/60">
                Recent values (sample-based)
              </div>
              <.sparkline values={Enum.map(@recent, &metric_value_ms/1)} />
            </div>
          </.ui_panel>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, default: nil
  attr :mono, :boolean, default: false

  defp kv(assigns) do
    ~H"""
    <div class="rounded-lg border border-base-200 bg-base-100 p-3">
      <div class="text-[11px] uppercase tracking-wider text-base-content/50 mb-1">{@label}</div>
      <div class={["text-sm", @mono && "font-mono text-xs"]}>{format_value(@value)}</div>
    </div>
    """
  end

  defp format_value(nil), do: "—"
  defp format_value(""), do: "—"
  defp format_value(v) when is_binary(v), do: v
  defp format_value(v), do: to_string(v)

  attr :values, :list, default: []

  defp sparkline(assigns) do
    values =
      assigns.values
      |> Enum.filter(&is_number/1)
      |> Enum.take(@recent_limit)
      |> Enum.reverse()

    {min_v, max_v} =
      case values do
        [] -> {0.0, 0.0}
        _ -> {Enum.min(values), Enum.max(values)}
      end

    points =
      values
      |> Enum.with_index()
      |> Enum.map(fn {v, idx} ->
        x = if length(values) > 1, do: idx / (length(values) - 1) * 200.0, else: 0.0
        y = normalize_y(v, min_v, max_v)
        "#{fmt(x)},#{fmt(y)}"
      end)
      |> Enum.join(" ")

    assigns =
      assigns
      |> assign(:points, points)

    ~H"""
    <div class="w-full">
      <svg viewBox="0 0 200 60" class="w-full h-16">
        <polyline
          fill="none"
          stroke="#8be9fd"
          stroke-width="2"
          stroke-linecap="round"
          stroke-linejoin="round"
          points={@points}
        />
      </svg>
    </div>
    """
  end

  defp normalize_y(v, min_v, max_v) do
    range = if max_v == min_v, do: 1.0, else: max_v - min_v
    55.0 - (v - min_v) / range * 50.0
  end

  defp fmt(num) when is_float(num), do: :erlang.float_to_binary(num, decimals: 1)
  defp fmt(num) when is_integer(num), do: Integer.to_string(num)

  defp format_ms_number(value) when is_float(value) do
    :erlang.float_to_binary(value, decimals: 1)
    |> String.trim_trailing("0")
    |> String.trim_trailing(".")
  end

  defp format_ms_number(value) when is_integer(value), do: Integer.to_string(value)
  defp format_ms_number(_), do: "0"

  attr :bins, :list, default: []

  defp histogram(assigns) do
    max_count =
      assigns.bins
      |> Enum.map(& &1.count)
      |> case do
        [] -> 0
        values -> Enum.max(values)
      end

    assigns = assign(assigns, :max_count, max_count)

    ~H"""
    <div class="flex items-end gap-1 h-20">
      <%= for bin <- @bins do %>
        <% height =
          if @max_count > 0 do
            max(2, round(bin.count / @max_count * 100))
          else
            0
          end %>
        <div class="flex-1 flex flex-col items-center">
          <div
            class="w-full rounded bg-primary/40"
            style={"height: #{height}%"}
            title={"#{bin.count} samples"}
          />
        </div>
      <% end %>
    </div>
    """
  end

  defp load_metric(socket, srql, span_id) do
    query = "in:otel_metrics span_id:\"#{escape_srql(span_id)}\" sort:timestamp:desc limit:1"

    case srql.query(query) do
      {:ok, %{"results" => [%{} = metric | _]}} ->
        socket
        |> assign(:metric, metric)
        |> assign(:error, nil)
        |> load_recent(srql, metric)

      {:ok, %{"results" => []}} ->
        assign(socket, :error, "Metric not found") |> assign(:metric, nil)

      {:error, reason} ->
        assign(socket, :error, "SRQL error: #{format_error(reason)}") |> assign(:metric, nil)

      {:ok, other} ->
        assign(socket, :error, "Unexpected response: #{inspect(other)}") |> assign(:metric, nil)
    end
  end

  defp load_recent(socket, srql, %{} = metric) do
    service = Map.get(metric, "service_name")
    operation = Map.get(metric, "span_name")
    metric_type = Map.get(metric, "metric_type")

    query =
      [
        "in:otel_metrics",
        "time:#{@recent_window}",
        (is_binary(service) and service != "") && "service_name:\"#{escape_srql(service)}\"",
        (is_binary(operation) and operation != "") && "span_name:\"#{escape_srql(operation)}\"",
        (is_binary(metric_type) and metric_type != "") &&
          "metric_type:\"#{escape_srql(metric_type)}\"",
        "sort:timestamp:desc",
        "limit:#{@recent_limit}"
      ]
      |> Enum.filter(&is_binary/1)
      |> Enum.join(" ")

    case srql.query(query) do
      {:ok, %{"results" => rows}} when is_list(rows) ->
        histogram =
          case normalize_metric_type(metric_type) do
            "histogram" -> build_histogram(rows)
            _ -> nil
          end

        socket
        |> assign(:recent, rows)
        |> assign(:histogram, histogram)

      _ ->
        assign(socket, :recent, []) |> assign(:histogram, nil)
    end
  end

  defp build_histogram(rows) when is_list(rows) do
    values = rows |> Enum.map(&metric_value_ms/1) |> Enum.filter(&is_number/1)

    if values == [] do
      nil
    else
      min_v = Enum.min(values)
      max_v = Enum.max(values)
      bins = 10
      range = if max_v == min_v, do: 1.0, else: max_v - min_v
      width = range / bins

      counts =
        Enum.reduce(values, List.duplicate(0, bins), fn v, acc ->
          idx =
            if width <= 0 do
              0
            else
              trunc((v - min_v) / width)
            end

          idx = idx |> max(0) |> min(bins - 1)
          List.update_at(acc, idx, &(&1 + 1))
        end)

      sorted = Enum.sort(values)
      p50 = Enum.at(sorted, trunc(length(sorted) * 0.50)) || min_v
      p95 = Enum.at(sorted, trunc(length(sorted) * 0.95)) || max_v

      %{
        min: Float.round(min_v * 1.0, 1),
        p50: Float.round(p50 * 1.0, 1),
        p95: Float.round(p95 * 1.0, 1),
        max: Float.round(max_v * 1.0, 1),
        bins:
          counts
          |> Enum.with_index()
          |> Enum.map(fn {count, idx} ->
            %{
              idx: idx,
              count: count,
              from: Float.round(min_v + idx * width, 1),
              to: Float.round(min_v + (idx + 1) * width, 1)
            }
          end)
      }
    end
  end

  defp build_histogram(_), do: nil

  defp format_metric_value(metric) do
    value = metric_value_ms(metric)
    if is_number(value), do: "#{Float.round(value * 1.0, 1)}ms", else: "—"
  end

  defp metric_value_ms(%{} = metric) do
    cond do
      is_number(metric["duration_ms"]) ->
        metric["duration_ms"] * 1.0

      is_binary(metric["duration_ms"]) ->
        parse_float(metric["duration_ms"])

      is_number(metric["duration_seconds"]) ->
        metric["duration_seconds"] * 1000.0

      is_binary(metric["duration_seconds"]) ->
        case parse_float(metric["duration_seconds"]) do
          n when is_number(n) -> n * 1000.0
          _ -> nil
        end

      true ->
        nil
    end
  end

  defp metric_value_ms(_), do: nil

  defp parse_float(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp parse_float(_), do: nil

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

  defp http_summary(metric) do
    method = Map.get(metric, "http_method")
    route = Map.get(metric, "http_route")
    status = Map.get(metric, "http_status_code")

    cond do
      is_binary(method) and method != "" and is_binary(route) and route != "" ->
        "#{method} #{route} (#{status || "—"})"

      is_binary(route) and route != "" ->
        "#{route} (#{status || "—"})"

      true ->
        "—"
    end
  end

  defp grpc_summary(metric) do
    service = Map.get(metric, "grpc_service")
    method = Map.get(metric, "grpc_method")
    status = Map.get(metric, "grpc_status_code")

    cond do
      is_binary(service) and service != "" and is_binary(method) and method != "" ->
        "#{service}/#{method} (#{status || "—"})"

      is_binary(service) and service != "" ->
        "#{service} (#{status || "—"})"

      true ->
        "—"
    end
  end

  defp correlated_logs_href(metric) do
    trace_id = Map.get(metric, "trace_id")

    q =
      "in:logs trace_id:\"#{escape_srql(trace_id)}\" time:last_24h sort:timestamp:desc limit:50"

    "/observability?" <> URI.encode_query(%{tab: "logs", q: q, limit: 50})
  end

  defp correlated_trace_href(metric) do
    trace_id = Map.get(metric, "trace_id")

    q =
      "in:otel_trace_summaries trace_id:\"#{escape_srql(trace_id)}\" time:last_24h sort:timestamp:desc limit:20"

    "/observability?" <> URI.encode_query(%{tab: "traces", q: q, limit: 20})
  end

  defp format_timestamp(row) do
    ts = Map.get(row, "timestamp")

    case parse_timestamp(ts) do
      {:ok, dt} -> Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
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

  defp normalize_metric_type(nil), do: ""

  defp normalize_metric_type(value) when is_binary(value),
    do: value |> String.trim() |> String.downcase()

  defp normalize_metric_type(value), do: value |> to_string() |> normalize_metric_type()

  defp escape_srql(nil), do: ""

  defp escape_srql(value) when is_binary(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end

  defp escape_srql(value), do: value |> to_string() |> escape_srql()

  defp format_error(%Jason.DecodeError{} = err), do: Exception.message(err)
  defp format_error(%ArgumentError{} = err), do: Exception.message(err)
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

  defp srql_module do
    Application.get_env(:serviceradar_web_ng, :srql_module, ServiceRadarWebNG.SRQL)
  end
end
