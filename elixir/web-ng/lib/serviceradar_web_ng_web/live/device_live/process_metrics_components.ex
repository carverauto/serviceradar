defmodule ServiceRadarWebNGWeb.DeviceLive.ProcessMetricsComponents do
  @moduledoc false

  use ServiceRadarWebNGWeb, :html

  # ---------------------------------------------------------------------------
  # Process Metrics Section
  # ---------------------------------------------------------------------------

  attr(:metrics, :list, required: true)

  def process_metrics_section(assigns) do
    ~H"""
    <% rows = @metrics || [] %>
    <% row_count = length(rows) %>
    <% last_sampled =
      rows
      |> Enum.max_by(&timestamp_sort_key/1, fn -> nil end)
      |> case do
        nil -> nil
        row -> Map.get(row, "timestamp")
      end %>
    <div class="rounded-xl border border-base-200 bg-base-100">
      <div class="px-4 py-3 border-b border-base-200 flex items-center justify-between gap-3">
        <div class="flex items-center gap-2">
          <.icon name="hero-command-line" class="size-4 text-accent" />
          <span class="text-sm font-semibold">Processes</span>
          <span class="text-xs text-base-content/50">
            last 15m{if row_count > 0, do: " · top #{row_count} by CPU", else: ""}
          </span>
        </div>
        <div class="text-xs text-base-content/50">
          <span :if={row_count > 0} class="font-mono">{format_timestamp(last_sampled)}</span>
        </div>
      </div>

      <div :if={row_count == 0} class="p-6 text-center">
        <.icon name="hero-command-line" class="size-10 text-base-content/20 mx-auto" />
        <p class="text-sm text-base-content/70 mt-2">No process metrics collected.</p>
        <p class="text-xs text-base-content/50 mt-1">
          Enable process collection in the sysmon profile and wait for samples.
        </p>
      </div>

      <div :if={row_count > 0} class="p-4 overflow-x-auto">
        <table class="table table-xs">
          <thead>
            <tr>
              <th>Process</th>
              <th class="text-right">PID</th>
              <th class="text-right">CPU %</th>
              <th class="text-right">Memory</th>
              <th>Status</th>
              <th>Sampled</th>
            </tr>
          </thead>
          <tbody>
            <%= for row <- rows do %>
              <tr class="hover">
                <td class="text-xs font-medium">{format_value(Map.get(row, "name"))}</td>
                <td class="text-xs font-mono text-right">{format_value(Map.get(row, "pid"))}</td>
                <td class="text-xs font-mono text-right">
                  {format_pct(parse_number(Map.get(row, "cpu_usage")))}%
                </td>
                <td class="text-xs font-mono text-right">
                  {format_bytes(Map.get(row, "memory_usage"))}
                </td>
                <td class="text-xs">{format_value(Map.get(row, "status"))}</td>
                <td class="text-xs font-mono">{format_timestamp(Map.get(row, "timestamp"))}</td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  defp timestamp_sort_key(row) when is_map(row) do
    case parse_datetime(Map.get(row, "timestamp")) do
      {:ok, dt} -> DateTime.to_unix(dt, :microsecond)
      _ -> 0
    end
  end

  defp timestamp_sort_key(_), do: 0

  defp format_timestamp(nil), do: "—"

  defp format_timestamp(value) do
    case parse_datetime(value) do
      {:ok, %DateTime{} = dt} -> Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
      _ -> "—"
    end
  end

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
