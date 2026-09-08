defmodule ServiceRadarCoreElx.CameraMediaIngressSession do
  @moduledoc """
  Session-scoped camera relay ingress process.

  Each accepted relay session gets one process on a core-elx node. The gateway
  forwards chunk batches and lifecycle operations to that process over ERTS.
  """

  use GenServer

  alias ServiceRadarCoreElx.CameraMediaSessionTracker

  @max_chunk_bytes 1_048_576

  def start_link(session, opts \\ []) when is_map(session) do
    GenServer.start_link(__MODULE__, {session, opts}, name: via(session.relay_session_id))
  end

  def upload_media(ingress_pid, chunks, timeout \\ 15_000) when is_list(chunks) do
    GenServer.call(ingress_pid, {:upload_media, chunks}, timeout)
  end

  def heartbeat(ingress_pid, %Camera.RelayHeartbeat{} = request, timeout \\ 15_000) do
    GenServer.call(ingress_pid, {:heartbeat, request}, timeout)
  end

  def close_relay_session(ingress_pid, %Camera.CloseRelaySessionRequest{} = request, timeout \\ 15_000) do
    GenServer.call(ingress_pid, {:close_relay_session, request}, timeout)
  end

  @impl true
  def init({session, opts}) do
    {:ok,
     %{
       session: session,
       tracker:
         Keyword.get(
           opts,
           :tracker,
           Application.get_env(
             :serviceradar_core_elx,
             :camera_media_session_tracker_module,
             CameraMediaSessionTracker
           )
         )
     }}
  end

  @impl true
  def handle_call({:upload_media, []}, _from, state) do
    {:reply, {:error, :empty_upload}, state}
  end

  def handle_call({:upload_media, chunks}, _from, state) do
    case reduce_chunks(state, chunks) do
      {:ok, %{session: session, last_sequence: last_sequence, draining: draining}} ->
        {:reply,
         {:ok,
          %Camera.UploadMediaResponse{
            received: true,
            last_sequence: last_sequence,
            message: upload_message(draining)
          }}, %{state | session: session}}

      {:error, reason, next_state} ->
        {:reply, {:error, reason}, next_state}
    end
  end

  def handle_call({:heartbeat, request}, _from, state) do
    with :ok <- verify_relay_session(state.session, request.relay_session_id, request.media_ingest_id),
         {:ok, session} <-
           state.tracker.heartbeat(request.relay_session_id, request.media_ingest_id, %{
             last_sequence: request.last_sequence,
             sent_bytes: request.sent_bytes
           }) do
      {:reply,
       {:ok,
        %Camera.RelayHeartbeatAck{
          accepted: true,
          lease_expires_at_unix: session.lease_expires_at_unix,
          message: heartbeat_message(session)
        }}, %{state | session: session}}
    else
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:close_relay_session, request}, _from, state) do
    with :ok <- verify_relay_session(state.session, request.relay_session_id, request.media_ingest_id),
         :ok <-
           state.tracker.close_session(request.relay_session_id, request.media_ingest_id, %{
             reason: request.reason
           }) do
      {:stop, :normal, {:ok, %Camera.CloseRelaySessionResponse{closed: true, message: "core relay session closed"}},
       state}
    else
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp reduce_chunks(state, chunks) do
    Enum.reduce_while(chunks, {:ok, %{session: state.session, last_sequence: 0, draining: false}}, fn
      %Camera.MediaChunk{} = chunk, {:ok, acc} ->
        case record_chunk(state, acc.session, chunk) do
          {:ok, session} ->
            {:cont,
             {:ok,
              %{
                session: session,
                last_sequence: chunk.sequence,
                draining: acc.draining || draining_session?(session)
              }}}

          {:error, reason} ->
            {:halt, {:error, reason, state}}
        end

      _other, {:ok, _acc} ->
        {:halt, {:error, :invalid_chunk, state}}
    end)
  end

  defp record_chunk(state, session, chunk) do
    with :ok <- verify_relay_session(session, chunk.relay_session_id, chunk.media_ingest_id),
         :ok <- validate_chunk_size(chunk.payload || <<>>) do
      state.tracker.record_chunk(chunk.relay_session_id, chunk.media_ingest_id, %{
        sequence: chunk.sequence,
        payload: chunk.payload || <<>>,
        pts: chunk.pts,
        dts: chunk.dts,
        keyframe: chunk.keyframe,
        codec: chunk.codec,
        payload_format: chunk.payload_format,
        track_id: chunk.track_id
      })
    end
  end

  defp validate_chunk_size(payload) when byte_size(payload) <= @max_chunk_bytes, do: :ok
  defp validate_chunk_size(_payload), do: {:error, :chunk_too_large}

  defp verify_relay_session(session, relay_session_id, media_ingest_id) do
    cond do
      session.relay_session_id != relay_session_id -> {:error, :not_found}
      session.media_ingest_id != media_ingest_id -> {:error, :media_ingest_mismatch}
      true -> :ok
    end
  end

  defp heartbeat_message(session) do
    if draining_session?(session) do
      "core heartbeat accepted during relay drain"
    else
      "core heartbeat accepted"
    end
  end

  defp upload_message(true), do: "media chunks accepted during relay drain"
  defp upload_message(false), do: "media chunks accepted by core-elx"

  defp draining_session?(%{status: status}), do: status in [:closing, "closing"]
  defp draining_session?(_session), do: false

  defp via(relay_session_id) do
    {:via, Registry, {ServiceRadarCoreElx.CameraMediaIngressRegistry, relay_session_id}}
  end
end
