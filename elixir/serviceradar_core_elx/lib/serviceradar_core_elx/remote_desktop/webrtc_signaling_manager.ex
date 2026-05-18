defmodule ServiceRadarCoreElx.RemoteDesktop.WebRTCSignalingManager do
  @moduledoc """
  Remote desktop WebRTC signaling session manager owned by `core-elx`.

  This binds an authorized RDP remote-access session to a viewer-scoped WebRTC
  signaling lifecycle. The desktop media manager owns the actual screen/control
  media path and plugs in behind this module.
  """

  use GenServer

  alias Membrane.WebRTC.Signaling
  alias ServiceRadarCoreElx.RemoteDesktop.MediaSessionManager
  alias ServiceRadarCoreElx.RemoteDesktop.SessionTracker
  alias ServiceRadarCoreElx.RemoteDesktop.WebRTCSignalPolicy

  @default_session_ttl_ms 60_000
  @default_offer_timeout_ms 5_000
  @transport "webrtc_desktop_media"

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def create_session(session_id, opts \\ []) when is_binary(session_id) do
    GenServer.call(server_name(opts), {:create_session, session_id, opts}, Keyword.get(opts, :timeout, 15_000))
  end

  def submit_answer(session_id, viewer_session_id, answer_sdp, opts \\ [])
      when is_binary(session_id) and is_binary(viewer_session_id) and is_binary(answer_sdp) do
    GenServer.call(server_name(opts), {:submit_answer, session_id, viewer_session_id, answer_sdp, opts})
  end

  def add_ice_candidate(session_id, viewer_session_id, candidate, opts \\ [])
      when is_binary(session_id) and is_binary(viewer_session_id) do
    GenServer.call(server_name(opts), {:add_ice_candidate, session_id, viewer_session_id, candidate, opts})
  end

  def apply_media_ack(session_id, viewer_session_id, ack, opts \\ [])
      when is_binary(session_id) and is_binary(viewer_session_id) and is_map(ack) do
    GenServer.call(server_name(opts), {:apply_media_ack, session_id, viewer_session_id, ack, opts})
  end

  def apply_control_frame(session_id, viewer_session_id, frame, opts \\ [])
      when is_binary(session_id) and is_binary(viewer_session_id) and is_map(frame) do
    GenServer.call(server_name(opts), {:apply_control_frame, session_id, viewer_session_id, frame, opts})
  end

  def close_session(session_id, viewer_session_id, opts \\ [])
      when is_binary(session_id) and is_binary(viewer_session_id) do
    GenServer.call(server_name(opts), {:close_session, session_id, viewer_session_id, opts})
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       sessions: %{},
       signaling_index: %{},
       session_ttl_ms:
         Keyword.get(
           opts,
           :session_ttl_ms,
           Application.get_env(
             :serviceradar_core_elx,
             :remote_desktop_webrtc_session_ttl_ms,
             @default_session_ttl_ms
           )
         ),
       offer_timeout_ms:
         Keyword.get(
           opts,
           :offer_timeout_ms,
           Application.get_env(
             :serviceradar_core_elx,
             :remote_desktop_webrtc_offer_timeout_ms,
             @default_offer_timeout_ms
           )
         ),
       session_tracker:
         Keyword.get(
           opts,
           :session_tracker,
           Application.get_env(:serviceradar_core_elx, :remote_desktop_webrtc_session_tracker, SessionTracker)
         ),
       media_manager:
         Keyword.get(
           opts,
           :media_manager,
           Application.get_env(:serviceradar_core_elx, :remote_desktop_media_session_manager, MediaSessionManager)
         )
     }}
  end

  @impl true
  def handle_call({:create_session, session_id, opts}, from, state) do
    with {:ok, _session} <- available_desktop_session(session_tracker(state).fetch_session(session_id)),
         {:ok, signaling} <- start_signaling(),
         :ok <- Signaling.register_peer(signaling, message_format: :json_data, pid: self()) do
      viewer_session_id = Ecto.UUID.generate()
      {expires_at, timer_ref} = schedule_expiry(viewer_session_id, state.session_ttl_ms)
      offer_timeout_ref = Process.send_after(self(), {:offer_timeout, viewer_session_id}, state.offer_timeout_ms)

      session = %{
        session_id: session_id,
        viewer_session_id: viewer_session_id,
        signaling_state: "viewer_authorized",
        answer_sdp: nil,
        last_candidate: nil,
        last_remote_candidate: nil,
        offer_sdp: nil,
        signaling: signaling,
        signaling_pid: signaling.pid,
        expires_at: expires_at,
        timer_ref: timer_ref,
        offer_timeout_ref: offer_timeout_ref,
        pending_reply_to: from
      }

      case media_manager(state).add_webrtc_viewer(
             session_id,
             viewer_session_id,
             signaling,
             opts
             |> Keyword.delete(:server)
             |> Keyword.put(:transport, @transport)
           ) do
        :ok ->
          {:noreply, put_session(state, session)}

        {:error, reason} ->
          _ = Signaling.close(signaling)
          {:reply, {:error, reason}, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:submit_answer, session_id, viewer_session_id, answer_sdp, _opts}, _from, state) do
    case fetch_session(state, session_id, viewer_session_id) do
      {:ok, session} ->
        case WebRTCSignalPolicy.validate_answer_sdp(answer_sdp) do
          :ok ->
            updated =
              session
              |> refresh_session(state.session_ttl_ms)
              |> Map.put(:signaling_state, "answer_applied")
              |> Map.put(:answer_sdp, answer_sdp)

            :ok =
              Signaling.signal(
                updated.signaling,
                %{"type" => "sdp_answer", "data" => %{"type" => "answer", "sdp" => answer_sdp}}
              )

            {:reply, {:ok, session_response(updated)}, put_session(state, updated)}

          {:error, reason} ->
            emit_signal_rejection(:sdp_answer, session, reason)
            {:reply, {:error, reason}, state}
        end

      {:error, :viewer_session_not_found} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:add_ice_candidate, session_id, viewer_session_id, candidate, _opts}, _from, state) do
    case fetch_session(state, session_id, viewer_session_id) do
      {:ok, session} ->
        case WebRTCSignalPolicy.validate_ice_candidate(candidate) do
          :ok ->
            updated =
              session
              |> refresh_session(state.session_ttl_ms)
              |> Map.put(:signaling_state, "candidate_buffered")
              |> Map.put(:last_candidate, candidate)

            :ok = Signaling.signal(updated.signaling, %{"type" => "ice_candidate", "data" => candidate})

            {:reply, {:ok, session_response(updated)}, put_session(state, updated)}

          {:error, reason} ->
            emit_signal_rejection(:ice_candidate, session, reason)
            {:reply, {:error, reason}, state}
        end

      {:error, :viewer_session_not_found} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:apply_media_ack, session_id, viewer_session_id, ack, opts}, _from, state) do
    case fetch_session(state, session_id, viewer_session_id) do
      {:ok, session} ->
        case media_manager(state).apply_browser_ack(
               session_id,
               viewer_session_id,
               ack,
               Keyword.delete(opts, :server)
             ) do
          {:ok, media_state} ->
            updated = refresh_session(session, state.session_ttl_ms)

            response =
              updated
              |> session_response()
              |> Map.put(:media_ack_state, media_state)

            {:reply, {:ok, response}, put_session(state, updated)}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      {:error, :viewer_session_not_found} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:apply_control_frame, session_id, viewer_session_id, frame, opts}, _from, state) do
    case fetch_session(state, session_id, viewer_session_id) do
      {:ok, session} ->
        case media_manager(state).apply_browser_control(
               session_id,
               viewer_session_id,
               frame,
               Keyword.delete(opts, :server)
             ) do
          {:ok, control_state} ->
            updated = refresh_session(session, state.session_ttl_ms)

            response =
              updated
              |> session_response()
              |> Map.put(:control_state, control_state)

            {:reply, {:ok, response}, put_session(state, updated)}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      {:error, :viewer_session_not_found} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:close_session, session_id, viewer_session_id, opts}, _from, state) do
    case Map.get(state.sessions, viewer_session_id) do
      nil ->
        {:reply, {:error, :viewer_session_not_found}, state}

      %{session_id: ^session_id} = session ->
        close_runtime_session(state, session)
        state = remove_session(state, session)

        {:reply,
         {:ok,
          %{
            viewer_session_id: viewer_session_id,
            signaling_state: "closed",
            close_reason: close_reason(opts)
          }}, state}

      _session ->
        {:reply, {:error, :viewer_session_not_found}, state}
    end
  end

  @impl true
  def handle_info({:expire_session, viewer_session_id}, state) do
    case Map.get(state.sessions, viewer_session_id) do
      nil ->
        {:noreply, state}

      session ->
        close_runtime_session(state, session)
        {:noreply, remove_session(state, session)}
    end
  end

  def handle_info({:offer_timeout, viewer_session_id}, state) do
    case Map.get(state.sessions, viewer_session_id) do
      nil ->
        {:noreply, state}

      %{pending_reply_to: from} = session when not is_nil(from) ->
        close_runtime_session(state, session)
        GenServer.reply(from, {:error, "desktop webrtc offer timed out"})
        {:noreply, remove_session(state, session)}

      _session ->
        {:noreply, state}
    end
  end

  def handle_info(
        {:membrane_webrtc_signaling, signaling_pid, %{"type" => "sdp_offer", "data" => offer_data}, _metadata},
        state
      ) do
    case fetch_session_by_signaling(state, signaling_pid) do
      {:ok, session} ->
        updated =
          session
          |> refresh_session(state.session_ttl_ms)
          |> cancel_offer_timeout()
          |> Map.put(:signaling_state, "offer_created")
          |> Map.put(:offer_sdp, extract_sdp(offer_data))
          |> Map.put(:pending_reply_to, nil)

        maybe_reply_offer(session.pending_reply_to, updated)
        {:noreply, put_session(state, updated)}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info(
        {:membrane_webrtc_signaling, signaling_pid, %{"type" => "ice_candidate", "data" => candidate}, _metadata},
        state
      ) do
    case fetch_session_by_signaling(state, signaling_pid) do
      {:ok, session} ->
        case WebRTCSignalPolicy.validate_ice_candidate(candidate) do
          :ok ->
            updated =
              session
              |> refresh_session(state.session_ttl_ms)
              |> Map.put(:last_remote_candidate, candidate)

            {:noreply, put_session(state, updated)}

          {:error, reason} ->
            emit_signal_rejection(:ice_candidate, session, reason)
            {:noreply, state}
        end

      :error ->
        {:noreply, state}
    end
  end

  def handle_info(
        {:membrane_webrtc_signaling, signaling_pid, %{"type" => "sdp_answer", "data" => answer_data}, _metadata},
        state
      ) do
    case fetch_session_by_signaling(state, signaling_pid) do
      {:ok, session} ->
        case extract_sdp(answer_data) do
          answer_sdp when is_binary(answer_sdp) ->
            case WebRTCSignalPolicy.validate_answer_sdp(answer_sdp) do
              :ok ->
                updated =
                  session
                  |> refresh_session(state.session_ttl_ms)
                  |> Map.put(:signaling_state, "answer_applied")
                  |> Map.put(:answer_sdp, answer_sdp)

                {:noreply, put_session(state, updated)}

              {:error, reason} ->
                emit_signal_rejection(:sdp_answer, session, reason)
                {:noreply, state}
            end

          _other ->
            emit_signal_rejection(:sdp_answer, session, :invalid_sdp)
            {:noreply, state}
        end

      :error ->
        {:noreply, state}
    end
  end

  defp session_tracker(state), do: Map.get(state, :session_tracker, SessionTracker)
  defp media_manager(state), do: Map.get(state, :media_manager, MediaSessionManager)
  defp server_name(opts), do: Keyword.get(opts, :server, __MODULE__)

  defp fetch_session(state, session_id, viewer_session_id) do
    case Map.get(state.sessions, viewer_session_id) do
      %{session_id: ^session_id} = session -> {:ok, session}
      _other -> {:error, :viewer_session_not_found}
    end
  end

  defp fetch_session_by_signaling(state, signaling_pid) when is_pid(signaling_pid) do
    with viewer_session_id when is_binary(viewer_session_id) <- Map.get(state.signaling_index, signaling_pid),
         session when is_map(session) <- Map.get(state.sessions, viewer_session_id) do
      {:ok, session}
    else
      _other -> :error
    end
  end

  defp put_session(state, session) do
    %{
      state
      | sessions: Map.put(state.sessions, session.viewer_session_id, session),
        signaling_index: Map.put(state.signaling_index, session.signaling_pid, session.viewer_session_id)
    }
  end

  defp remove_session(state, session) do
    %{
      state
      | sessions: Map.delete(state.sessions, session.viewer_session_id),
        signaling_index: Map.delete(state.signaling_index, session.signaling_pid)
    }
  end

  defp available_desktop_session({:ok, session}) when is_map(session), do: {:ok, session}
  defp available_desktop_session(session) when is_map(session), do: {:ok, session}
  defp available_desktop_session(nil), do: {:error, :not_found}
  defp available_desktop_session(other), do: other

  defp refresh_session(session, session_ttl_ms) do
    _ = Process.cancel_timer(session.timer_ref)
    {expires_at, timer_ref} = schedule_expiry(session.viewer_session_id, session_ttl_ms)

    session
    |> Map.put(:expires_at, expires_at)
    |> Map.put(:timer_ref, timer_ref)
  end

  defp close_runtime_session(state, session) do
    _ = cancel_timer(session.timer_ref)
    _ = cancel_timer(session.offer_timeout_ref)
    _ = media_manager(state).remove_webrtc_viewer(session.session_id, session.viewer_session_id)
    _ = Signaling.close(session.signaling)
    :ok
  end

  defp schedule_expiry(viewer_session_id, session_ttl_ms) do
    expires_at = DateTime.add(DateTime.utc_now(), div(session_ttl_ms, 1_000), :second)
    timer_ref = Process.send_after(self(), {:expire_session, viewer_session_id}, session_ttl_ms)
    {expires_at, timer_ref}
  end

  defp session_response(session) do
    %{
      viewer_session_id: session.viewer_session_id,
      signaling_state: session.signaling_state,
      offer_sdp: session.offer_sdp,
      remote_ice_candidate: session.last_remote_candidate,
      expires_at: DateTime.to_iso8601(session.expires_at)
    }
  end

  defp start_signaling do
    case Signaling.start_link([]) do
      {:ok, signaling_pid} -> {:ok, Signaling.new(signaling_pid)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_reply_offer(nil, _session), do: :ok
  defp maybe_reply_offer(from, session), do: GenServer.reply(from, {:ok, session_response(session)})

  defp cancel_offer_timeout(session) do
    cancel_timer(session.offer_timeout_ref)
    Map.put(session, :offer_timeout_ref, nil)
  end

  defp extract_sdp(%{"sdp" => sdp}) when is_binary(sdp), do: sdp
  defp extract_sdp(%{sdp: sdp}) when is_binary(sdp), do: sdp
  defp extract_sdp(_other), do: nil

  defp close_reason(opts) do
    opts
    |> Keyword.get(:reason, "viewer closed desktop webrtc signaling session")
    |> to_string()
    |> String.trim()
    |> case do
      "" -> "viewer closed desktop webrtc signaling session"
      trimmed -> trimmed
    end
  end

  defp cancel_timer(ref) when is_reference(ref), do: Process.cancel_timer(ref)
  defp cancel_timer(_other), do: false

  defp emit_signal_rejection(signal_type, session, reason) do
    :telemetry.execute(
      [:serviceradar_core_elx, :remote_desktop, :webrtc, :signal_rejected],
      %{count: 1},
      %{
        reason: reason,
        session_id: session.session_id,
        signal_type: signal_type,
        viewer_session_id: session.viewer_session_id
      }
    )
  end
end
