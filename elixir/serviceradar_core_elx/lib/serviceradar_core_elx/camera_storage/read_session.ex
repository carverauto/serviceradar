defmodule ServiceRadarCoreElx.CameraStorage.ReadSession do
  @moduledoc false
  use GenServer, shutdown: 40_000

  alias ServiceRadarCoreElx.CameraStorage.ReadTasks
  alias ServiceRadarObjectStorage.Session, as: ObjectStorageSession

  @default_max_slots 8

  def start_link(config) do
    name = Map.get(config, :session_name, __MODULE__)
    GenServer.start_link(__MODULE__, config, name: name)
  end

  def reserve(deadline, server \\ __MODULE__), do: GenServer.call(server, {:reserve, deadline})

  @impl true
  def init(config) do
    provider = Map.merge(config.provider, %{socket_owner: self(), task_supervisor: ReadTasks})
    default_slots = if Map.get(config, :mode) == :fixed, do: 1, else: @default_max_slots
    max_slots = Map.get(config, :max_concurrency, default_slots)

    {:ok,
     %{
       config: %{config | provider: provider},
       max_slots: max_slots,
       slots: %{},
       slot: nil,
       by_owner: %{},
       by_monitor: %{},
       draining_tokens: MapSet.new()
     }}
  end

  @impl true
  def handle_call({:reserve, deadline}, {owner, _}, state) do
    in_use = map_size(state.slots) + MapSet.size(state.draining_tokens)

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
      {:reply, :ok, put_slots(%{state | by_monitor: by_monitor}, slots)}
    else
      _ -> {:reply, {:error, :archive_read_unavailable}, state}
    end
  end

  def handle_call({:http_socket_owner, _, _}, _, state), do: {:reply, {:error, :archive_read_unavailable}, state}

  @impl true
  def handle_info({:deadline, token}, state) do
    case Map.fetch(state.slots, token) do
      {:ok, slot} ->
        by_monitor = stop_socket(slot.socket, state.by_monitor)
        Process.exit(slot.owner, :kill)
        slots = Map.put(state.slots, token, %{slot | socket: nil})
        {:noreply, put_slots(%{state | by_monitor: by_monitor}, slots)}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, monitor, :process, _pid, _}, state) do
    case Map.pop(state.by_monitor, monitor) do
      {{:owner, token}, by_monitor} ->
        case Map.pop(state.slots, token) do
          {nil, _} ->
            {:noreply, %{state | by_monitor: by_monitor}}

          {slot, slots} ->
            by_monitor = stop_socket(slot.socket, by_monitor)
            Process.cancel_timer(slot.timer)
            by_owner = Map.delete(state.by_owner, slot.owner)

            next_state =
              %{state | by_owner: by_owner, by_monitor: by_monitor}
              |> put_slots(slots)
              |> hold_longshore_drain(slot.token)

            {:noreply, next_state}
        end

      {{:socket, token}, by_monitor} ->
        slots =
          case Map.fetch(state.slots, token) do
            {:ok, slot} -> Map.put(state.slots, token, %{slot | socket: nil})
            :error -> state.slots
          end

        {:noreply, put_slots(%{state | by_monitor: by_monitor}, slots)}

      {nil, _} ->
        {:noreply, state}
    end
  end

  def handle_info({:token_drained, token}, state) do
    {:noreply, %{state | draining_tokens: MapSet.delete(state.draining_tokens, token)}}
  end

  def handle_info({:EXIT, _pid, reason}, state), do: {:stop, reason, state}

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def format_status(_), do: %{state: :redacted}

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
        socket: nil
      }

      admitted_config = %{
        state.config
        | provider: Map.put(state.config.provider, :owner_token, token)
      }

      slots = Map.put(state.slots, token, slot)
      by_owner = Map.put(state.by_owner, owner, token)
      by_monitor = Map.put(state.by_monitor, owner_mon, {:owner, token})

      {:reply, {:ok, admitted_config}, put_slots(%{state | by_owner: by_owner, by_monitor: by_monitor}, slots)}
    else
      {:reply, {:error, :archive_read_unavailable}, state}
    end
  end

  defp put_slots(state, slots) do
    first_slot =
      case Map.values(slots) do
        [slot | _] -> slot
        [] -> nil
      end

    %{state | slots: slots, slot: first_slot}
  end

  defp hold_longshore_drain(state, token) do
    case Map.get(state.config.provider, :longshore_session) do
      session when not is_nil(session) ->
        if server_alive?(session) do
          ObjectStorageSession.await_token_drain(session, token, self())
          %{state | draining_tokens: MapSet.put(state.draining_tokens, token)}
        else
          state
        end

      nil ->
        state
    end
  end

  defp server_alive?(pid) when is_pid(pid), do: Process.alive?(pid)
  defp server_alive?(name) when is_atom(name), do: Process.whereis(name) != nil

  defp stop_socket(nil, by_monitor), do: by_monitor

  defp stop_socket({pid, monitor}, by_monitor) do
    Process.exit(pid, :kill)
    receive do: ({:DOWN, ^monitor, :process, ^pid, _} -> :ok)
    Map.delete(by_monitor, monitor)
  end
end
