defmodule ServiceRadarWebNGWeb.LogLive.EventSummary do
  @moduledoc """
  Severity counts for the Events tab cards.

  The cards count the window the SRQL query lists, relative (`time:last_7d`)
  or absolute (`time:[start,end]`), and fall back to the last seven days when
  the query names none. Counting goes through the loader behind the
  dashboard's Events Over Time chart, so both surfaces agree: it reads the
  warehouse when events are served from StarRocks, and on CNPG fills whatever
  the short-retention hourly rollup no longer covers from raw `ocsf_events`.
  """

  alias ServiceRadarWebNGWeb.DashboardLive.EventWindow
  alias ServiceRadarWebNGWeb.NetflowLive.Visualize.TimeWindow

  @default_time "last_7d"
  # A plain events list query is capped at 90 days by SRQL
  # (rust/srql/src/query/cagg.rs `max_time_range_days_for_ast`, enforced by
  # rust/srql/src/time.rs `resolve_with_max_days`). Keep in step.
  @max_span_days 90
  @max_span_seconds @max_span_days * 86_400

  @spec default_time() :: String.t()
  def default_time, do: @default_time

  @spec empty() :: map()
  def empty, do: %{total: 0, critical: 0, high: 0, medium: 0, low: 0, time: @default_time}

  @doc """
  Loads the severity counts for `query`. `opts` are passed to
  `EventWindow.load/2`.
  """
  @spec load(String.t() | nil, keyword()) :: map()
  def load(query, opts \\ []) do
    {time, start_at, end_at} = window(query)
    window = %{value: time, start: start_at, end: end_at, seconds: max(DateTime.diff(end_at, start_at), 1)}

    case EventWindow.load(window, opts) do
      {:ok, %{event_summary: summary}} ->
        summary
        |> Map.update!(:critical, &(&1 + Map.get(summary, :fatal, 0)))
        |> Map.put(:time, time)

      _ ->
        Map.put(empty(), :time, time)
    end
  end

  @doc """
  The SRQL time token the cards count, with the window it resolves to at `now`.

  Every form SRQL accepts resolves the way SRQL resolves it. A query that names
  no time, or one SRQL would reject, counts the last seven days.
  """
  @spec window(String.t() | nil, DateTime.t()) :: {String.t(), DateTime.t(), DateTime.t()}
  def window(query, now \\ DateTime.utc_now()) do
    now = DateTime.truncate(now, :second)

    with true <- is_binary(query),
         {:ok, time} <- TimeWindow.time_token_from_query(query),
         {:ok, start_at, end_at} <- resolve(time, now) do
      {time, start_at, end_at}
    else
      _ ->
        {:ok, start_at, end_at} = resolve(@default_time, now)
        {@default_time, start_at, end_at}
    end
  end

  defp resolve(token, now) do
    value = token |> String.trim() |> String.trim("\"") |> String.trim("'")
    value = if String.starts_with?(value, "["), do: value, else: String.downcase(value)

    with {:ok, start_at, end_at} <- resolve_value(value, now),
         true <- DateTime.compare(start_at, end_at) != :gt,
         true <- DateTime.diff(end_at, start_at) <= @max_span_seconds do
      {:ok, start_at, end_at}
    else
      _ -> :error
    end
  end

  defp resolve_value("today", now) do
    {:ok, midnight(DateTime.to_date(now)), now}
  end

  defp resolve_value("yesterday", now) do
    today = DateTime.to_date(now)
    {:ok, midnight(Date.add(today, -1)), midnight(today)}
  end

  defp resolve_value("[" <> _ = value, now) do
    if String.ends_with?(value, "]") do
      value |> String.slice(1..-2//1) |> String.split(",", parts: 2) |> resolve_range(now)
    else
      :error
    end
  end

  defp resolve_value(value, now) do
    with {:ok, seconds} <- relative_seconds(value) do
      {:ok, DateTime.add(now, -seconds, :second), now}
    end
  end

  defp resolve_range([start_raw, end_raw], now) do
    case {String.trim(start_raw), String.trim(end_raw)} do
      {"", ""} ->
        :error

      {"", end_raw} ->
        with {:ok, end_at} <- parse_datetime(end_raw) do
          {:ok, DateTime.add(end_at, -@max_span_seconds, :second), end_at}
        end

      {start_raw, ""} ->
        with {:ok, start_at} <- parse_datetime(start_raw) do
          {:ok, start_at, now}
        end

      {start_raw, end_raw} ->
        with {:ok, start_at} <- parse_datetime(start_raw),
             {:ok, end_at} <- parse_datetime(end_raw) do
          {:ok, start_at, end_at}
        end
    end
  end

  defp resolve_range(_parts, _now), do: :error

  defp relative_seconds(value) do
    normalized = String.replace(value, ["_", "-", " "], "")
    normalized = String.replace_prefix(normalized, "last", "")

    with [_, digits, unit] <- Regex.run(~r/\A(\d{1,9})([a-z]+)\z/, normalized),
         {:ok, unit_seconds} <- unit_seconds(unit) do
      {:ok, String.to_integer(digits) * unit_seconds}
    else
      _ -> :error
    end
  end

  defp unit_seconds(unit) when unit in ~w(m min mins minute minutes), do: {:ok, 60}
  defp unit_seconds(unit) when unit in ~w(h hour hours), do: {:ok, 3600}
  defp unit_seconds(unit) when unit in ~w(d day days), do: {:ok, 86_400}
  defp unit_seconds(unit) when unit in ~w(y year years), do: {:ok, 365 * 86_400}
  defp unit_seconds(_unit), do: :error

  defp parse_datetime(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        {:ok, DateTime.truncate(datetime, :second)}

      _ ->
        with {:ok, naive} <- NaiveDateTime.from_iso8601(value),
             {:ok, datetime} <- DateTime.from_naive(naive, "Etc/UTC") do
          {:ok, DateTime.truncate(datetime, :second)}
        else
          _ -> :error
        end
    end
  end

  defp midnight(date), do: DateTime.new!(date, ~T[00:00:00], "Etc/UTC")

  @doc """
  The Events query a card links to: the card's severity over the window it
  counted, so the list total matches the number on the card.
  """
  @spec severity_query(String.t(), String.t()) :: String.t()
  def severity_query(severity, time) do
    time = if String.contains?(time, " "), do: ~s("#{time}"), else: time
    "in:events severity:#{severity} time:#{time} sort:time:desc"
  end
end
