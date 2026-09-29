defmodule ServiceRadar.SweepJobs.Ingestion.Dispatcher do
  @moduledoc """
  Spreads sweep result chunks across the sweep ingestion workers of every core
  node while keeping each partition's chunks in order.

  Runs on the coordinator next to `ServiceRadar.StatusHandler`, which casts
  asynchronous sweep results here instead of into the singleton
  `ServiceRadar.ResultsRouter` mailbox. The dispatcher never touches the
  database: it derives a partition key, picks a worker and forwards the chunk.

  ## Ordering

  The partition key is `{agent_id, sweep_group_id}`: execution bookkeeping,
  superseding and per-agent availability are all scoped to one group on one
  agent. A partition with chunks in flight is always sent to the worker that
  holds them, so a later chunk can never overtake an earlier one. A partition
  with nothing in flight goes to the worker with the fewest chunks in flight,
  so load follows work across nodes.

  Workers acknowledge every chunk with `{:sweep_ingested, key, worker}`.

  ## Membership

  Workers join a `:pg` group; the dispatcher follows it with `:pg.monitor/2`.
  The dispatcher also monitors the local `:pg` scope process and each worker
  pid directly. When a worker leaves or its process monitor fires, its
  partitions are released and the chunks it still held are reported as lost.
  When the scope process itself crashes, all workers are released and the
  dispatcher re-subscribes once the scope is restarted. With no workers at
  all, chunks fall back to the `ResultsRouter`, which ingests them inline as
  it always has.
  """

  use GenServer

  alias ServiceRadar.SweepJobs.Ingestion.Supervisor, as: IngestionSupervisor

  require Logger

  @dispatch_event [:serviceradar, :sweep_ingestion, :dispatch]
  @fallback_event [:serviceradar, :sweep_ingestion, :fallback]
  @lost_event [:serviceradar, :sweep_ingestion, :lost]
  @dropped_event [:serviceradar, :sweep_ingestion, :dropped]
  @monitor_retry_ms 1_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Hands one asynchronous sweep results status to the dispatcher."
  @spec dispatch(GenServer.server(), map()) :: :ok
  def dispatch(server \\ __MODULE__, status) when is_map(status) do
    GenServer.cast(server, {:dispatch, status})
  end

  @doc "Whether the dispatcher is running on this node."
  @spec running?(atom()) :: boolean()
  def running?(name \\ __MODULE__), do: is_pid(Process.whereis(name))

  @doc false
  @spec state(GenServer.server()) :: map()
  def state(server \\ __MODULE__), do: GenServer.call(server, :state)

  @doc """
  Partition key for a sweep results status: the gateway-authenticated agent and
  the sweep group named in the payload. A payload that cannot be decoded keys
  on the agent alone; the worker then reports the decode error.
  """
  @spec partition_key(map()) :: {term(), String.t() | nil}
  def partition_key(status) do
    {status[:agent_id], payload_sweep_group_id(status[:message])}
  end

  defp payload_sweep_group_id(message) when is_binary(message) and byte_size(message) > 0 do
    case Jason.decode(message) do
      {:ok, %{"sweep_group_id" => group_id}} when is_binary(group_id) and group_id != "" ->
        group_id

      _ ->
        nil
    end
  end

  defp payload_sweep_group_id(_message), do: nil

  @impl true
  def init(opts) do
    state = %{
      scope: Keyword.get(opts, :scope, IngestionSupervisor.scope()),
      group: Keyword.get(opts, :group, IngestionSupervisor.group()),
      fallback: Keyword.get(opts, :fallback, {__MODULE__, :fallback_to_router, []}),
      monitor_ref: nil,
      scope_monitor_ref: nil,
      # worker pid => chunks in flight
      workers: %{},
      # partition key => %{worker: pid, in_flight: pos_integer()}
      partitions: %{},
      # monitor ref => worker pid
      worker_refs: %{}
    }

    {:ok, monitor_members(state)}
  end

  @impl true
  def handle_cast({:dispatch, status}, state) do
    key = partition_key(status)

    case choose_worker(state, key) do
      nil ->
        run_fallback(state.fallback, status)
        :telemetry.execute(@fallback_event, %{count: 1}, %{})
        {:noreply, state}

      worker ->
        send(worker, {:sweep_ingest, self(), key, status})
        state = track_dispatch(state, key, worker)

        :telemetry.execute(
          @dispatch_event,
          %{
            partition_in_flight: state.partitions[key].in_flight,
            worker_in_flight: state.workers[worker]
          },
          %{node: node(worker)}
        )

        {:noreply, state}
    end
  end

  @impl true
  def handle_call(:state, _from, state) do
    {:reply, Map.take(state, [:workers, :partitions]), state}
  end

  @impl true
  def handle_info({:sweep_ingested, key, worker}, state) do
    {:noreply, track_done(state, key, worker)}
  end

  def handle_info({ref, :join, _group, pids}, %{monitor_ref: ref} = state) do
    {workers, worker_refs} =
      Enum.reduce(pids, {state.workers, state.worker_refs}, fn pid, {workers, refs} ->
        if Map.has_key?(workers, pid) do
          {workers, refs}
        else
          mref = Process.monitor(pid)
          {Map.put(workers, pid, 0), Map.put(refs, mref, pid)}
        end
      end)

    {:noreply, %{state | workers: workers, worker_refs: worker_refs}}
  end

  def handle_info({ref, :leave, _group, pids}, %{monitor_ref: ref} = state) do
    state =
      Enum.reduce(pids, state, fn pid, acc ->
        acc |> demonitor_worker(pid) |> release_worker(pid)
      end)

    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{scope_monitor_ref: ref} = state) do
    Enum.each(state.worker_refs, fn {mref, _} -> Process.demonitor(mref, [:flush]) end)

    state =
      state.workers
      |> Map.keys()
      |> Enum.reduce(state, &release_worker(&2, &1))

    Process.send_after(self(), :monitor_members, @monitor_retry_ms)
    {:noreply, %{state | scope_monitor_ref: nil, monitor_ref: nil, worker_refs: %{}}}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    case Map.pop(state.worker_refs, ref) do
      {nil, _} ->
        {:noreply, state}

      {_pid, worker_refs} ->
        {:noreply, release_worker(%{state | worker_refs: worker_refs}, pid)}
    end
  end

  def handle_info(:monitor_members, state), do: {:noreply, monitor_members(state)}

  def handle_info(_message, state), do: {:noreply, state}

  @doc false
  def fallback_to_router(status) do
    case Process.whereis(ServiceRadar.ResultsRouter) do
      pid when is_pid(pid) ->
        GenServer.cast(pid, {:results_update, status})

      nil ->
        Logger.warning(
          "No sweep ingestion worker or ResultsRouter available; dropping sweep results"
        )

        :telemetry.execute(@dropped_event, %{count: 1}, %{})
    end

    :ok
  end

  # -- membership -------------------------------------------------------------

  defp monitor_members(state) do
    if state.scope_monitor_ref, do: Process.demonitor(state.scope_monitor_ref, [:flush])
    Enum.each(state.worker_refs, fn {mref, _} -> Process.demonitor(mref, [:flush]) end)
    state = %{state | scope_monitor_ref: nil, worker_refs: %{}}

    case Process.whereis(state.scope) do
      nil ->
        Logger.debug("Sweep ingestion scope not registered; retrying")
        Process.send_after(self(), :monitor_members, @monitor_retry_ms)
        state

      scope_pid ->
        scope_monitor_ref = Process.monitor(scope_pid)
        {ref, pids} = :pg.monitor(state.scope, state.group)
        worker_refs = Map.new(pids, fn pid -> {Process.monitor(pid), pid} end)

        %{
          state
          | monitor_ref: ref,
            scope_monitor_ref: scope_monitor_ref,
            workers: Map.new(pids, &{&1, 0}),
            worker_refs: worker_refs
        }
    end
  catch
    :exit, reason ->
      Logger.debug("Sweep ingestion scope unavailable; retrying: #{inspect(reason)}")
      Process.send_after(self(), :monitor_members, @monitor_retry_ms)
      state
  end

  defp demonitor_worker(state, pid) do
    case Enum.find(state.worker_refs, fn {_mref, p} -> p == pid end) do
      {mref, _} ->
        Process.demonitor(mref, [:flush])
        %{state | worker_refs: Map.delete(state.worker_refs, mref)}

      nil ->
        state
    end
  end

  defp release_worker(state, worker) do
    {held, partitions} =
      Enum.split_with(state.partitions, fn {_key, partition} -> partition.worker == worker end)

    lost = Enum.reduce(held, 0, fn {_key, partition}, acc -> acc + partition.in_flight end)

    if lost > 0 do
      Logger.warning(
        "Sweep ingestion worker on #{node(worker)} left with #{lost} chunk(s) in flight"
      )

      :telemetry.execute(@lost_event, %{count: lost}, %{node: node(worker)})
    end

    %{state | workers: Map.delete(state.workers, worker), partitions: Map.new(partitions)}
  end

  # -- assignment -------------------------------------------------------------

  defp choose_worker(state, key) do
    case state.partitions do
      %{^key => %{worker: worker}} -> worker
      _ -> least_loaded(state.workers, key)
    end
  end

  defp least_loaded(workers, _key) when map_size(workers) == 0, do: nil

  defp least_loaded(workers, key) do
    workers
    |> Enum.min_by(fn {worker, in_flight} ->
      {in_flight, if(node(worker) == node(), do: 1, else: 0), :erlang.phash2({key, worker})}
    end)
    |> elem(0)
  end

  defp track_dispatch(state, key, worker) do
    partitions =
      Map.update(state.partitions, key, %{worker: worker, in_flight: 1}, fn partition ->
        %{partition | in_flight: partition.in_flight + 1}
      end)

    %{state | partitions: partitions, workers: Map.update(state.workers, worker, 1, &(&1 + 1))}
  end

  defp track_done(state, key, worker) do
    workers =
      case state.workers do
        %{^worker => in_flight} -> Map.put(state.workers, worker, max(in_flight - 1, 0))
        _ -> state.workers
      end

    partitions =
      case state.partitions do
        %{^key => %{worker: ^worker, in_flight: in_flight}} when in_flight > 1 ->
          Map.put(state.partitions, key, %{worker: worker, in_flight: in_flight - 1})

        %{^key => %{worker: ^worker}} ->
          Map.delete(state.partitions, key)

        _ ->
          state.partitions
      end

    %{state | workers: workers, partitions: partitions}
  end

  defp run_fallback({module, function, args}, status),
    do: apply(module, function, [status | args])
end
