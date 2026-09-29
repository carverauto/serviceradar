defmodule ServiceRadarWebNG.Topology.WorldOverlay do
  @moduledoc """
  Bounds telemetry work, coalesces tile reads and caches plain overlay payloads.

  Native preparation and telemetry SQL run in separate supervised processes.
  The owner waits for the prepare process to exit before starting SQL, so a
  database wait retains no native world. The cache contains no native handles.
  Serving callers must check current analytics and device authority before
  calling this internal API and again before delivering its result.

  Initial defaults are a 15-minute query window, a 120-second sample freshness
  cutoff and a 5-second database timeout. The 5-second cache TTL never changes
  a sample's timestamps or its original freshness cutoff.
  """

  use GenServer

  alias ServiceRadarWebNG.Topology.TileControl
  alias ServiceRadarWebNG.Topology.TileKey
  alias ServiceRadarWebNG.Topology.WorldCache
  alias ServiceRadarWebNG.Topology.WorldOverlayReader

  @max_active 4
  @max_waiters 64
  @max_entries 128
  @max_bytes 8_388_608
  @ttl_ms 5_000
  @prepare_timeout 20_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  @doc "Reads telemetry for the client's encoded tile revision without changing geometry."
  def fetch(%TileKey{} = key, revision, server \\ __MODULE__) when is_binary(revision) and byte_size(revision) == 64 do
    GenServer.call(server, {:fetch, key, revision}, 30_000)
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @impl true
  def init(opts) do
    pubsub = Keyword.fetch!(opts, :pubsub)
    Phoenix.PubSub.subscribe(pubsub, "topology:world")

    settings = %{
      window_seconds: Keyword.get(opts, :window_seconds, 900),
      freshness_seconds: Keyword.get(opts, :freshness_seconds, 120),
      timeout_ms: Keyword.get(opts, :timeout_ms, 5_000)
    }

    if !(is_integer(settings.window_seconds) and settings.window_seconds in 1..3600 and
           is_integer(settings.freshness_seconds) and settings.freshness_seconds in 1..settings.window_seconds and
           is_integer(settings.timeout_ms) and settings.timeout_ms in 1..5_000) do
      raise ArgumentError, "invalid topology overlay query settings"
    end

    {:ok,
     %{
       tasks: Keyword.fetch!(opts, :task_supervisor),
       cache: Keyword.fetch!(opts, :cache),
       health: Keyword.fetch!(opts, :health),
       settings: settings,
       entries: %{},
       bytes: 0,
       active: %{},
       task_refs: %{},
       caller_refs: %{}
     }}
  end

  @impl true
  def handle_call({:fetch, key, revision}, from, state) do
    with {:ok, manifest} <- WorldCache.manifest(state.cache),
         true <- key.layout_version == manifest.layout_version do
      fence = TileControl.fence(manifest)
      address = {key, revision, fence.generation}
      entry = Map.get(state.entries, address)

      cond do
        entry && now() - entry.at < @ttl_ms ->
          {:reply, {:ok, entry.payload}, state}

        map_size(state.caller_refs) >= @max_waiters ->
          {:reply, {:error, :busy}, state}

        Map.has_key?(state.active, address) ->
          if state.active[address].cancelled,
            do: {:reply, {:error, :busy}, state},
            else: {:noreply, add_waiter(state, address, from)}

        map_size(state.active) >= @max_active ->
          {:reply, {:error, :busy}, state}

        true ->
          continuation = if entry, do: entry.continuation
          cache = state.cache
          health = state.health
          work = fn -> WorldOverlayReader.prepare(key, fence, revision, continuation, cache, health) end
          pending = %{fence: fence, waiters: [], phase: :prepare, result: nil, cancelled: false}
          state = put_in(state.active[address], pending)
          {:noreply, state |> add_waiter(address, from) |> launch(address, work, @prepare_timeout)}
      end
    else
      false -> {:reply, {:error, :layout_changed}, state}
      error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_info({:overlay_result, address, token, result}, state) do
    case state.active[address] do
      %{token: ^token, cancelled: false} -> {:noreply, put_in(state.active[address].result, result)}
      _ -> {:noreply, state}
    end
  end

  def handle_info({:overlay_timeout, address, token}, state) do
    case state.active[address] do
      %{token: ^token, cancelled: false} -> {:noreply, cancel(state, address, :timeout)}
      _ -> {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    cond do
      address = state.task_refs[ref] ->
        pending = state.active[address]
        Process.cancel_timer(pending.timer)
        state = %{state | task_refs: Map.delete(state.task_refs, ref)}
        {:noreply, task_exited(state, address, pending)}

      address = state.caller_refs[ref] ->
        state = %{state | caller_refs: Map.delete(state.caller_refs, ref)}
        state = update_in(state.active[address].waiters, &Enum.reject(&1, fn {monitor, _} -> monitor == ref end))
        {:noreply, if(state.active[address].waiters == [], do: cancel(state, address, :cancelled), else: state)}

      true ->
        {:noreply, state}
    end
  end

  def handle_info({:topology_world_ready, _fence}, state) do
    state = Enum.reduce(Map.keys(state.active), state, &cancel(&2, &1, :source_changed))
    {:noreply, %{state | entries: %{}, bytes: 0}}
  end

  # A durable head may be ahead of this node's coherent installed world. Only
  # installation changes the serving fence; the loader consumes this hint.
  def handle_info({:topology_world_changed, _fence}, state), do: {:noreply, state}

  defp task_exited(state, address, %{cancelled: true}), do: %{state | active: Map.delete(state.active, address)}

  defp task_exited(state, address, %{phase: :prepare, result: {:ok, prepared}} = pending) do
    # Only this DOWN handler may start SQL. The terminated preparation process
    # has released its world, health and selection references, including its
    # stack; native completion alone would not establish that property.
    if current?(state, pending.fence) do
      settings = state.settings
      state = put_in(state.active[address], %{pending | phase: :rates, result: nil})
      launch(state, address, fn -> WorldOverlayReader.read_rates(prepared, settings) end, settings.timeout_ms + 2_000)
    else
      finish(state, address, {:error, :source_changed})
    end
  end

  defp task_exited(state, address, %{phase: :rates, result: {:ok, result}} = pending) do
    if current?(state, pending.fence) do
      case admit(state, address, result) do
        {:ok, state} -> finish(state, address, {:ok, result.payload})
        {:error, reason} -> finish(state, address, {:error, reason})
      end
    else
      finish(state, address, {:error, :source_changed})
    end
  end

  defp task_exited(state, address, %{result: {:error, _} = error}), do: finish(state, address, error)
  defp task_exited(state, address, _pending), do: finish(state, address, {:error, :unavailable})

  defp launch(state, address, work, timeout) do
    owner = self()
    token = make_ref()

    case Task.Supervisor.start_child(state.tasks, fn -> send(owner, {:overlay_result, address, token, work.()}) end) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        timer = Process.send_after(self(), {:overlay_timeout, address, token}, timeout)
        state = update_in(state.active[address], &Map.merge(&1, %{pid: pid, ref: ref, token: token, timer: timer}))
        %{state | task_refs: Map.put(state.task_refs, ref, address)}

      {:error, _} ->
        finish(state, address, {:error, :busy})
    end
  end

  defp add_waiter(state, address, {pid, _tag} = from) do
    ref = Process.monitor(pid)
    state = update_in(state.active[address].waiters, &[{ref, from} | &1])
    %{state | caller_refs: Map.put(state.caller_refs, ref, address)}
  end

  defp cancel(state, address, reason) do
    pending = state.active[address]
    Process.exit(pending.pid, :kill)
    state = reply(state, address, {:error, reason})
    put_in(state.active[address].cancelled, true)
  end

  defp finish(state, address, result) do
    state = reply(state, address, result)
    %{state | active: Map.delete(state.active, address)}
  end

  defp reply(state, address, result) do
    state =
      Enum.reduce(state.active[address].waiters, state, fn {ref, from}, state ->
        Process.demonitor(ref, [:flush])
        GenServer.reply(from, result)
        %{state | caller_refs: Map.delete(state.caller_refs, ref)}
      end)

    put_in(state.active[address].waiters, [])
  end

  defp current?(state, fence) do
    case WorldCache.manifest(state.cache) do
      {:ok, manifest} -> TileControl.fence(manifest) == fence
      _ -> false
    end
  end

  defp admit(state, address, result) do
    bytes = :erlang.external_size(result)

    if bytes > @max_bytes do
      {:error, :overlay_budget_exceeded}
    else
      previous = state.entries[address]
      entry = Map.merge(result, %{bytes: bytes, at: now()})

      state = %{
        state
        | entries: Map.put(state.entries, address, entry),
          bytes: state.bytes + bytes - if(previous, do: previous.bytes, else: 0)
      }

      {:ok, evict(state)}
    end
  end

  defp evict(state) when map_size(state.entries) <= @max_entries and state.bytes <= @max_bytes, do: state

  defp evict(state) do
    {key, oldest} = Enum.min_by(state.entries, fn {_key, entry} -> entry.at end)
    evict(%{state | entries: Map.delete(state.entries, key), bytes: state.bytes - oldest.bytes})
  end

  defp now, do: System.monotonic_time(:millisecond)
end
