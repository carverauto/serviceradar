defmodule ServiceRadar.Inventory.EndpointInventoryIngestorQueue do
  @moduledoc """
  Bounded admission queue for endpoint inventory ingestion.

  The queue keeps expensive package/SBOM ingestion out of the ResultsRouter
  process and gives correlated fleet changes a clear backpressure boundary.
  Callers may either enqueue and return immediately, or wait for the queued job
  result when an agent needs the scan acknowledgement directives.
  """

  use GenServer

  alias ServiceRadar.Inventory.EndpointInventoryIngestor

  require Logger

  defmodule Job do
    @moduledoc false
    defstruct [:id, :payload, :opts, :reply_to, :enqueued_at]
  end

  defmodule State do
    @moduledoc false
    defstruct pending: :queue.new(),
              pending_count: 0,
              inflight: %{},
              max_concurrency: 4,
              max_pending: 256
  end

  @type enqueue_result :: :ok | {:error, term()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec enqueue(map(), keyword()) :: enqueue_result()
  def enqueue(payload, opts \\ []) when is_map(payload) do
    call_queue({:enqueue, payload, opts, :async}, admission_timeout_ms())
  end

  @spec enqueue_and_wait(map(), keyword(), timeout()) :: {:ok, map()} | {:error, term()}
  def enqueue_and_wait(payload, opts \\ [], timeout \\ ingest_timeout_ms())
      when is_map(payload) do
    call_queue({:enqueue, payload, opts, :sync}, timeout)
  end

  @spec ingest_now(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def ingest_now(payload, opts \\ []) when is_map(payload) do
    ingest_report(payload, opts)
  end

  @impl true
  def init(opts) do
    state = %State{
      max_concurrency: Keyword.get(opts, :max_concurrency, max_concurrency()),
      max_pending: Keyword.get(opts, :max_pending, max_pending())
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:enqueue, payload, opts, mode}, from, state) do
    if at_capacity?(state) do
      {:reply, {:error, :endpoint_inventory_ingest_queue_full}, state}
    else
      job = %Job{
        id: System.unique_integer([:positive, :monotonic]),
        payload: payload,
        opts: opts,
        reply_to: reply_to(mode, from),
        enqueued_at: System.monotonic_time(:millisecond)
      }

      state =
        state
        |> enqueue_job(job)
        |> maybe_start_jobs()

      if mode == :async do
        {:reply, :ok, state}
      else
        {:noreply, state}
      end
    end
  end

  @impl true
  def handle_info({:endpoint_inventory_ingest_finished, job_id, result}, state) do
    case Map.pop(state.inflight, job_id) do
      {nil, _inflight} ->
        {:noreply, state}

      {inflight_job, inflight} ->
        Process.demonitor(inflight_job.monitor_ref, [:flush])
        reply(inflight_job.job, result)

        state
        |> Map.put(:inflight, inflight)
        |> maybe_start_jobs()
        |> then(&{:noreply, &1})
    end
  end

  @impl true
  def handle_info({:DOWN, monitor_ref, :process, _pid, reason}, state) do
    case pop_inflight_by_monitor_ref(state.inflight, monitor_ref) do
      {nil, _inflight} ->
        {:noreply, state}

      {_inflight_job, _inflight} when reason == :normal ->
        {:noreply, state}

      {inflight_job, inflight} ->
        Logger.warning("Endpoint inventory ingestion task exited", reason: inspect(reason))

        reply(inflight_job.job, {:error, {:endpoint_inventory_ingest_task_exit, reason}})

        state
        |> Map.put(:inflight, inflight)
        |> maybe_start_jobs()
        |> then(&{:noreply, &1})
    end
  end

  defp call_queue(message, timeout) do
    GenServer.call(__MODULE__, message, timeout)
  catch
    :exit, {:timeout, _call} -> {:error, :endpoint_inventory_ingest_queue_timeout}
    :exit, {:noproc, _call} -> {:error, :endpoint_inventory_ingest_queue_unavailable}
    :exit, reason -> {:error, {:endpoint_inventory_ingest_queue_unavailable, reason}}
  end

  defp enqueue_job(%State{} = state, %Job{} = job) do
    %{
      state
      | pending: :queue.in(job, state.pending),
        pending_count: state.pending_count + 1
    }
  end

  defp maybe_start_jobs(%State{} = state) do
    if can_start_job?(state) do
      state
      |> start_next_job()
      |> maybe_start_jobs()
    else
      state
    end
  end

  defp can_start_job?(%State{} = state) do
    state.pending_count > 0 and map_size(state.inflight) < state.max_concurrency
  end

  defp start_next_job(%State{} = state) do
    {{:value, job}, pending} = :queue.out(state.pending)
    state = %{state | pending: pending, pending_count: state.pending_count - 1}
    parent = self()

    task_fun = fn ->
      result =
        job.payload
        |> ingest_report(job.opts)
        |> after_ingest(job.payload, job.opts)

      send(parent, {:endpoint_inventory_ingest_finished, job.id, result})
    end

    case start_task(task_fun) do
      {:ok, pid, monitor_ref} ->
        put_in(state.inflight[job.id], %{
          job: job,
          pid: pid,
          monitor_ref: monitor_ref
        })

      {:error, reason} ->
        Logger.warning("Failed to start endpoint inventory ingestion task",
          reason: inspect(reason)
        )

        reply(job, {:error, {:endpoint_inventory_ingest_task_start_failed, reason}})
        state
    end
  end

  defp start_task(task_fun) do
    start_task_with_supervisor(task_fun)
  catch
    :exit, {:noproc, _details} -> start_task_fallback(task_fun)
    :exit, {:normal, _details} -> start_task_fallback(task_fun)
    :exit, reason -> {:error, reason}
  end

  defp start_task_with_supervisor(task_fun) do
    case Task.Supervisor.start_child(
           ServiceRadar.EndpointInventoryIngestor.TaskSupervisor,
           task_fun
         ) do
      {:ok, pid} -> {:ok, pid, Process.monitor(pid)}
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  defp start_task_fallback(task_fun) do
    case Task.start(task_fun) do
      {:ok, pid} -> {:ok, pid, Process.monitor(pid)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ingest_report(payload, opts) do
    ingestor().ingest_report(payload, opts)
  rescue
    error ->
      Logger.warning("Endpoint inventory ingestion failed", error: inspect(error))
      {:error, error}
  end

  defp after_ingest(result, payload, opts) do
    run_after_ingest_callback(payload, result, opts)
    result
  end

  defp run_after_ingest_callback(payload, result, opts) do
    case Application.get_env(:serviceradar_core, :endpoint_inventory_after_ingest_callback) do
      callback when is_function(callback, 3) ->
        callback.(payload, result, opts)

      {module, function} when is_atom(module) and is_atom(function) ->
        apply(module, function, [payload, result, opts])

      nil ->
        :ok
    end
  rescue
    error ->
      Logger.warning("Endpoint inventory after-ingest callback failed", error: inspect(error))
      :ok
  end

  defp reply(%Job{reply_to: nil}, _result), do: :ok
  defp reply(%Job{reply_to: from}, result), do: GenServer.reply(from, result)

  defp reply_to(:async, _from), do: nil
  defp reply_to(:sync, from), do: from

  defp at_capacity?(%State{} = state) do
    state.pending_count + map_size(state.inflight) >= state.max_pending
  end

  defp pop_inflight_by_monitor_ref(inflight, monitor_ref) do
    case Enum.find(inflight, fn {_job_id, job} -> job.monitor_ref == monitor_ref end) do
      nil -> {nil, inflight}
      {job_id, job} -> {job, Map.delete(inflight, job_id)}
    end
  end

  defp ingestor do
    Application.get_env(
      :serviceradar_core,
      :endpoint_inventory_ingestor,
      EndpointInventoryIngestor
    )
  end

  defp max_concurrency do
    Application.get_env(:serviceradar_core, :endpoint_inventory_ingestor_max_concurrency, 4)
  end

  defp max_pending do
    Application.get_env(:serviceradar_core, :endpoint_inventory_ingestor_queue_max_pending, 256)
  end

  defp admission_timeout_ms do
    Application.get_env(
      :serviceradar_core,
      :endpoint_inventory_ingestor_admission_timeout_ms,
      5_000
    )
  end

  defp ingest_timeout_ms do
    Application.get_env(:serviceradar_core, :endpoint_inventory_ingestor_timeout_ms, 30_000)
  end
end
