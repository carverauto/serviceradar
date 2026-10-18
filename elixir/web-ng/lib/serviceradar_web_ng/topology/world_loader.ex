defmodule ServiceRadarWebNG.Topology.WorldLoader do
  @moduledoc """
  Loads one persisted world at a time into this BEAM node's native cache.

  Geometry polling reads only the small publication head. Full geometry reads
  occur at boot or after a publication. An optional canonical ordinal projection
  follows installation when the dictionary epoch or its ordinal high-water and
  row count change. It advances one dictionary page per supervised turn; the
  owner keeps the private mapping and cursor between turns, so every turn
  polls the geometry head first and projection failures retry on their own
  backoff from the retained cursor. Only a complete mapping for the current
  world and dictionary epoch is installed; a staged mapping for a replaced
  world or epoch is released. A pending geometry publication preempts the scan.
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
  # This optional scan shares the database with the canonical publisher:
  # at most forty 500-row pages per second.
  @projection_page_ms 25
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
       projection: nil,
       projection_backoff: 1_000,
       projection_retry_at: nil,
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

  def handle_info({:projection_turn, token}, %{active: %{token: token} = active} = state),
    do: {:noreply, %{state | active: %{active | projection: true}}}

  def handle_info({:world_loaded, token, result, staged}, %{active: %{token: token, timed_out: false}} = state) do
    state = state |> release() |> keep_projection(staged)

    case result do
      {:ok, {:unchanged, manifest}} ->
        WorldCache.observe_head(manifest, state.cache)
        {:noreply, schedule_next(%{state | backoff: 1_000})}

      {:ok, :deferred} ->
        {:noreply, schedule_next(state)}

      {:ok, :projection_progress} ->
        {:noreply, schedule_next(projection_succeeded(%{state | backoff: 1_000}))}

      {:ok, {:ordinals, world, mapping, progress}} ->
        state = %{state | projection: nil}

        case install_projection(world, mapping, progress, state.cache) do
          :ok ->
            now = System.monotonic_time(:millisecond)
            {:noreply, schedule_next(projection_succeeded(%{state | backoff: 1_000, ordinal_scan_at: now}))}

          {:error, _reason} ->
            _ = TopologyAtlas.release_ordinals(mapping)
            {:noreply, schedule_next(projection_failed(state))}
        end

      {:ok, %{world: world, manifest: manifest, tiles: tiles}} ->
        case WorldCache.install(world, manifest, tiles, state.cache) do
          result when result == :ok or result == {:ok, :unchanged} ->
            generation = max(state.installed_generation, manifest.generation)
            state = keep_projection(%{state | installed_generation: generation, backoff: 1_000}, nil)
            # Geometry becomes available before the optional dictionary scan.
            {:noreply, schedule(state, 0)}

          {:error, _reason} ->
            {:noreply, retry(state)}
        end

      {:error, {:ordinals, _reason}} ->
        Logger.warning("Topology ordinal projection turn failed; retaining its staged progress")
        {:noreply, schedule_next(projection_failed(state))}

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

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{active: %{ref: ref, projection: true}} = state),
    do: {:noreply, state |> release() |> projection_failed() |> schedule_next()}

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
    staged = state.projection
    state = clear_elapsed_retry(state)
    waiting = not is_nil(state.projection_retry_at)

    case Task.Supervisor.start_child(state.tasks, fn ->
           {result, staged} = load(installed, cache, owner, token, ordinal_scan_at, staged, waiting)
           send(owner, {:world_loaded, token, result, staged})
         end) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        timeout = Process.send_after(self(), {:world_load_timeout, token}, @load_timeout)
        active = %{pid: pid, ref: ref, token: token, timeout: timeout, timed_out: false, projection: false}
        %{state | active: active, timer: nil}

      {:error, _reason} ->
        retry(state)
    end
  end

  defp load(installed, cache, owner, token, ordinal_scan_at, staged, waiting) do
    case World.active_manifest(:system) do
      {:ok, manifest} ->
        send(owner, {:world_head_observed, token, manifest})

        cond do
          manifest.generation > installed -> {load_snapshot(owner, token), staged}
          waiting -> {{:ok, {:unchanged, manifest}}, staged}
          true -> load_ordinals(cache, manifest, owner, token, ordinal_scan_at, staged)
        end

      error ->
        {error, staged}
    end
  end

  defp load_ordinals(cache, manifest, owner, token, ordinal_scan_at, staged) do
    with :ok <- continue_ordinals(owner, token),
         {:ok, snapshot} <- BitmapIndex.snapshot(),
         {:ok, current} <- WorldCache.world(cache) do
      epoch = snapshot.dictionary_epoch

      if resumable?(staged, current.world, epoch) do
        projection_turn(staged, owner, token)
      else
        if staged, do: TopologyAtlas.release_ordinals(staged.mapping)
        start_projection(current, epoch, cache, manifest, owner, token, ordinal_scan_at)
      end
    else
      {:error, :bitmap_disabled} = disabled -> {ordinal_result(disabled, cache, manifest), nil}
      other -> {ordinal_result(other, cache, manifest), staged}
    end
  end

  defp start_projection(current, epoch, cache, manifest, owner, token, ordinal_scan_at) do
    with {:ok, progress} <- dictionary_progress(current, epoch),
         :ok <- continue_ordinals(owner, token) do
      if ordinals_due?(current, epoch, progress, ordinal_scan_at) do
        case TopologyAtlas.new_ordinals(current.world, epoch) do
          {:ok, mapping} ->
            staged = %{world: current.world, epoch: epoch, mapping: mapping, cursor: 0, progress: progress}
            projection_turn(staged, owner, token)

          other ->
            {ordinal_result(other, cache, manifest), nil}
        end
      else
        {{:ok, {:unchanged, manifest}}, nil}
      end
    else
      other -> {ordinal_result(other, cache, manifest), nil}
    end
  end

  defp ordinal_result({:error, reason}, _cache, manifest) when reason in [:index_not_ready, :index_unavailable],
    do: {:ok, {:unchanged, manifest}}

  defp ordinal_result({:error, :bitmap_disabled}, cache, manifest) do
    WorldCache.clear_ordinals(cache)
    {:ok, {:unchanged, manifest}}
  end

  defp ordinal_result(:deferred, _cache, _manifest), do: {:ok, :deferred}
  defp ordinal_result({:error, reason}, _cache, _manifest), do: {:error, {:ordinals, reason}}

  defp resumable?(%{world: world, epoch: epoch}, world, epoch), do: true
  defp resumable?(_staged, _world, _epoch), do: false

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

  # One 500-row page per supervised turn. Assignments are permanent, so a page
  # replayed after a cancelled turn applies identically.
  defp projection_turn(staged, owner, token) do
    send(owner, {:projection_turn, token})

    # A dirty native call can finish after its worker is cancelled. If sealing
    # succeeded before the completion message was lost, install that result
    # instead of repeatedly applying a page to an already sealed mapping.
    case TopologyAtlas.ordinal_info(staged.world, staged.mapping) do
      {:ok, %{ready: true}} -> seal_projection(staged)
      {:ok, _info} -> projection_page(staged, owner, token)
      {:error, reason} -> {{:error, {:ordinals, reason}}, staged}
    end
  end

  defp projection_page(staged, owner, token) do
    with {:ok, page} <- BitmapSource.identity_page(staged.cursor),
         {:ok, _info} <- TopologyAtlas.apply_ordinals(staged.world, staged.mapping, page.entries) do
      case page.next_cursor do
        nil ->
          seal_projection(staged)

        next when next > staged.cursor ->
          advanced = %{staged | cursor: next}

          case continue_ordinals(owner, token) do
            :ok -> {{:ok, :projection_progress}, advanced}
            :deferred -> {{:ok, :deferred}, advanced}
          end

        _ ->
          {{:error, {:ordinals, :invalid_identity_cursor}}, staged}
      end
    else
      {:error, reason} -> {{:error, {:ordinals, reason}}, staged}
    end
  end

  defp seal_projection(staged) do
    case TopologyAtlas.seal_ordinals(staged.world, staged.mapping) do
      {:ok, _info} -> {{:ok, {:ordinals, staged.world, staged.mapping, staged.progress}}, staged}
      {:error, reason} -> {{:error, {:ordinals, reason}}, nil}
    end
  end

  defp install_projection(world, mapping, progress, cache) do
    with {:ok, %{dictionary_epoch: epoch}} <- BitmapIndex.snapshot(),
         {:ok, %{dictionary_epoch: ^epoch}} <- TopologyAtlas.ordinal_info(world, mapping) do
      WorldCache.install_ordinals(world, mapping, cache, progress)
    else
      {:error, reason} -> {:error, reason}
      {:ok, _obsolete} -> {:error, :dictionary_changed}
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

  defp keep_projection(state, staged) do
    case state.projection do
      %{mapping: mapping} ->
        if not (is_map(staged) and staged.mapping == mapping), do: TopologyAtlas.release_ordinals(mapping)

      nil ->
        :ok
    end

    %{state | projection: staged}
  end

  defp projection_succeeded(state), do: %{state | projection_backoff: 1_000, projection_retry_at: nil}

  defp projection_failed(state) do
    delay = state.projection_backoff + :rand.uniform(250)

    %{
      state
      | projection_backoff: min(state.projection_backoff * 2, @max_backoff),
        projection_retry_at: System.monotonic_time(:millisecond) + delay
    }
  end

  defp clear_elapsed_retry(%{projection_retry_at: at} = state) when is_integer(at) do
    if System.monotonic_time(:millisecond) >= at, do: %{state | projection_retry_at: nil}, else: state
  end

  defp clear_elapsed_retry(state), do: state

  defp retry(state) do
    delay = state.backoff + :rand.uniform(250)
    schedule(%{state | backoff: min(state.backoff * 2, @max_backoff)}, delay)
  end

  defp schedule(state, delay) do
    if state.timer, do: Process.cancel_timer(state.timer)
    %{state | timer: Process.send_after(self(), :refresh, delay)}
  end

  defp schedule_next(state) do
    delay =
      cond do
        state.desired_generation > state.installed_generation ->
          0

        is_integer(state.projection_retry_at) ->
          min(@poll_ms, max(state.projection_retry_at - System.monotonic_time(:millisecond), 0))

        not is_nil(state.projection) ->
          @projection_page_ms

        true ->
          @poll_ms
      end

    schedule(state, delay)
  end
end
