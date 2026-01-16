defmodule ServiceRadar.Inventory.SyncIngestorQueue do
  @moduledoc """
  Buffers sync result chunks and coalesces bursts before ingestion.

  In tenant-unaware mode, operates as a single queue since the DB schema
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

    cond do
      queue.chunk_count == 0 ->
        {:noreply, state}

      true ->
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
    record_sync_start(updates, actor)
    result = sync_ingestor().ingest_updates(updates, actor: actor)
    Logger.info("SyncIngestor result: #{inspect(result)}")

    record_sync_status(updates, actor, result)

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

  defp record_sync_status(updates, actor, ingest_result) do
    sync_service_id = extract_sync_service_id(updates)

    with_sync_service(sync_service_id, actor, fn source ->
      {action, action_attrs} = build_sync_finish(ingest_result, length(updates))
      update_sync_source(source, actor, action, action_attrs, sync_service_id, "status")
    end)
  rescue
    error ->
      Logger.warning("Error recording sync status: #{inspect(error)}")
  end

  defp record_sync_start(updates, actor) do
    sync_service_id = extract_sync_service_id(updates)

    with_sync_service(sync_service_id, actor, fn source ->
      action_attrs = %{device_count: length(updates)}
      update_sync_source(source, actor, :sync_start, action_attrs, sync_service_id, "start")
    end)
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

  defp extract_sync_service_id([update | _]) when is_map(update) do
    metadata = update["metadata"] || update[:metadata] || %{}
    metadata["sync_service_id"] || metadata[:sync_service_id]
  end

  defp extract_sync_service_id(_), do: nil

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
