defmodule ServiceRadarCoreElx.CameraRelay.ViewerRegistry do
  @moduledoc """
  Tracks active browser viewers for each relay session and fans Membrane output
  only to registered viewers.
  """

  use GenServer

  alias ServiceRadar.Camera.RelayPubSub
  alias ServiceRadar.Camera.RelaySessionManager
  alias ServiceRadarCoreElx.CameraMediaSessionTracker

  require Logger

  @default_idle_close_ms 5_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def broadcast_chunk(relay_session_id, payload) when is_binary(relay_session_id) and is_map(payload) do
    GenServer.cast(__MODULE__, {:broadcast_chunk, relay_session_id, payload})
  end

  def viewer_count(relay_session_id) when is_binary(relay_session_id) do
    GenServer.call(__MODULE__, {:viewer_count, relay_session_id})
  end

  @impl true
  def init(opts) do
    :ok = RelayPubSub.subscribe_viewer_control()

    {:ok,
     %{
       viewers: %{},
       close_timers: %{},
       idle_close_ms:
         Keyword.get(
           opts,
           :idle_close_ms,
           Application.get_env(:serviceradar_core_elx, :camera_relay_idle_close_ms, @default_idle_close_ms)
         ),
       session_closer:
         Keyword.get(
           opts,
           :session_closer,
           Application.get_env(:serviceradar_core_elx, :camera_relay_session_closer, RelaySessionManager)
         ),
       session_closer_opts:
         Keyword.get(
           opts,
           :session_closer_opts,
           Application.get_env(:serviceradar_core_elx, :camera_relay_session_closer_opts, [])
         ),
       session_tracker:
         Keyword.get(
           opts,
           :session_tracker,
           Application.get_env(:serviceradar_core_elx, :camera_relay_session_tracker, CameraMediaSessionTracker)
         )
     }}
  end

  @impl true
  def handle_call({:viewer_count, relay_session_id}, _from, state) do
    count =
      state.viewers
      |> Map.get(relay_session_id, MapSet.new())
      |> MapSet.size()

    {:reply, count, state}
  end

  @impl true
  def handle_cast({:broadcast_chunk, relay_session_id, payload}, state) do
    state
    |> viewers_for(relay_session_id)
    |> Enum.each(fn viewer_id ->
      :ok =
        RelayPubSub.broadcast_viewer_chunk(relay_session_id, viewer_id, %{
          relay_session_id: relay_session_id,
          viewer_id: viewer_id,
          payload: Map.get(payload, :payload, <<>>),
          media_ingest_id: Map.get(payload, :media_ingest_id),
          sequence: Map.get(payload, :sequence),
          pts: Map.get(payload, :pts),
          dts: Map.get(payload, :dts),
          codec: Map.get(payload, :codec),
          payload_format: Map.get(payload, :payload_format),
          track_id: Map.get(payload, :track_id),
          keyframe: Map.get(payload, :keyframe, false) == true
        })
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info({:camera_relay_viewer_join, %{relay_session_id: relay_session_id, viewer_id: viewer_id}}, state) do
    updated =
      state
      |> cancel_close_timer(relay_session_id)
      |> update_viewers(relay_session_id, &MapSet.put(&1, viewer_id))

    :ok =
      session_tracker(state).sync_viewer_count(
        relay_session_id,
        viewer_count_from_state(updated, relay_session_id)
      )

    {:noreply, updated}
  end

  def handle_info({:camera_relay_viewer_leave, %{relay_session_id: relay_session_id, viewer_id: viewer_id}}, state) do
    updated = update_viewers(state, relay_session_id, &MapSet.delete(&1, viewer_id))

    :ok =
      session_tracker(state).sync_viewer_count(
        relay_session_id,
        viewer_count_from_state(updated, relay_session_id)
      )

    {:noreply, maybe_schedule_idle_close(updated, relay_session_id)}
  end

  def handle_info({:idle_close_relay, relay_session_id}, state) do
    state = pop_close_timer(state, relay_session_id)

    if viewer_count_from_state(state, relay_session_id) == 0 do
      close_relay_session(state, relay_session_id)
    end

    {:noreply, state}
  end

  defp viewers_for(state, relay_session_id) do
    state
    |> Map.get(:viewers, %{})
    |> Map.get(relay_session_id, MapSet.new())
  end

  defp update_viewers(state, relay_session_id, updater) do
    updated_set =
      state
      |> viewers_for(relay_session_id)
      |> updater.()

    viewers =
      if MapSet.size(updated_set) == 0 do
        Map.delete(state.viewers, relay_session_id)
      else
        Map.put(state.viewers, relay_session_id, updated_set)
      end

    %{state | viewers: viewers}
  end

  defp viewer_count_from_state(state, relay_session_id) do
    state
    |> viewers_for(relay_session_id)
    |> MapSet.size()
  end

  defp maybe_schedule_idle_close(state, relay_session_id) do
    if viewer_count_from_state(state, relay_session_id) == 0 do
      if Map.has_key?(state.close_timers, relay_session_id) do
        state
      else
        timer_ref = Process.send_after(self(), {:idle_close_relay, relay_session_id}, state.idle_close_ms)
        put_in(state, [:close_timers, relay_session_id], timer_ref)
      end
    else
      cancel_close_timer(state, relay_session_id)
    end
  end

  defp cancel_close_timer(state, relay_session_id) do
    case Map.pop(state.close_timers, relay_session_id) do
      {nil, _timers} ->
        state

      {timer_ref, timers} ->
        _ = Process.cancel_timer(timer_ref)
        %{state | close_timers: timers}
    end
  end

  defp pop_close_timer(state, relay_session_id) do
    {_timer_ref, timers} = Map.pop(state.close_timers, relay_session_id)
    %{state | close_timers: timers}
  end

  defp session_tracker(state), do: Map.get(state, :session_tracker, CameraMediaSessionTracker)

  defp close_relay_session(state, relay_session_id) do
    reason = "viewer idle timeout"
    closer_opts = Keyword.put(state.session_closer_opts, :reason, reason)

    try do
      case state.session_closer.request_close(relay_session_id, closer_opts) do
        {:ok, session} ->
          :ok =
            session_tracker(state).mark_closing(relay_session_id, %{
              close_reason: Map.get(session, :close_reason) || reason,
              viewer_count: 0
            })

          :ok

        {:error, :not_found} ->
          :ok

        {:error, {:invalid_status, _status}} ->
          :ok

        {:error, _reason} ->
          :ok
      end
    rescue
      error ->
        Logger.warning("Ignored camera relay idle close failure for #{relay_session_id}: #{format_close_error(error)}")

        :ok
    catch
      kind, reason ->
        Logger.warning("Ignored camera relay idle close failure for #{relay_session_id}: #{kind}: #{inspect(reason)}")

        :ok
    end
  end

  defp format_close_error(%{__struct__: module}) do
    module
    |> inspect()
    |> String.trim_leading("Elixir.")
  end

  defp format_close_error(error), do: Exception.message(error)
end
