defmodule ServiceRadar.Analytics.StarRocks.Workload.Pinner do
  @moduledoc """
  Pins this node's pooled StarRocks sessions to its resource group once the
  group exists, however late that is.

  The pool pins a session when it connects (`Workload.pin_session/3`), and a
  pooled session lives as long as its connection. `SchemaMigrator` creates
  the groups only after the versioned DDL, which can take hours, so on every
  fresh install and every upgrade that introduces them the pools connect
  first: each of those sessions stays in `default_wg` and reports itself
  here. This process then retries the pin every 30 seconds on a pooled
  session and, as soon as one pins, reconnects the pool so that
  every session is pinned again as it reconnects.

  It does not wait for the migrator. Only one replica creates the groups, and
  the others reach that point only when their own migrator runs to the end,
  which a replica queued behind hours of DDL may never do.

  A missing group is logged once per outage, not once per session. Queries
  keep running in `default_wg` meanwhile; none fails for want of a group.
  """

  use GenServer

  alias ServiceRadar.Analytics.StarRocks.MySQL
  alias ServiceRadar.Analytics.StarRocks.Workload

  require Logger

  @probe_interval_ms 30_000

  @doc """
  Reports a session that connected but could not be pinned. Called from the
  pool's `after_connect`, so it never blocks the connection.
  """
  @spec session_unpinned(term()) :: :ok
  def session_unpinned(reason), do: GenServer.cast(__MODULE__, {:unpinned, reason})

  @doc """
  Options, each defaulting to production: `:probe` (pins one pooled session,
  `(group -> :ok | {:error, term})`), `:repin` (reconnects the pool) and
  `:probe_interval_ms`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    {:ok,
     %{
       group: Workload.resource_group(Workload.current()),
       probe: Keyword.get(opts, :probe, &probe/1),
       repin: Keyword.get(opts, :repin, &MySQL.repin_sessions/0),
       interval: Keyword.get(opts, :probe_interval_ms, @probe_interval_ms),
       unpinned?: false,
       timer: nil
     }}
  end

  @impl true
  def handle_cast({:unpinned, reason}, state) do
    {:noreply, state |> warn_once(reason) |> schedule_probe()}
  end

  @impl true
  def handle_info(:probe, state) do
    state = %{state | timer: nil}

    case state.probe.(state.group) do
      :ok ->
        state.repin.()
        Logger.info("StarRocks sessions pinned to resource group #{state.group}")
        {:noreply, %{state | unpinned?: false}}

      {:error, reason} ->
        {:noreply, state |> warn_once(reason) |> schedule_probe()}
    end
  end

  defp warn_once(%{unpinned?: true} = state, _reason), do: state

  defp warn_once(state, reason) do
    Logger.warning(
      "StarRocks sessions not pinned to resource group #{state.group}; " <>
        "they run in default_wg until it exists",
      reason: inspect(reason)
    )

    %{state | unpinned?: true}
  end

  defp schedule_probe(%{timer: nil} = state),
    do: %{state | timer: Process.send_after(self(), :probe, state.interval)}

  defp schedule_probe(state), do: state

  defp probe(group), do: Workload.pin(MySQL, group, &MySQL.query(&2, conn: &1))
end
