defmodule ServiceRadarNVR.Capacity do
  @moduledoc """
  Serializes volume reservations; retained bytes remain charged after worker exit.

  Admission reads an incremental block ledger instead of scanning the volume on
  every call. The ledger holds each block directory's charged bytes and missing
  publication allowances. It is built once per storage lifetime by a paged scan
  of 1,024 directories per step: a volume that fits in one step is ready at once,
  a larger one answers `:nvr_inventory_rebuilding` until the scan finishes, while
  reads keep working. Every change that passes through this process updates it:
  the block an admitted writer holds is re-measured on each measurement, when it
  rotates and when its writer exits, and a block is re-measured after a
  publication record, archive receipt or recovery touches it. A block that cannot
  be measured drops the ledger, so the next call rebuilds it and reports why.

  A bounded audit re-measures 64 settled blocks per second, rotating through the
  ledger, and on each full rotation compares the volume root with it. Any
  difference closes admission with `:nvr_inventory_mismatch` until the service
  restarts. The audit never repairs or deletes.

  The block cap is the install bound `SERVICERADAR_NVR_MAX_BLOCKS`. At the cap
  admission refuses with `:nvr_inventory_limit`; reads, archive and receipts keep
  working, and nothing is deleted to make room.
  """
  use GenServer

  alias ServiceRadarNVR.Config
  alias ServiceRadarNVR.Disk
  alias ServiceRadarNVR.Publication
  alias ServiceRadarRecording.Spool
  alias ServiceRadarRecording.Storage
  alias ServiceRadarRecordingControl.RecoveryGate

  # Fixed: the archive uploads each block object in a single PUT of at most 16 MiB.
  @block_bytes %{max_block_bytes: 16_777_216, max_fragment_bytes: 4_194_304}
  @probe_interval_ms 1000
  @publication_timeout 30_000
  @rebuild_page 1024
  @audit_interval_ms 1000
  @audit_batch 64

  def start_link(config), do: GenServer.start_link(__MODULE__, config, name: __MODULE__)

  @doc "Reserve a recording slot for the block `block_id` the caller is about to write."
  def reserve(block_id), do: GenServer.call(__MODULE__, {:reserve, block_id})

  @doc "Settle the caller's sealed block and move its reservation to `next_block_id`."
  def next_block(token, next_block_id), do: GenServer.call(__MODULE__, {:next_block, token, next_block_id})

  def check(token), do: GenServer.call(__MODULE__, {:check, token})
  def status, do: GenServer.call(__MODULE__, :status)
  def delivery_config, do: GenServer.call(__MODULE__, :delivery_config)
  def recovery_storage, do: GenServer.call(__MODULE__, :recovery_storage)
  def recovery_ready, do: GenServer.call(__MODULE__, :recovery_ready)

  @doc "Up to `limit` ledger block IDs strictly after `after_id` (nil from the start), ascending."
  def ledger_page(after_id, limit), do: GenServer.call(__MODULE__, {:ledger_page, after_id, limit})

  @doc "Block IDs that an admitted writer currently holds."
  def active_blocks, do: GenServer.call(__MODULE__, :active_blocks)

  def prepare_publication(block_id, reference),
    do: GenServer.call(__MODULE__, {:publication, block_id, :intent, reference}, @publication_timeout + 5_000)

  def acknowledge_publication(block_id, bytes),
    do: GenServer.call(__MODULE__, {:publication, block_id, :acknowledgement, bytes}, @publication_timeout + 5_000)

  # Shares the one publication slot, so the receipt spends its block's receipt
  # allowance under the same write guard as the publication records.
  def record_archive_receipt(block_id, bytes),
    do: GenServer.call(__MODULE__, {:publication, block_id, :archive_receipt, bytes}, @publication_timeout + 5_000)

  def recover_block(block_id, expected_identity),
    do: GenServer.call(__MODULE__, {:recover_block, block_id, expected_identity}, 30_000)

  @impl true
  def init(config) do
    # Writers rotate at the configured fragment count. Reads, recovery and
    # publication accept the configured ceiling instead, so lowering the setting
    # never strands a block written before the change.
    limits = Map.put(@block_bytes, :max_fragments, config.max_block_fragments)
    {:ok, bytes} = Spool.reservation_bytes(limits)
    Process.send_after(self(), :audit, @audit_interval_ms)

    {:ok,
     %{
       config: config,
       limits: limits,
       read_limits: Map.put(@block_bytes, :max_fragments, Config.block_fragments_ceiling()),
       storage: nil,
       reservations: %{},
       active: %{},
       ledger: nil,
       rebuild: nil,
       inventory: :ok,
       audit_after: nil,
       block_bytes: bytes,
       publication_floor: 0,
       publication: nil,
       probe: nil
     }}
  end

  @impl true
  def handle_call({:reserve, block_id}, {owner, _}, state) do
    with {:ok, block_id} <- valid_block_id(block_id),
         {:ok, storage} <- storage(state),
         {:ok, usage, state} <- measure(storage, state),
         :ok <- consistent(state),
         :ok <- admission(usage) do
      token = Process.monitor(owner)

      {:reply, {:ok, token, storage, state.limits},
       %{
         state
         | reservations: Map.put(state.reservations, token, owner),
           active: Map.put(state.active, token, block_id),
           publication_floor: usage.publication_reserved_bytes + usage.publication_block_bytes,
           probe: nil
       }}
    else
      {:error, _} = error -> {:reply, error, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
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

  def handle_call({:next_block, token, next_block_id}, {owner, _}, state) do
    # Replace this worker's reservation atomically; the sealed block and its
    # missing publication records stay charged at their measured size.
    with true <- Map.get(state.reservations, token) == owner || {:error, :nvr_reservation_lost},
         {:ok, next_block_id} <- valid_block_id(next_block_id),
         {:ok, storage} <- storage(state),
         {:ok, usage, state} <- measure(storage, state),
         :ok <- consistent(state),
         :ok <-
           admission(%{
             usage
             | reservations: usage.reservations - 1,
               reserved_bytes: usage.reserved_bytes - state.block_bytes,
               publication_reserved_bytes: usage.publication_reserved_bytes - usage.publication_block_bytes
           }) do
      active = Map.put(state.active, token, next_block_id)
      {:reply, :ok, %{state | active: active, publication_floor: usage.publication_reserved_bytes, probe: nil}}
    else
      {:error, _} = error -> {:reply, error, %{state | probe: nil}}
      {:error, reason, state} -> {:reply, {:error, reason}, %{state | probe: nil}}
    end
  end

  def handle_call(:delivery_config, _from, state) do
    result =
      with :ok <- RecoveryGate.check(state.config.recovery_gate) do
        if state.config.delivery, do: {:ok, state.config.delivery}, else: {:error, :nvr_delivery_not_configured}
      end

    {:reply, result, state}
  end

  def handle_call(:recovery_ready, _from, state) do
    {:reply, RecoveryGate.check(state.config.recovery_gate), state}
  end

  def handle_call(:status, _from, state) do
    with {:ok, storage} <- storage(state),
         {:ok, usage, state} <- measure(storage, state) do
      {:reply, {:ok, usage}, state}
    else
      {:error, _} = error -> {:reply, error, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:ledger_page, after_id, limit}, _from, state) do
    with {:ok, storage} <- storage(state),
         {:ok, state} <- ensure_ledger(%{state | storage: storage}) do
      {:reply, {:ok, page(state.ledger.entries, after_id, limit)}, state}
    else
      {:error, _} = error -> {:reply, error, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:active_blocks, _from, state), do: {:reply, MapSet.new(Map.values(state.active)), state}

  def handle_call(:recovery_storage, _from, state) do
    case storage(state) do
      {:ok, storage} -> {:reply, {:ok, storage, state.read_limits}, %{state | storage: storage}}
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
    with {:ok, storage} <- storage(state),
         {:ok, state} <- ensure_ledger(%{state | storage: storage}),
         {:ok, free} <- Disk.available_bytes(storage.root),
         :ok <- writable(free, state.config.reserve_bytes) do
      result = Spool.recover_sealed(storage, block_id, identity, state.read_limits)
      {:reply, result, settle(%{state | probe: nil}, block_id)}
    else
      {:error, _} = error -> {:reply, error, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:publication, _block_id, _kind, _payload}, _from, %{publication: publication} = state)
      when not is_nil(publication) do
    {:reply, {:error, :nvr_publication_capacity}, state}
  end

  def handle_call({:publication, block_id, kind, payload}, from, state) do
    with {:ok, storage} <- storage(state),
         {:ok, publication} <- start_publication(storage, block_id, kind, payload, state.read_limits, from) do
      {:noreply, %{state | storage: storage, publication: publication}}
    else
      {:error, _} = error -> {:reply, error, state}
    end
  end

  def handle_call({:publication_write, kind, additional}, {owner, _}, %{publication: %{pid: owner} = publication} = state) do
    with {:ok, usage, state} <- measure(state.storage, state),
         :ok <- publication_capacity(usage, kind, additional) do
      # Write guards keep the missing record's allowance and the complete
      # pending write until the task exits and its block is re-measured.
      floor = usage.publication_reserved_bytes + additional
      publication = %{publication | reserved_bytes: additional}
      {:reply, :ok, %{state | publication: publication, publication_floor: floor, probe: nil}}
    else
      {:error, _} = error -> {:reply, error, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
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

    # A failed/partial write remains on disk. Re-measure its block only after
    # the writer is dead; a failed measure keeps the previous conservative floor.
    state = settle(%{state | publication: nil, probe: nil}, publication.block_id)

    state =
      case measure(state.storage, state) do
        {:ok, usage, state} -> %{state | publication_floor: usage.publication_reserved_bytes}
        {:error, _} -> state
        {:error, _reason, state} -> state
      end

    GenServer.reply(publication.from, result)
    {:noreply, state}
  end

  def handle_info({:DOWN, token, :process, owner, _}, state) do
    if Map.get(state.reservations, token) == owner do
      {block_id, active} = Map.pop(state.active, token)
      state = %{state | reservations: Map.delete(state.reservations, token), active: active, probe: nil}
      # The worker's last block is settled at the size it left on disk.
      {:noreply, settle(state, block_id)}
    else
      {:noreply, %{state | probe: nil}}
    end
  end

  def handle_info(:rebuild_page, %{rebuild: %{}} = state), do: {:noreply, rebuild_step(state)}
  def handle_info(:rebuild_page, state), do: {:noreply, state}

  def handle_info(:audit, state) do
    Process.send_after(self(), :audit, @audit_interval_ms)
    {:noreply, audit(state)}
  end

  defp start_publication(storage, block_id, kind, payload, limits, from) do
    owner = self()
    token = make_ref()

    case Task.Supervisor.start_child(ServiceRadarNVR.PublicationTasks, fn ->
           receive do
             {:publication_start, ^token} -> publish(owner, token, storage, block_id, kind, payload, limits)
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
           block_id: block_id,
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

  defp publish(owner, token, storage, block_id, kind, payload, limits) do
    # The task's own deadline survives loss of the requesting caller. Timeout
    # and crash are unknown outcomes; immutable files are preserved for retry.
    {:ok, timer} = :timer.exit_after(@publication_timeout, {:shutdown, :nvr_publication_timeout})

    try do
      result =
        with {:ok, bytes, additional} <- Publication.prepare(storage, block_id, kind, payload, limits),
             :ok <- GenServer.call(owner, {:publication_write, kind, additional}, :infinity),
             :ok <- Publication.persist(storage, block_id, kind, bytes) do
          {:ok, bytes}
        end

      send(owner, {:publication_result, token, result})
    after
      :timer.cancel(timer)
    end
  end

  defp storage(%{config: %{root: nil}}), do: {:error, :nvr_storage_not_configured}

  defp storage(state) do
    with :ok <- RecoveryGate.check(state.config.recovery_gate), do: open_storage(state)
  end

  defp open_storage(%{storage: nil, config: config}), do: Storage.open(config.root, config.storage_id)
  defp open_storage(%{storage: storage}), do: with(:ok <- Storage.verify(storage), do: {:ok, storage})

  # Usage from the ledger, with each block an admitted writer holds re-measured.
  defp measure(storage, state) do
    with :ok <- RecoveryGate.check(state.config.recovery_gate),
         {:ok, state} <- ensure_ledger(%{state | storage: storage}),
         {:ok, state} <- remeasure_active(state),
         {:ok, free} <- Disk.available_bytes(storage.root),
         :ok <- Storage.verify(storage),
         :ok <- RecoveryGate.check(state.config.recovery_gate) do
      ledger = state.ledger

      {:ok,
       %{
         inventory: if(state.inventory == :ok, do: :ready, else: :mismatch),
         used_bytes: ledger.used_bytes,
         blocks: :gb_trees.size(ledger.entries),
         max_blocks: state.config.max_blocks,
         reservations: map_size(state.reservations),
         reserved_bytes: map_size(state.reservations) * state.block_bytes,
         publication_reserved_bytes:
           ledger.pending_bytes + map_size(state.reservations) * Publication.pending_bytes([]) +
             publication_write_bytes(state),
         publication_write_reserved_bytes: publication_write_bytes(state),
         publication_operations: if(is_nil(state.publication), do: 0, else: 1),
         publication_block_bytes: Publication.pending_bytes([]),
         available_bytes: free,
         max_spool_bytes: state.config.max_spool_bytes,
         reserve_bytes: state.config.reserve_bytes,
         block_bytes: state.block_bytes
       }, state}
    end
  end

  defp consistent(%{inventory: {:mismatch, _block}}), do: {:error, :nvr_inventory_mismatch}
  defp consistent(_state), do: :ok

  defp remeasure_active(state) do
    Enum.reduce_while(Map.values(state.active), {:ok, state}, fn block_id, {:ok, state} ->
      case remeasure(state, block_id) do
        {:ok, state} -> {:cont, {:ok, state}}
        {:error, reason} -> {:halt, {:error, reason, drop_ledger(state)}}
      end
    end)
  end

  # Re-measure one block after a change this process saw; a block that cannot
  # be measured drops the ledger so the next call rebuilds and reports it.
  defp settle(state, nil), do: state

  defp settle(state, block_id) do
    case remeasure(state, block_id) do
      {:ok, state} -> state
      {:error, _reason} -> drop_ledger(state)
    end
  end

  defp remeasure(%{ledger: nil} = state, _block_id), do: {:ok, state}

  defp remeasure(state, block_id) do
    case Disk.block_usage(state.storage.root, block_id) do
      {:ok, bytes, pending} -> {:ok, %{state | ledger: ledger_put(state.ledger, block_id, {bytes, pending})}}
      {:error, :enoent} -> {:ok, %{state | ledger: ledger_delete(state.ledger, block_id)}}
      {:error, _} = error -> error
    end
  end

  defp drop_ledger(state), do: %{state | ledger: nil, rebuild: nil, audit_after: nil}

  defp ensure_ledger(%{ledger: %{}} = state), do: {:ok, state}
  defp ensure_ledger(%{rebuild: %{}} = state), do: {:error, :nvr_inventory_rebuilding, state}

  defp ensure_ledger(state) do
    with {:ok, names} <- Disk.block_names(state.storage) do
      case rebuild_step(%{state | rebuild: %{names: names, ledger: empty_ledger()}}) do
        %{ledger: %{}} = state -> {:ok, state}
        %{rebuild: %{}} = state -> {:error, :nvr_inventory_rebuilding, state}
        %{rebuild: {:failed, reason}} = state -> {:error, reason, %{state | rebuild: nil}}
      end
    end
  end

  # One page of the scan that builds the ledger. A larger volume continues by
  # message, so status and reads keep being served while it is measured.
  defp rebuild_step(%{rebuild: %{names: names, ledger: ledger}} = state) do
    {page, rest} = Enum.split(names, @rebuild_page)

    result =
      Enum.reduce_while(page, {:ok, ledger}, fn name, {:ok, ledger} ->
        case Disk.block_usage(state.storage.root, name) do
          {:ok, bytes, pending} -> {:cont, {:ok, ledger_put(ledger, name, {bytes, pending})}}
          {:error, :enoent} -> {:cont, {:ok, ledger}}
          {:error, _} -> {:halt, {:error, :nvr_inventory_unavailable}}
        end
      end)

    case {result, rest} do
      {{:ok, ledger}, []} ->
        %{state | ledger: ledger, rebuild: nil, audit_after: nil}

      {{:ok, ledger}, rest} ->
        send(self(), :rebuild_page)
        %{state | rebuild: %{names: rest, ledger: ledger}}

      {{:error, reason}, _rest} ->
        %{state | rebuild: {:failed, reason}}
    end
  end

  defp empty_ledger, do: %{entries: :gb_trees.empty(), used_bytes: 0, pending_bytes: 0}

  defp ledger_put(ledger, block_id, {bytes, pending} = usage) do
    {used, waiting} =
      case :gb_trees.lookup(block_id, ledger.entries) do
        {:value, {old_bytes, old_pending}} -> {ledger.used_bytes - old_bytes, ledger.pending_bytes - old_pending}
        :none -> {ledger.used_bytes, ledger.pending_bytes}
      end

    %{
      entries: :gb_trees.enter(block_id, usage, ledger.entries),
      used_bytes: used + bytes,
      pending_bytes: waiting + pending
    }
  end

  defp ledger_delete(ledger, block_id) do
    case :gb_trees.lookup(block_id, ledger.entries) do
      {:value, {bytes, pending}} ->
        %{
          entries: :gb_trees.delete(block_id, ledger.entries),
          used_bytes: ledger.used_bytes - bytes,
          pending_bytes: ledger.pending_bytes - pending
        }

      :none ->
        ledger
    end
  end

  defp page(entries, after_id, limit) do
    iterator =
      if is_nil(after_id), do: :gb_trees.iterator(entries), else: :gb_trees.iterator_from(after_id, entries)

    take(iterator, after_id, limit, [])
  end

  defp take(_iterator, _after_id, 0, acc), do: Enum.reverse(acc)

  defp take(iterator, after_id, limit, acc) do
    case :gb_trees.next(iterator) do
      {^after_id, _value, iterator} -> take(iterator, after_id, limit, acc)
      {key, _value, iterator} -> take(iterator, after_id, limit - 1, [key | acc])
      :none -> Enum.reverse(acc)
    end
  end

  # Re-measure a fixed number of settled blocks per tick, rotating, and on each
  # full rotation compare the volume root with the ledger. Blocks that a writer
  # or a publication holds change legitimately and are skipped.
  defp audit(%{ledger: %{}, inventory: :ok, storage: %Storage{}} = state) do
    with :ok <- RecoveryGate.check(state.config.recovery_gate),
         :ok <- Storage.verify(state.storage) do
      busy = busy_blocks(state)
      batch = page(state.ledger.entries, state.audit_after, @audit_batch)

      case Enum.find(batch, &changed?(state, &1, busy)) do
        nil when length(batch) < @audit_batch -> audit_root(%{state | audit_after: nil}, busy)
        nil -> %{state | audit_after: List.last(batch)}
        block_id -> %{state | inventory: {:mismatch, block_id}}
      end
    else
      _ -> state
    end
  end

  defp audit(state), do: state

  defp changed?(state, block_id, busy) do
    not MapSet.member?(busy, block_id) and
      case Disk.block_usage(state.storage.root, block_id) do
        {:ok, bytes, pending} -> {bytes, pending} != :gb_trees.get(block_id, state.ledger.entries)
        {:error, _} -> true
      end
  end

  defp audit_root(state, busy) do
    case Disk.block_names(state.storage) do
      {:ok, names} ->
        case Enum.find(names, &(not :gb_trees.is_defined(&1, state.ledger.entries) and not MapSet.member?(busy, &1))) do
          nil -> state
          name -> %{state | inventory: {:mismatch, name}}
        end

      {:error, _} ->
        state
    end
  end

  defp busy_blocks(state) do
    active = MapSet.new(Map.values(state.active))
    if state.publication, do: MapSet.put(active, state.publication.block_id), else: active
  end

  defp valid_block_id(block_id) do
    if is_binary(block_id) and Regex.match?(~r/\A[0-9a-f]{64}\z/, block_id),
      do: {:ok, block_id},
      else: {:error, :invalid_block_id}
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
    case RecoveryGate.check(state.config.recovery_gate) do
      :ok -> pressure(state, System.monotonic_time(:millisecond))
      error -> {error, %{state | probe: nil}}
    end
  end

  defp pressure(state, now) do
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
