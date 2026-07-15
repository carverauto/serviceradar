defmodule ServiceRadarCoreElx.RemoteDesktop.DataChannelProvider do
  @moduledoc """
  ExWebRTC-backed desktop media provider for SRDP DataChannels.

  A provider session is started per authorized desktop viewer. It owns the
  server-created WebRTC DataChannels that the browser client already expects:
  one binary channel for SRDP media frames and one JSON control channel for
  browser acknowledgements/backpressure.
  """

  use GenServer

  alias ExWebRTC.DataChannel
  alias ExWebRTC.ICECandidate
  alias ExWebRTC.PeerConnection
  alias ExWebRTC.SessionDescription
  alias Membrane.WebRTC.Signaling
  alias ServiceRadarCoreElx.RemoteDesktop.MediaFrameEnvelope
  alias ServiceRadarCoreElx.RemoteDesktop.WebRTCSignalingManager
  alias ServiceRadarCoreElx.RemoteDesktop.WebRTCSignalPolicy

  @media_channel "desktop-media"
  @control_channel "desktop-control"
  @ack_message_type "desktop_media_ack"
  @max_data_channel_count 4
  @max_data_channel_message_bytes 16 * 1024 * 1024
  @default_registry __MODULE__.Registry
  @default_supervisor __MODULE__.Supervisor

  def add_webrtc_viewer(session_id, viewer_session_id, signaling, opts \\ [])
      when is_binary(session_id) and is_binary(viewer_session_id) do
    supervisor = Keyword.get(opts, :supervisor, @default_supervisor)

    child_opts =
      opts
      |> Keyword.put(:session_id, session_id)
      |> Keyword.put(:viewer_session_id, viewer_session_id)
      |> Keyword.put(:signaling, signaling)

    case DynamicSupervisor.start_child(supervisor, {__MODULE__, child_opts}) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def remove_webrtc_viewer(session_id, viewer_session_id, opts \\ [])
      when is_binary(session_id) and is_binary(viewer_session_id) do
    case lookup(session_id, viewer_session_id, opts) do
      {:ok, pid} -> GenServer.stop(pid, :normal)
      :error -> :ok
    end
  end

  def forward_frame(session_id, viewer_session_id, %Desktopmedia.DesktopMediaFrameChunk{} = frame, opts \\ [])
      when is_binary(session_id) and is_binary(viewer_session_id) do
    case lookup(session_id, viewer_session_id, opts) do
      {:ok, pid} -> GenServer.call(pid, {:forward_frame, frame}, Keyword.get(opts, :timeout, 15_000))
      :error -> {:error, :viewer_session_not_found}
    end
  end

  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :session_id), Keyword.fetch!(opts, :viewer_session_id)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: via_name(opts))
  end

  @impl true
  def init(opts) do
    state = %{
      control_ref: nil,
      control_open?: false,
      ice_servers: Keyword.get(opts, :ice_servers, []),
      media_ref: nil,
      media_open?: false,
      data_channel_refs: MapSet.new(),
      peer_connection: nil,
      peer_connection_module: Keyword.get(opts, :peer_connection, PeerConnection),
      registry: Keyword.get(opts, :registry, @default_registry),
      session_id: Keyword.fetch!(opts, :session_id),
      signaling: Keyword.fetch!(opts, :signaling),
      signaling_manager: Keyword.get(opts, :signaling_manager, WebRTCSignalingManager),
      signaling_manager_opts: Keyword.get(opts, :signaling_manager_opts, []),
      viewer_session_id: Keyword.fetch!(opts, :viewer_session_id)
    }

    {:ok, state, {:continue, :start_peer_connection}}
  end

  @impl true
  def handle_continue(:start_peer_connection, state) do
    with :ok <- Signaling.register_element(state.signaling),
         {:ok, pc} <- start_peer_connection(state),
         {:ok, media_channel} <- create_data_channel(state.peer_connection_module, pc, @media_channel),
         {:ok, control_channel} <- create_data_channel(state.peer_connection_module, pc, @control_channel),
         {:ok, offer} <- state.peer_connection_module.create_offer(pc),
         :ok <- state.peer_connection_module.set_local_description(pc, offer),
         :ok <- Signaling.signal(state.signaling, offer) do
      {:noreply,
       %{
         state
         | peer_connection: pc,
           media_ref: media_channel.ref,
           control_ref: control_channel.ref,
           data_channel_refs: MapSet.new([media_channel.ref, control_channel.ref])
       }}
    else
      {:error, reason} -> {:stop, reason, state}
    end
  end

  @impl true
  def handle_call({:forward_frame, frame}, _from, %{media_open?: true, media_ref: media_ref} = state) do
    reply =
      with {:ok, iodata} <- MediaFrameEnvelope.encode_iodata(frame),
           payload = IO.iodata_to_binary(iodata),
           :ok <- validate_data_channel_message_size(payload) do
        state.peer_connection_module.send_data(state.peer_connection, media_ref, payload, :binary)
      end

    {:reply, reply, state}
  end

  def handle_call({:forward_frame, _frame}, _from, state) do
    {:reply, {:error, :media_data_channel_not_open}, state}
  end

  @impl true
  def handle_info({:membrane_webrtc_signaling, _pid, %SessionDescription{type: :answer} = answer, _metadata}, state) do
    case WebRTCSignalPolicy.validate_answer_sdp(answer.sdp) do
      :ok ->
        :ok = state.peer_connection_module.set_remote_description(state.peer_connection, answer)
        {:noreply, state}

      {:error, reason} ->
        emit_signal_rejection(:sdp_answer, state, reason)
        {:stop, {:invalid_remote_description, reason}, state}
    end
  end

  def handle_info({:membrane_webrtc_signaling, _pid, %ICECandidate{} = candidate, _metadata}, state) do
    case WebRTCSignalPolicy.validate_ice_candidate(candidate) do
      :ok ->
        :ok = state.peer_connection_module.add_ice_candidate(state.peer_connection, candidate)

      {:error, reason} ->
        emit_signal_rejection(:ice_candidate, state, reason)
    end

    {:noreply, state}
  end

  def handle_info({:ex_webrtc, _pc, {:ice_candidate, candidate}}, state) do
    case WebRTCSignalPolicy.validate_ice_candidate(candidate) do
      :ok ->
        :ok = Signaling.signal(state.signaling, candidate)

      {:error, reason} ->
        emit_signal_rejection(:ice_candidate, state, reason)
    end

    {:noreply, state}
  end

  def handle_info({:ex_webrtc, _pc, {:data_channel, %DataChannel{} = channel}}, state) do
    emit_data_channel_rejection(:unexpected_data_channel, state)
    _ = state.peer_connection_module.close_data_channel(state.peer_connection, channel.ref)

    {:noreply, state}
  end

  def handle_info({:ex_webrtc, _pc, {:data_channel_state_change, ref, :open}}, state) do
    {:noreply, set_channel_open(state, ref, true)}
  end

  def handle_info({:ex_webrtc, _pc, {:data_channel_state_change, ref, :closed}}, state) do
    {:noreply, set_channel_open(state, ref, false)}
  end

  def handle_info({:ex_webrtc, _pc, {:data, ref, data}}, %{control_ref: ref} = state) do
    _ = route_control_message(data, state)
    {:noreply, state}
  end

  def handle_info({:ex_webrtc, _pc, _message}, state), do: {:noreply, state}

  @impl true
  def terminate(reason, state) do
    notify_signaling_manager_terminated(state, reason)
    close_peer_connection(state)
    :ok
  end

  defp start_peer_connection(state) do
    state.peer_connection_module.start_link(
      controlling_process: self(),
      ice_servers: state.ice_servers
    )
  end

  defp create_data_channel(peer_connection, pc, label) do
    peer_connection.create_data_channel(pc, label, ordered: true, protocol: "srdp")
  end

  defp validate_data_channel_message_size(data) when byte_size(data) <= @max_data_channel_message_bytes, do: :ok

  defp validate_data_channel_message_size(_data), do: {:error, :data_channel_message_too_large}

  defp route_control_message(data, state) when is_binary(data) and byte_size(data) > @max_data_channel_message_bytes do
    emit_data_channel_rejection(:message_too_large, state)
    :ignore
  end

  defp route_control_message(data, state) when is_binary(data) do
    with {:ok, message} when is_map(message) <- Jason.decode(data) do
      route_decoded_control_message(message, state)
    end
  end

  defp route_control_message(_data, _state), do: :ignore

  defp route_decoded_control_message(%{"type" => @ack_message_type} = ack, state) do
    state.signaling_manager.apply_media_ack(
      state.session_id,
      state.viewer_session_id,
      ack,
      state.signaling_manager_opts
    )
  end

  defp route_decoded_control_message(%{"frame_type" => frame_type} = frame, state)
       when frame_type in ["desktop.input", "desktop.resize", "desktop.quality", "desktop.disconnect"] do
    state.signaling_manager.apply_control_frame(
      state.session_id,
      state.viewer_session_id,
      frame,
      state.signaling_manager_opts
    )
  end

  defp route_decoded_control_message(_message, _state), do: :ignore

  defp set_channel_open(%{media_ref: ref} = state, ref, open?), do: %{state | media_open?: open?}
  defp set_channel_open(%{control_ref: ref} = state, ref, open?), do: %{state | control_open?: open?}
  defp set_channel_open(state, _ref, _open?), do: state

  defp notify_signaling_manager_terminated(state, _reason) do
    if function_exported?(state.signaling_manager, :provider_terminated, 3) do
      state.signaling_manager.provider_terminated(
        state.session_id,
        state.viewer_session_id,
        state.signaling_manager_opts
      )
    end

    :ok
  rescue
    _error -> :ok
  catch
    :exit, _reason -> :ok
  end

  defp close_peer_connection(%{peer_connection: nil}), do: :ok

  defp close_peer_connection(state) do
    _ = state.peer_connection_module.close(state.peer_connection)
    :ok
  rescue
    _error -> :ok
  catch
    :exit, _reason -> :ok
  end

  defp lookup(session_id, viewer_session_id, opts) do
    registry = Keyword.get(opts, :registry, @default_registry)

    case Registry.lookup(registry, {session_id, viewer_session_id}) do
      [{pid, _value}] -> {:ok, pid}
      [] -> :error
    end
  end

  defp via_name(opts) do
    {:via, Registry,
     {Keyword.get(opts, :registry, @default_registry),
      {Keyword.fetch!(opts, :session_id), Keyword.fetch!(opts, :viewer_session_id)}}}
  end

  defp emit_signal_rejection(signal_type, state, reason) do
    :telemetry.execute(
      [:serviceradar_core_elx, :remote_desktop, :webrtc, :signal_rejected],
      %{count: 1},
      %{
        reason: reason,
        session_id: state.session_id,
        signal_type: signal_type,
        viewer_session_id: state.viewer_session_id
      }
    )
  end

  defp emit_data_channel_rejection(reason, state) do
    :telemetry.execute(
      [:serviceradar_core_elx, :remote_desktop, :webrtc, :data_channel_rejected],
      %{count: 1},
      %{
        current_channels: MapSet.size(state.data_channel_refs),
        max_channels: @max_data_channel_count,
        max_message_bytes: @max_data_channel_message_bytes,
        reason: reason,
        session_id: state.session_id,
        viewer_session_id: state.viewer_session_id
      }
    )
  end
end
