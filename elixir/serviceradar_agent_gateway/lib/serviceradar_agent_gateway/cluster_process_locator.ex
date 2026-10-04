defmodule ServiceRadarAgentGateway.ClusterProcessLocator do
  @moduledoc """
  Cached answer to "which connected nodes run the process registered as `name`?"

  The gateway forwards to core coordinator singletons (`ServiceRadar.StatusHandler`,
  `ServiceRadar.ClusterHealth`) that live on whichever core node holds the
  coordinator role. Finding them used to take one `:rpc.call(node, Process,
  :whereis, ...)` per connected node, one after another, on every status push and
  every core call, so a single unresponsive node added its whole timeout to each.

  Lookups read an ETS table owned by this process and make no distribution round
  trips. Every located process is monitored, so its entry is dropped as soon as
  it exits or its node disconnects: a coordinator failover is a cache miss, never
  a stale hit that silently drops casts.

  On a miss every connected node is probed concurrently, and callers are answered
  as soon as any node reports the process. An unresponsive node therefore cannot
  delay a lookup that another node satisfies. When no node runs the process, the
  empty answer is kept for five seconds (and forgotten as soon as a node connects),
  so a core outage does not turn every lookup into a full sweep.

  Without a running locator (the application is not started), lookups probe all
  connected nodes concurrently and cache nothing.
  """

  use GenServer

  require Logger

  @table __MODULE__
  @probe_timeout_ms 5_000
  @miss_ttl_ms 5_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Connected nodes (in `Node.list/0` order) that run a process registered as `name`.
  """
  @spec nodes(atom()) :: [node()]
  def nodes(name) when is_atom(name) do
    case cached(name) do
      {:hit, nodes} -> nodes
      :known_absent -> []
      :miss -> discover(name)
      :unavailable -> probe_uncached(name)
    end
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :protected, :set, read_concurrency: true])
    :ok = :net_kernel.monitor_nodes(true)
    {:ok, %{waiters: %{}, probes: %{}, probe_refs: %{}, monitors: %{}}}
  end

  @impl true
  def handle_call({:discover, name}, from, state) do
    case cached(name) do
      {:hit, nodes} ->
        {:reply, nodes, state}

      :known_absent ->
        {:reply, [], state}

      :miss ->
        state = update_in(state.waiters, &Map.update(&1, name, [from], fn froms -> [from | froms] end))
        {:noreply, ensure_probing(state, name)}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.probe_refs, ref) do
      {{name, node}, probe_refs} ->
        {:noreply, probe_finished(%{state | probe_refs: probe_refs}, name, node, probe_result(reason))}

      {nil, _probe_refs} ->
        {:noreply, located_down(state, ref)}
    end
  end

  # A node that just connected may run what every other node lacks.
  def handle_info({:nodeup, _node}, state) do
    :ets.match_delete(@table, {{:absent, :_}, :_})
    {:noreply, state}
  end

  # Monitors on located processes report the disconnect themselves.
  def handle_info({:nodedown, _node}, state), do: {:noreply, state}

  def handle_info(_message, state), do: {:noreply, state}

  defp cached(name) do
    case located_nodes(name) do
      [] -> if absent?(name), do: :known_absent, else: :miss
      nodes -> {:hit, nodes}
    end
  rescue
    ArgumentError -> :unavailable
  end

  defp located_nodes(name) do
    located = @table |> :ets.match({{:located, name, :_}, :"$1"}) |> List.flatten()

    case located do
      [] -> []
      located -> Enum.filter(Node.list(), &(&1 in located))
    end
  end

  defp absent?(name) do
    case :ets.lookup(@table, {:absent, name}) do
      [{_key, expires_at}] -> System.monotonic_time(:millisecond) < expires_at
      [] -> false
    end
  end

  defp discover(name) do
    GenServer.call(__MODULE__, {:discover, name}, @probe_timeout_ms + 1_000)
  catch
    :exit, reason ->
      Logger.warning("Locating #{inspect(name)} in the cluster failed: #{inspect(reason)}")
      []
  end

  defp probe_uncached(name) do
    nodes = Node.list()

    nodes
    |> :erpc.multicall(Process, :whereis, [name], @probe_timeout_ms)
    |> Enum.zip(nodes)
    |> Enum.flat_map(fn
      {{:ok, pid}, node} when is_pid(pid) -> [node]
      _other -> []
    end)
  end

  defp ensure_probing(%{probes: probes} = state, name) when is_map_key(probes, name), do: state

  defp ensure_probing(state, name) do
    case Node.list() do
      [] ->
        finish_discovery(state, name, false)

      nodes ->
        probe_refs =
          Enum.reduce(nodes, state.probe_refs, fn node, refs ->
            Map.put(refs, spawn_probe(node, name), {name, node})
          end)

        discovery = %{outstanding: MapSet.new(nodes), found?: false}
        %{state | probe_refs: probe_refs, probes: Map.put(state.probes, name, discovery)}
    end
  end

  # The probe reports through its exit reason, so the one :DOWN message carries
  # the answer and also covers a probe that died without giving one. A raw
  # `spawn` (not proc_lib) exits without a crash report. The erpc timeout bounds
  # how long a probe of an unresponsive node can stay outstanding.
  defp spawn_probe(node, name) do
    {_pid, ref} =
      spawn_monitor(fn ->
        exit({:probe_result, remote_whereis(node, name)})
      end)

    ref
  end

  defp remote_whereis(node, name) do
    case :erpc.call(node, Process, :whereis, [name], @probe_timeout_ms) do
      pid when is_pid(pid) -> pid
      _other -> nil
    end
  catch
    _kind, _reason -> nil
  end

  defp probe_result({:probe_result, pid}) when is_pid(pid), do: pid
  defp probe_result(_reason), do: nil

  defp probe_finished(state, name, node, pid) do
    state = if is_pid(pid), do: record_located(state, name, node, pid), else: state
    discovery = Map.get(state.probes, name, %{outstanding: MapSet.new(), found?: false})
    discovery = %{outstanding: MapSet.delete(discovery.outstanding, node), found?: discovery.found? or is_pid(pid)}

    cond do
      MapSet.size(discovery.outstanding) == 0 ->
        finish_discovery(%{state | probes: Map.delete(state.probes, name)}, name, discovery.found?)

      is_pid(pid) ->
        reply_waiters(%{state | probes: Map.put(state.probes, name, discovery)}, name)

      true ->
        %{state | probes: Map.put(state.probes, name, discovery)}
    end
  end

  # Only a discovery in which every node answered "not here" proves absence. One
  # that found the process, which has since exited, says nothing about where it
  # runs now: caching that as absent would hide a coordinator that has already
  # moved to another node.
  defp finish_discovery(state, name, found?) do
    if !found? do
      :ets.insert(@table, {{:absent, name}, System.monotonic_time(:millisecond) + @miss_ttl_ms})
    end

    reply_waiters(state, name)
  end

  defp reply_waiters(state, name) do
    {froms, waiters} = Map.pop(state.waiters, name, [])
    nodes = located_nodes(name)
    Enum.each(froms, &GenServer.reply(&1, nodes))
    %{state | waiters: waiters}
  end

  defp record_located(state, name, node, pid) do
    if :ets.member(@table, {:located, name, pid}) do
      state
    else
      :ets.insert(@table, {{:located, name, pid}, node})
      :ets.delete(@table, {:absent, name})
      ref = Process.monitor(pid)
      %{state | monitors: Map.put(state.monitors, ref, {name, pid})}
    end
  end

  defp located_down(state, ref) do
    case Map.pop(state.monitors, ref) do
      {{name, pid}, monitors} ->
        :ets.delete(@table, {:located, name, pid})
        %{state | monitors: monitors}

      {nil, _monitors} ->
        state
    end
  end
end
