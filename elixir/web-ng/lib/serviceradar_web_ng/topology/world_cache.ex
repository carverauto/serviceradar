defmodule ServiceRadarWebNG.Topology.WorldCache do
  @moduledoc """
  Installs coherent native worlds and caches bounded encoded tiles.

  The owner serializes publication, LRU admission and request coalescing. Tile
  generation runs in supervised tasks, never inside the owner. A stale task
  cannot overwrite a newer generation. Cached geometry survives a publication
  until its next read confirms or replaces its content revision.
  """

  use GenServer

  alias ServiceRadarWebNG.Topology.TileControl
  alias ServiceRadarWebNG.Topology.TileKey
  alias ServiceRadarWebNG.Topology.WorldTile

  @max_builds 4
  @max_waiters 64
  @build_timeout 10_000
  @max_tile_bytes 262_144

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [Keyword.put_new(opts, :name, __MODULE__)]}}
  end

  def install(world, manifest, prepared, server \\ __MODULE__), do: call(server, {:install, world, manifest, prepared})

  def observe_head(manifest, server \\ __MODULE__), do: call(server, {:observe_head, manifest})
  def manifest(server \\ __MODULE__), do: call(server, :manifest)
  def world(server \\ __MODULE__), do: call(server, :world)

  def fetch(%TileKey{} = key, priority \\ :foreground, server \\ __MODULE__) when priority in [:foreground, :background],
    do: call(server, {:fetch, key, priority})

  @impl true
  def init(opts) do
    max_entries = Keyword.get(opts, :max_entries, 512)
    max_bytes = Keyword.get(opts, :max_bytes, 134_217_728)

    if !(is_integer(max_entries) and max_entries > 0 and is_integer(max_bytes) and max_bytes > 0) do
      raise ArgumentError, "tile cache limits must be positive integers"
    end

    {:ok,
     %{
       current: nil,
       observed_generation: 0,
       entries: %{},
       pinned: MapSet.new(),
       bytes: 0,
       clock: 0,
       pending: %{},
       task_refs: %{},
       caller_refs: %{},
       max_entries: max_entries,
       max_bytes: max_bytes,
       task_supervisor: Keyword.fetch!(opts, :task_supervisor),
       pubsub: Keyword.fetch!(opts, :pubsub)
     }}
  end

  @impl true
  def handle_call({:observe_head, manifest}, _from, state) do
    {:reply, :ok, %{state | observed_generation: max(state.observed_generation, manifest.generation)}}
  end

  def handle_call({:install, world, manifest, prepared}, _from, state) do
    cond do
      state.current && manifest.generation <= state.current.manifest.generation ->
        {:reply, {:ok, :unchanged}, state}

      !valid_prepared?(prepared, manifest) ->
        {:reply, {:error, :invalid_prepared_tiles}, state}

      map_size(prepared) > state.max_entries or prepared_bytes(prepared) > state.max_bytes ->
        {:reply, {:error, :insufficient_cache_budget}, state}

      true ->
        state =
          if state.current && state.current.manifest.layout_version == manifest.layout_version do
            state
          else
            %{state | entries: %{}, bytes: 0}
          end

        entries = Map.drop(state.entries, Map.keys(prepared))
        bytes = Enum.reduce(entries, 0, fn {_key, entry}, bytes -> bytes + entry.bytes end)

        state = %{
          state
          | current: %{world: world, manifest: manifest},
            pinned: MapSet.new(Map.keys(prepared)),
            entries: entries,
            bytes: bytes,
            observed_generation: max(state.observed_generation, manifest.generation)
        }

        state = Enum.reduce(prepared, state, fn {key, tile}, state -> cache(state, key, tile, manifest.generation) end)

        Phoenix.PubSub.broadcast(state.pubsub, "topology:world", {:topology_world_ready, TileControl.fence(manifest)})
        {:reply, :ok, state}
    end
  end

  def handle_call(_request, _from, %{current: nil} = state), do: {:reply, {:error, :not_ready}, state}

  def handle_call(:manifest, _from, state) do
    manifest =
      Map.merge(state.current.manifest, %{
        observed_generation: state.observed_generation,
        catching_up: state.observed_generation > state.current.manifest.generation
      })

    {:reply, {:ok, manifest}, state}
  end

  def handle_call(:world, _from, state), do: {:reply, {:ok, state.current}, state}

  def handle_call({:fetch, %TileKey{z: z}, _priority}, _from, %{current: %{manifest: %{zmax: zmax}}} = state)
      when z > zmax, do: {:reply, {:error, :invalid_tile}, state}

  def handle_call({:fetch, key, priority}, from, state) do
    generation = state.current.manifest.generation

    case {key.layout_version == state.current.manifest.layout_version, Map.get(state.entries, key)} do
      {false, _entry} ->
        {:reply, {:error, :layout_changed}, state}

      {true, %{generation: ^generation} = entry} ->
        state = touch(state, key, entry)
        {:reply, {:ok, Map.put(entry.tile, :generation, generation)}, state}

      {true, _entry} ->
        admit(key, priority, from, state)
    end
  end

  @impl true
  def handle_info({:tile_built, key, token, result}, state) do
    case Map.get(state.pending, key) do
      %{token: ^token, timed_out: false} = pending ->
        {result, state} = accept_result(key, pending.generation, result, state)
        {:noreply, finish(key, result, state)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:tile_timeout, key, token}, state) do
    case Map.get(state.pending, key) do
      %{token: ^token, pid: pid, timed_out: false} ->
        # Dirty NIF termination can wait for native work. Keep its admission
        # slot until DOWN, without blocking this owner or the task supervisor.
        Process.exit(pid, :kill)
        state = reply_waiters(key, {:error, :tile_timeout}, state)
        pending = %{Map.fetch!(state.pending, key) | timed_out: true}
        {:noreply, %{state | pending: Map.put(state.pending, key, pending)}}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    cond do
      key = Map.get(state.task_refs, ref) ->
        {:noreply, finish(key, {:error, :unavailable}, state)}

      key = Map.get(state.caller_refs, ref) ->
        pending = Map.fetch!(state.pending, key)
        pending = %{pending | waiters: Map.delete(pending.waiters, ref)}

        {:noreply,
         %{state | pending: Map.put(state.pending, key, pending), caller_refs: Map.delete(state.caller_refs, ref)}}

      true ->
        {:noreply, state}
    end
  end

  defp admit(key, priority, from, state) do
    limit = if priority == :foreground, do: @max_builds, else: @max_builds - 1

    cond do
      map_size(state.caller_refs) >= @max_waiters ->
        {:reply, {:error, :busy}, state}

      match?(%{timed_out: true}, Map.get(state.pending, key)) ->
        {:reply, {:error, :busy}, state}

      Map.has_key?(state.pending, key) ->
        {:noreply, add_waiter(key, from, state)}

      map_size(state.pending) >= limit ->
        {:reply, {:error, :busy}, state}

      true ->
        start_build(key, from, state)
    end
  end

  defp start_build(key, from, state) do
    owner = self()
    token = make_ref()
    %{world: world, manifest: manifest} = state.current

    task = fn ->
      result =
        :telemetry.span(
          [:serviceradar, :topology, :tile, :build],
          %{layout_version: key.layout_version, key: TileKey.id(key)},
          fn ->
            result = WorldTile.build(world, key)
            {result, %{outcome: elem(result, 0)}}
          end
        )

      send(owner, {:tile_built, key, token, result})
    end

    case Task.Supervisor.start_child(state.task_supervisor, task) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        timer = Process.send_after(self(), {:tile_timeout, key, token}, @build_timeout)

        pending = %{
          token: token,
          pid: pid,
          ref: ref,
          timer: timer,
          generation: manifest.generation,
          waiters: %{},
          timed_out: false
        }

        state = %{state | pending: Map.put(state.pending, key, pending), task_refs: Map.put(state.task_refs, ref, key)}
        {:noreply, add_waiter(key, from, state)}

      {:error, :max_children} ->
        {:reply, {:error, :busy}, state}

      {:error, _reason} ->
        {:reply, {:error, :unavailable}, state}
    end
  end

  defp add_waiter(key, {pid, _tag} = from, state) do
    ref = Process.monitor(pid)
    pending = Map.fetch!(state.pending, key)
    pending = %{pending | waiters: Map.put(pending.waiters, ref, from)}
    %{state | pending: Map.put(state.pending, key, pending), caller_refs: Map.put(state.caller_refs, ref, key)}
  end

  defp accept_result(key, generation, result, state) do
    if state.current.manifest.generation == generation do
      case result do
        {:ok, tile} ->
          if valid_tile?(tile) do
            previous = Map.get(state.entries, key)
            # Native selection descriptors belong to the current world even
            # when its geometry bytes are unchanged (for example new bindings).
            tile =
              if previous && previous.tile.revision == tile.revision,
                do: %{tile | payload: previous.tile.payload},
                else: tile

            {{:ok, Map.put(tile, :generation, generation)}, cache(state, key, tile, generation)}
          else
            {{:error, :tile_budget_exceeded}, state}
          end

        {:error, _reason} = error ->
          {error, state}
      end
    else
      {{:error, :source_changed}, state}
    end
  end

  defp finish(key, result, state) do
    pending = Map.fetch!(state.pending, key)
    Process.cancel_timer(pending.timer)
    Process.demonitor(pending.ref, [:flush])
    state = reply_waiters(key, result, state)

    %{
      state
      | pending: Map.delete(state.pending, key),
        task_refs: Map.delete(state.task_refs, pending.ref)
    }
  end

  defp reply_waiters(key, result, state) do
    pending = Map.fetch!(state.pending, key)

    for {ref, from} <- pending.waiters do
      Process.demonitor(ref, [:flush])
      GenServer.reply(from, result)
    end

    %{
      state
      | pending: Map.put(state.pending, key, %{pending | waiters: %{}}),
        caller_refs: Map.drop(state.caller_refs, Map.keys(pending.waiters))
    }
  end

  defp cache(state, key, tile, generation) do
    old_bytes =
      case Map.get(state.entries, key) do
        nil -> 0
        entry -> entry.bytes
      end

    bytes = :erlang.external_size(tile) + tile.selection_bytes
    entry = %{tile: tile, generation: generation, bytes: bytes, touch: state.clock + 1}

    trim(%{
      state
      | entries: Map.put(state.entries, key, entry),
        bytes: state.bytes - old_bytes + bytes,
        clock: state.clock + 1
    })
  end

  defp trim(state) when map_size(state.entries) <= state.max_entries and state.bytes <= state.max_bytes, do: state

  defp trim(state) do
    {key, entry} =
      state.entries
      |> Enum.reject(fn {key, _entry} -> MapSet.member?(state.pinned, key) end)
      |> Enum.min_by(fn {_key, entry} -> entry.touch end)

    trim(%{state | entries: Map.delete(state.entries, key), bytes: state.bytes - entry.bytes})
  end

  defp touch(state, key, entry),
    do: %{state | entries: Map.put(state.entries, key, %{entry | touch: state.clock + 1}), clock: state.clock + 1}

  defp valid_prepared?(prepared, manifest) when is_map(prepared) and map_size(prepared) <= 21 do
    expected = TileKey.low_zoom(manifest)

    map_size(prepared) == length(expected) &&
      Enum.all?(expected, fn key -> valid_tile?(Map.get(prepared, key)) end)
  end

  defp valid_prepared?(_prepared, _manifest), do: false

  defp prepared_bytes(prepared) do
    Enum.reduce(prepared, 0, fn {_key, tile}, bytes -> bytes + :erlang.external_size(tile) + tile.selection_bytes end)
  end

  defp valid_tile?(%{payload: payload, revision: revision, selection_bytes: selection_bytes})
       when is_binary(payload) and byte_size(payload) <= @max_tile_bytes and is_binary(revision) and
              byte_size(revision) == 64 and is_integer(selection_bytes) and selection_bytes >= 0, do: true

  defp valid_tile?(_tile), do: false

  defp call(server, request) do
    GenServer.call(server, request, @build_timeout + 5_000)
  catch
    :exit, _reason -> {:error, :unavailable}
  end
end
