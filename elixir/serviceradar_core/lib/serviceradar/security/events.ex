defmodule ServiceRadar.Security.Events do
  @moduledoc """
  Non-blocking recorder for `ServiceRadar.Security.SecurityEvent`.

  Callers on the request hot path invoke `record/1` (and friends),
  which casts to a per-node GenServer. The GenServer batches inserts
  and persists them via Ash in one supervised task at a time, so the
  request path is never blocked on Postgres latency. Queued and in-flight
  events both count against the bounded capacity. Under sustained overflow
  events are dropped and the
  `[:serviceradar, :security, :events, :dropped]` telemetry counter is
  incremented rather than blocking the caller.

  The recorder broadcasts inserted events on
  `Phoenix.PubSub.broadcast(ServiceRadar.PubSub, "security_events", event)`
  so the Settings → Audit → Events LiveView can live-tail without an
  extra DB poll.
  """

  use GenServer

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Security.SecurityEvent

  require Logger

  @default_max_queue 1_000
  @flush_interval to_timeout(second: 1)
  @flush_batch_size 50
  @task_supervisor ServiceRadar.Security.Events.TaskSupervisor

  ## Client API

  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc """
  Records an event asynchronously. Returns `:ok` immediately even on
  overflow — on overflow the event is dropped and a telemetry counter
  is incremented.

  Required fields: `:kind` (atom in `SecurityEvent.kinds/0`).
  Optional fields: `:severity` (default `:info`), `:actor_id`, `:ip`,
  `:route`, `:details`, `:correlation_id`. `:occurred_at` defaults to
  `DateTime.utc_now/0` if omitted.
  """
  @spec record(map()) :: :ok
  @spec record(map(), GenServer.server()) :: :ok
  def record(attrs, server \\ __MODULE__) when is_map(attrs) do
    payload = normalize(attrs)
    GenServer.cast(server, {:record, payload})
  end

  @doc """
  Waits until every event accepted before this call has finished its
  persistence attempt.

  Events accepted concurrently after the call are not part of its barrier.
  """
  @spec flush() :: :ok
  @spec flush(GenServer.server()) :: :ok
  def flush(server \\ __MODULE__), do: GenServer.call(server, :flush, :infinity)

  @doc false
  def __default_max_queue__, do: @default_max_queue

  ## Server callbacks

  @impl true
  def init(opts) do
    max_queue =
      Keyword.get(opts, :max_queue) ||
        :serviceradar_core
        |> Application.get_env(__MODULE__, [])
        |> Keyword.get(:max_queue, @default_max_queue)

    flush_interval = Keyword.get(opts, :flush_interval, @flush_interval)
    schedule_flush(flush_interval)

    {:ok,
     %{
       queue: :queue.new(),
       queue_size: 0,
       max_queue: max_queue,
       dropped: 0,
       accepted_count: 0,
       completed_count: 0,
       in_flight: nil,
       flush_waiters: [],
       flush_interval: flush_interval,
       persist_fun: Keyword.get(opts, :persist_fun, &persist/1),
       task_supervisor: Keyword.get(opts, :task_supervisor, @task_supervisor)
     }}
  end

  @impl true
  def handle_cast({:record, payload}, state) do
    if outstanding_count(state) >= state.max_queue do
      :telemetry.execute([:serviceradar, :security, :events, :dropped], %{count: 1}, %{})
      {:noreply, %{state | dropped: state.dropped + 1}}
    else
      {:noreply,
       %{
         state
         | queue: :queue.in(payload, state.queue),
           queue_size: state.queue_size + 1,
           accepted_count: state.accepted_count + 1
       }}
    end
  end

  @impl true
  def handle_call(:flush, from, state) do
    state = %{
      state
      | flush_waiters: [{from, state.accepted_count} | state.flush_waiters]
    }

    state =
      state
      |> reply_ready_flushes()
      |> maybe_start_persistence()

    {:noreply, state}
  end

  @impl true
  def handle_info(:flush, state) do
    schedule_flush(state.flush_interval)
    {:noreply, maybe_start_persistence(state)}
  end

  def handle_info({task_ref, _result}, %{in_flight: %{task_ref: task_ref}} = state)
      when is_reference(task_ref) do
    Process.demonitor(task_ref, [:flush])
    {:noreply, complete_persistence(state)}
  end

  def handle_info(
        {:DOWN, task_ref, :process, _pid, reason},
        %{in_flight: %{task_ref: task_ref} = in_flight} = state
      ) do
    Logger.warning("SecurityEvents: persistence task exited; dropping in-flight batch",
      reason: inspect(reason),
      batch_size: in_flight.count
    )

    state = record_persistence_drop(state, in_flight.count, reason)
    {:noreply, complete_persistence(state)}
  end

  def handle_info(_, state), do: {:noreply, state}

  ## Internals

  defp outstanding_count(state) do
    state.queue_size + if(state.in_flight, do: state.in_flight.count, else: 0)
  end

  defp maybe_start_persistence(%{in_flight: in_flight} = state) when not is_nil(in_flight),
    do: state

  defp maybe_start_persistence(%{queue_size: 0} = state), do: state

  defp maybe_start_persistence(state) do
    limit = next_batch_limit(state)
    {batch, remaining_queue, remaining_size} = take(state.queue, state.queue_size, limit)
    persist_fun = state.persist_fun

    task_fun = fn -> persist_fun.(batch) end

    case start_persistence_task(state.task_supervisor, task_fun) do
      {:ok, task} ->
        %{
          state
          | queue: remaining_queue,
            queue_size: remaining_size,
            in_flight: %{
              count: length(batch),
              task_ref: task.ref,
              pid: task.pid
            }
        }

      {:error, reason} ->
        Logger.warning("SecurityEvents: failed to start persistence task",
          reason: inspect(reason)
        )

        state
    end
  end

  defp start_persistence_task(task_supervisor, task_fun) do
    {:ok, Task.Supervisor.async_nolink(task_supervisor, task_fun)}
  catch
    :exit, reason -> {:error, reason}
  end

  defp complete_persistence(%{in_flight: in_flight} = state) do
    state
    |> Map.put(:in_flight, nil)
    |> Map.update!(:completed_count, &(&1 + in_flight.count))
    |> reply_ready_flushes()
    |> maybe_start_persistence()
  end

  defp record_persistence_drop(state, count, reason) do
    :telemetry.execute(
      [:serviceradar, :security, :events, :dropped],
      %{count: count},
      %{reason: reason, source: :persistence_task}
    )

    %{state | dropped: state.dropped + count}
  end

  defp reply_ready_flushes(state) do
    {ready, waiting} =
      Enum.split_with(state.flush_waiters, fn {_from, target} ->
        target <= state.completed_count
      end)

    Enum.each(ready, fn {from, _target} -> GenServer.reply(from, :ok) end)
    %{state | flush_waiters: waiting}
  end

  defp next_batch_limit(%{flush_waiters: []}), do: @flush_batch_size

  defp next_batch_limit(state) do
    next_target =
      state.flush_waiters
      |> Enum.map(fn {_from, target} -> target end)
      |> Enum.min()

    min(@flush_batch_size, next_target - state.completed_count)
  end

  defp take(queue, size, limit) do
    n = min(size, limit)

    queue
    |> do_take(n, [])
    |> case do
      {items, q_rest} -> {Enum.reverse(items), q_rest, size - n}
    end
  end

  defp do_take(queue, 0, acc), do: {acc, queue}

  defp do_take(queue, n, acc) do
    case :queue.out(queue) do
      {{:value, item}, rest} -> do_take(rest, n - 1, [item | acc])
      {:empty, rest} -> {acc, rest}
    end
  end

  defp persist([]), do: :ok

  defp persist(batch) do
    actor = SystemActor.system(:security_events)

    Enum.each(batch, fn payload ->
      try do
        case SecurityEvent
             |> Ash.Changeset.for_create(:create, payload)
             |> Ash.create(actor: actor) do
          {:ok, event} ->
            broadcast(event)

          {:error, error} ->
            Logger.warning(
              "SecurityEvents: persist failed: #{inspect(error)}; payload=#{inspect(payload)}"
            )
        end
      rescue
        e ->
          # DB unreachable or other infra failure — never let event
          # persistence crash the recorder.
          Logger.warning(
            "SecurityEvents: persist crashed: #{Exception.message(e)}; dropping event"
          )
      end
    end)
  end

  defp broadcast(event) do
    Phoenix.PubSub.broadcast(ServiceRadar.PubSub, "security_events", {:security_event, event})
  rescue
    _ -> :ok
  end

  defp schedule_flush(:infinity), do: :ok
  defp schedule_flush(interval), do: Process.send_after(self(), :flush, interval)

  defp normalize(attrs) do
    attrs
    |> Map.put_new(:occurred_at, DateTime.utc_now())
    |> Map.put_new(:severity, :info)
    |> Map.put_new(:details, %{})
  end
end
