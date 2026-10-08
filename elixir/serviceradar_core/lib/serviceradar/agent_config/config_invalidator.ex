defmodule ServiceRadar.AgentConfig.ConfigInvalidator do
  @moduledoc """
  Coalesces config invalidation into one rebuild and push per config type.

  Callers cast. Invalidations that arrive inside the debounce window share one
  rebuild. An invalidation that arrives while that rebuild is running marks the
  type dirty, and exactly one follow-up rebuild runs after it. At most one
  rebuild is in flight and one is pending for each type, so a burst of UI
  saves cannot stack fleet compiles in a LiveView process.

  The rebuild runs under `#{__MODULE__}.TaskSupervisor`. The worker caps its
  heap with `Process.flag(:max_heap_size, ...)`, so a runaway compile kills
  that worker. This process logs the kill, emits telemetry, and retries once.
  A second kill waits for a later invalidation instead of looping. A kill while
  a follow-up is pending still schedules that follow-up, so the last
  invalidation is not dropped.
  """

  use GenServer

  require Logger

  @telemetry_event [:serviceradar, :agent_config, :config_invalidation, :stop]
  @default_debounce_ms 1_000
  # 2^27 words is 1 GiB on a 64-bit VM, under the web-ng pod limit.
  @default_max_heap_words 134_217_728
  @max_attempts 2

  def telemetry_event, do: @telemetry_event

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Ask for a rebuild and push of `config_type`.

  Returns `:ok` when the request is accepted. The push finishes later.
  """
  @spec request(GenServer.server(), atom(), keyword()) :: :ok
  def request(server \\ __MODULE__, config_type, opts \\ [])

  def request(server, config_type, opts) when is_atom(config_type) and is_list(opts) do
    callers =
      Keyword.get_lazy(opts, :callers, fn ->
        [self() | Process.get(:"$callers", [])]
      end)

    scope = normalize_scope(Keyword.get(opts, :scope, :all_online))
    GenServer.cast(server, {:invalidate, config_type, callers, scope})
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       slots: %{},
       debounce_ms:
         Keyword.get(
           opts,
           :debounce_ms,
           Application.get_env(
             :serviceradar_core,
             :config_invalidation_debounce_ms,
             @default_debounce_ms
           )
         ),
       max_heap_words:
         Keyword.get(
           opts,
           :max_heap_words,
           Application.get_env(
             :serviceradar_core,
             :config_invalidation_max_heap_words,
             @default_max_heap_words
           )
         ),
       push: Keyword.get(opts, :push, &ServiceRadar.Edge.AgentCommandBus.push_config_for_type/2),
       cache: Keyword.get(opts, :cache, &ServiceRadar.AgentConfig.ConfigCache.invalidate/1),
       schedule: Keyword.get(opts, :schedule, &default_schedule/2),
       task_supervisor:
         Keyword.get(
           opts,
           :task_supervisor,
           ServiceRadar.AgentConfig.ConfigInvalidator.TaskSupervisor
         )
     }}
  end

  @impl true
  def handle_cast({:invalidate, config_type, callers, scope}, state) do
    {:noreply, note_invalidate(state, config_type, callers, scope)}
  end

  @impl true
  def handle_info({:fire, config_type, ref}, state) do
    {:noreply, fire(state, config_type, ref)}
  end

  def handle_info({:invalidation_done, config_type, memory}, state) do
    {:noreply, finish_running(state, config_type, :ok, memory)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case slot_by_monitor(state, ref) do
      {config_type, _slot} ->
        {:noreply, finish_running(state, config_type, down_status(reason), 0)}

      nil ->
        {:noreply, state}
    end
  end

  defp note_invalidate(state, config_type, callers, scope) do
    case Map.get(state.slots, config_type) do
      nil ->
        schedule(state, config_type, callers, 1, 0, scope)

      %{phase: :scheduled} = slot ->
        put_slot(state, config_type, %{
          slot
          | coalesced: slot.coalesced + 1,
            callers: callers,
            scope: merge_scope(slot.scope, scope)
        })

      %{phase: :running} = slot ->
        put_slot(state, config_type, %{
          slot
          | dirty: true,
            follow_coalesced: slot.follow_coalesced + 1,
            callers: callers,
            follow_scope: merge_scope(slot.follow_scope, scope)
        })
    end
  end

  defp fire(state, config_type, ref) do
    case Map.get(state.slots, config_type) do
      %{phase: :scheduled, timer: ^ref} = slot ->
        start_worker(state, config_type, slot)

      _ ->
        state
    end
  end

  defp start_worker(state, config_type, slot) do
    parent = self()
    heap_words = state.max_heap_words
    push = state.push
    cache = state.cache
    callers = slot.callers || []

    work = fn ->
      Process.flag(:max_heap_size, %{size: heap_words, kill: true, error_logger: true})

      if callers != [] do
        Process.put(:"$callers", callers)
      end

      cache.(config_type)
      push.(config_type, slot.scope)

      memory =
        case Process.info(self(), :memory) do
          {:memory, bytes} when is_integer(bytes) -> bytes
          _ -> 0
        end

      send(parent, {:invalidation_done, config_type, memory})
    end

    case Task.Supervisor.start_child(state.task_supervisor, work) do
      {:ok, pid} ->
        mon = Process.monitor(pid)

        put_slot(state, config_type, %{
          slot
          | phase: :running,
            task: pid,
            mon: mon,
            started_at: System.monotonic_time(),
            dirty: false,
            follow_coalesced: 0,
            follow_scope: MapSet.new()
        })

      {:error, reason} ->
        Logger.warning(
          "Config invalidation worker failed to start for #{config_type}: #{inspect(reason)}"
        )

        schedule(state, config_type, slot.callers, slot.coalesced, slot.attempts, slot.scope)
    end
  end

  defp finish_running(state, config_type, status, memory) do
    case Map.get(state.slots, config_type) do
      %{phase: :running} = slot ->
        if is_reference(slot.mon) do
          Process.demonitor(slot.mon, [:flush])
        end

        log_failure(config_type, status)
        emit(config_type, status, slot, memory)
        continue_after(state, config_type, slot, status)

      _ ->
        state
    end
  end

  defp continue_after(state, config_type, slot, :ok) do
    if slot.dirty do
      schedule(
        state,
        config_type,
        slot.callers,
        max(slot.follow_coalesced, 1),
        0,
        slot.follow_scope
      )
    else
      drop_slot(state, config_type)
    end
  end

  defp continue_after(state, config_type, slot, _status) do
    attempts = slot.attempts + 1
    coalesced = slot.coalesced + slot.follow_coalesced

    cond do
      attempts < @max_attempts ->
        scope = merge_scope(slot.scope, slot.follow_scope)
        schedule(state, config_type, slot.callers, max(coalesced, 1), attempts, scope)

      slot.dirty ->
        schedule(
          state,
          config_type,
          slot.callers,
          max(slot.follow_coalesced, 1),
          0,
          merge_scope(slot.scope, slot.follow_scope)
        )

      true ->
        drop_slot(state, config_type)
    end
  end

  defp schedule(state, config_type, callers, coalesced, attempts, scope) do
    ref = make_ref()
    state.schedule.({:fire, config_type, ref}, state.debounce_ms)

    put_slot(state, config_type, %{
      phase: :scheduled,
      timer: ref,
      dirty: false,
      coalesced: coalesced,
      follow_coalesced: 0,
      callers: callers,
      scope: scope,
      follow_scope: MapSet.new(),
      task: nil,
      mon: nil,
      started_at: nil,
      attempts: attempts
    })
  end

  defp normalize_scope({:device, uid}) when is_binary(uid) and uid != "",
    do: MapSet.new([{:device, uid}])

  defp normalize_scope(agent_ids) when is_list(agent_ids),
    do: MapSet.new(agent_ids, &{:agent, &1})

  defp normalize_scope(%MapSet{} = scope), do: scope
  defp normalize_scope(_scope), do: :all_online

  defp merge_scope(:all_online, _scope), do: :all_online
  defp merge_scope(_scope, :all_online), do: :all_online
  defp merge_scope(left, right), do: MapSet.union(left, right)

  defp emit(config_type, status, slot, memory) do
    duration =
      case slot.started_at do
        started when is_integer(started) ->
          System.convert_time_unit(System.monotonic_time() - started, :native, :millisecond)

        _ ->
          0
      end

    :telemetry.execute(
      @telemetry_event,
      %{duration: duration, worker_memory_bytes: memory, coalesced: slot.coalesced},
      %{config_type: config_type, status: status}
    )
  end

  defp log_failure(_config_type, :ok), do: :ok

  defp log_failure(config_type, status) do
    Logger.error(
      "Config invalidation worker stopped for type=#{config_type} status=#{status}. " <>
        "The invalidator is still up and will retry a bounded follow-up."
    )
  end

  defp down_status(:kill), do: :killed
  defp down_status(:killed), do: :killed
  defp down_status(:normal), do: :error
  defp down_status(_reason), do: :error

  defp slot_by_monitor(state, ref) do
    Enum.find(state.slots, fn {_config_type, slot} -> slot.mon == ref end)
  end

  defp put_slot(state, config_type, slot) do
    %{state | slots: Map.put(state.slots, config_type, slot)}
  end

  defp drop_slot(state, config_type) do
    %{state | slots: Map.delete(state.slots, config_type)}
  end

  defp default_schedule(message, delay_ms) do
    Process.send_after(self(), message, delay_ms)
  end
end
