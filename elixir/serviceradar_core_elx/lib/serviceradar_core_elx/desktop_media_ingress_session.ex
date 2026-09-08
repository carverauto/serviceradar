defmodule ServiceRadarCoreElx.DesktopMediaIngressSession do
  @moduledoc """
  Session-scoped desktop media ingress process.

  This is the core-elx handoff point between gateway-accepted desktop chunks and
  browser media delivery. The current slice validates bindings and issues credit
  acknowledgements; renderer fan-out attaches behind this process next.
  """

  use GenServer

  alias ServiceRadarCoreElx.RemoteDesktop.MediaSessionManager

  @default_max_chunk_bytes 1_048_576
  @default_idle_timeout_ms 60_000

  def start_link(session, opts \\ []) when is_map(session) do
    GenServer.start_link(__MODULE__, {session, opts}, name: via(session.desktop_session_id))
  end

  def forward_frame(ingress_pid, %Desktopmedia.DesktopMediaFrameChunk{} = frame, timeout \\ 15_000)
      when is_pid(ingress_pid) do
    GenServer.call(ingress_pid, {:forward_frame, frame}, timeout)
  end

  @impl true
  def init({session, opts}) do
    idle_timeout_ms =
      opts
      |> Keyword.get(
        :idle_timeout_ms,
        Application.get_env(
          :serviceradar_core_elx,
          :remote_desktop_media_ingress_idle_timeout_ms,
          @default_idle_timeout_ms
        )
      )
      |> normalize_idle_timeout_ms()

    {:ok,
     schedule_idle_timeout(%{
       session: session,
       last_sequence: 0,
       sent_bytes: 0,
       media_manager: Keyword.get(opts, :media_manager, MediaSessionManager),
       idle_timeout_ms: idle_timeout_ms,
       idle_timer: nil,
       idle_token: nil
     })}
  end

  @impl true
  def handle_call({:forward_frame, frame}, _from, state) do
    with :ok <- verify_frame_binding(state.session, frame),
         :ok <- validate_frame_size(state.session, frame) do
      frame_cost = frame_byte_count(frame)
      last_sequence = max(state.last_sequence, normalize_uint(frame.sequence))
      sent_bytes = state.sent_bytes + frame_cost

      case state.media_manager.forward_frame(state.session.desktop_session_id, frame, session: state.session) do
        {:ok, %Desktopmedia.DesktopMediaAck{} = ack} ->
          :telemetry.execute(
            [:serviceradar, :desktop_media, :ingress, :frame],
            %{bytes: frame_cost, sequence: frame.sequence, sent_bytes: sent_bytes},
            %{
              desktop_session_id: state.session.desktop_session_id,
              media_session_id: state.session.media_session_id,
              media_ingest_id: state.session.media_ingest_id,
              agent_id: state.session.agent_id,
              gateway_id: state.session.gateway_id,
              payload_family: frame.payload_family,
              encoding: frame.encoding
            }
          )

          next_state =
            state
            |> Map.merge(%{last_sequence: last_sequence, sent_bytes: sent_bytes})
            |> schedule_idle_timeout()

          {:reply, {:ok, ack}, next_state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info({:idle_timeout, idle_token}, %{idle_token: idle_token} = state) do
    {:stop, :normal, state}
  end

  def handle_info({:idle_timeout, _stale_token}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    _ = cancel_timer(state.idle_timer)
    _ = close_media_session(state.media_manager, state.session.desktop_session_id)
    :ok
  end

  defp verify_frame_binding(session, frame) do
    cond do
      session.desktop_session_id != frame.desktop_session_id ->
        {:error, :not_found}

      session.media_session_id != frame.media_session_id ->
        {:error, :media_session_mismatch}

      frame.media_ingest_id not in [nil, "", session.media_ingest_id] ->
        {:error, :media_ingest_mismatch}

      session.agent_id != frame.agent_id ->
        {:error, :agent_id_mismatch}

      true ->
        :ok
    end
  end

  defp validate_frame_size(session, frame) do
    if frame_byte_count(frame) <= max_chunk_bytes(session) do
      :ok
    else
      {:error, :chunk_too_large}
    end
  end

  defp frame_byte_count(frame), do: byte_size(frame.metadata || <<>>) + byte_size(frame.payload || <<>>)

  defp max_chunk_bytes(%{max_chunk_bytes: value}), do: normalize_uint(value, @default_max_chunk_bytes)
  defp max_chunk_bytes(_session), do: @default_max_chunk_bytes

  defp normalize_uint(value, default \\ 0)
  defp normalize_uint(value, _default) when is_integer(value) and value >= 0, do: value
  defp normalize_uint(_value, default), do: default

  defp normalize_idle_timeout_ms(value) when is_integer(value) and value > 0, do: value
  defp normalize_idle_timeout_ms(_value), do: @default_idle_timeout_ms

  defp schedule_idle_timeout(state) do
    _ = cancel_timer(state.idle_timer)
    idle_token = make_ref()
    timer_ref = Process.send_after(self(), {:idle_timeout, idle_token}, state.idle_timeout_ms)
    %{state | idle_timer: timer_ref, idle_token: idle_token}
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer_ref), do: Process.cancel_timer(timer_ref)

  defp close_media_session(media_manager, desktop_session_id) do
    if function_exported?(media_manager, :close_session, 1) do
      media_manager.close_session(desktop_session_id)
    else
      :ok
    end
  catch
    :exit, _reason -> :ok
  end

  defp via(desktop_session_id) do
    {:via, Registry, {ServiceRadarCoreElx.DesktopMediaIngressRegistry, desktop_session_id}}
  end
end
