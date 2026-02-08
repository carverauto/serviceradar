defmodule ServiceRadar.Inventory.SyncIngestorQueue do
  @moduledoc """
  Buffers sync result chunks and coalesces bursts before ingestion.

  In schema-agnostic mode, operates as a single queue since the DB schema
  is set by CNPG search_path credentials.
  """

  use GenServer

  require Logger

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Integrations.IntegrationSource
  alias ServiceRadar.Inventory.SyncIngestor

  defmodule Queue do
    @moduledoc false
    defstruct batches: [], chunk_count: 0, timer_ref: nil, inflight: false, ready: false
  end

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def enqueue(message) do
    GenServer.cast(__MODULE__, {:enqueue, message})
  end

  def ingest_sync_results(message) do
    do_ingest_results(message)
  end

  @impl true
  def init(_opts) do
    {:ok, %{queue: %Queue{}, inflight_ref: nil}}
  end

  @impl true
  def handle_cast({:enqueue, message}, state) do
    case decode_results(message) do
      {:ok, updates} ->
        {:noreply, enqueue_updates(state, updates)}

      {:error, reason} ->
        Logger.warning("Sync results decode failed: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:flush, state) do
    queue = state.queue

    if queue.chunk_count == 0 do
      {:noreply, state}
    else
      queue = %{queue | timer_ref: nil, ready: true}
      state = %{state | queue: queue}
      {:noreply, maybe_start_ingestion(state)}
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

      {:noreply, maybe_start_ingestion(state)}
    else
      {:noreply, state}
    end
  end

  defp enqueue_updates(state, updates) do
    queue = state.queue

    queue = %{
      queue
      | batches: [updates | queue.batches],
        chunk_count: queue.chunk_count + 1
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
    updates = queue.batches |> Enum.reverse() |> List.flatten()

    Logger.info("Coalesced #{queue.chunk_count} sync chunks into #{length(updates)} updates")

    queue = %{queue | batches: [], chunk_count: 0, inflight: true, ready: false, timer_ref: nil}
    state = %{state | queue: queue}

    task_fun = fn ->
      ingest_updates(updates)
    end

    case start_task(task_fun) do
      {:ok, ref} ->
        %{state | inflight_ref: ref}

      {:error, reason} ->
        Logger.warning("Failed to start sync ingestion task: #{inspect(reason)}")
        queue = %{queue | inflight: false, ready: true}
        %{state | queue: queue}
    end
  end

  defp start_task(task_fun) do
    case Task.Supervisor.start_child(ServiceRadar.SyncIngestor.TaskSupervisor, task_fun) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        {:ok, ref}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, other}
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

  defp ingest_updates(updates) do
    Logger.info("Processing sync results")
    Logger.info("Decoded #{length(updates)} sync updates")

    # DB connection's search_path determines the schema
    actor = SystemActor.system(:sync_ingestor)
    sync_meta = extract_sync_meta(updates)
    record_sync_start(updates, actor, sync_meta)
    result = sync_ingestor().ingest_updates(updates, actor: actor)
    Logger.info("SyncIngestor result: #{inspect(result)}")

    record_sync_status(updates, actor, result, sync_meta)

    result
  rescue
    error ->
      Logger.warning("Sync results ingestion failed: #{inspect(error)}")
      {:error, error}
  end

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
        {action, action_attrs} =
          build_sync_finish(ingest_result, sync_device_count(updates, sync_meta))

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

      total_devices =
        acc[:total_devices] || get_integer(meta, ["total_devices", :total_devices])

      chunk_index =
        select_min(acc[:chunk_index], get_integer(meta, ["chunk_index", :chunk_index]))

      total_chunks = acc[:total_chunks] || get_integer(meta, ["total_chunks", :total_chunks])

      is_final = acc[:is_final] || get_bool(meta, ["is_final", :is_final])

      %{
        sync_service_id: sync_service_id,
        total_devices: total_devices,
        chunk_index: chunk_index,
        total_chunks: total_chunks,
        is_final: is_final
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

  defp sync_ingestor do
    Application.get_env(:serviceradar_core, :sync_ingestor, SyncIngestor)
  end
end
