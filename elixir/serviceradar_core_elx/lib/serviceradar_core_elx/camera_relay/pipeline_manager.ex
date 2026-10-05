defmodule ServiceRadarCoreElx.CameraRelay.PipelineManager do
  @moduledoc """
  Starts and manages Membrane relay pipelines keyed by relay session id.

  A pipeline that stops on its own (not through `close_session/1`) is logged
  and reported to the session tracker, which drains the relay so the agent
  closes it instead of uploading into a session with no media path.

  Only the pipeline lifecycle (open, close, DOWN) goes through this process.
  Session-to-pipeline lookups are mirrored into a protected ETS table, so
  `record_chunk/2` and the viewer/branch calls run in the caller: a chunk is a
  direct send to the session's pipeline, and a slow `Membrane.Pipeline.call`
  for one camera no longer blocks every other camera's chunks behind this
  mailbox.
  """

  use GenServer

  alias ServiceRadarCoreElx.CameraMediaSessionTracker
  alias ServiceRadarCoreElx.CameraRelay.Pipeline

  require Logger

  @pipelines_table :camera_relay_pipelines
  @pipeline_call_timeout 5_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def open_session(attrs) when is_map(attrs) do
    GenServer.call(__MODULE__, {:open_session, attrs})
  end

  def record_chunk(relay_session_id, attrs) when is_binary(relay_session_id) and is_map(attrs) do
    with {:ok, pipeline_pid} <- pipeline_pid(relay_session_id) do
      send(pipeline_pid, {:media_chunk, Map.put(attrs, :relay_session_id, relay_session_id)})
      :ok
    end
  end

  def add_webrtc_viewer(relay_session_id, viewer_session_id, signaling, opts \\ [])
      when is_binary(relay_session_id) and is_binary(viewer_session_id) do
    pipeline_call(
      relay_session_id,
      {:add_webrtc_viewer, viewer_session_id, signaling, opts},
      Keyword.get(opts, :timeout, @pipeline_call_timeout)
    )
  end

  def add_analysis_branch(relay_session_id, branch_id, opts \\ [])
      when is_binary(relay_session_id) and is_binary(branch_id) do
    pipeline_call(
      relay_session_id,
      {:add_analysis_branch, branch_id, opts},
      Keyword.get(opts, :timeout, @pipeline_call_timeout)
    )
  end

  def add_boombox_branch(relay_session_id, branch_id, opts \\ [])
      when is_binary(relay_session_id) and is_binary(branch_id) do
    pipeline_call(
      relay_session_id,
      {:add_boombox_branch, branch_id, opts},
      Keyword.get(opts, :timeout, @pipeline_call_timeout)
    )
  end

  def remove_webrtc_viewer(relay_session_id, viewer_session_id)
      when is_binary(relay_session_id) and is_binary(viewer_session_id) do
    pipeline_call(relay_session_id, {:remove_webrtc_viewer, viewer_session_id}, @pipeline_call_timeout)
  end

  def remove_analysis_branch(relay_session_id, branch_id) when is_binary(relay_session_id) and is_binary(branch_id) do
    pipeline_call(relay_session_id, {:remove_analysis_branch, branch_id}, @pipeline_call_timeout)
  end

  def remove_boombox_branch(relay_session_id, branch_id) when is_binary(relay_session_id) and is_binary(branch_id) do
    pipeline_call(relay_session_id, {:remove_boombox_branch, branch_id}, @pipeline_call_timeout)
  end

  defp pipeline_call(relay_session_id, message, timeout) do
    with {:ok, pipeline_pid} <- pipeline_pid(relay_session_id) do
      Membrane.Pipeline.call(pipeline_pid, message, timeout)
    end
  end

  defp pipeline_pid(relay_session_id) do
    case :ets.lookup(@pipelines_table, relay_session_id) do
      [{^relay_session_id, pipeline_pid}] -> {:ok, pipeline_pid}
      [] -> {:error, :not_found}
    end
  rescue
    ArgumentError -> {:error, :not_found}
  end

  def close_session(relay_session_id) when is_binary(relay_session_id) do
    GenServer.call(__MODULE__, {:close_session, relay_session_id})
  end

  @impl true
  def init(opts) do
    _ = :ets.new(@pipelines_table, [:named_table, :protected, :set, read_concurrency: true])

    {:ok,
     %{
       sessions: %{},
       session_tracker:
         Keyword.get(
           opts,
           :session_tracker,
           Application.get_env(
             :serviceradar_core_elx,
             :camera_media_session_tracker_module,
             CameraMediaSessionTracker
           )
         )
     }}
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

            true = :ets.insert(@pipelines_table, {relay_session_id, pipeline_pid})
            {:reply, {:ok, session}, put_in(state, [:sessions, relay_session_id], session)}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:close_session, relay_session_id}, _from, state) do
    case Map.pop(state.sessions, relay_session_id) do
      {nil, sessions} ->
        {:reply, {:error, :not_found}, %{state | sessions: sessions}}

      {session, sessions} ->
        true = :ets.delete(@pipelines_table, relay_session_id)
        Process.demonitor(session.monitor_ref, [:flush])
        send(session.pipeline_pid, :end_of_stream)
        :ok = Membrane.Pipeline.terminate(session.pipeline_pid)
        {:reply, :ok, %{state | sessions: sessions}}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Enum.find(state.sessions, fn {_relay_session_id, session} -> session.monitor_ref == ref end) do
      {relay_session_id, _session} ->
        Logger.warning(
          "Camera relay media pipeline stopped: relay_session_id=#{relay_session_id} reason=#{inspect(reason)}"
        )

        true = :ets.delete(@pipelines_table, relay_session_id)
        _ = state.session_tracker.pipeline_down(relay_session_id, reason)
        {:noreply, update_in(state, [:sessions], &Map.delete(&1, relay_session_id))}

      nil ->
        {:noreply, state}
    end
  end

  defp required_string!(attrs, key) do
    case attrs |> Map.get(key, "") |> to_string() |> String.trim() do
      "" -> raise ArgumentError, "#{key} is required"
      value -> value
    end
  end
end
