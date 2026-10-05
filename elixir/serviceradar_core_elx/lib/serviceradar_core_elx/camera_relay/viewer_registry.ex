defmodule ServiceRadarCoreElx.CameraRelay.ViewerRegistry do
  @moduledoc """
  Tracks active browser viewers for each relay session and fans Membrane output
  only to registered viewers.

  Membership changes (join/leave/idle close) go through this process. The
  per-chunk hot path does not: viewers are mirrored into a public ETS table, so
  `broadcast_chunk/2` fans out from the calling pipeline sink and
  `viewer_count/1` is a table read. Previously every camera's every chunk was a
  cast into this one mailbox (unbounded, no drop policy), and the session
  tracker's per-chunk `viewer_count` call queued behind them; under load that
  call timed out and crashed the tracker, dropping every relay session.
  """

  use GenServer

  alias ServiceRadar.Camera.RelayPubSub
  alias ServiceRadar.Camera.RelaySessionManager
  alias ServiceRadarCoreElx.CameraMediaSessionTracker

  require Logger

  @default_idle_close_ms 5_000
  @viewers_table :camera_relay_viewers

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Fans one media chunk to the session's viewers, from the calling process."
  def broadcast_chunk(relay_session_id, payload) when is_binary(relay_session_id) and is_map(payload) do
    relay_session_id
    |> viewers()
    |> Enum.each(fn viewer_id ->
      :ok =
        RelayPubSub.broadcast_viewer_chunk(
          relay_session_id,
          viewer_id,
          viewer_chunk(relay_session_id, viewer_id, payload)
        )
    end)
  end

  @doc "Current viewer count for a relay session; a table read, never a call."
  def viewer_count(relay_session_id) when is_binary(relay_session_id) do
    relay_session_id |> viewers() |> MapSet.size()
  end

  defp viewers(relay_session_id) do
    case :ets.lookup(@viewers_table, relay_session_id) do
      [{^relay_session_id, viewers}] -> viewers
      [] -> MapSet.new()
    end
  rescue
    # The table is owned by this process; before it starts (or while it
    # restarts) there are no viewers to fan out to.
    ArgumentError -> MapSet.new()
  end

  defp viewer_chunk(relay_session_id, viewer_id, payload) do
    %{
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
    }
  end

  @impl true
  def init(opts) do
    :ok = RelayPubSub.subscribe_viewer_control()
    _ = :ets.new(@viewers_table, [:named_table, :protected, :set, read_concurrency: true])

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

    if viewer_count_from_state(state, relay_session_id) == 0 and
         owns_relay_session?(state, relay_session_id) do
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
        true = :ets.delete(@viewers_table, relay_session_id)
        Map.delete(state.viewers, relay_session_id)
      else
        true = :ets.insert(@viewers_table, {relay_session_id, updated_set})
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

  defp owns_relay_session?(state, relay_session_id) do
    case session_tracker(state).fetch_session(relay_session_id) do
      nil -> false
      {:error, _reason} -> false
      _session -> true
    end
  end

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
end
