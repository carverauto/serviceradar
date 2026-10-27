defmodule ServiceRadarCoreElx.CameraStorage.ReadSession do
  @moduledoc false
  use GenServer

  alias ServiceRadarCoreElx.CameraStorage.ReadTasks

  def start_link(config), do: GenServer.start_link(__MODULE__, config, name: __MODULE__)
  def reserve(deadline), do: GenServer.call(__MODULE__, {:reserve, deadline})

  @impl true
  def init(config) do
    provider = Map.merge(config.provider, %{socket_owner: self(), task_supervisor: ReadTasks})
    {:ok, %{config: %{config | provider: provider}, slot: nil}}
  end

  @impl true
  def handle_call({:reserve, deadline}, {owner, _}, %{slot: nil} = state) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining in 1..10_000 do
      token = make_ref()
      timer = Process.send_after(self(), {:deadline, token}, remaining)

      slot = %{
        owner: owner,
        monitor: Process.monitor(owner),
        timer: timer,
        token: token,
        deadline: deadline,
        socket: nil
      }

      {:reply, {:ok, state.config}, %{state | slot: slot}}
    else
      {:reply, {:error, :archive_read_unavailable}, state}
    end
  end

  def handle_call({:reserve, _}, _, state), do: {:reply, {:error, :archive_read_busy}, state}

  def handle_call({:http_socket_owner, owner, socket}, {owner, _}, %{slot: %{owner: owner, socket: nil} = slot} = state) do
    if System.monotonic_time(:millisecond) < slot.deadline do
      {:reply, :ok, %{state | slot: %{slot | socket: {socket, Process.monitor(socket)}}}}
    else
      {:reply, {:error, :archive_read_unavailable}, state}
    end
  end

  def handle_call({:http_socket_owner, _, _}, _, state), do: {:reply, {:error, :archive_read_unavailable}, state}

  @impl true
  def handle_info({:deadline, token}, %{slot: %{token: token} = slot} = state) do
    stop_socket(slot.socket)
    Process.exit(slot.owner, :kill)
    {:noreply, %{state | slot: %{slot | socket: nil}}}
  end

  def handle_info({:DOWN, monitor, :process, owner, _}, %{slot: %{owner: owner, monitor: monitor} = slot} = state) do
    stop_socket(slot.socket)
    Process.cancel_timer(slot.timer)
    {:noreply, %{state | slot: nil}}
  end

  def handle_info({:DOWN, monitor, :process, socket, _}, %{slot: %{socket: {socket, monitor}} = slot} = state) do
    {:noreply, %{state | slot: %{slot | socket: nil}}}
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def format_status(_), do: %{state: :redacted}

  defp stop_socket(nil), do: :ok

  defp stop_socket({pid, monitor}) do
    Process.exit(pid, :kill)
    receive do: ({:DOWN, ^monitor, :process, ^pid, _} -> :ok)
  end
end
