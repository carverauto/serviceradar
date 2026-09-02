defmodule ServiceRadarWebNGWeb.DeviceLive.ProcessMetricsComponents do
  @moduledoc false

  use ServiceRadarWebNGWeb, :html

  import ServiceRadarWebNGWeb.DeviceLive.ProcessTablePagination, only: [search_bar: 1, paginator: 1]
  import ServiceRadarWebNGWeb.SRQLComponents, only: [srql_sparkline: 1]

  alias ServiceRadarWebNGWeb.DeviceLive.ProcessTablePagination

  # ---------------------------------------------------------------------------
  # Process Metrics Section
  # ---------------------------------------------------------------------------

  attr(:metrics, :list, required: true)
  attr(:search, :string, default: "")
  attr(:page, :integer, default: 1)
  attr(:timezone, :string, default: "Etc/UTC")

  def process_metrics_section(assigns) do
    all_rows = assigns.metrics || []

    last_sampled =
      all_rows
      |> Enum.max_by(&timestamp_sort_key/1, fn -> nil end)
      |> case do
        nil -> nil
        row -> Map.get(row, "timestamp")
      end

    pagination =
      ProcessTablePagination.paginate(all_rows, assigns.search, assigns.page, fields: &process_metric_search_fields/1)

    assigns =
      assigns
      |> assign(:rows, pagination.rows)
      |> assign(:pagination, pagination)
      |> assign(:row_count, pagination.total)
      |> assign(:last_sampled, last_sampled)

    ~H"""
    <div class="rounded-xl border border-sr-line bg-sr-surface">
      <div class="px-4 py-3 border-b border-sr-line">
        <div class="flex items-center justify-between gap-3">
          <div class="flex items-center gap-2">
            <.icon name="hero-command-line" class="size-4 text-accent" />
            <span class="text-sm font-semibold">Processes</span>
            <span class="text-xs text-sr-muted">
              last 15m{if @row_count > 0, do: " · top #{@row_count} by CPU", else: ""}
            </span>
          </div>
          <div class="text-xs text-sr-muted">
            <.user_time
              :if={@row_count > 0}
              id="device-process-metrics-last-sampled-at"
              value={@last_sampled}
              timezone={@timezone}
              style={:compact}
              class="font-mono"
            />
          </div>
        </div>

        <div :if={@row_count > 0} class="mt-3">
          <.search_bar
            id="process-metrics-search"
            event="process_metrics_search"
            search={@search}
            placeholder="Search by process, PID, status…"
            total={@pagination.total}
            filtered_total={@pagination.filtered_total}
            filtered?={@pagination.filtered?}
          />
        </div>
      </div>

      <div :if={@row_count == 0} class="p-6 text-center">
        <.icon name="hero-command-line" class="size-10 text-sr-ink/20 mx-auto" />
        <p class="text-sm text-sr-muted mt-2">No process metrics collected.</p>
        <p class="text-xs text-sr-muted mt-1">
          Enable process collection in the sysmon profile and wait for samples.
        </p>
      </div>

      <div
        :if={@row_count > 0 and @pagination.filtered_total == 0}
        class="p-6 text-center text-sm text-sr-muted"
      >
        No processes match the current search.
      </div>

      <div :if={@pagination.filtered_total > 0} class="p-4 overflow-x-auto">
        <table class={ui_table_class(size: "xs")}>
          <thead>
            <tr>
              <th>Process</th>
              <th class="text-right">PID</th>
              <th class="text-right">CPU %</th>
              <th>CPU Trend</th>
              <th class="text-right">Memory</th>
              <th>Status</th>
              <th>Sampled</th>
            </tr>
          </thead>
          <tbody>
            <%= for {row, index} <- Enum.with_index(@rows) do %>
              <tr class="hover">
                <td class="text-xs font-medium">{format_value(Map.get(row, "name"))}</td>
                <td class="text-xs font-mono text-right">{format_value(Map.get(row, "pid"))}</td>
                <td class="text-xs font-mono text-right">
                  {format_pct(parse_number(Map.get(row, "cpu_usage")))}%
                </td>
                <td class="text-xs text-sr-brand">
                  <.srql_sparkline points={Map.get(row, "_cpu_sparkline", [])} />
                </td>
                <td class="text-xs font-mono text-right">
                  {format_bytes(Map.get(row, "memory_usage"))}
                </td>
                <td class="text-xs">{format_value(Map.get(row, "status"))}</td>
                <td class="text-xs font-mono">
                  <.user_time
                    id={"device-process-metric-#{process_time_key(row, index)}-timestamp"}
                    value={Map.get(row, "timestamp")}
                    timezone={@timezone}
                    style={:compact}
                  />
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>

      <.paginator
        page={@pagination.page}
        page_count={@pagination.page_count}
        range_start={@pagination.range_start}
        range_end={@pagination.range_end}
        filtered_total={@pagination.filtered_total}
        prev_event="process_metrics_prev_page"
        next_event="process_metrics_next_page"
      />
    </div>
    """
  end

  defp process_metric_search_fields(row) when is_map(row) do
    [
      Map.get(row, "name"),
      Map.get(row, "pid"),
      Map.get(row, "status")
    ]
  end

  defp process_metric_search_fields(_row), do: []

  defp timestamp_sort_key(row) when is_map(row) do
    case parse_datetime(Map.get(row, "timestamp")) do
      {:ok, dt} -> DateTime.to_unix(dt, :microsecond)
      _ -> 0
    end
  end

  defp timestamp_sort_key(_), do: 0

  defp parse_datetime(%DateTime{} = dt), do: {:ok, dt}

  defp parse_datetime(%NaiveDateTime{} = ndt) do
    {:ok, DateTime.from_naive!(ndt, "Etc/UTC")}
  end

  defp parse_datetime(value) when is_binary(value) do
    with {:error, _} <- DateTime.from_iso8601(value),
         {:ok, ndt} <- NaiveDateTime.from_iso8601(value) do
      {:ok, DateTime.from_naive!(ndt, "Etc/UTC")}
    else
      {:ok, dt, _offset} -> {:ok, dt}
      {:error, _} -> {:error, :invalid_datetime}
    end
  end

  defp parse_datetime(_), do: {:error, :invalid_datetime}

  defp process_time_key(row, index) do
    [Map.get(row, "id"), Map.get(row, "uid"), Map.get(row, "pid"), Map.get(row, "name")]
    |> Enum.find_value(&process_id_fragment/1)
    |> Kernel.||(Integer.to_string(index))
  end

  defp process_id_fragment(value) when value in [nil, ""], do: nil

  defp process_id_fragment(value) do
    case value |> to_string() |> String.replace(~r/[^a-zA-Z0-9_-]+/, "-") |> String.trim("-") do
      "" -> nil
      fragment -> fragment
    end
  end

  defp parse_number(value) when is_integer(value), do: value * 1.0
  defp parse_number(value) when is_float(value), do: value

  defp parse_number(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" ->
        nil

      match?({_, ""}, Float.parse(value)) ->
        {v, ""} = Float.parse(value)
        v

      match?({_, ""}, Integer.parse(value)) ->
        {v, ""} = Integer.parse(value)
        v * 1.0

      true ->
        nil
    end
  end

  defp parse_number(_), do: nil

  defp format_pct(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 1)
  defp format_pct(value) when is_integer(value), do: Integer.to_string(value)
  defp format_pct(_), do: "—"

  defp format_bytes(bytes) when is_number(bytes) do
    cond do
      bytes >= 1_099_511_627_776 -> "#{Float.round(bytes / 1_099_511_627_776 * 1.0, 1)} TB"
      bytes >= 1_073_741_824 -> "#{Float.round(bytes / 1_073_741_824 * 1.0, 1)} GB"
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576 * 1.0, 1)} MB"
      bytes >= 1024 -> "#{Float.round(bytes / 1024 * 1.0, 1)} KB"
      true -> "#{bytes} B"
    end
  end

  defp format_bytes(_), do: "—"

  defp format_value(nil), do: "—"
  defp format_value(""), do: "—"
  defp format_value(v) when is_binary(v), do: v
  defp format_value(v), do: to_string(v)
end
