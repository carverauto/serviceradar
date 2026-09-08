defmodule ServiceRadarAgentGateway.ControlStreamTelemetry do
  @moduledoc false

  use GenServer

  alias ServiceRadarAgentGateway.Config

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @spec connected(pid(), map()) :: :ok
  def connected(pid, metadata) when is_pid(pid) and is_map(metadata) do
    GenServer.cast(__MODULE__, {:connected, pid, metadata})
  end

  @impl true
  def init(_opts) do
    emit_active(0)
    {:ok, %{sessions: %{}}}
  end

  @impl true
  def handle_cast({:connected, pid, metadata}, state) do
    if Map.has_key?(state.sessions, pid) do
      {:noreply, state}
    else
      ref = Process.monitor(pid)
      sessions = Map.put(state.sessions, pid, {ref, metadata})
      emit(:established, metadata)
      emit_active(map_size(sessions))
      {:noreply, %{state | sessions: sessions}}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    case Map.get(state.sessions, pid) do
      {^ref, metadata} ->
        sessions = Map.delete(state.sessions, pid)
        emit(:closed, metadata)
        emit_active(map_size(sessions))
        {:noreply, %{state | sessions: sessions}}

      _other ->
        {:noreply, state}
    end
  end

  defp emit(event, metadata) do
    :telemetry.execute(
      [:serviceradar, :agent_gateway, :control_stream, event],
      %{count: 1},
      %{gateway_id: metadata[:gateway_id] || Config.gateway_id()}
    )
  end

  defp emit_active(count) do
    :telemetry.execute(
      [:serviceradar, :agent_gateway, :control_stream, :active],
      %{count: count},
      %{gateway_id: Config.gateway_id()}
    )
  end
end
