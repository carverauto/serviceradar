defmodule ServiceRadarNVR.Capacity do
  @moduledoc "Serializes volume reservations; retained bytes remain charged after worker exit."
  use GenServer

  alias ServiceRadarNVR.Disk
  alias ServiceRadarRecording.Spool
  alias ServiceRadarRecording.Storage

  @limits %{max_block_bytes: 16_777_216, max_fragments: 8, max_fragment_bytes: 4_194_304}
  @probe_interval_ms 1000

  def start_link(config), do: GenServer.start_link(__MODULE__, config, name: __MODULE__)
  def reserve, do: GenServer.call(__MODULE__, :reserve)
  def check(token), do: GenServer.call(__MODULE__, {:check, token})
  def status, do: GenServer.call(__MODULE__, :status)

  @impl true
  def init(config) do
    {:ok, bytes} = Spool.reservation_bytes(@limits)
    {:ok, %{config: config, storage: nil, reservations: %{}, block_bytes: bytes, probe: nil}}
  end

  @impl true
  def handle_call(:reserve, {owner, _}, state) do
    with {:ok, storage} <- storage(state),
         {:ok, usage} <- measure(storage, state),
         :ok <- admission(usage, state) do
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

  def handle_call(:status, _from, state) do
    result = with {:ok, storage} <- storage(state), do: measure(storage, state)
    {:reply, result, state}
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
         reserved_bytes: map_size(state.reservations) * state.block_bytes,
         available_bytes: free,
         max_spool_bytes: state.config.max_spool_bytes,
         reserve_bytes: state.config.reserve_bytes,
         block_bytes: state.block_bytes
       }}
    end
  end

  defp admission(usage, state) do
    cond do
      usage.blocks + map_size(state.reservations) + 1 > usage.max_blocks ->
        {:error, :nvr_inventory_limit}

      usage.used_bytes + usage.reserved_bytes + state.block_bytes > usage.max_spool_bytes ->
        {:error, :nvr_spool_budget_exhausted}

      usage.available_bytes < usage.reserve_bytes + usage.reserved_bytes + state.block_bytes ->
        {:error, :nvr_storage_pressure}

      true ->
        :ok
    end
  end

  # Full reservations remain charged even as they are written. This deliberately
  # under-admits instead of relying on a racy measurement of each active tail.
  defp pressure(state) do
    now = System.monotonic_time(:millisecond)

    case state.probe do
      {at, result} when now - at < @probe_interval_ms ->
        {result, state}

      _ ->
        result =
          with :ok <- Storage.verify(state.storage),
               {:ok, free} <- Disk.available_bytes(state.storage.root),
               true <- free >= state.config.reserve_bytes + map_size(state.reservations) * state.block_bytes do
            :ok
          else
            false -> {:error, :nvr_storage_pressure}
            {:error, _} = error -> error
          end

        {result, %{state | probe: {now, result}}}
    end
  end
end
