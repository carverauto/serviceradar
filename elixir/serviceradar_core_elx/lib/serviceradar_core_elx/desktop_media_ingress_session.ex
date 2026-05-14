defmodule ServiceRadarCoreElx.DesktopMediaIngressSession do
  @moduledoc """
  Session-scoped desktop media ingress process.

  This is the core-elx handoff point between gateway-accepted desktop chunks and
  browser media delivery. The current slice validates bindings and issues credit
  acknowledgements; renderer fan-out attaches behind this process next.
  """

  use GenServer

  @default_max_chunk_bytes 1_048_576

  def start_link(session, opts \\ []) when is_map(session) do
    GenServer.start_link(__MODULE__, {session, opts}, name: via(session.desktop_session_id))
  end

  def forward_frame(ingress_pid, %Desktopmedia.DesktopMediaFrameChunk{} = frame, timeout \\ 15_000)
      when is_pid(ingress_pid) do
    GenServer.call(ingress_pid, {:forward_frame, frame}, timeout)
  end

  @impl true
  def init({session, _opts}) do
    {:ok, %{session: session, last_sequence: 0, sent_bytes: 0}}
  end

  @impl true
  def handle_call({:forward_frame, frame}, _from, state) do
    with :ok <- verify_frame_binding(state.session, frame),
         :ok <- validate_frame_size(state.session, frame) do
      frame_cost = frame_byte_count(frame)
      last_sequence = max(state.last_sequence, normalize_uint(frame.sequence))
      sent_bytes = state.sent_bytes + frame_cost

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

      {:reply, {:ok, ack_for(state.session, frame, frame_cost)},
       %{state | last_sequence: last_sequence, sent_bytes: sent_bytes}}
    else
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
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

  defp ack_for(session, frame, frame_cost) do
    %Desktopmedia.DesktopMediaAck{
      desktop_session_id: frame.desktop_session_id,
      media_session_id: frame.media_session_id,
      media_ingest_id: session.media_ingest_id,
      gateway_id: session.gateway_id,
      last_accepted_sequence: frame.sequence,
      credit_bytes: frame_cost
    }
  end

  defp frame_byte_count(frame), do: byte_size(frame.metadata || <<>>) + byte_size(frame.payload || <<>>)

  defp max_chunk_bytes(%{max_chunk_bytes: value}), do: normalize_uint(value, @default_max_chunk_bytes)
  defp max_chunk_bytes(_session), do: @default_max_chunk_bytes

  defp normalize_uint(value, default \\ 0)
  defp normalize_uint(value, _default) when is_integer(value) and value >= 0, do: value
  defp normalize_uint(_value, default), do: default

  defp via(desktop_session_id) do
    {:via, Registry, {ServiceRadarCoreElx.DesktopMediaIngressRegistry, desktop_session_id}}
  end
end
