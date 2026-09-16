defmodule ServiceRadarWebNGWeb.LogLive.NetflowSummary do
  @moduledoc false

  alias ServiceRadarWebNGWeb.NetflowLive.Visualize.TimeWindow
  alias ServiceRadarWebNGWeb.NetflowVisualize.Query

  def empty do
    %{
      total: 0,
      tcp: 0,
      udp: 0,
      other: 0,
      total_bytes: 0,
      total_packets: 0,
      avg_bps: 0.0,
      avg_pps: 0.0,
      window_seconds: 0,
      error: nil
    }
  end

  def load(srql_module, query, scope, observed_rows? \\ false, opts \\ []) do
    base = query |> Query.flows_base_query("last_1h") |> Query.flows_sanitize_for_stats()

    with {:ok, seconds} <- window_seconds(base, opts),
         {:ok, total} <- scalar(srql_module, base, scope, "count(*) as total", "total"),
         {:ok, bytes} <- scalar(srql_module, base, scope, "sum(bytes_total) as total_bytes", "total_bytes"),
         {:ok, packets} <- scalar(srql_module, base, scope, "sum(packets_total) as total_packets", "total_packets"),
         {:ok, protocols} <- rows(srql_module, ~s|#{base} stats:"count(*) as total by protocol_num" limit:256|, scope),
         :ok <- consistent_totals(total, protocols, observed_rows?) do
      tcp = protocol_count(protocols, 6)
      udp = protocol_count(protocols, 17)

      {:ok,
       %{
         total: total,
         tcp: tcp,
         udp: udp,
         other: max(total - tcp - udp, 0),
         total_bytes: bytes,
         total_packets: packets,
         avg_bps: bytes * 8.0 / seconds,
         avg_pps: packets * 1.0 / seconds,
         window_seconds: seconds
       }}
    end
  end

  defp window_seconds(base, opts) do
    case Keyword.fetch(opts, :window_seconds) do
      {:ok, seconds} when is_integer(seconds) and seconds > 0 ->
        {:ok, seconds}

      :error ->
        with {:ok, {start_at, end_at}} <- TimeWindow.parse_time_window_from_query(base) do
          {:ok, max(DateTime.diff(end_at, start_at, :second), 1)}
        end

      _ ->
        {:error, :invalid_netflow_window}
    end
  end

  defp scalar(srql_module, base, scope, expression, key) do
    with {:ok, [row]} <- rows(srql_module, ~s|#{base} stats:"#{expression}" limit:1|, scope),
         true <- Map.has_key?(row, key),
         {:ok, value} <- count(row[key]) do
      {:ok, value}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_netflow_summary}
    end
  end

  defp rows(srql_module, query, scope) do
    case srql_module.query(query, %{scope: scope}) do
      {:ok, %{"results" => rows}} when is_list(rows) ->
        {:ok,
         Enum.map(rows, fn
           %{"payload" => %{} = payload} -> payload
           %{} = row -> row
           _ -> %{}
         end)}

      _ ->
        {:error, :netflow_summary_unavailable}
    end
  end

  # A materialized aggregate may be empty or stale while raw records exist.
  # The current explorer page is evidence of missing coverage, never a total.
  defp consistent_totals(0, _protocols, true), do: {:error, :netflow_summary_incomplete}

  defp consistent_totals(total, protocols, _observed_rows?) do
    if total == 0 and Enum.any?(protocols, &(number(&1["total"]) > 0)),
      do: {:error, :netflow_summary_incomplete},
      else: :ok
  end

  defp protocol_count(rows, protocol) do
    rows |> Enum.filter(&(number(&1["protocol_num"]) == protocol)) |> Enum.map(&number(&1["total"])) |> Enum.sum()
  end

  defp count(nil), do: {:ok, 0}
  defp count(value) when is_integer(value) and value >= 0, do: {:ok, value}
  defp count(value) when is_float(value) and value >= 0, do: {:ok, trunc(value)}
  defp count(%Decimal{} = value), do: value |> Decimal.to_integer() |> count()

  defp count(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> count(number)
      _ -> {:error, :invalid_netflow_summary}
    end
  end

  defp count(_), do: {:error, :invalid_netflow_summary}

  defp number(value) do
    case count(value) do
      {:ok, number} -> number
      _ -> 0
    end
  end
end
