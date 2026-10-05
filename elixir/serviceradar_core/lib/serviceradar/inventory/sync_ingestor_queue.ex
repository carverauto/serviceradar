defmodule ServiceRadar.Inventory.SyncIngestorQueue do
  @moduledoc """
  Buffers sync result chunks and coalesces bursts before ingestion.

  In schema-agnostic mode, operates as a single queue since the DB schema
  is set by CNPG search_path credentials.

  Admission is bounded and answers: `enqueue/1` returns `:ok`, or
  `{:error, :sync_ingest_queue_full}` once the queued chunks or bytes reach
  their limits (`:sync_ingestor_queue_max_pending_chunks`, default 256, and
  `:sync_ingestor_queue_max_pending_bytes`, default 512 MiB), counting chunks
  queued while an ingestion task is running. The queue holds the raw payloads;
  they are decoded in the ingestion task, so a large or malformed payload costs
  this process nothing.

  The queue remembers which chunks of each sync run it has ingested. When a
  run's final chunk arrives and some of its chunks never did -- rejected here,
  or lost upstream -- the run is recorded as failed with `:sync_run_incomplete`
  (so its snapshot is not activated) and `[:serviceradar, :sync_ingestion,
  :incomplete_run]` is emitted.
  """

  use GenServer

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Integrations.IntegrationSource
  alias ServiceRadar.Inventory.ArmisSourceSnapshot
  alias ServiceRadar.Inventory.SyncIngestor
  alias ServiceRadar.Repo

  require Logger

  defmodule Queue do
    @moduledoc false
    defstruct batches: [], chunk_count: 0, bytes: 0, timer_ref: nil, inflight: false, ready: false
  end

  @default_max_pending_chunks 256
  @default_max_pending_bytes 512 * 1_024 * 1_024
  @default_admission_timeout_ms 5_000
  # A run whose final chunk never arrives is forgotten after this long.
  @run_tracking_ttl_ms to_timeout(hour: 6)

  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @spec enqueue(binary() | nil) ::
          :ok | {:error, :sync_ingest_queue_full | :sync_ingest_queue_unavailable}
  def enqueue(message) do
    GenServer.call(queue_server(), {:enqueue, message}, admission_timeout_ms())
  catch
    :exit, reason ->
      Logger.warning("Sync ingestion queue did not admit a chunk: #{inspect(reason)}")
      {:error, :sync_ingest_queue_unavailable}
  end

  def ingest_sync_results(message) do
    do_ingest_results(message)
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       queue: %Queue{},
       inflight_ref: nil,
       runs: %{},
       task_supervisor: Keyword.get(opts, :task_supervisor, task_supervisor())
     }}
  end

  @impl true
  def handle_call({:enqueue, message}, _from, state) do
    bytes = message_bytes(message)
    queue = state.queue

    if queue.chunk_count + 1 > max_pending_chunks() or queue.bytes + bytes > max_pending_bytes() do
      :telemetry.execute(
        [:serviceradar, :sync_ingestion, :rejected],
        %{count: 1, bytes: bytes},
        %{
          reason: :sync_ingest_queue_full
        }
      )

      Logger.warning("Sync ingestion queue full; rejected a #{bytes}-byte chunk")
      {:reply, {:error, :sync_ingest_queue_full}, state}
    else
      :telemetry.execute(
        [:serviceradar, :sync_ingestion, :admitted],
        %{count: 1, bytes: bytes},
        %{}
      )

      {:reply, :ok, state |> enqueue_message(message, bytes) |> emit_state()}
    end
  end

  defp emit_state(state) do
    :telemetry.execute(
      [:serviceradar, :sync_ingestion, :state],
      %{
        pending_count: state.queue.chunk_count,
        pending_bytes: state.queue.bytes,
        in_flight_count: if(state.queue.inflight, do: 1, else: 0)
      },
      %{}
    )

    state
  end

  # The ingestion task reports the chunks it ingested for runs not yet final.
  @impl true
  def handle_cast({:sync_runs_seen, seen, finished}, state) do
    now = System.monotonic_time(:millisecond)

    runs =
      state.runs
      |> Map.drop(finished)
      |> Map.merge(seen, fn _key, old, new ->
        %{new | indices: MapSet.union(old.indices, new.indices)}
      end)
      |> Map.reject(fn {_key, run} -> now - run.seen_at > @run_tracking_ttl_ms end)

    {:noreply, %{state | runs: runs}}
  end

  @impl true
  def handle_info(:flush, state) do
    queue = state.queue

    if queue.chunk_count == 0 do
      {:noreply, state}
    else
      queue = %{queue | timer_ref: nil, ready: true}
      state = %{state | queue: queue}
      {:noreply, state |> maybe_start_ingestion() |> emit_state()}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    if state.inflight_ref == ref do
      queue = %{state.queue | inflight: false}
      state = %{state | queue: queue, inflight_ref: nil}

      if reason != :normal do
        Logger.warning("Sync ingestion task exited: #{inspect(reason)}")
      end

      {:noreply, state |> maybe_start_ingestion() |> emit_state()}
    else
      {:noreply, state}
    end
  end

  defp message_bytes(message) when is_binary(message), do: byte_size(message)
  defp message_bytes(_message), do: 0

  defp enqueue_message(state, message, bytes) do
    queue = state.queue

    queue = %{
      queue
      | batches: [message | queue.batches],
        chunk_count: queue.chunk_count + 1,
        bytes: queue.bytes + bytes
    }

    {queue, state} = maybe_schedule_flush(state, queue)
    state = %{state | queue: queue}

    if force_flush?(queue) do
      cancel_timer(queue.timer_ref)
      send(self(), :flush)
      state
    else
      state
    end
  end

  defp maybe_schedule_flush(state, queue) do
    coalesce_ms = coalesce_window_ms()

    cond do
      coalesce_ms <= 0 ->
        send(self(), :flush)
        {queue, state}

      queue.timer_ref == nil ->
        ref = Process.send_after(self(), :flush, coalesce_ms)
        {%{queue | timer_ref: ref}, state}

      true ->
        {queue, state}
    end
  end

  defp force_flush?(queue) do
    max_chunks = queue_max_chunks()

    is_integer(max_chunks) and max_chunks > 0 and queue.chunk_count >= max_chunks
  end

  defp maybe_start_ingestion(state) do
    queue = state.queue

    if queue.ready and not queue.inflight and queue.chunk_count > 0 do
      start_ingestion_task(state)
    else
      state
    end
  end

  defp start_ingestion_task(state) do
    queue = state.queue
    messages = Enum.reverse(queue.batches)
    chunk_count = queue.chunk_count
    runs = state.runs
    owner = self()

    queue = %{
      queue
      | batches: [],
        chunk_count: 0,
        bytes: 0,
        inflight: true,
        ready: false,
        timer_ref: nil
    }

    state = %{state | queue: queue}

    task_fun = fn -> ingest_messages(messages, chunk_count, runs, owner) end

    case start_task(task_fun, state.task_supervisor) do
      {:ok, ref} ->
        %{state | inflight_ref: ref}

      {:error, reason} ->
        Logger.warning("Failed to start sync ingestion task: #{inspect(reason)}")
        queue = %{queue | inflight: false, ready: true}
        %{state | queue: queue}
    end
  end

  defp start_task(task_fun, nil), do: start_task_fallback(task_fun)

  defp start_task(task_fun, supervisor) do
    start_task_with_supervisor(task_fun, supervisor)
  catch
    :exit, {:noproc, _details} ->
      start_task_fallback(task_fun)

    :exit, {:normal, _details} ->
      start_task_fallback(task_fun)

    :exit, reason ->
      {:error, reason}
  end

  defp start_task_with_supervisor(task_fun, supervisor) do
    case Task.Supervisor.start_child(supervisor, task_fun) do
      {:ok, pid} ->
        {:ok, Process.monitor(pid)}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, other}
    end
  end

  defp start_task_fallback(task_fun) do
    case Task.start(task_fun) do
      {:ok, pid} -> {:ok, Process.monitor(pid)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref), do: Process.cancel_timer(ref)

  defp coalesce_window_ms do
    Application.get_env(:serviceradar_core, :sync_ingestor_coalesce_ms, 250)
  end

  defp queue_max_chunks do
    Application.get_env(:serviceradar_core, :sync_ingestor_queue_max_chunks, 10)
  end

  @doc false
  # Chunk capacity, for operator views of ingestion lanes.
  def max_pending_chunks do
    Application.get_env(
      :serviceradar_core,
      :sync_ingestor_queue_max_pending_chunks,
      @default_max_pending_chunks
    )
  end

  defp max_pending_bytes do
    Application.get_env(
      :serviceradar_core,
      :sync_ingestor_queue_max_pending_bytes,
      @default_max_pending_bytes
    )
  end

  defp admission_timeout_ms do
    Application.get_env(
      :serviceradar_core,
      :sync_ingestor_queue_admission_timeout_ms,
      @default_admission_timeout_ms
    )
  end

  defp queue_server do
    Application.get_env(:serviceradar_core, :sync_ingestor_queue_server, __MODULE__)
  end

  defp task_supervisor do
    Application.get_env(
      :serviceradar_core,
      :sync_ingestor_task_supervisor,
      ServiceRadar.SyncIngestor.TaskSupervisor
    )
  end

  # Runs in the ingestion task: decode, group by sync run, check each run that
  # ends here for missing chunks, ingest, and report the runs still open.
  defp ingest_messages(messages, chunk_count, runs, owner) do
    chunks = Enum.flat_map(messages, &decode_chunk/1)
    groups = Enum.chunk_by(chunks, &sync_batch_key/1)

    Logger.info(
      "Coalesced #{chunk_count} sync chunks into #{length(groups)} run groups and " <>
        "#{chunks |> Enum.map(&length/1) |> Enum.sum()} updates"
    )

    {seen, finished} =
      Enum.reduce(groups, {%{}, []}, fn group, {seen, finished} ->
        key = sync_batch_key(hd(group))
        {track, complete?} = track_run(key, group, Map.merge(runs, seen))
        _ = ingest_updates(List.flatten(group), complete?)

        case track do
          :finished -> {Map.delete(seen, key), [key | finished]}
          {:open, run} -> {Map.put(seen, key, run), finished}
          :untracked -> {seen, finished}
        end
      end)

    GenServer.cast(owner, {:sync_runs_seen, seen, finished})
  end

  defp decode_chunk(message) do
    case decode_results(message) do
      {:ok, []} ->
        []

      {:ok, updates} ->
        [updates]

      {:error, reason} ->
        Logger.warning("Sync results decode failed: #{inspect(reason)}")
        []
    end
  end

  # Returns how the run stands after this group, and whether the group may be
  # recorded as a complete run.
  defp track_run({:sync_run, _source_id, _run_id} = key, group, runs) do
    metas = Enum.map(group, &extract_sync_meta/1)
    previous = Map.get(runs, key, %{indices: MapSet.new(), total: nil})

    indices =
      metas
      |> Enum.map(& &1[:chunk_index])
      |> Enum.filter(&is_integer/1)
      |> MapSet.new()
      |> MapSet.union(previous.indices)

    total = Enum.find_value(metas, previous.total, & &1[:total_chunks])

    if Enum.any?(metas, &(&1[:is_final] == true)) do
      {:finished, run_complete?(key, indices, total)}
    else
      {{:open, %{indices: indices, total: total, seen_at: System.monotonic_time(:millisecond)}},
       true}
    end
  end

  defp track_run(_legacy_key, _group, _runs), do: {:untracked, true}

  defp run_complete?(_key, _indices, total) when not is_integer(total) or total <= 0, do: true

  defp run_complete?({:sync_run, source_id, run_id}, indices, total) do
    missing = total - MapSet.size(indices)

    if missing > 0 do
      :telemetry.execute(
        [:serviceradar, :sync_ingestion, :incomplete_run],
        %{count: 1, missing_chunks: missing, total_chunks: total},
        %{sync_service_id: source_id, sync_run_id: run_id}
      )

      Logger.warning(
        "Sync run #{run_id} for source #{source_id} is incomplete: #{missing} of #{total} chunks missing"
      )

      false
    else
      true
    end
  end

  @doc false
  def group_batches_for_ingestion(batches) when is_list(batches) do
    batches
    |> Enum.chunk_by(&sync_batch_key/1)
    |> Enum.map(&List.flatten/1)
  end

  defp sync_batch_key(updates) do
    case extract_sync_meta(updates) do
      %{sync_service_id: source_id, sync_run_id: run_id}
      when is_binary(source_id) and source_id != "" and is_binary(run_id) and run_id != "" ->
        {:sync_run, source_id, run_id}

      _ ->
        :legacy
    end
  end

  defp ingest_updates(updates, complete? \\ true) do
    Logger.info("Processing sync results")
    Logger.info("Decoded #{length(updates)} sync updates")

    # DB connection's search_path determines the schema
    actor = SystemActor.system(:sync_ingestor)
    sync_meta = extract_sync_meta(updates)
    device_updates = strip_sync_control_updates(updates)
    log_sync_progress("started", updates, sync_meta)
    record_sync_start(updates, actor, sync_meta)
    result = ingest_device_updates(device_updates, actor)
    # A run with missing chunks keeps the devices it did deliver but is recorded
    # as failed, and its snapshot is not activated from partial data.
    result = if complete? or result != :ok, do: result, else: {:error, :sync_run_incomplete}
    result = maybe_activate_source_snapshot(result, updates, sync_meta, actor)
    Logger.info("SyncIngestor result: #{inspect(result)}")

    record_sync_status(updates, actor, result, sync_meta)
    log_sync_progress("finished", updates, sync_meta, result)

    result
  rescue
    error ->
      Logger.warning("Sync results ingestion failed: #{inspect(error)}")
      {:error, error}
  end

  defp ingest_device_updates([], _actor), do: :ok

  defp ingest_device_updates(updates, actor),
    do: sync_ingestor().ingest_updates(updates, actor: actor)

  @doc false
  def strip_sync_control_updates(updates) when is_list(updates) do
    Enum.reject(updates, fn update ->
      is_map(update) and
        (Map.get(update, "_sync_control") || Map.get(update, :_sync_control)) ==
          "collection_final"
    end)
  end

  def strip_sync_control_updates(_updates), do: []

  defp do_ingest_results(message) do
    case decode_results(message) do
      {:ok, updates} ->
        ingest_updates(updates)

      {:error, reason} ->
        Logger.warning("Sync results decode failed: #{inspect(reason)}")
        {:error, {:invalid_sync_results, reason}}
    end
  end

  defp record_sync_status(updates, actor, ingest_result, sync_meta) do
    sync_service_id = extract_sync_service_id(updates, sync_meta)

    if should_record_sync_status?(sync_meta) do
      with_sync_service(sync_service_id, actor, fn source ->
        device_count = sync_source_device_count(sync_service_id, sync_meta, updates)

        {action, action_attrs} =
          build_sync_finish(ingest_result, device_count)

        update_sync_source(source, actor, action, action_attrs, sync_service_id, "status")
      end)
    else
      :ok
    end
  rescue
    error ->
      Logger.warning("Error recording sync status: #{inspect(error)}")
  end

  defp record_sync_start(updates, actor, sync_meta) do
    sync_service_id = extract_sync_service_id(updates, sync_meta)

    if should_record_sync_start?(sync_meta) do
      with_sync_service(sync_service_id, actor, fn source ->
        action_attrs = %{device_count: sync_device_count(updates, sync_meta)}
        update_sync_source(source, actor, :sync_start, action_attrs, sync_service_id, "start")
      end)
    else
      :ok
    end
  rescue
    error ->
      Logger.warning("Error recording sync start: #{inspect(error)}")
  end

  defp with_sync_service(nil, _actor, _fun), do: :ok

  defp with_sync_service(sync_service_id, actor, fun) do
    # DB connection's search_path determines the schema
    case IntegrationSource.get_by_id(sync_service_id, actor: actor) do
      {:ok, source} ->
        fun.(source)

      {:error, reason} ->
        Logger.debug(
          "Could not find IntegrationSource #{sync_service_id} to record sync: #{inspect(reason)}"
        )
    end
  end

  defp update_sync_source(source, actor, action, action_attrs, sync_service_id, label) do
    # DB connection's search_path determines the schema
    source
    |> Ash.Changeset.for_update(action, action_attrs)
    |> Ash.update(actor: actor)
    |> case do
      {:ok, _} ->
        Logger.debug("Recorded sync #{label} for IntegrationSource #{sync_service_id}")

      {:error, reason} ->
        Logger.warning(
          "Failed to record sync #{label} for #{sync_service_id}: #{inspect(reason)}"
        )
    end
  end

  defp build_sync_finish(ingest_result, device_count) do
    case ingest_result do
      :ok ->
        {:sync_success, %{result: :success, device_count: device_count}}

      {:error, reason} ->
        result = failure_result(reason)

        {:sync_failed,
         %{
           result: result,
           device_count: device_count,
           error_message: error_message(reason)
         }}
    end
  end

  defp failure_result(reason) do
    if reason in [:timeout, :timed_out] do
      :timeout
    else
      :failed
    end
  end

  defp error_message(reason) when is_binary(reason), do: reason
  defp error_message(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_message(reason), do: inspect(reason)

  defp extract_sync_service_id(updates, sync_meta) do
    meta_id =
      case sync_meta do
        %{sync_service_id: id} when is_binary(id) and id != "" -> id
        _ -> nil
      end

    meta_id || extract_sync_service_id_from_updates(updates)
  end

  defp extract_sync_service_id_from_updates([update | _]) when is_map(update) do
    metadata = update["metadata"] || update[:metadata] || %{}
    metadata["sync_service_id"] || metadata[:sync_service_id]
  end

  defp extract_sync_service_id_from_updates(_), do: nil

  defp extract_sync_meta(updates) when is_list(updates) do
    Enum.reduce(updates, %{}, fn update, acc ->
      meta = update["sync_meta"] || update[:sync_meta] || %{}

      sync_service_id =
        acc[:sync_service_id] || get_string(meta, ["sync_service_id", :sync_service_id])

      sync_run_id =
        acc[:sync_run_id] || get_string(meta, ["sync_run_id", :sync_run_id])

      total_devices =
        select_max(acc[:total_devices], get_integer(meta, ["total_devices", :total_devices]))

      chunk_index =
        select_min(acc[:chunk_index], get_integer(meta, ["chunk_index", :chunk_index]))

      total_chunks = acc[:total_chunks] || get_integer(meta, ["total_chunks", :total_chunks])

      is_final = acc[:is_final] || get_bool(meta, ["is_final", :is_final])

      population =
        case get_map(meta, ["population", :population]) do
          value when map_size(value) > 0 -> value
          _ -> acc[:population]
        end

      %{
        sync_service_id: sync_service_id,
        sync_run_id: sync_run_id,
        total_devices: total_devices,
        chunk_index: chunk_index,
        total_chunks: total_chunks,
        is_final: is_final,
        population: population
      }
    end)
  end

  defp extract_sync_meta(_), do: %{}

  defp sync_device_count(updates, sync_meta) do
    case sync_meta do
      %{total_devices: total} when is_integer(total) and total >= 0 -> total
      _ -> length(updates)
    end
  end

  defp sync_source_device_count(sync_service_id, sync_meta, updates)
       when is_binary(sync_service_id) and sync_service_id != "" do
    case exact_population_count(sync_meta) do
      count when is_integer(count) ->
        count

      nil ->
        case Repo.query(
               """
               SELECT COUNT(DISTINCT d.uid)
               FROM platform.ocsf_devices AS d
               LEFT JOIN platform.device_identifiers AS di
                 ON di.device_id = d.uid
                AND di.identifier_type = 'integration_id'
               WHERE d.deleted_at IS NULL
                 AND COALESCE(d.metadata->>'sync_service_id', di.metadata->>'sync_service_id') = $1
               """,
               [sync_service_id]
             ) do
          {:ok, %{rows: [[count]]}} when is_integer(count) ->
            count

          _ ->
            sync_device_count(updates, sync_meta)
        end
    end
  rescue
    error ->
      Logger.debug("Could not count synced devices for #{sync_service_id}: #{inspect(error)}")
      sync_device_count(updates, sync_meta)
  end

  defp sync_source_device_count(_sync_service_id, sync_meta, updates) do
    sync_device_count(updates, sync_meta)
  end

  defp exact_population_count(%{population: population}) when is_map(population) do
    get_integer(population, ["distinct_source_ids", :distinct_source_ids])
  end

  defp exact_population_count(_sync_meta), do: nil

  defp should_record_sync_start?(sync_meta) do
    cond do
      is_map(sync_meta) and map_size(sync_meta) == 0 ->
        true

      match?(%{chunk_index: 0}, sync_meta) ->
        true

      match?(%{chunk_index: nil}, sync_meta) ->
        true

      is_map(sync_meta) ->
        false

      true ->
        true
    end
  end

  defp should_record_sync_status?(sync_meta) do
    cond do
      is_map(sync_meta) and map_size(sync_meta) == 0 ->
        true

      match?(%{is_final: true}, sync_meta) ->
        true

      match?(%{total_chunks: 1}, sync_meta) ->
        true

      match?(%{chunk_index: nil}, sync_meta) ->
        true

      is_map(sync_meta) ->
        false

      true ->
        true
    end
  end

  defp get_string(map, keys) do
    Enum.find_value(keys, fn key ->
      case map do
        %{^key => value} when is_binary(value) -> value
        _ -> nil
      end
    end)
  end

  defp get_map(map, keys) do
    Enum.find_value(keys, %{}, fn key ->
      case map do
        %{^key => value} when is_map(value) -> value
        _ -> nil
      end
    end)
  end

  defp select_max(nil, value), do: value
  defp select_max(value, nil), do: value
  defp select_max(left, right), do: max(left, right)

  defp maybe_activate_source_snapshot(:ok, updates, %{is_final: true} = sync_meta, actor) do
    case ArmisSourceSnapshot.activate(updates, sync_meta, actor: actor) do
      :ok -> :ok
      {:error, :not_armis_source} -> :ok
      {:error, reason} -> {:error, {:source_snapshot_activation_failed, reason}}
    end
  end

  defp maybe_activate_source_snapshot(result, _updates, _sync_meta, _actor), do: result

  defp get_integer(map, keys) do
    Enum.find_value(keys, fn key ->
      case map do
        %{^key => value} -> normalize_integer(value)
        _ -> nil
      end
    end)
  end

  defp normalize_integer(value) when is_integer(value), do: value
  defp normalize_integer(value) when is_float(value), do: trunc(value)

  defp normalize_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      _ -> nil
    end
  end

  defp normalize_integer(_value), do: nil

  defp get_bool(map, keys) do
    Enum.find_value(keys, fn key ->
      case map do
        %{^key => value} when is_boolean(value) -> value
        %{^key => value} when is_binary(value) -> value == "true"
        _ -> nil
      end
    end) || false
  end

  defp select_min(nil, value), do: value
  defp select_min(value, nil), do: value

  defp select_min(value, other) when is_integer(value) and is_integer(other),
    do: min(value, other)

  defp decode_results(nil), do: {:ok, []}

  defp decode_results(message) when is_binary(message) do
    case Jason.decode(message) do
      {:ok, updates} when is_list(updates) -> {:ok, updates}
      {:ok, _other} -> {:error, :unexpected_payload}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_results(_message), do: {:error, :unsupported_payload}

  defp log_sync_progress(stage, updates, sync_meta, result \\ nil) do
    Logger.info(
      "Sync ingestion #{stage}: " <>
        "sync_service_id=#{inspect(sync_meta[:sync_service_id])} " <>
        "sync_run_id=#{inspect(sync_meta[:sync_run_id])} " <>
        "chunk_index=#{inspect(sync_meta[:chunk_index])} " <>
        "total_chunks=#{inspect(sync_meta[:total_chunks])} " <>
        "is_final=#{inspect(sync_meta[:is_final])} " <>
        "update_count=#{length(updates)} " <>
        "total_devices=#{inspect(sync_meta[:total_devices])} " <>
        "result=#{inspect(result)}"
    )
  end

  defp sync_ingestor do
    Application.get_env(:serviceradar_core, :sync_ingestor, SyncIngestor)
  end
end
