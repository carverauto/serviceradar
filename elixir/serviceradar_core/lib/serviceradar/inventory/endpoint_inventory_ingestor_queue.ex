defmodule ServiceRadar.Inventory.EndpointInventoryIngestorQueue do
  @moduledoc """
  Bounded admission queue for endpoint inventory ingestion.

  The queue keeps expensive package/SBOM ingestion out of the ResultsRouter
  process and gives correlated fleet changes a clear backpressure boundary.
  Callers may either enqueue and return immediately, or wait for the queued job
  result when an agent needs the scan acknowledgement directives.
  """

  use GenServer

  alias ServiceRadar.EndpointInventoryIngestor.TaskSupervisor
  alias ServiceRadar.Inventory.EndpointInventoryIngestor

  require Logger

  @default_ingest_timeout_ms 20_000
  @timeout_reply_grace_ms 1_000

  defmodule Job do
    @moduledoc false
    defstruct [:id, :agent_id, :payload, :opts, :reply_to, :timeout_ms, :enqueued_at]
  end

  defmodule State do
    @moduledoc false
    defstruct pending: :queue.new(),
              pending_count: 0,
              inflight: %{},
              max_concurrency: 4,
              max_pending: 256,
              max_pending_per_agent: 32,
              task_supervisor: TaskSupervisor
  end

  @type enqueue_result :: :ok | {:error, term()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @spec enqueue(map(), keyword()) :: enqueue_result()
  def enqueue(payload, opts \\ []) when is_map(payload) do
    call_queue({:enqueue, payload, opts, :async, ingest_timeout_ms()}, admission_timeout_ms())
  end

  @spec enqueue_and_reply(map(), GenServer.from(), keyword()) :: enqueue_result()
  def enqueue_and_reply(payload, reply_to, opts \\ []) when is_map(payload) do
    call_queue(
      {:enqueue, payload, opts, {:reply_to, reply_to}, ingest_timeout_ms()},
      admission_timeout_ms()
    )
  end

  @spec enqueue_and_wait(map(), keyword(), timeout()) :: {:ok, map()} | {:error, term()}
  def enqueue_and_wait(payload, opts \\ [], timeout \\ ingest_timeout_ms())
      when is_map(payload) do
    call_queue({:enqueue, payload, opts, :sync, timeout}, queue_call_timeout(timeout))
  end

  @spec ingest_now(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def ingest_now(payload, opts \\ []) when is_map(payload) do
    ingest_report(payload, opts)
  end

  @impl true
  def init(opts) do
    state = %State{
      max_concurrency: Keyword.get(opts, :max_concurrency, max_concurrency()),
      max_pending: Keyword.get(opts, :max_pending, max_pending()),
      max_pending_per_agent: Keyword.get(opts, :max_pending_per_agent, max_pending_per_agent()),
      task_supervisor: Keyword.get(opts, :task_supervisor, task_supervisor())
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:enqueue, payload, opts, mode, timeout_ms}, from, state) do
    agent_id = agent_id(payload)

    cond do
      at_capacity?(state) ->
        {:reply, {:error, :endpoint_inventory_ingest_queue_full}, state}

      agent_at_capacity?(state, agent_id) ->
        {:reply, {:error, :endpoint_inventory_ingest_queue_full}, state}

      true ->
        job = %Job{
          id: System.unique_integer([:positive, :monotonic]),
          agent_id: agent_id,
          payload: payload,
          opts: opts,
          reply_to: reply_to(mode, from),
          timeout_ms: timeout_ms,
          enqueued_at: System.monotonic_time(:millisecond)
        }

        state =
          state
          |> enqueue_job(job)
          |> maybe_start_jobs()

        if admission_reply?(mode) do
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
        cancel_timeout_timer(inflight_job.timeout_ref)
        reply(inflight_job.job, result)

        state
        |> Map.put(:inflight, inflight)
        |> maybe_start_jobs()
        |> then(&{:noreply, &1})
    end
  end

  @impl true
  def handle_info({:endpoint_inventory_ingest_timeout, job_id}, state) do
    case Map.pop(state.inflight, job_id) do
      {nil, _inflight} ->
        {:noreply, state}

      {inflight_job, inflight} ->
        Process.demonitor(inflight_job.monitor_ref, [:flush])
        Process.exit(inflight_job.pid, :kill)

        Logger.warning("Endpoint inventory ingestion task timed out",
          job_id: job_id,
          timeout_ms: inspect(inflight_job.job.timeout_ms)
        )

        reply(inflight_job.job, {:error, :endpoint_inventory_ingest_queue_timeout})

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
        cancel_timeout_timer(inflight_job.timeout_ref)

        Logger.warning("Endpoint inventory ingestion task exited", reason: inspect(reason))

        reply(inflight_job.job, {:error, {:endpoint_inventory_ingest_task_exit, reason}})

        state
        |> Map.put(:inflight, inflight)
        |> maybe_start_jobs()
        |> then(&{:noreply, &1})
    end
  end

  defp call_queue(message, timeout) do
    GenServer.call(queue_server(), message, timeout)
  catch
    :exit, {:timeout, _call} -> {:error, :endpoint_inventory_ingest_queue_timeout}
    :exit, {:noproc, _call} -> {:error, :endpoint_inventory_ingest_queue_unavailable}
    :exit, reason -> {:error, {:endpoint_inventory_ingest_queue_unavailable, reason}}
  end

  defp queue_call_timeout(:infinity), do: :infinity
  defp queue_call_timeout(timeout) when is_integer(timeout), do: timeout + @timeout_reply_grace_ms

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
    state.pending_count > 0 and map_size(state.inflight) < state.max_concurrency and
      runnable_job_pending?(state)
  end

  defp runnable_job_pending?(%State{} = state) do
    busy_agents = state.inflight |> Map.values() |> MapSet.new(& &1.job.agent_id)

    state.pending
    |> :queue.to_list()
    |> Enum.any?(&(not MapSet.member?(busy_agents, &1.agent_id)))
  end

  defp start_next_job(%State{} = state) do
    {job, state} = dequeue_next_job(state)
    parent = self()

    task_fun = fn ->
      result =
        job.payload
        |> ingest_report(job.opts)
        |> after_ingest(job.payload, job.opts)

      send(parent, {:endpoint_inventory_ingest_finished, job.id, result})
    end

    case start_task(task_fun, state.task_supervisor) do
      {:ok, pid, monitor_ref} ->
        timeout_ref = start_timeout_timer(job)

        put_in(state.inflight[job.id], %{
          job: job,
          pid: pid,
          monitor_ref: monitor_ref,
          timeout_ref: timeout_ref
        })

      {:error, reason} ->
        Logger.warning("Failed to start endpoint inventory ingestion task",
          reason: inspect(reason)
        )

        reply(job, {:error, {:endpoint_inventory_ingest_task_start_failed, reason}})
        state
    end
  end

  defp start_timeout_timer(%Job{timeout_ms: :infinity}), do: nil

  defp start_timeout_timer(%Job{id: job_id, timeout_ms: timeout_ms})
       when is_integer(timeout_ms) and timeout_ms >= 0 do
    Process.send_after(self(), {:endpoint_inventory_ingest_timeout, job_id}, timeout_ms)
  end

  defp cancel_timeout_timer(nil), do: :ok
  defp cancel_timeout_timer(timer_ref), do: Process.cancel_timer(timer_ref)

  defp dequeue_next_job(%State{} = state) do
    busy_agents =
      state.inflight
      |> Map.values()
      |> MapSet.new(& &1.job.agent_id)

    jobs = :queue.to_list(state.pending)

    {:ok, job, remaining} = split_next_fair_job(jobs, busy_agents, [])

    {job, %{state | pending: :queue.from_list(remaining), pending_count: state.pending_count - 1}}
  end

  defp split_next_fair_job([], _busy_agents, _seen), do: :none

  defp split_next_fair_job([job | rest], busy_agents, seen) do
    if MapSet.member?(busy_agents, job.agent_id) do
      split_next_fair_job(rest, busy_agents, [job | seen])
    else
      {:ok, job, Enum.reverse(seen, rest)}
    end
  end

  defp start_task(task_fun, nil), do: start_task_fallback(task_fun)

  defp start_task(task_fun, supervisor) do
    start_task_with_supervisor(task_fun, supervisor)
  catch
    :exit, {:noproc, _details} -> start_task_fallback(task_fun)
    :exit, {:normal, _details} -> start_task_fallback(task_fun)
    :exit, reason -> {:error, reason}
  end

  defp start_task_with_supervisor(task_fun, supervisor) do
    case Task.Supervisor.start_child(
           supervisor,
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
  defp reply_to({:reply_to, from}, _from), do: from

  defp admission_reply?(:async), do: true
  defp admission_reply?({:reply_to, _from}), do: true
  defp admission_reply?(:sync), do: false

  defp at_capacity?(%State{} = state) do
    state.pending_count + map_size(state.inflight) >= state.max_pending
  end

  defp agent_at_capacity?(%State{} = state, agent_id) do
    max_per_agent = state.max_pending_per_agent

    is_integer(max_per_agent) and max_per_agent > 0 and
      agent_load(state, agent_id) >= max_per_agent
  end

  defp agent_load(%State{} = state, agent_id) do
    pending_count =
      state.pending
      |> :queue.to_list()
      |> Enum.count(&(&1.agent_id == agent_id))

    inflight_count =
      state.inflight
      |> Map.values()
      |> Enum.count(&(&1.job.agent_id == agent_id))

    pending_count + inflight_count
  end

  defp agent_id(payload) do
    (Map.get(payload, "agent_id") || Map.get(payload, :agent_id) || "__unknown__")
    |> to_string()
    |> String.trim()
    |> case do
      "" -> "__unknown__"
      value -> value
    end
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

  defp queue_server do
    Application.get_env(:serviceradar_core, :endpoint_inventory_ingestor_queue_server, __MODULE__)
  end

  defp task_supervisor do
    Application.get_env(
      :serviceradar_core,
      :endpoint_inventory_ingestor_task_supervisor,
      TaskSupervisor
    )
  end

  defp max_concurrency do
    Application.get_env(:serviceradar_core, :endpoint_inventory_ingestor_max_concurrency, 4)
  end

  defp max_pending do
    Application.get_env(:serviceradar_core, :endpoint_inventory_ingestor_queue_max_pending, 256)
  end

  defp max_pending_per_agent do
    Application.get_env(
      :serviceradar_core,
      :endpoint_inventory_ingestor_queue_max_pending_per_agent,
      32
    )
  end

  defp admission_timeout_ms do
    Application.get_env(
      :serviceradar_core,
      :endpoint_inventory_ingestor_admission_timeout_ms,
      5_000
    )
  end

  defp ingest_timeout_ms do
    Application.get_env(
      :serviceradar_core,
      :endpoint_inventory_ingestor_timeout_ms,
      @default_ingest_timeout_ms
    )
  end
end
