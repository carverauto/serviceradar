defmodule ServiceRadarWebNG.Topology.WorldHealth do
  @moduledoc """
  Owns one availability index independently of immutable geometry.

  The owner serializes admission and publication. One supervised task performs
  bounded database reads, native mutations or a detached generation rebase.
  Readers receive native handles and never wait behind a whole-fleet seed.
  Dirty identities are hints to reread current state, not ordered observations.
  Rolling reconciliation repairs missed hints and subscription gaps.
  """

  use GenServer

  alias ServiceRadar.Inventory.DevicePubSub
  alias ServiceRadar.TopologyAtlas
  alias ServiceRadarWebNG.Topology.WorldCache
  alias ServiceRadarWebNG.Topology.WorldHealthSource

  @batch_size 500
  @max_dirty 5_000
  @max_dirty_bytes 524_288
  @task_timeout 30_000
  @scan_interval 30_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  @doc "Returns generation-fenced native handles and truthful source progress."
  def snapshot(server \\ __MODULE__) do
    GenServer.call(server, :snapshot)
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @impl true
  def init(opts) do
    pubsub = Keyword.fetch!(opts, :pubsub)
    Phoenix.PubSub.subscribe(pubsub, "topology:world")
    Phoenix.PubSub.subscribe(pubsub, DevicePubSub.invalidation_topic())
    send(self(), :step)

    {:ok,
     %{
       cache: Keyword.fetch!(opts, :cache),
       tasks: Keyword.fetch!(opts, :task_supervisor),
       current: nil,
       epoch: epoch(),
       sequence: 0,
       active: nil,
       timer: nil,
       dirty: MapSet.new(),
       dirty_bytes: 0,
       cursor: nil,
       scan_due: 0,
       scan_started_at: nil,
       last_reconciled_at: nil,
       last_read_at: nil,
       rescan: true,
       prefer_scan: true,
       source_error: false
     }}
  end

  @impl true
  def handle_call(:snapshot, _from, %{current: nil} = state), do: {:reply, {:error, :not_ready}, state}

  def handle_call(:snapshot, _from, state) do
    # This small O(log N) read takes the native lock only for progress counters.
    %{world: world, health: health} = state.current

    reply =
      with {:ok, info} <- TopologyAtlas.health_info(world, health) do
        progress = Map.merge(info, progress(state))
        {:ok, Map.put(state.current, :progress, progress)}
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_info(:step, state), do: {:noreply, step(%{state | timer: nil})}
  def handle_info({:topology_world_ready, _fence}, state), do: {:noreply, wake(state)}

  def handle_info({:devices_invalidated, ids}, state) do
    {:noreply, state |> remember(ids) |> wake()}
  end

  def handle_info(:devices_rescan, state), do: {:noreply, wake(%{state | rescan: true})}

  def handle_info({:health_finished, token, result}, %{active: %{token: token, timed_out: false}} = state) do
    work = state.active.work
    state = release(state)

    case result do
      {:ok, result} -> {:noreply, state |> accept(work, result) |> schedule(0)}
      {:error, _reason} -> {:noreply, retry(state, work)}
    end
  end

  def handle_info({:health_timeout, token}, %{active: %{token: token, timed_out: false}} = state) do
    Process.exit(state.active.pid, :kill)
    # DOWN only ends BEAM bookkeeping. Native admission remains held until
    # Rust returns, including when this task or the owner exits first.
    {:noreply, %{state | active: %{state.active | timed_out: true}, source_error: true}}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{active: %{ref: ref}} = state) do
    work = state.active.work
    {:noreply, state |> release() |> retry(work)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp step(%{active: active} = state) when not is_nil(active), do: state

  defp step(state) do
    case WorldCache.world(state.cache) do
      {:ok, target} ->
        if is_nil(state.current) or target.manifest.generation != state.current.manifest.generation do
          launch(state, {:install, target})
        else
          next_read(state)
        end

      {:error, _reason} ->
        schedule(%{state | source_error: true}, 1_000)
    end
  end

  defp next_read(state) do
    scan? = state.cursor != nil or state.rescan or state.scan_due <= now()
    dirty? = MapSet.size(state.dirty) > 0

    cond do
      scan? and (state.prefer_scan or not dirty?) ->
        state =
          if is_nil(state.cursor) do
            %{state | scan_started_at: DateTime.utc_now(), rescan: false}
          else
            state
          end

        launch(%{state | prefer_scan: false}, {:scan, state.cursor})

      dirty? ->
        ids = Enum.take(state.dirty, @batch_size)
        dirty = MapSet.difference(state.dirty, MapSet.new(ids))
        bytes = state.dirty_bytes - Enum.sum(Enum.map(ids, &byte_size/1))
        launch(%{state | dirty: dirty, dirty_bytes: bytes, prefer_scan: true}, {:dirty, ids})

      true ->
        schedule(state, min(max(state.scan_due - now(), 1), 1_000))
    end
  end

  defp launch(state, work) do
    token = make_ref()
    owner = self()
    current = state.current
    epoch = state.epoch
    sequence = state.sequence + 1

    case Task.Supervisor.start_child(state.tasks, fn ->
           send(owner, {:health_finished, token, perform(work, current, epoch, sequence)})
         end) do
      {:ok, pid} ->
        active = %{
          pid: pid,
          ref: Process.monitor(pid),
          token: token,
          work: work,
          timed_out: false,
          timeout: Process.send_after(self(), {:health_timeout, token}, @task_timeout)
        }

        %{state | active: active, sequence: sequence}

      {:error, _reason} ->
        retry(state, work)
    end
  end

  defp perform({:install, target}, nil, epoch, _sequence) do
    with {:ok, health} <- TopologyAtlas.new_health(target.world, epoch),
         do: {:ok, Map.put(target, :health, health)}
  end

  defp perform({:install, target}, current, epoch, _sequence) do
    with {:ok, health} <- TopologyAtlas.rebase_health(current.world, current.health, target.world, epoch),
         do: {:ok, Map.put(target, :health, health)}
  end

  defp perform({:scan, cursor}, current, _epoch, sequence) do
    with {:ok, page} <- TopologyAtlas.device_ids_page(current.world, cursor, @batch_size),
         :ok <- observe(current, page.ids, sequence) do
      {:ok, page.next_cursor}
    end
  end

  defp perform({:dirty, ids}, current, _epoch, sequence) do
    with :ok <- observe(current, ids, sequence), do: {:ok, nil}
  end

  defp observe(current, ids, sequence) do
    with {:ok, rows} <- WorldHealthSource.fetch(ids),
         {:ok, _result} <- TopologyAtlas.apply_health(current.world, current.health, sequence, rows),
         do: :ok
  end

  defp accept(state, {:install, _target}, current) do
    %{
      state
      | current: current,
        cursor: nil,
        scan_due: 0,
        rescan: true,
        prefer_scan: true,
        scan_started_at: nil,
        last_reconciled_at: nil
    }
  end

  defp accept(state, {:scan, _cursor}, nil) do
    %{
      state
      | cursor: nil,
        scan_due: now() + @scan_interval,
        last_reconciled_at: state.scan_started_at,
        last_read_at: DateTime.utc_now(),
        source_error: false
    }
  end

  defp accept(state, {:scan, _cursor}, next_cursor),
    do: %{state | cursor: next_cursor, last_read_at: DateTime.utc_now(), source_error: false}

  defp accept(state, {:dirty, _ids}, _result), do: %{state | last_read_at: DateTime.utc_now(), source_error: false}

  defp retry(state, {:dirty, ids}), do: state |> remember(ids) |> retry(:read)

  defp retry(state, _work), do: schedule(%{state | source_error: true}, 1_000 + :rand.uniform(250))

  defp remember(state, ids) do
    Enum.reduce(ids, state, fn id, state ->
      cond do
        not is_binary(id) or id == "" or MapSet.member?(state.dirty, id) ->
          state

        MapSet.size(state.dirty) >= @max_dirty or state.dirty_bytes + byte_size(id) > @max_dirty_bytes ->
          %{state | rescan: true}

        true ->
          %{state | dirty: MapSet.put(state.dirty, id), dirty_bytes: state.dirty_bytes + byte_size(id)}
      end
    end)
  end

  defp progress(state) do
    %{
      source_status: source_status(state),
      last_read_at: state.last_read_at,
      reconciled_since: state.last_reconciled_at,
      pending: MapSet.size(state.dirty),
      pending_bytes: state.dirty_bytes,
      reconciling: state.cursor != nil or state.rescan
    }
  end

  defp source_status(%{source_error: true}), do: :stale
  defp source_status(%{last_reconciled_at: nil}), do: :seeding

  defp source_status(state) do
    if state.rescan or state.cursor != nil or MapSet.size(state.dirty) > 0 or state.active != nil,
      do: :refreshing,
      else: :current
  end

  defp wake(%{active: nil} = state), do: schedule(state, 0)
  defp wake(state), do: state

  defp schedule(state, delay) do
    if state.timer, do: Process.cancel_timer(state.timer)
    %{state | timer: Process.send_after(self(), :step, delay)}
  end

  defp release(state) do
    Process.cancel_timer(state.active.timeout)
    Process.demonitor(state.active.ref, [:flush])
    %{state | active: nil}
  end

  defp now, do: System.monotonic_time(:millisecond)

  defp epoch do
    case :crypto.strong_rand_bytes(8) do
      <<0::64>> -> epoch()
      <<value::unsigned-64>> -> value
    end
  end
end
