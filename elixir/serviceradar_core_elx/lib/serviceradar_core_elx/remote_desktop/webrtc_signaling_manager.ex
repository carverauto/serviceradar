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

  def close_session(session_id, viewer_session_id, opts \\ [])
      when is_binary(session_id) and is_binary(viewer_session_id) do
    GenServer.call(server_name(opts), {:close_session, session_id, viewer_session_id, opts})
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       sessions: %{},
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
             Keyword.put(opts, :transport, @transport)
           ) do
        :ok ->
          {:noreply, put_in(state, [:sessions, viewer_session_id], session)}

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

        {:reply, {:ok, session_response(updated)}, put_in(state, [:sessions, viewer_session_id], updated)}

      {:error, :viewer_session_not_found} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:add_ice_candidate, session_id, viewer_session_id, candidate, _opts}, _from, state) do
    case fetch_session(state, session_id, viewer_session_id) do
      {:ok, session} ->
        updated =
          session
          |> refresh_session(state.session_ttl_ms)
          |> Map.put(:signaling_state, "candidate_buffered")
          |> Map.put(:last_candidate, candidate)

        :ok = Signaling.signal(updated.signaling, %{"type" => "ice_candidate", "data" => candidate})

        {:reply, {:ok, session_response(updated)}, put_in(state, [:sessions, viewer_session_id], updated)}

      {:error, :viewer_session_not_found} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:close_session, session_id, viewer_session_id, opts}, _from, state) do
    case Map.pop(state.sessions, viewer_session_id) do
      {nil, _sessions} ->
        {:reply, {:error, :viewer_session_not_found}, state}

      {%{session_id: ^session_id} = session, sessions} ->
        close_runtime_session(state, session)

        {:reply,
         {:ok,
          %{
            viewer_session_id: viewer_session_id,
            signaling_state: "closed",
            close_reason: close_reason(opts)
          }}, %{state | sessions: sessions}}

      {_session, _sessions} ->
        {:reply, {:error, :viewer_session_not_found}, state}
    end
  end

  @impl true
  def handle_info({:expire_session, viewer_session_id}, state) do
    case Map.pop(state.sessions, viewer_session_id) do
      {nil, _sessions} ->
        {:noreply, state}

      {session, sessions} ->
        close_runtime_session(state, session)
        {:noreply, %{state | sessions: sessions}}
    end
  end

  def handle_info({:offer_timeout, viewer_session_id}, state) do
    case Map.pop(state.sessions, viewer_session_id) do
      {nil, _sessions} ->
        {:noreply, state}

      {%{pending_reply_to: from} = session, sessions} when not is_nil(from) ->
        close_runtime_session(state, session)
        GenServer.reply(from, {:error, "desktop webrtc offer timed out"})
        {:noreply, %{state | sessions: sessions}}

      {_session, _sessions} ->
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
        {:noreply, put_in(state, [:sessions, session.viewer_session_id], updated)}

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
        updated =
          session
          |> refresh_session(state.session_ttl_ms)
          |> Map.put(:last_remote_candidate, candidate)

        {:noreply, put_in(state, [:sessions, session.viewer_session_id], updated)}

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
        updated =
          session
          |> refresh_session(state.session_ttl_ms)
          |> Map.put(:signaling_state, "answer_applied")
          |> Map.put(:answer_sdp, extract_sdp(answer_data))

        {:noreply, put_in(state, [:sessions, session.viewer_session_id], updated)}

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
    Enum.find_value(state.sessions, :error, fn {_viewer_session_id, session} ->
      if session.signaling_pid == signaling_pid, do: {:ok, session}, else: false
    end)
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
end
