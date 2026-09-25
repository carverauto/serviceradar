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
  The SRQL time token the cards count, with the window it resolves to.
  """
  @spec window(String.t() | nil) :: {String.t(), DateTime.t(), DateTime.t()}
  def window(query) do
    with true <- is_binary(query),
         {:ok, time} <- TimeWindow.time_token_from_query(query),
         {:ok, {start_at, end_at}} <- TimeWindow.parse_time_token(time),
         true <- DateTime.before?(start_at, end_at) do
      {time, start_at, end_at}
    else
      _ ->
        {:ok, {start_at, end_at}} = TimeWindow.parse_time_token(@default_time)
        {@default_time, start_at, end_at}
    end
  end

  @doc """
  The Events query a card links to: the card's severity over the window it
  counted, so the list total matches the number on the card.
  """
  @spec severity_query(String.t(), String.t()) :: String.t()
  def severity_query(severity, time), do: "in:events severity:#{severity} time:#{time} sort:time:desc"
end
