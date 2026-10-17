defmodule ServiceRadarWebNG.Topology.WorldLoader do
  @moduledoc """
  Loads one persisted world at a time into this BEAM node's native cache.

  Geometry polling reads only the small publication head. Full geometry reads
  occur at boot or after a publication. An optional canonical ordinal projection
  follows installation when the dictionary epoch or its ordinal high-water and
  row count change. A pending geometry publication preempts that scan.
  Batches leave the database transaction before
  native indexing and low-zoom tile generation begin. A coherent snapshot can
  be installed behind the newest observed head, followed by one coalesced
  catch-up; continuous ingestion must not starve initial availability.
  """

  use GenServer

  alias ServiceRadar.NetworkDiscovery.World
  alias ServiceRadar.TopologyAtlas
  alias ServiceRadarWebNG.Topology.BitmapIndex
  alias ServiceRadarWebNG.Topology.BitmapSource
  alias ServiceRadarWebNG.Topology.TileKey
  alias ServiceRadarWebNG.Topology.WorldCache
  alias ServiceRadarWebNG.Topology.WorldTile

  require Logger

  @poll_ms 15_000
  @ordinal_rescan_ms 60_000
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
       ordinal_scan_at: nil,
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

  def handle_info({:bitmap_index_ready, _epochs}, state), do: {:noreply, refresh(state)}

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

      {:ok, :deferred} ->
        {:noreply, schedule_next(state)}

      {:ok, {:ordinals, world, mapping, progress}} ->
        case WorldCache.install_ordinals(world, mapping, state.cache, progress) do
          :ok ->
            {:noreply, schedule_next(%{state | backoff: 1_000, ordinal_scan_at: System.monotonic_time(:millisecond)})}

          {:error, reason} when reason in [:source_changed, :not_ready] ->
            _ = TopologyAtlas.release_ordinals(mapping)
            {:noreply, retry(state)}

          {:error, _reason} ->
            {:noreply, retry(state)}
        end

      {:ok, %{world: world, manifest: manifest, tiles: tiles}} ->
        case WorldCache.install(world, manifest, tiles, state.cache) do
          result when result == :ok or result == {:ok, :unchanged} ->
            generation = max(state.installed_generation, manifest.generation)
            state = %{state | installed_generation: generation, backoff: 1_000}
            # Geometry becomes available before the optional dictionary scan.
            {:noreply, schedule(state, 0)}

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

  @impl true
  def handle_call({:loader_position, token}, _from, %{active: %{token: token}} = state) do
    {:reply, {:ok, state.desired_generation, state.installed_generation}, state}
  end

  def handle_call({:loader_position, _token}, _from, state), do: {:reply, :stale, state}

  defp refresh(%{active: active} = state) when not is_nil(active), do: state

  defp refresh(state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    owner = self()
    token = make_ref()
    installed = state.installed_generation
    cache = state.cache

    ordinal_scan_at = state.ordinal_scan_at

    case Task.Supervisor.start_child(state.tasks, fn ->
           send(owner, {:world_loaded, token, load(installed, cache, owner, token, ordinal_scan_at)})
         end) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        timeout = Process.send_after(self(), {:world_load_timeout, token}, @load_timeout)
        %{state | active: %{pid: pid, ref: ref, token: token, timeout: timeout, timed_out: false}, timer: nil}

      {:error, _reason} ->
        retry(state)
    end
  end

  defp load(installed, cache, owner, token, ordinal_scan_at) do
    with {:ok, manifest} <- World.active_manifest(:system) do
      send(owner, {:world_head_observed, token, manifest})

      if manifest.generation <= installed do
        load_ordinals(cache, manifest, owner, token, ordinal_scan_at)
      else
        load_snapshot(owner, token)
      end
    end
  end

  defp load_ordinals(cache, manifest, owner, token, ordinal_scan_at) do
    with :ok <- continue_ordinals(owner, token),
         {:ok, snapshot} <- BitmapIndex.snapshot(),
         {:ok, current} <- WorldCache.world(cache),
         {:ok, progress} <- dictionary_progress(current, snapshot.dictionary_epoch),
         :ok <- continue_ordinals(owner, token) do
      if ordinals_due?(current, snapshot.dictionary_epoch, progress, ordinal_scan_at) do
        case TopologyAtlas.new_ordinals(current.world, snapshot.dictionary_epoch) do
          {:ok, mapping} ->
            case seal_ordinal_projection(current.world, mapping, owner, token) do
              :ok -> {:ok, {:ordinals, current.world, mapping, progress}}
              other -> release_unused_ordinals(mapping, other)
            end

          other ->
            other
        end
      else
        {:ok, {:unchanged, manifest}}
      end
    else
      {:error, reason} when reason in [:index_not_ready, :index_unavailable] ->
        {:ok, {:unchanged, manifest}}

      {:error, :bitmap_disabled} ->
        WorldCache.clear_ordinals(cache)
        {:ok, {:unchanged, manifest}}

      :deferred ->
        {:ok, :deferred}

      {:error, _reason} = error ->
        error
    end
  end

  # Permanent assignments cannot change a complete projection for this world/epoch.
  defp dictionary_progress(%{ordinals: %{info: info}, dictionary_ordinal: progress}, epoch)
       when info.dictionary_epoch == epoch and info.mapped == info.total, do: {:ok, progress}

  defp dictionary_progress(_current, _epoch), do: BitmapSource.dictionary_progress()

  defp ordinals_due?(%{ordinals: %{info: info}, dictionary_ordinal: recorded}, epoch, progress, scanned_at) do
    cond do
      info.dictionary_epoch != epoch ->
        true

      recorded == progress ->
        false

      is_nil(scanned_at) ->
        true

      System.monotonic_time(:millisecond) - scanned_at >= @ordinal_rescan_ms ->
        true

      true ->
        false
    end
  end

  defp ordinals_due?(_current, _epoch, _progress, _scanned_at), do: true

  defp seal_ordinal_projection(world, mapping, owner, token) do
    with :ok <- load_identity_pages(world, mapping, 0, owner, token),
         {:ok, _info} <- TopologyAtlas.seal_ordinals(world, mapping) do
      :ok
    end
  end

  defp release_unused_ordinals(mapping, result) do
    _ = TopologyAtlas.release_ordinals(mapping)

    case result do
      :deferred -> {:ok, :deferred}
      other -> other
    end
  end

  defp continue_ordinals(owner, token) do
    case loader_position(owner, token) do
      {:ok, desired, installed} when desired <= installed -> :ok
      _ -> :deferred
    end
  end

  defp loader_position(owner, token) do
    GenServer.call(owner, {:loader_position, token}, 5_000)
  catch
    :exit, _reason -> :stale
  end

  defp load_identity_pages(world, mapping, cursor, owner, token) do
    with :ok <- continue_ordinals(owner, token),
         {:ok, page} <- BitmapSource.identity_page(cursor),
         {:ok, _info} <- TopologyAtlas.apply_ordinals(world, mapping, page.entries),
         :ok <- continue_ordinals(owner, token) do
      case page.next_cursor do
        nil ->
          :ok

        next when next > cursor ->
          # This optional scan shares the database with the canonical publisher.
          # At most forty 500-row pages per second, in one supervised task.
          Process.sleep(25)
          load_identity_pages(world, mapping, next, owner, token)

        _ ->
          {:error, :invalid_identity_cursor}
      end
    end
  end

  defp load_snapshot(owner, token) do
    with {:ok, %{builder: builder, manifest: manifest}} <- World.stream_active(nil, &load_batch/2),
         :ok <- notify_head(owner, token, manifest),
         {:ok, world} <- TopologyAtlas.finish_world(builder),
         {:ok, info} <- TopologyAtlas.world_info(world),
         manifest = Map.put(manifest, :bounds, info.bounds),
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
