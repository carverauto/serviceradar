defmodule ServiceRadarCoreElx.CameraStorage.ReadSession do
  @moduledoc false
  use GenServer, shutdown: 40_000

  alias ServiceRadarCoreElx.CameraStorage.ReadTasks
  alias ServiceRadarObjectStorage.Session, as: ObjectStorageSession

  @default_max_slots 8
  @max_longshore_slots 4

  def start_link(config) do
    name = Map.get(config, :session_name, __MODULE__)
    GenServer.start_link(__MODULE__, config, name: name)
  end

  def reserve(deadline, server \\ __MODULE__), do: GenServer.call(server, {:reserve, deadline})

  def attach_longshore_session(session_pid, server \\ __MODULE__, timeout \\ 5_000) do
    GenServer.call(server, {:longshore_session, self(), session_pid}, timeout)
  catch
    :exit, _ -> {:error, :archive_read_unavailable}
  end

  @impl true
  def init(config) do
    provider = Map.merge(config.provider, %{socket_owner: self(), task_supervisor: ReadTasks})
    max_slots = effective_max_slots(config)

    {:ok,
     %{
       config: %{config | provider: provider},
       max_slots: max_slots,
       slots: %{},
       by_owner: %{},
       by_monitor: %{},
       draining_tokens: %{}
     }}
  end

  @impl true
  def handle_call({:reserve, deadline}, {owner, _}, state) do
    in_use = map_size(state.slots) + map_size(state.draining_tokens)

    cond do
      in_use >= state.max_slots ->
        {:reply, {:error, :archive_read_busy}, state}

      Map.has_key?(state.by_owner, owner) ->
        {:reply, {:error, :archive_read_busy}, state}

      true ->
        admit_slot(owner, deadline, state)
    end
  end

  def handle_call({:http_socket_owner, owner, socket}, {owner, _}, state) do
    with {:ok, token} <- Map.fetch(state.by_owner, owner),
         {:ok, %{owner: ^owner, socket: nil} = slot} <- Map.fetch(state.slots, token),
         true <- System.monotonic_time(:millisecond) < slot.deadline do
      sock_mon = Process.monitor(socket)
      updated_slot = %{slot | socket: {socket, sock_mon}}
      slots = Map.put(state.slots, token, updated_slot)
      by_monitor = Map.put(state.by_monitor, sock_mon, {:socket, token})
      {:reply, :ok, %{state | slots: slots, by_monitor: by_monitor}}
    else
      _ -> {:reply, {:error, :archive_read_unavailable}, state}
    end
  end

  def handle_call({:http_socket_owner, _, _}, _, state), do: {:reply, {:error, :archive_read_unavailable}, state}

  def handle_call({:longshore_session, owner, session_pid}, {owner, _}, state) when is_pid(session_pid) do
    with {:ok, token} <- Map.fetch(state.by_owner, owner),
         {:ok, %{owner: ^owner} = slot} <- Map.fetch(state.slots, token),
         true <- System.monotonic_time(:millisecond) < slot.deadline do
      slots = Map.put(state.slots, token, %{slot | longshore_session: session_pid})
      {:reply, :ok, %{state | slots: slots}}
    else
      _ -> {:reply, {:error, :archive_read_unavailable}, state}
    end
  end

  def handle_call({:longshore_session, _, _}, _, state), do: {:reply, {:error, :archive_read_unavailable}, state}

  @impl true
  def handle_info({:deadline, token}, state) do
    case Map.fetch(state.slots, token) do
      {:ok, slot} ->
        by_monitor = stop_socket(slot.socket, state.by_monitor)
        Process.exit(slot.owner, :kill)
        slots = Map.put(state.slots, token, %{slot | socket: nil})
        {:noreply, %{state | slots: slots, by_monitor: by_monitor}}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, monitor, :process, _pid, _}, state) do
    case Map.pop(state.by_monitor, monitor) do
      {{:owner, token}, by_monitor} ->
        {:noreply, handle_owner_down(token, by_monitor, state)}

      {{:socket, token}, by_monitor} ->
        slots =
          case Map.fetch(state.slots, token) do
            {:ok, slot} -> Map.put(state.slots, token, %{slot | socket: nil})
            :error -> state.slots
          end

        {:noreply, %{state | slots: slots, by_monitor: by_monitor}}

      {{:drain, token}, by_monitor} ->
        draining_tokens = Map.delete(state.draining_tokens, token)
        {:noreply, %{state | draining_tokens: draining_tokens, by_monitor: by_monitor}}

      {nil, _} ->
        {:noreply, state}
    end
  end

  def handle_info({:token_drained, token}, state) do
    case Map.pop(state.draining_tokens, token) do
      {nil, _} ->
        {:noreply, state}

      {drain_mon, draining_tokens} ->
        Process.demonitor(drain_mon, [:flush])
        by_monitor = Map.delete(state.by_monitor, drain_mon)
        {:noreply, %{state | draining_tokens: draining_tokens, by_monitor: by_monitor}}
    end
  end

  def handle_info({:EXIT, _pid, reason}, state), do: {:stop, reason, state}

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def format_status(status), do: Map.put(status, :state, :redacted)

  defp effective_max_slots(config) do
    case Map.get(config, :mode, :fixed) do
      :fixed ->
        1

      :per_request ->
        configured = max(Map.get(config, :max_concurrency, @default_max_slots), 1)

        if Map.get(config.provider, :transport, :http) == :longshore do
          min(configured, @max_longshore_slots)
        else
          configured
        end
    end
  end

  defp admit_slot(owner, deadline, state) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining in 1..10_000 do
      token = make_ref()
      timer = Process.send_after(self(), {:deadline, token}, remaining)
      owner_mon = Process.monitor(owner)

      slot = %{
        owner: owner,
        monitor: owner_mon,
        timer: timer,
        token: token,
        deadline: deadline,
        socket: nil,
        longshore_session: nil
      }

      admitted_config = %{
        state.config
        | provider: Map.put(state.config.provider, :owner_token, token)
      }

      slots = Map.put(state.slots, token, slot)
      by_owner = Map.put(state.by_owner, owner, token)
      by_monitor = Map.put(state.by_monitor, owner_mon, {:owner, token})

      {:reply, {:ok, admitted_config}, %{state | slots: slots, by_owner: by_owner, by_monitor: by_monitor}}
    else
      {:reply, {:error, :archive_read_unavailable}, state}
    end
  end

  defp handle_owner_down(token, by_monitor, state) do
    case Map.pop(state.slots, token) do
      {nil, _} ->
        %{state | by_monitor: by_monitor}

      {slot, slots} ->
        by_monitor = stop_socket(slot.socket, by_monitor)
        Process.cancel_timer(slot.timer)
        by_owner = Map.delete(state.by_owner, slot.owner)
        session = slot.longshore_session || Map.get(state.config.provider, :longshore_session)

        hold_longshore_drain(
          %{state | slots: slots, by_owner: by_owner, by_monitor: by_monitor},
          slot.token,
          session
        )
    end
  end

  defp hold_longshore_drain(state, _token, nil), do: state

  defp hold_longshore_drain(state, token, session) do
    case resolve_pid(session) do
      pid when is_pid(pid) ->
        drain_mon = Process.monitor(pid)
        ObjectStorageSession.await_token_drain(pid, token, self())

        %{
          state
          | draining_tokens: Map.put(state.draining_tokens, token, drain_mon),
            by_monitor: Map.put(state.by_monitor, drain_mon, {:drain, token})
        }

      nil ->
        state
    end
  end

  defp resolve_pid(pid) when is_pid(pid), do: if(Process.alive?(pid), do: pid)
  defp resolve_pid(name) when is_atom(name), do: Process.whereis(name)
  defp resolve_pid(_), do: nil

  defp stop_socket(nil, by_monitor), do: by_monitor

  defp stop_socket({pid, monitor}, by_monitor) do
    Process.exit(pid, :kill)
    receive do: ({:DOWN, ^monitor, :process, ^pid, _} -> :ok)
    Map.delete(by_monitor, monitor)
  end
end
