defmodule ServiceRadar.Edge.ProxmoxConsoleBroker do
  @moduledoc """
  Broker boundary for Proxmox browser console byte streams.

  The broker forwards browser PTY input over the existing agent control stream
  and forwards agent console frames back to the owning WebSock process.
  """

  use GenServer

  alias ServiceRadar.Edge.AgentCommandBus
  alias ServiceRadar.Edge.ProxmoxConsolePubSub

  @callback start_link(map(), pid(), keyword()) :: GenServer.on_start()
  @callback send_input(pid(), binary()) :: :ok | {:error, term()}
  @callback resize(pid(), pos_integer(), pos_integer()) :: :ok | {:error, term()}
  @callback close(pid(), term()) :: :ok

  def start_link(session, owner, opts \\ []) when is_pid(owner) do
    GenServer.start_link(__MODULE__, {session, owner, opts})
  end

  def send_input(pid, data) when is_pid(pid) and is_binary(data) do
    GenServer.call(pid, {:send_input, data})
  end

  def resize(pid, cols, rows) when is_pid(pid) and is_integer(cols) and is_integer(rows) do
    GenServer.call(pid, {:resize, cols, rows})
  end

  def close(pid, reason) when is_pid(pid) do
    GenServer.cast(pid, {:close, reason})
  end

  @impl true
  def init({session, owner, opts}) do
    Process.monitor(owner)
    :ok = ProxmoxConsolePubSub.subscribe(session.id)

    state = %{
      session: session,
      owner: owner,
      required_gateway_node: nil,
      closed?: false
    }

    case send_frame(state, "open", "", Keyword.get(opts, :cols), Keyword.get(opts, :rows), nil) do
      :ok -> {:ok, state}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:send_input, data}, _from, state) do
    {:reply, send_frame(state, "data", data, nil, nil, nil), state}
  end

  def handle_call({:resize, cols, rows}, _from, state) do
    {:reply, send_frame(state, "resize", "", cols, rows, nil), state}
  end

  @impl true
  def handle_cast({:close, reason}, state) do
    _ = send_frame(state, "close", "", nil, nil, inspect(reason))
    {:stop, :normal, %{state | closed?: true}}
  end

  @impl true
  def handle_info({:proxmox_console_frame, %{frame_type: "data", data: data}}, state) when is_binary(data) do
    send(state.owner, {:proxmox_console_data, data})
    {:noreply, state}
  end

  def handle_info({:proxmox_console_frame, %{frame_type: frame_type, reason: reason}}, state)
      when frame_type in ["close", "error"] do
    send(state.owner, {:proxmox_console_closed, reason || frame_type})
    {:stop, :normal, %{state | closed?: true}}
  end

  def handle_info({:proxmox_console_frame, _frame}, state), do: {:noreply, state}
  def handle_info({:DOWN, _ref, :process, _pid, reason}, state), do: {:stop, reason, state}

  @impl true
  def terminate(reason, %{closed?: false} = state) do
    _ = send_frame(state, "close", "", nil, nil, inspect(reason))
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp send_frame(state, frame_type, data, cols, rows, reason) do
    frame = %Monitoring.ConsoleFrame{
      session_id: state.session.id,
      frame_type: frame_type,
      data: data || "",
      cols: uint32(cols),
      rows: uint32(rows),
      reason: reason || "",
      timestamp: System.system_time(:second)
    }

    AgentCommandBus.send_console_frame(state.session.agent_id, frame, required_gateway_node: state.required_gateway_node)
  end

  defp uint32(value) when is_integer(value) and value > 0, do: min(value, 65_535)
  defp uint32(_value), do: 0
end
