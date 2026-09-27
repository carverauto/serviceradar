defmodule ServiceRadarWebNG.Topology.WorldLoader do
  @moduledoc """
  Loads one persisted world at a time into this BEAM node's native cache.

  Polling reads only the small publication head. Full reads occur at boot or
  after a geometry publication. Batches leave the database transaction before
  native indexing and low-zoom tile generation begin. A coherent snapshot can
  be installed behind the newest observed head, followed by one coalesced
  catch-up; continuous ingestion must not starve initial availability.
  """

  use GenServer

  alias ServiceRadar.NetworkDiscovery.World
  alias ServiceRadar.TopologyAtlas
  alias ServiceRadarWebNG.Topology.TileKey
  alias ServiceRadarWebNG.Topology.WorldCache
  alias ServiceRadarWebNG.Topology.WorldTile

  require Logger

  @poll_ms 15_000
  @load_timeout to_timeout(minute: 6)
  @max_backoff 60_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  @impl true
  def init(opts) do
    pubsub = Keyword.fetch!(opts, :pubsub)
    Phoenix.PubSub.subscribe(pubsub, "topology:world")
    send(self(), :refresh)

    {:ok,
     %{
       cache: Keyword.fetch!(opts, :cache),
       tasks: Keyword.fetch!(opts, :task_supervisor),
       installed_generation: 0,
       desired_generation: 0,
       active: nil,
       timer: nil,
       backoff: 1_000
     }}
  end

  @impl true
  def handle_info({:topology_world_changed, manifest}, state) do
    WorldCache.observe_head(manifest, state.cache)
    state = %{state | desired_generation: max(state.desired_generation, manifest.generation)}
    {:noreply, refresh(state)}
  end

  def handle_info(:refresh, state), do: {:noreply, refresh(%{state | timer: nil})}

  def handle_info({:world_head_observed, token, manifest}, %{active: %{token: token}} = state) do
    WorldCache.observe_head(manifest, state.cache)
    {:noreply, %{state | desired_generation: max(state.desired_generation, manifest.generation)}}
  end

  def handle_info({:world_loaded, token, result}, %{active: %{token: token, timed_out: false}} = state) do
    state = release(state)

    case result do
      {:ok, {:unchanged, manifest}} ->
        WorldCache.observe_head(manifest, state.cache)
        {:noreply, schedule_next(%{state | backoff: 1_000})}

      {:ok, %{world: world, manifest: manifest, tiles: tiles}} ->
        case WorldCache.install(world, manifest, tiles, state.cache) do
          result when result == :ok or result == {:ok, :unchanged} ->
            state = %{state | installed_generation: max(state.installed_generation, manifest.generation), backoff: 1_000}
            {:noreply, schedule_next(state)}

          {:error, _reason} ->
            {:noreply, retry(state)}
        end

      {:error, _reason} ->
        Logger.warning("Topology world refresh failed; retaining the installed geometry")
        {:noreply, retry(state)}
    end
  end

  def handle_info({:world_load_timeout, token}, %{active: %{token: token, pid: pid, timed_out: false}} = state) do
    # Cancel without blocking the owner. DOWN releases BEAM bookkeeping;
    # the native gate retains its permit until any dirty computation returns.
    Process.exit(pid, :kill)
    {:noreply, %{state | active: %{state.active | timed_out: true}}}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{active: %{ref: ref}} = state),
    do: {:noreply, state |> release() |> retry()}

  def handle_info(_stale_task_message, state), do: {:noreply, state}

  defp refresh(%{active: active} = state) when not is_nil(active), do: state

  defp refresh(state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    owner = self()
    token = make_ref()
    installed = state.installed_generation

    case Task.Supervisor.start_child(state.tasks, fn ->
           send(owner, {:world_loaded, token, load(installed, owner, token)})
         end) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        timeout = Process.send_after(self(), {:world_load_timeout, token}, @load_timeout)
        %{state | active: %{pid: pid, ref: ref, token: token, timeout: timeout, timed_out: false}, timer: nil}

      {:error, _reason} ->
        retry(state)
    end
  end

  defp load(installed, owner, token) do
    with {:ok, manifest} <- World.active_manifest(:system) do
      send(owner, {:world_head_observed, token, manifest})

      if manifest.generation <= installed do
        {:ok, {:unchanged, manifest}}
      else
        load_snapshot(owner, token)
      end
    end
  end

  defp load_snapshot(owner, token) do
    with {:ok, %{builder: builder, manifest: manifest}} <- World.stream_active(nil, &load_batch/2),
         :ok <- notify_head(owner, token, manifest),
         {:ok, world} <- TopologyAtlas.finish_world(builder),
         {:ok, tiles} <- prepare_tiles(world, manifest) do
      {:ok, %{world: world, manifest: manifest, tiles: tiles}}
    end
  end

  defp load_batch({:manifest, manifest}, nil) do
    with {:ok, builder} <- TopologyAtlas.new_builder(manifest.layout_version, manifest.zmax) do
      {:ok, %{builder: builder, manifest: manifest}}
    end
  end

  defp load_batch({:positions, rows}, state) do
    with :ok <- TopologyAtlas.add_positions(state.builder, rows), do: {:ok, state}
  end

  defp load_batch({:relations, rows}, state) do
    with :ok <- TopologyAtlas.add_relations(state.builder, rows), do: {:ok, state}
  end

  defp notify_head(owner, token, manifest) do
    send(owner, {:world_head_observed, token, manifest})
    :ok
  end

  defp prepare_tiles(world, manifest) do
    Enum.reduce_while(TileKey.low_zoom(manifest), {:ok, %{}}, fn key, {:ok, tiles} ->
      case WorldTile.build(world, key) do
        {:ok, tile} -> {:cont, {:ok, Map.put(tiles, key, tile)}}
        error -> {:halt, error}
      end
    end)
  end

  defp release(state) do
    Process.cancel_timer(state.active.timeout)
    Process.demonitor(state.active.ref, [:flush])
    %{state | active: nil}
  end

  defp retry(state) do
    delay = state.backoff + :rand.uniform(250)
    schedule(%{state | backoff: min(state.backoff * 2, @max_backoff)}, delay)
  end

  defp schedule(state, delay) do
    if state.timer, do: Process.cancel_timer(state.timer)
    %{state | timer: Process.send_after(self(), :refresh, delay)}
  end

  defp schedule_next(state) do
    delay = if state.desired_generation > state.installed_generation, do: 0, else: @poll_ms
    schedule(state, delay)
  end
end
