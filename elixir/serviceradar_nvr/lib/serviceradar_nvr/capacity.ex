defmodule ServiceRadarNVR.Capacity do
  @moduledoc "Serializes volume reservations; retained bytes remain charged after worker exit."
  use GenServer

  alias ServiceRadarNVR.Disk
  alias ServiceRadarNVR.PublicationIntent
  alias ServiceRadarRecording.Spool
  alias ServiceRadarRecording.Storage

  @limits %{max_block_bytes: 16_777_216, max_fragments: 8, max_fragment_bytes: 4_194_304}
  @probe_interval_ms 1000

  def start_link(config), do: GenServer.start_link(__MODULE__, config, name: __MODULE__)
  def reserve, do: GenServer.call(__MODULE__, :reserve)
  def next_block(token), do: GenServer.call(__MODULE__, {:next_block, token})
  def check(token), do: GenServer.call(__MODULE__, {:check, token})
  def status, do: GenServer.call(__MODULE__, :status)
  def recovery_storage, do: GenServer.call(__MODULE__, :recovery_storage)

  def prepare_publication(block_id, reference),
    do: GenServer.call(__MODULE__, {:prepare_publication, block_id, reference}, 30_000)

  def recover_block(block_id, expected_identity),
    do: GenServer.call(__MODULE__, {:recover_block, block_id, expected_identity}, 30_000)

  @impl true
  def init(config) do
    {:ok, bytes} = Spool.reservation_bytes(@limits)
    {:ok, %{config: config, storage: nil, reservations: %{}, block_bytes: bytes, probe: nil}}
  end

  @impl true
  def handle_call(:reserve, {owner, _}, state) do
    with {:ok, storage} <- storage(state),
         {:ok, usage} <- measure(storage, state),
         :ok <- admission(usage) do
      token = Process.monitor(owner)
      reservations = Map.put(state.reservations, token, owner)
      {:reply, {:ok, token, storage, @limits}, %{state | storage: storage, reservations: reservations, probe: nil}}
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
    result =
      with true <- Map.get(state.reservations, token) == owner || {:error, :nvr_reservation_lost},
           {:ok, storage} <- storage(state),
           {:ok, usage} <- measure(storage, state) do
        # Replace this worker's reservation atomically; the sealed block remains
        # in the fresh inventory. No unreserved writer can slip between blocks.
        admission(%{
          usage
          | reservations: usage.reservations - 1,
            reserved_bytes: usage.reserved_bytes - state.block_bytes
        })
      end

    {:reply, result, %{state | probe: nil}}
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

  def handle_call({:prepare_publication, _block_id, _reference}, _from, %{reservations: reservations} = state)
      when map_size(reservations) > 0 do
    {:reply, {:error, :nvr_recordings_active}, state}
  end

  def handle_call({:prepare_publication, block_id, reference}, _from, state) do
    case storage(state) do
      {:ok, storage} ->
        result =
          with {:ok, usage} <- measure(storage, state),
               {:ok, bytes, additional} <- PublicationIntent.prepare(storage, block_id, reference, @limits),
               :ok <- publication_capacity(usage, additional),
               :ok <- PublicationIntent.persist(storage, block_id, bytes) do
            {:ok, bytes}
          end

        {:reply, result, %{state | storage: storage, probe: nil}}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_info({:DOWN, token, :process, owner, _}, state) do
    reservations =
      if Map.get(state.reservations, token) == owner,
        do: Map.delete(state.reservations, token),
        else: state.reservations

    {:noreply, %{state | reservations: reservations, probe: nil}}
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
         available_bytes: free,
         max_spool_bytes: state.config.max_spool_bytes,
         reserve_bytes: state.config.reserve_bytes,
         block_bytes: state.block_bytes
       }}
    end
  end

  # Existing exact retries only sync retained evidence and need no new budget.
  # No writer is admitted during this operation, so it cannot spend a recording
  # reservation or race a new reservation while committing the metadata.
  defp publication_capacity(_usage, 0), do: :ok

  defp publication_capacity(usage, bytes) do
    cond do
      usage.used_bytes + bytes > usage.max_spool_bytes -> {:error, :nvr_spool_budget_exhausted}
      usage.available_bytes < usage.reserve_bytes + bytes -> {:error, :nvr_storage_pressure}
      true -> :ok
    end
  end

  @doc """
  Admission charges retained bytes, every full active reservation and the new
  block against the logical budget, and requires the physical floor plus all of
  those reservations to be free. Full reservations stay charged even as they are
  written, deliberately under-admitting instead of measuring each active tail.
  """
  def admission(usage) do
    cond do
      usage.blocks + usage.reservations + 1 > usage.max_blocks ->
        {:error, :nvr_inventory_limit}

      usage.used_bytes + usage.reserved_bytes + usage.block_bytes > usage.max_spool_bytes ->
        {:error, :nvr_spool_budget_exhausted}

      usage.available_bytes < usage.reserve_bytes + usage.reserved_bytes + usage.block_bytes ->
        {:error, :nvr_storage_pressure}

      true ->
        :ok
    end
  end

  @doc "Admitted workers may consume their reserved space and stop only at the physical floor."
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
               do: writable(free, state.config.reserve_bytes)

        {result, %{state | probe: {now, result}}}
    end
  end
end
