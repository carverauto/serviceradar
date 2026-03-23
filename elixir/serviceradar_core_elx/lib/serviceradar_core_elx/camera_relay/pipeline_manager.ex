defmodule ServiceRadarCoreElx.CameraRelay.PipelineManager do
  @moduledoc """
  Starts and manages Membrane relay pipelines keyed by relay session id.
  """

  use GenServer

  alias ServiceRadarCoreElx.CameraRelay.Pipeline

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def open_session(attrs) when is_map(attrs) do
    GenServer.call(__MODULE__, {:open_session, attrs})
  end

  def record_chunk(relay_session_id, attrs) when is_binary(relay_session_id) and is_map(attrs) do
    GenServer.call(__MODULE__, {:record_chunk, relay_session_id, attrs})
  end

  def close_session(relay_session_id) when is_binary(relay_session_id) do
    GenServer.call(__MODULE__, {:close_session, relay_session_id})
  end

  @impl true
  def init(_opts) do
    {:ok, %{sessions: %{}}}
  end

  @impl true
  def handle_call({:open_session, attrs}, _from, state) do
    relay_session_id = required_string!(attrs, :relay_session_id)

    case Map.fetch(state.sessions, relay_session_id) do
      {:ok, _session} ->
        {:reply, {:error, :already_exists}, state}

      :error ->
        case Membrane.Pipeline.start(Pipeline, relay_session_id: relay_session_id) do
          {:ok, supervisor_pid, pipeline_pid} ->
            ref = Process.monitor(pipeline_pid)

            session = %{
              relay_session_id: relay_session_id,
              supervisor_pid: supervisor_pid,
              pipeline_pid: pipeline_pid,
              monitor_ref: ref
            }

            {:reply, {:ok, session}, put_in(state, [:sessions, relay_session_id], session)}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:record_chunk, relay_session_id, attrs}, _from, state) do
    case Map.get(state.sessions, relay_session_id) do
      %{pipeline_pid: pipeline_pid} ->
        send(pipeline_pid, {:media_chunk, Map.put(attrs, :relay_session_id, relay_session_id)})
        {:reply, :ok, state}

      nil ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:close_session, relay_session_id}, _from, state) do
    case Map.pop(state.sessions, relay_session_id) do
      {nil, sessions} ->
        {:reply, {:error, :not_found}, %{state | sessions: sessions}}

      {session, sessions} ->
        Process.demonitor(session.monitor_ref, [:flush])
        send(session.pipeline_pid, :end_of_stream)
        :ok = Membrane.Pipeline.terminate(session.pipeline_pid)
        {:reply, :ok, %{state | sessions: sessions}}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    sessions =
      Enum.reduce(state.sessions, state.sessions, fn {relay_session_id, session}, acc ->
        if session.monitor_ref == ref do
          Map.delete(acc, relay_session_id)
        else
          acc
        end
      end)

    {:noreply, %{state | sessions: sessions}}
  end

  defp required_string!(attrs, key) do
    case attrs |> Map.get(key, "") |> to_string() |> String.trim() do
      "" -> raise ArgumentError, "#{key} is required"
      value -> value
    end
  end
end
