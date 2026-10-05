defmodule ServiceRadar.Inventory.SyncIngestorQueue do
  @moduledoc """
  Buffers sync result chunks and coalesces bursts before ingestion.

  In schema-agnostic mode, operates as a single queue since the DB schema
  is set by CNPG search_path credentials.
  """

  use GenServer

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Ingestion.RuntimeMetrics
  alias ServiceRadar.Ingestion.WorkerBudget
  alias ServiceRadar.Integrations.IntegrationSource
  alias ServiceRadar.Inventory.ArmisSourceSnapshot
  alias ServiceRadar.Inventory.SyncIngestor
  alias ServiceRadar.Inventory.SyncRunLedger
  alias ServiceRadar.Repo

  require Logger

  @max_items 32
  @max_bytes 64 * 1_024 * 1_024
  @max_per_run 16
  @worker_timeout_ms 10_000

  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  def child_spec(opts),
    do: %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}

  # The producer extracts the small ordering identity. It is already a bounded
  # ingestion worker; no JSON decode or database call occurs in queue callbacks.
  def enqueue(message) do
    bytes = if is_binary(message), do: byte_size(message), else: 0

    if bytes > @max_bytes do
      RuntimeMetrics.record(:sync, :rejected, %{reason: :wire_payload_too_large})
      {:error, :sync_ingest_queue_full}
    else
      headers =
        case decode_results(message) do
          {:ok, updates} -> extract_sync_meta(updates)
          _ -> %{}
        end

      descriptor = %{bytes: bytes, key: run_key(headers)}
      result = reserve_and_submit(queue_server(), descriptor, message)

      if match?({:error, _}, result) do
        SyncRunLedger.reject(headers)
      end

      result
    end
  end

  defp reserve_and_submit(server, descriptor, message) do
    with {:ok, id} <- GenServer.call(server, {:reserve, descriptor}, 1_000) do
      GenServer.call(server, {:submit, id, message}, 1_000)
    end
  catch
    :exit, _ -> {:error, :sync_ingest_queue_unavailable}
  end

  def ingest_sync_results(message), do: do_ingest_results(message)

  @impl true
  def init(opts) do
    opts = Keyword.merge(Application.get_env(:serviceradar_core, __MODULE__, []), opts)
    max_items = Keyword.get(opts, :max_items, @max_items)
    max_bytes = Keyword.get(opts, :max_bytes, @max_bytes)

    if !(is_integer(max_items) and max_items > 0 and is_integer(max_bytes) and
           max_bytes > 0 and max_bytes <= @max_bytes and
           is_integer(coalesce_window_ms()) and coalesce_window_ms() >= 0 and
           is_integer(queue_max_chunks()) and queue_max_chunks() > 0) do
      raise ArgumentError, "invalid sync ingestion queue limits"
    end

    {:ok,
     %{
       jobs: %{},
       pending: :queue.new(),
       bytes: 0,
       timer: nil,
       active: nil,
       task_supervisor: Keyword.get(opts, :task_supervisor, task_supervisor()),
       max_items: max_items,
       max_bytes: max_bytes
     }}
  end

  @impl true
  def handle_call({:reserve, %{bytes: bytes, key: key}}, {owner, _}, state)
      when is_integer(bytes) and bytes > 0 and bytes <= @max_bytes do
    per_run = Enum.count(state.jobs, fn {_id, job} -> job.key == key end)

    if :erlang.external_size(key) > 4_096 or map_size(state.jobs) >= state.max_items or
         state.bytes + bytes > state.max_bytes or
         per_run >= @max_per_run do
      RuntimeMetrics.record(:sync, :rejected, %{reason: :sync_ingest_queue_full})
      {:reply, {:error, :sync_ingest_queue_full}, state}
    else
      id = make_ref()
      timer = Process.send_after(self(), {:reservation_expired, id}, 2_000)

      job = %{
        bytes: bytes,
        key: key,
        phase: :reserved,
        message: nil,
        monitor: Process.monitor(owner),
        timer: timer
      }

      RuntimeMetrics.record(:sync, :admitted, %{})

      {:reply, {:ok, id},
       record_state(%{state | jobs: Map.put(state.jobs, id, job), bytes: state.bytes + bytes})}
    end
  end

  def handle_call({:reserve, _descriptor}, _from, state) do
    {:reply, {:error, :invalid_admission_descriptor}, state}
  end

  def handle_call({:submit, id, message}, _from, state) do
    bytes = if is_binary(message), do: byte_size(message), else: 0

    case state.jobs[id] do
      %{phase: :reserved, bytes: ^bytes} = job ->
        Process.cancel_timer(job.timer)
        Process.demonitor(job.monitor, [:flush])
        job = %{job | phase: :pending, message: message, timer: nil, monitor: nil}

        state = %{
          state
          | jobs: Map.put(state.jobs, id, job),
            pending: :queue.in(id, state.pending)
        }

        {:reply, :ok, maybe_flush(state)}

      _ ->
        {:reply, {:error, :sync_ingest_queue_full}, state}
    end
  end

  @impl true
  def handle_info({:flush, token}, %{timer: {_ref, token}} = state),
    do: {:noreply, start_ingestion(%{state | timer: nil})}

  def handle_info({:flush, _stale}, state), do: {:noreply, state}

  def handle_info({:reservation_expired, id}, state) do
    case state.jobs[id] do
      %{phase: :reserved} -> {:noreply, release(state, [id])}
      _ -> {:noreply, state}
    end
  end

  def handle_info({:worker_result, pid, result}, %{active: %{pid: pid} = active} = state),
    do: {:noreply, %{state | active: Map.put(active, :result, result)}}

  def handle_info({:worker_timeout, pid}, %{active: %{pid: pid}} = state) do
    RuntimeMetrics.record(:sync, :worker_timeout, %{count: 1})
    Process.exit(pid, :kill)
    {:noreply, state}
  end

  def handle_info({:worker_timeout, _}, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{active: %{ref: ref} = active} = state) do
    Process.cancel_timer(active.timer)
    state = %{state | active: nil}

    if reason == :normal and active.result != nil do
      accepted = Enum.all?(active.result, &(&1 == :ok or match?({:ok, _}, &1)))

      RuntimeMetrics.record(:sync, :completion, %{
        count: length(active.ids),
        outcome: if(accepted, do: :accepted, else: :not_accepted),
        execution_ms: System.monotonic_time(:millisecond) - active.started_at
      })

      {:noreply, state |> release(active.ids) |> maybe_flush()}
    else
      RuntimeMetrics.record(:sync, :worker_crash, %{count: 1})

      Logger.warning("Sync ingestion worker exited; retrying retained bounded batch",
        reason: inspect(reason)
      )

      pending = :queue.join(:queue.from_list(active.ids), state.pending)
      {:noreply, arm(%{state | pending: pending})}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    ids = for {id, %{monitor: monitor}} <- state.jobs, monitor == ref, do: id
    {:noreply, release(state, ids)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp maybe_flush(state) do
    if :queue.len(state.pending) >= queue_max_chunks(),
      do: start_ingestion(invalidate_timer(state)),
      else: arm(state)
  end

  defp start_ingestion(%{active: active} = state) when not is_nil(active), do: arm(state)

  defp start_ingestion(state) do
    if :queue.is_empty(state.pending) do
      state
    else
      ids = :queue.to_list(state.pending)
      messages = Enum.map(ids, &state.jobs[&1].message)
      owner = self()

      fun = fn ->
        decoded = Enum.map(messages, &decode_results/1)

        batches =
          Enum.flat_map(decoded, fn decoded ->
            case decoded do
              {:ok, updates} ->
                [updates]

              {:error, reason} ->
                Logger.warning("Sync result decode rejected: #{inspect(reason)}")
                RuntimeMetrics.record(:sync, :rejected, %{reason: :malformed_payload})
                []
            end
          end)

        result =
          WorkerBudget.run(
            WorkerBudget,
            :sync,
            fn ->
              results = batches |> group_batches_for_ingestion() |> Enum.map(&ingest_updates/1)
              results ++ for {:error, reason} <- decoded, do: {:error, {:sync_decode, reason}}
            end
          )

        send(owner, {:worker_result, self(), result})
      end

      case Task.Supervisor.start_child(state.task_supervisor, fun) do
        {:ok, pid} ->
          timer = Process.send_after(self(), {:worker_timeout, pid}, @worker_timeout_ms)

          record_state(%{
            state
            | pending: :queue.new(),
              active: %{
                ids: ids,
                pid: pid,
                ref: Process.monitor(pid),
                timer: timer,
                result: nil,
                started_at: System.monotonic_time(:millisecond)
              }
          })

        {:error, _} ->
          arm(state)
      end
    end
  catch
    :exit, _ -> arm(state)
  end

  defp arm(%{timer: timer} = state) when not is_nil(timer), do: state

  defp arm(state) do
    if :queue.is_empty(state.pending) do
      state
    else
      token = make_ref()
      ms = max(coalesce_window_ms(), 0)
      %{state | timer: {Process.send_after(self(), {:flush, token}, ms), token}}
    end
  end

  defp invalidate_timer(%{timer: {ref, _}} = state) do
    Process.cancel_timer(ref)
    %{state | timer: nil}
  end

  defp invalidate_timer(state), do: state

  defp release(state, ids) do
    ids
    |> Enum.reduce(state, fn id, acc ->
      case Map.pop(acc.jobs, id) do
        {nil, _} ->
          acc

        {job, jobs} ->
          if is_reference(job.monitor), do: Process.demonitor(job.monitor, [:flush])
          if is_reference(job.timer), do: Process.cancel_timer(job.timer)
          %{acc | jobs: jobs, bytes: acc.bytes - job.bytes}
      end
    end)
    |> record_state()
  end

  defp record_state(state) do
    active_ids = if state.active, do: state.active.ids, else: []

    active_bytes =
      Enum.reduce(active_ids, 0, fn id, acc -> acc + (state.jobs[id] || %{bytes: 0}).bytes end)

    RuntimeMetrics.record(:sync, :state, %{
      pending_count: map_size(state.jobs) - length(active_ids),
      pending_bytes: state.bytes - active_bytes,
      in_flight_count: length(active_ids),
      in_flight_bytes: active_bytes
    })

    state
  end

  defp run_key(meta), do: {meta[:sync_service_id], meta[:sync_run_id]}

  defp coalesce_window_ms do
    Application.get_env(:serviceradar_core, :sync_ingestor_coalesce_ms, 250)
  end

  defp queue_max_chunks do
    Application.get_env(:serviceradar_core, :sync_ingestor_queue_max_chunks, 10)
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

  defp ingest_updates(updates) do
    Logger.info("Processing sync results")
    Logger.info("Decoded #{length(updates)} sync updates")

    # DB connection's search_path determines the schema
    actor = SystemActor.system(:sync_ingestor)
    sync_meta = extract_sync_meta(updates)
    device_updates = strip_sync_control_updates(updates)
    log_sync_progress("started", updates, sync_meta)
    record_sync_start(updates, actor, sync_meta)
    result = ingest_device_updates(device_updates, actor)
    metas = updates |> Enum.map(fn update -> extract_sync_meta([update]) end) |> Enum.uniq()

    result =
      if result == :ok do
        SyncRunLedger.committed(metas)
      else
        Enum.each(metas, &SyncRunLedger.reject/1)
        result
      end

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
    do: sync_ingestor().ingest_updates(updates, actor: actor, batch_concurrency: 1)

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

      total_chunks =
        select_max(acc[:total_chunks], get_integer(meta, ["total_chunks", :total_chunks]))

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
