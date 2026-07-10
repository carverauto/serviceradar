defmodule ServiceRadar.Observability.StatefulAlertEvaluationQueue do
  @moduledoc """
  Bounded async admission queue for stateful alert event evaluation.

  `StatefulAlertEngine.evaluate_events/1` is a synchronous GenServer call with a
  long timeout. This queue keeps bursty event sources, such as endpoint
  inventory findings, from blocking their ingest processors while preserving a
  clear concurrency and backlog limit.
  """

  use GenServer

  alias ServiceRadar.Observability.StatefulAlertEngine

  require Logger

  defmodule Job do
    @moduledoc false
    defstruct [:id, :events, :enqueued_at]
  end

  defmodule State do
    @moduledoc false
    defstruct pending: :queue.new(),
              pending_count: 0,
              inflight: %{},
              max_concurrency: 2,
              max_pending: 512
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec enqueue_events([map()], GenServer.server()) :: :ok | {:error, term()}
  def enqueue_events(events, server \\ __MODULE__)
  def enqueue_events([], _server), do: :ok

  def enqueue_events(events, server) when is_list(events) do
    call_queue(server, {:enqueue_events, events}, admission_timeout_ms())
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
  def handle_call({:enqueue_events, events}, _from, state) do
    if at_capacity?(state) do
      {:reply, {:error, :stateful_alert_evaluation_queue_full}, state}
    else
      job = %Job{
        id: System.unique_integer([:positive, :monotonic]),
        events: events,
        enqueued_at: System.monotonic_time(:millisecond)
      }

      state =
        state
        |> enqueue_job(job)
        |> maybe_start_jobs()

      {:reply, :ok, state}
    end
  end

  @impl true
  def handle_info({:stateful_alert_evaluation_finished, job_id}, state) do
    case Map.pop(state.inflight, job_id) do
      {nil, _inflight} ->
        {:noreply, state}

      {inflight_job, inflight} ->
        Process.demonitor(inflight_job.monitor_ref, [:flush])

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

      {_inflight_job, inflight} ->
        Logger.warning("Stateful alert evaluation task exited", reason: inspect(reason))

        state
        |> Map.put(:inflight, inflight)
        |> maybe_start_jobs()
        |> then(&{:noreply, &1})
    end
  end

  defp call_queue(server, message, timeout) do
    GenServer.call(server, message, timeout)
  catch
    :exit, {:timeout, _call} -> {:error, :stateful_alert_evaluation_queue_timeout}
    :exit, {:noproc, _call} -> {:error, :stateful_alert_evaluation_queue_unavailable}
    :exit, reason -> {:error, {:stateful_alert_evaluation_queue_unavailable, reason}}
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
      evaluate_events(job.events)
      send(parent, {:stateful_alert_evaluation_finished, job.id})
    end

    case start_task(task_fun) do
      {:ok, pid, monitor_ref} ->
        put_in(state.inflight[job.id], %{
          job: job,
          pid: pid,
          monitor_ref: monitor_ref
        })

      {:error, reason} ->
        Logger.warning("Failed to start stateful alert evaluation task",
          reason: inspect(reason)
        )

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
           ServiceRadar.StatefulAlertEvaluation.TaskSupervisor,
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

  defp evaluate_events(events) do
    result =
      case evaluator() do
        callback when is_function(callback, 1) ->
          callback.(events)

        {module, function} when is_atom(module) and is_atom(function) ->
          apply(module, function, [events])

        module when is_atom(module) ->
          module.evaluate_events(events)
      end

    case result do
      :ok ->
        :ok

      {:error, reason} = error ->
        Logger.warning("Stateful alert event evaluation failed: #{inspect(reason)}")
        error
    end
  rescue
    error ->
      Logger.warning("Stateful alert event evaluation failed", error: inspect(error))
      {:error, error}
  end

  defp at_capacity?(%State{} = state) do
    state.pending_count + map_size(state.inflight) >= state.max_pending
  end

  defp pop_inflight_by_monitor_ref(inflight, monitor_ref) do
    case Enum.find(inflight, fn {_job_id, job} -> job.monitor_ref == monitor_ref end) do
      nil -> {nil, inflight}
      {job_id, job} -> {job, Map.delete(inflight, job_id)}
    end
  end

  defp evaluator do
    Application.get_env(
      :serviceradar_core,
      :stateful_alert_event_evaluator,
      StatefulAlertEngine
    )
  end

  defp max_concurrency do
    Application.get_env(:serviceradar_core, :stateful_alert_evaluation_max_concurrency, 2)
  end

  defp max_pending do
    Application.get_env(:serviceradar_core, :stateful_alert_evaluation_queue_max_pending, 512)
  end

  defp admission_timeout_ms do
    Application.get_env(
      :serviceradar_core,
      :stateful_alert_evaluation_admission_timeout_ms,
      1_000
    )
  end
end
