defmodule ServiceRadarNVR.Capacity do
  @moduledoc "Serializes volume reservations; retained bytes remain charged after worker exit."
  use GenServer

  alias ServiceRadarNVR.Disk
  alias ServiceRadarNVR.Publication
  alias ServiceRadarRecording.Spool
  alias ServiceRadarRecording.Storage

  @limits %{max_block_bytes: 16_777_216, max_fragments: 8, max_fragment_bytes: 4_194_304}
  @probe_interval_ms 1000
  @publication_timeout 30_000

  def start_link(config), do: GenServer.start_link(__MODULE__, config, name: __MODULE__)
  def reserve, do: GenServer.call(__MODULE__, :reserve)
  def next_block(token), do: GenServer.call(__MODULE__, {:next_block, token})
  def check(token), do: GenServer.call(__MODULE__, {:check, token})
  def status, do: GenServer.call(__MODULE__, :status)
  def recovery_storage, do: GenServer.call(__MODULE__, :recovery_storage)

  def prepare_publication(block_id, reference),
    do: GenServer.call(__MODULE__, {:publication, block_id, :intent, reference}, @publication_timeout + 5_000)

  def acknowledge_publication(block_id, bytes),
    do: GenServer.call(__MODULE__, {:publication, block_id, :acknowledgement, bytes}, @publication_timeout + 5_000)

  def recover_block(block_id, expected_identity),
    do: GenServer.call(__MODULE__, {:recover_block, block_id, expected_identity}, 30_000)

  @impl true
  def init(config) do
    {:ok, bytes} = Spool.reservation_bytes(@limits)

    {:ok,
     %{
       config: config,
       storage: nil,
       reservations: %{},
       block_bytes: bytes,
       publication_floor: 0,
       publication: nil,
       probe: nil
     }}
  end

  @impl true
  def handle_call(:reserve, {owner, _}, state) do
    with {:ok, storage} <- storage(state),
         {:ok, usage} <- measure(storage, state),
         :ok <- admission(usage) do
      token = Process.monitor(owner)
      reservations = Map.put(state.reservations, token, owner)

      {:reply, {:ok, token, storage, @limits},
       %{
         state
         | storage: storage,
           reservations: reservations,
           publication_floor: usage.publication_reserved_bytes + usage.publication_block_bytes,
           probe: nil
       }}
    else
      {:error, _} = error -> {:reply, error, state}
    end
  end

  def handle_call({:check, token}, {owner, _}, state) do
    if Map.get(state.reservations, token) == owner do
      {result, state} = pressure(state)
      {:reply, result, state}
    else
      {:reply, {:error, :nvr_reservation_lost}, state}
    end
  end

  def handle_call({:next_block, token}, {owner, _}, state) do
    # Replace this worker's reservation atomically; the sealed block and its
    # missing publication records remain charged in the fresh inventory.
    with true <- Map.get(state.reservations, token) == owner || {:error, :nvr_reservation_lost},
         {:ok, storage} <- storage(state),
         {:ok, usage} <- measure(storage, state),
         :ok <-
           admission(%{
             usage
             | reservations: usage.reservations - 1,
               reserved_bytes: usage.reserved_bytes - state.block_bytes,
               publication_reserved_bytes: usage.publication_reserved_bytes - usage.publication_block_bytes
           }) do
      {:reply, :ok, %{state | publication_floor: usage.publication_reserved_bytes, probe: nil}}
    else
      {:error, _} = error -> {:reply, error, %{state | probe: nil}}
    end
  end

  def handle_call(:status, _from, state) do
    result = with {:ok, storage} <- storage(state), do: measure(storage, state)
    {:reply, result, state}
  end

  def handle_call(:recovery_storage, _from, state) do
    case storage(state) do
      {:ok, storage} -> {:reply, {:ok, storage, @limits}, %{state | storage: storage}}
      {:error, _} = error -> {:reply, error, state}
    end
  end

  def handle_call({:recover_block, _block_id, _identity}, _from, %{publication: publication} = state)
      when not is_nil(publication) do
    {:reply, {:error, :nvr_publication_capacity}, state}
  end

  def handle_call({:recover_block, _block_id, _identity}, _from, %{reservations: reservations} = state)
      when map_size(reservations) > 0 do
    {:reply, {:error, :nvr_recordings_active}, state}
  end

  def handle_call({:recover_block, block_id, identity}, _from, state) do
    # Keep admission serialized through the repair and seal. There are no local
    # writers, so verification cannot stall an admitted recording's write guard.
    case storage(state) do
      {:ok, storage} ->
        result =
          with {:ok, _inventory} <- Disk.inventory(storage),
               {:ok, free} <- Disk.available_bytes(storage.root),
               :ok <- writable(free, state.config.reserve_bytes) do
            Spool.recover_sealed(storage, block_id, identity, @limits)
          end

        {:reply, result, %{state | storage: storage, probe: nil}}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:publication, _block_id, _kind, _payload}, _from, %{publication: publication} = state)
      when not is_nil(publication) do
    {:reply, {:error, :nvr_publication_capacity}, state}
  end

  def handle_call({:publication, block_id, kind, payload}, from, state) do
    with {:ok, storage} <- storage(state),
         {:ok, publication} <- start_publication(storage, block_id, kind, payload, from) do
      {:noreply, %{state | storage: storage, publication: publication}}
    else
      {:error, _} = error -> {:reply, error, state}
    end
  end

  def handle_call({:publication_write, kind, additional}, {owner, _}, %{publication: %{pid: owner} = publication} = state) do
    with {:ok, usage} <- measure(state.storage, state),
         :ok <- publication_capacity(usage, kind, additional) do
      # Keep the complete pending write charged until the task has exited, even
      # when inventory already sees the new file and drops its missing slot.
      spent = if additional > 0, do: Publication.max_bytes(kind), else: 0
      floor = usage.publication_reserved_bytes - spent + additional
      publication = %{publication | reserved_bytes: additional}
      {:reply, :ok, %{state | publication: publication, publication_floor: floor, probe: nil}}
    else
      {:error, _} = error -> {:reply, error, state}
    end
  end

  def handle_call({:publication_write, _kind, _additional}, _from, state) do
    {:reply, {:error, :nvr_publication_unavailable}, state}
  end

  @impl true
  def handle_info({:publication_result, token, result}, %{publication: %{token: token} = publication} = state) do
    {:noreply, %{state | publication: %{publication | result: result}}}
  end

  def handle_info(
        {:DOWN, monitor, :process, pid, reason},
        %{publication: %{monitor: monitor, pid: pid} = publication} = state
      ) do
    result =
      case reason do
        :normal -> publication.result
        {:shutdown, :nvr_publication_timeout} -> {:error, :nvr_publication_timeout}
        _ -> {:error, :nvr_publication_unavailable}
      end

    state = %{state | publication: nil, probe: nil}

    # A failed/partial write remains on disk. Rebuild allowances only after the
    # writer is dead; failed inventory keeps the previous conservative floor.
    state =
      case measure(state.storage, state) do
        {:ok, usage} -> %{state | publication_floor: usage.publication_reserved_bytes}
        {:error, _} -> state
      end

    GenServer.reply(publication.from, result)
    {:noreply, state}
  end

  def handle_info({:DOWN, token, :process, owner, _}, state) do
    reservations =
      if Map.get(state.reservations, token) == owner,
        do: Map.delete(state.reservations, token),
        else: state.reservations

    # The worker may have created a block since the last inventory. Keep its
    # publication headroom until the next admission rebuilds it from disk.
    {:noreply, %{state | reservations: reservations, probe: nil}}
  end

  defp start_publication(storage, block_id, kind, payload, from) do
    owner = self()
    token = make_ref()

    case Task.Supervisor.start_child(ServiceRadarNVR.PublicationTasks, fn ->
           receive do
             {:publication_start, ^token} -> publish(owner, token, storage, block_id, kind, payload)
           end
         end) do
      {:ok, pid} ->
        monitor = Process.monitor(pid)
        send(pid, {:publication_start, token})

        {:ok,
         %{
           pid: pid,
           monitor: monitor,
           token: token,
           from: from,
           reserved_bytes: 0,
           result: {:error, :nvr_publication_unavailable}
         }}

      {:error, :max_children} ->
        {:error, :nvr_publication_capacity}

      {:error, _} ->
        {:error, :nvr_publication_unavailable}
    end
  catch
    :exit, _ -> {:error, :nvr_publication_unavailable}
  end

  defp publish(owner, token, storage, block_id, kind, payload) do
    # The task's own deadline survives loss of the requesting caller. Timeout
    # and crash are unknown outcomes; immutable files are preserved for retry.
    {:ok, timer} = :timer.exit_after(@publication_timeout, {:shutdown, :nvr_publication_timeout})

    try do
      result =
        with {:ok, bytes, additional} <- Publication.prepare(storage, block_id, kind, payload, @limits),
             :ok <- GenServer.call(owner, {:publication_write, kind, additional}),
             :ok <- Publication.persist(storage, block_id, kind, bytes) do
          {:ok, bytes}
        end

      send(owner, {:publication_result, token, result})
    after
      :timer.cancel(timer)
    end
  end

  defp storage(%{config: %{root: nil}}), do: {:error, :nvr_storage_not_configured}
  defp storage(%{storage: nil, config: config}), do: Storage.open(config.root, config.storage_id)
  defp storage(%{storage: storage}), do: with(:ok <- Storage.verify(storage), do: {:ok, storage})

  defp measure(storage, state) do
    with {:ok, inventory} <- Disk.inventory(storage),
         {:ok, free} <- Disk.available_bytes(storage.root),
         :ok <- Storage.verify(storage) do
      {:ok,
       %{
         used_bytes: inventory.used_bytes,
         blocks: inventory.blocks,
         max_blocks: inventory.max_blocks,
         reservations: map_size(state.reservations),
         reserved_bytes: map_size(state.reservations) * state.block_bytes,
         publication_reserved_bytes:
           inventory.publication_reserved_bytes + map_size(state.reservations) * Publication.pending_bytes([]) +
             publication_write_bytes(state),
         publication_write_reserved_bytes: publication_write_bytes(state),
         publication_operations: if(is_nil(state.publication), do: 0, else: 1),
         publication_block_bytes: Publication.pending_bytes([]),
         available_bytes: free,
         max_spool_bytes: state.config.max_spool_bytes,
         reserve_bytes: state.config.reserve_bytes,
         block_bytes: state.block_bytes
       }}
    end
  end

  defp publication_write_bytes(%{publication: nil}), do: 0
  defp publication_write_bytes(%{publication: publication}), do: publication.reserved_bytes

  # Exact retries only sync retained evidence and need no new budget.
  defp publication_capacity(_usage, _kind, 0), do: :ok

  defp publication_capacity(usage, kind, bytes) do
    # Spend only this absent record's allowance; preserve all other slots. A
    # retained partial record cannot reach this path because prepare refuses it.
    needed = usage.reserved_bytes + bytes + usage.publication_reserved_bytes - Publication.max_bytes(kind)

    cond do
      usage.used_bytes + needed > usage.max_spool_bytes -> {:error, :nvr_spool_budget_exhausted}
      usage.available_bytes < usage.reserve_bytes + needed -> {:error, :nvr_storage_pressure}
      true -> :ok
    end
  end

  @doc """
  Admission charges retained bytes, missing publication records, every full
  active reservation and the new block with its publication allowance. The
  physical floor plus these reservations must be free. Full active reservations
  stay charged even as they are written, conservatively under-admitting.
  """
  def admission(usage) do
    needed = usage.reserved_bytes + usage.block_bytes + usage.publication_reserved_bytes + usage.publication_block_bytes

    cond do
      usage.blocks + usage.reservations + 1 > usage.max_blocks ->
        {:error, :nvr_inventory_limit}

      usage.used_bytes + needed > usage.max_spool_bytes ->
        {:error, :nvr_spool_budget_exhausted}

      usage.available_bytes < usage.reserve_bytes + needed ->
        {:error, :nvr_storage_pressure}

      true ->
        :ok
    end
  end

  @doc "Admitted workers may consume reserved media space, but must preserve the supplied free-space floor."
  def writable(available_bytes, reserve_bytes) when available_bytes >= reserve_bytes, do: :ok
  def writable(_available_bytes, _reserve_bytes), do: {:error, :nvr_storage_pressure}

  defp pressure(state) do
    now = System.monotonic_time(:millisecond)

    case state.probe do
      {at, result} when now - at < @probe_interval_ms ->
        {result, state}

      _ ->
        result =
          with :ok <- Storage.verify(state.storage),
               {:ok, free} <- Disk.available_bytes(state.storage.root),
               do: writable(free, state.config.reserve_bytes + state.publication_floor)

        {result, %{state | probe: {now, result}}}
    end
  end
end
