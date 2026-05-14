defmodule ServiceRadarCoreElx.RemoteDesktop.MediaSessionManager do
  @moduledoc """
  Core-owned desktop media session manager.

  This process keeps viewer attachment and frame accounting state for desktop
  media without retaining screen payloads. A separate offer provider is still
  required before WebRTC viewers can be admitted, so browser access remains
  fail-closed until a concrete data-channel/media provider is configured.
  """

  use GenServer

  @default_unavailable "desktop media plane is not available"

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def add_webrtc_viewer(session_id, viewer_session_id, signaling, opts \\ [])
      when is_binary(session_id) and is_binary(viewer_session_id) do
    GenServer.call(server_name(opts), {:add_webrtc_viewer, session_id, viewer_session_id, signaling, opts})
  end

  def remove_webrtc_viewer(session_id, viewer_session_id, opts \\ [])
      when is_binary(session_id) and is_binary(viewer_session_id) do
    GenServer.call(server_name(opts), {:remove_webrtc_viewer, session_id, viewer_session_id})
  end

  def forward_frame(session_id, %Desktopmedia.DesktopMediaFrameChunk{} = frame, opts \\ []) when is_binary(session_id) do
    GenServer.call(server_name(opts), {:forward_frame, session_id, frame, opts}, Keyword.get(opts, :timeout, 15_000))
  end

  def fetch_session(session_id, opts \\ []) when is_binary(session_id) do
    GenServer.call(server_name(opts), {:fetch_session, session_id})
  end

  def reset(opts \\ []) do
    GenServer.call(server_name(opts), :reset)
  end

  @impl true
  def init(_opts) do
    {:ok, %{sessions: %{}}}
  end

  @impl true
  def handle_call({:add_webrtc_viewer, session_id, viewer_session_id, signaling, opts}, _from, state) do
    with {:ok, provider} <- resolve_offer_provider(opts),
         :ok <- provider.add_webrtc_viewer(session_id, viewer_session_id, signaling, opts) do
      session = Map.get(state.sessions, session_id, new_session(session_id))

      viewer = %{
        viewer_session_id: viewer_session_id,
        signaling_pid: signaling_pid(signaling),
        transport: Keyword.get(opts, :transport),
        attached_at_unix: now_unix()
      }

      updated =
        session
        |> put_in([:viewers, viewer_session_id], viewer)
        |> Map.put(:updated_at_unix, now_unix())

      emit_viewer_event(:attached, updated, viewer)
      {:reply, :ok, put_in(state, [:sessions, session_id], updated)}
    else
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:remove_webrtc_viewer, session_id, viewer_session_id}, _from, state) do
    case Map.get(state.sessions, session_id) do
      nil ->
        {:reply, :ok, state}

      session ->
        {viewer, viewers} = Map.pop(session.viewers, viewer_session_id)

        updated =
          session
          |> Map.put(:viewers, viewers)
          |> Map.put(:updated_at_unix, now_unix())

        if viewer, do: emit_viewer_event(:removed, updated, viewer)

        {:reply, :ok, put_in(state, [:sessions, session_id], updated)}
    end
  end

  def handle_call({:forward_frame, session_id, frame, opts}, _from, state) do
    session =
      state.sessions
      |> Map.get(session_id, new_session(session_id))
      |> merge_frame_session_metadata(Keyword.get(opts, :session, %{}))

    frame_cost = frame_byte_count(frame)
    viewer_count = map_size(session.viewers)

    updated =
      session
      |> Map.put(:last_sequence, max(session.last_sequence, normalize_uint(frame.sequence)))
      |> Map.update!(:forwarded_bytes, &(&1 + frame_cost))
      |> Map.update!(:forwarded_frames, &(&1 + 1))
      |> Map.put(:updated_at_unix, now_unix())
      |> put_last_frame_metadata(frame, frame_cost, viewer_count)

    emit_frame_event(updated, frame, frame_cost, viewer_count)

    {:reply, {:ok, ack_for(updated, frame, frame_cost, viewer_count)}, put_in(state, [:sessions, session_id], updated)}
  end

  def handle_call({:fetch_session, session_id}, _from, state) do
    {:reply, sanitize_session(Map.get(state.sessions, session_id)), state}
  end

  def handle_call(:reset, _from, _state) do
    {:reply, :ok, %{sessions: %{}}}
  end

  defp resolve_offer_provider(opts) do
    provider =
      Keyword.get(opts, :offer_provider) ||
        Application.get_env(:serviceradar_core_elx, :remote_desktop_media_offer_provider)

    cond do
      is_nil(provider) ->
        {:error, @default_unavailable}

      Code.ensure_loaded?(provider) and function_exported?(provider, :add_webrtc_viewer, 4) ->
        {:ok, provider}

      true ->
        {:error, {:invalid_offer_provider, provider}}
    end
  end

  defp new_session(session_id) do
    now = now_unix()

    %{
      session_id: session_id,
      desktop_session_id: session_id,
      media_session_id: nil,
      media_ingest_id: nil,
      agent_id: nil,
      gateway_id: nil,
      viewers: %{},
      last_sequence: 0,
      forwarded_bytes: 0,
      forwarded_frames: 0,
      last_frame: nil,
      created_at_unix: now,
      updated_at_unix: now
    }
  end

  defp merge_frame_session_metadata(session, attrs) when is_map(attrs) do
    session
    |> maybe_put(:desktop_session_id, Map.get(attrs, :desktop_session_id))
    |> maybe_put(:media_session_id, Map.get(attrs, :media_session_id))
    |> maybe_put(:media_ingest_id, Map.get(attrs, :media_ingest_id))
    |> maybe_put(:agent_id, Map.get(attrs, :agent_id))
    |> maybe_put(:gateway_id, Map.get(attrs, :gateway_id))
  end

  defp put_last_frame_metadata(session, frame, frame_cost, viewer_count) do
    Map.put(session, :last_frame, %{
      sequence: frame.sequence,
      bytes: frame_cost,
      payload_family: frame.payload_family,
      encoding: frame.encoding,
      width: frame.width,
      height: frame.height,
      flags: frame.flags,
      viewer_count: viewer_count
    })
  end

  defp ack_for(session, frame, frame_cost, viewer_count) do
    %Desktopmedia.DesktopMediaAck{
      desktop_session_id: frame.desktop_session_id,
      media_session_id: frame.media_session_id,
      media_ingest_id: session.media_ingest_id || frame.media_ingest_id,
      gateway_id: session.gateway_id || "",
      last_accepted_sequence: frame.sequence,
      credit_bytes: frame_cost,
      pause: viewer_count == 0
    }
  end

  defp sanitize_session(nil), do: nil

  defp sanitize_session(session) do
    %{
      session_id: session.session_id,
      desktop_session_id: session.desktop_session_id,
      media_session_id: session.media_session_id,
      media_ingest_id: session.media_ingest_id,
      agent_id: session.agent_id,
      gateway_id: session.gateway_id,
      viewer_count: map_size(session.viewers),
      last_sequence: session.last_sequence,
      forwarded_bytes: session.forwarded_bytes,
      forwarded_frames: session.forwarded_frames,
      last_frame: session.last_frame,
      created_at_unix: session.created_at_unix,
      updated_at_unix: session.updated_at_unix
    }
  end

  defp emit_viewer_event(event, session, viewer) do
    :telemetry.execute(
      [:serviceradar, :desktop_media, :viewer, event],
      %{viewer_count: map_size(session.viewers)},
      %{
        session_id: session.session_id,
        viewer_session_id: viewer.viewer_session_id,
        transport: viewer.transport
      }
    )
  end

  defp emit_frame_event(session, frame, frame_cost, viewer_count) do
    :telemetry.execute(
      [:serviceradar, :desktop_media, :manager, :frame],
      %{bytes: frame_cost, sequence: frame.sequence, viewer_count: viewer_count},
      %{
        session_id: session.session_id,
        desktop_session_id: frame.desktop_session_id,
        media_session_id: frame.media_session_id,
        media_ingest_id: session.media_ingest_id || frame.media_ingest_id,
        agent_id: session.agent_id,
        gateway_id: session.gateway_id,
        payload_family: frame.payload_family,
        encoding: frame.encoding
      }
    )
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp signaling_pid(%{pid: pid}) when is_pid(pid), do: pid
  defp signaling_pid(_signaling), do: nil

  defp frame_byte_count(frame), do: byte_size(frame.metadata || <<>>) + byte_size(frame.payload || <<>>)

  defp normalize_uint(value) when is_integer(value) and value >= 0, do: value
  defp normalize_uint(_value), do: 0

  defp now_unix, do: System.os_time(:second)

  defp server_name(opts), do: Keyword.get(opts, :server, __MODULE__)
end
