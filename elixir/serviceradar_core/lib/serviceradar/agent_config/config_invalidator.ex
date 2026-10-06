defmodule ServiceRadar.AgentConfig.ConfigInvalidator do
  @moduledoc """
  Coalescing owner for fleet-wide config pushes.

  `ConfigServer.invalidate/1` used to run `AgentCommandBus.push_config_for_type/1`
  synchronously in the caller: a LiveView toggle of one interface's SNMP
  collection rebuilt and pushed agent config for every online session, in the
  web-ng request process. Rapid toggles stacked those rebuilds concurrently
  until the pod was OOMKilled by its cgroup (#5341) -- a kill no supervisor
  can react to, because the kernel takes the whole OS process.

  This GenServer owns the push side of invalidation instead:

    * callers `cast`; repeated invalidates for a config type inside a
      debounce window collapse into ONE rebuild+push;
    * the rebuild runs in a supervised `Task` (never in the LiveView or
      request process) with `max_heap_size` + `kill: true`, so a runaway
      build kills only that worker while the pod stays up;
    * at most one rebuild runs and one is pending per type, so a click storm
      cannot queue unbounded work;
    * every completed rebuild emits telemetry with its duration, the worker's
      final heap size, and how many invalidates it coalesced.

  Cache invalidation itself (`ConfigCache.invalidate/2`) stays synchronous in
  the caller, so any compile after a change still sees fresh source; only the
  advisory push to agents is coalesced. A push is an optimization over the
  agent's own config poll, so delaying or collapsing pushes cannot lose a
  change.
  """

  use GenServer

  alias ServiceRadar.Edge.AgentCommandBus

  require Logger

  # Read at use time, not compile time: tests shrink the window.
  defp debounce_ms,
    do: Application.get_env(:serviceradar_core, :config_invalidator_debounce_ms, 500)

  # A runaway rebuild must die long before the pod's cgroup limit: 512 MiB of
  # heap words on a 64-bit BEAM. Configurable for tests.
  @default_max_heap_bytes 512 * 1024 * 1024

  defp default_max_heap_words, do: div(@default_max_heap_bytes, :erlang.system_info(:wordsize))

  defmodule TypeState do
    @moduledoc false
    defstruct [
      :timer,
      :task_ref,
      :started_at,
      coalesced: 0,
      running?: false,
      dirty?: false
    ]
  end

  defmodule State do
    @moduledoc false
    defstruct [:task_supervisor, :push, :max_heap_words, types: %{}]
  end

  @doc """
  Schedules one coalesced rebuild+push for `config_type`.

  Returns immediately; the work never runs in the caller's process.
  """
  @spec invalidate(atom()) :: :ok
  def invalidate(config_type) when is_atom(config_type) do
    GenServer.cast(__MODULE__, {:invalidate, config_type})
  catch
    :exit, _reason -> :ok
  end

  def invalidate(_config_type), do: :ok

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, init_opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, init_opts, name: name)
  end

  @doc false
  @spec task_supervisor_name() :: module()
  def task_supervisor_name, do: __MODULE__.TaskSupervisor

  @impl true
  def init(opts) do
    {:ok,
     %State{
       task_supervisor: Keyword.get(opts, :task_supervisor, task_supervisor_name()),
       push: Keyword.get(opts, :push),
       max_heap_words: Keyword.get(opts, :max_heap_words, default_max_heap_words())
     }}
  end

  @impl true
  def handle_cast({:invalidate, config_type}, %State{} = state) do
    type_state = Map.get(state.types, config_type, %TypeState{})

    type_state =
      cond do
        type_state.running? ->
          # A rebuild is in flight: remember that more changes landed and let
          # its completion schedule the follow-up. One pending rebuild is the
          # whole queue, so a click storm cannot pile work up.
          struct(type_state, dirty?: true, coalesced: type_state.coalesced + 1)

        type_state.timer ->
          struct(type_state, coalesced: type_state.coalesced + 1)

        true ->
          timer = Process.send_after(self(), {:push, config_type}, debounce_ms())
          struct(type_state, timer: timer, coalesced: 1)
      end

    {:noreply, %{state | types: Map.put(state.types, config_type, type_state)}}
  end

  @impl true
  def handle_info({:push, config_type}, %State{} = state) do
    type_state = Map.get(state.types, config_type, %TypeState{})

    case start_rebuild(config_type, state) do
      {:ok, task} ->
        type_state =
          struct(type_state,
            timer: nil,
            running?: true,
            task_ref: task.ref,
            started_at: System.monotonic_time(:millisecond)
          )

        {:noreply, %{state | types: Map.put(state.types, config_type, type_state)}}

      :error ->
        # No supervisor available: the cache is already invalidated, agents
        # converge on their own poll, and the next invalidate retries.
        Logger.warning("ConfigInvalidator: could not start rebuild for #{config_type}")

        type_state = struct(type_state, timer: nil)
        {:noreply, %{state | types: Map.put(state.types, config_type, type_state)}}
    end
  end

  # A bare `DOWN` head would parse as the alias :"Elixir.DOWN" and never
  # match the monitor message; the literal atom is required.
  def handle_info({:DOWN, ref, :process, _pid, reason}, %State{} = state) do
    case Enum.find(state.types, fn {_type, ts} -> ts.task_ref == ref end) do
      {config_type, type_state} ->
        duration_ms = System.monotonic_time(:millisecond) - (type_state.started_at || 0)

        if reason != :normal do
          Logger.warning(
            "ConfigInvalidator: rebuild for #{config_type} ended abnormally " <>
              "(coalesced=#{type_state.coalesced}, duration_ms=#{duration_ms}): #{inspect(reason)}"
          )
        end

        :telemetry.execute(
          [:serviceradar, :agent_config, :config_push],
          %{duration_ms: duration_ms, coalesced: type_state.coalesced},
          %{config_type: config_type, reason: classify_exit(reason)}
        )

        type_state = struct(type_state, running?: false, task_ref: nil, started_at: nil)

        type_state =
          if type_state.dirty? do
            # Changes landed while the rebuild ran: exactly one follow-up.
            timer = Process.send_after(self(), {:push, config_type}, 0)
            struct(type_state, dirty?: false, coalesced: 0, timer: timer)
          else
            struct(type_state, coalesced: 0)
          end

        {:noreply, %{state | types: Map.put(state.types, config_type, type_state)}}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp start_rebuild(config_type, %State{} = state) do
    push = state.push || (&AgentCommandBus.push_config_for_type/1)
    supervisor = state.task_supervisor
    max_heap_words = state.max_heap_words

    worker = fn ->
      # A runaway rebuild dies here alone, never the pod: the kill targets
      # this worker process, the DOWN message records it, and the pending
      # follow-up still runs. (`max_heap_size` is measured in words; `size`
      # is the flag map's key.)
      if max_heap_words do
        Process.flag(:max_heap_size, %{size: max_heap_words, kill: true})
      end

      push.(config_type)
      :ok
    end

    try do
      case Task.Supervisor.async_nolink(supervisor, worker) do
        %Task{} = task -> {:ok, task}
        other -> other
      end
    catch
      :exit, _reason -> :error
    end
  end

  defp classify_exit(:normal), do: :normal
  defp classify_exit(:killed), do: :max_heap_size_killed
  defp classify_exit(:noconnection), do: :worker_node_down

  defp classify_exit(reason) when is_atom(reason), do: reason
  defp classify_exit({reason, _}), do: reason
  defp classify_exit(_), do: :unknown
end
