defmodule ServiceRadarWebNGWeb.DeviceLive.CameraRelayRuntime do
  @moduledoc false

  alias Phoenix.Component
  alias ServiceRadar.Camera.RelaySession
  alias ServiceRadarWebNGWeb.DeviceLive.CameraComponents

  @default_poll_interval_ms 1_000

  def preserve_active_session(socket, device_uid) do
    if socket.assigns.device_uid == device_uid do
      socket.assigns.active_camera_relay_session
    end
  end

  def preserve_last_session(socket, device_uid) do
    if socket.assigns.device_uid == device_uid do
      socket.assigns.last_camera_relay_session
    end
  end

  def refresh_session(socket, relay_session_id) do
    active_session = socket.assigns.active_camera_relay_session

    cond do
      is_nil(active_session) ->
        socket

      active_session.id != relay_session_id ->
        socket

      true ->
        case fetch_session(socket.assigns.current_scope, relay_session_id) do
          {:ok, nil} ->
            clear_active_session(socket)

          {:ok, session} ->
            apply_session_update(socket, session)

          {:error, _reason} ->
            schedule_refresh(relay_session_id)
            socket
        end
    end
  end

  def request_open(camera_source_id, stream_profile_id, scope, insecure_skip_verify) do
    with {:ok, camera_source_id} <- normalize_uuid_param(camera_source_id),
         {:ok, stream_profile_id} <- normalize_uuid_param(stream_profile_id) do
      session_manager().request_open(
        camera_source_id,
        stream_profile_id,
        scope: scope,
        insecure_skip_verify: insecure_skip_verify
      )
    end
  end

  def request_close(session_id, scope) do
    session_manager().request_close(
      session_id,
      reason: "viewer closed device details",
      scope: scope
    )
  end

  def schedule_refresh(relay_session_id) when is_binary(relay_session_id) do
    Process.send_after(
      self(),
      {:refresh_camera_relay_session, relay_session_id},
      poll_interval_ms()
    )
  end

  def schedule_refresh(_relay_session_id), do: :ok

  def format_error({:agent_offline, _agent_id}, _format_fallback), do: "Assigned agent is offline for this camera source"

  def format_error(:invalid_uuid, _format_fallback), do: "Invalid camera relay request"
  def format_error(reason, _format_fallback) when is_binary(reason), do: reason
  def format_error(reason, format_fallback) when is_function(format_fallback, 1), do: format_fallback.(reason)

  defp fetch_session(scope, relay_session_id) do
    fetcher =
      Application.get_env(
        :serviceradar_web_ng,
        :camera_relay_session_fetcher,
        fn session_id, ash_opts -> RelaySession.get_by_id(session_id, ash_opts) end
      )

    fetcher.(relay_session_id, scope: scope)
  end

  defp apply_session_update(socket, session) do
    current_session =
      socket.assigns.active_camera_relay_session || socket.assigns.last_camera_relay_session

    session = prefer_session(current_session, session)

    if CameraComponents.relay_session_terminal?(session) do
      socket
      |> Component.assign(:active_camera_relay_session, nil)
      |> Component.assign(:last_camera_relay_session, session)
    else
      schedule_refresh(session.id)

      socket
      |> Component.assign(:active_camera_relay_session, session)
      |> Component.assign(:last_camera_relay_session, nil)
    end
  end

  defp clear_active_session(socket) do
    Component.assign(socket, :active_camera_relay_session, nil)
  end

  defp prefer_session(current_session, incoming_session) do
    if session_regresses?(current_session, incoming_session) do
      current_session
    else
      incoming_session
    end
  end

  defp session_regresses?(%{id: current_id} = current_session, %{id: incoming_id} = incoming_session)
       when is_binary(current_id) and current_id == incoming_id do
    status_rank(incoming_session) < status_rank(current_session)
  end

  defp session_regresses?(_current_session, _incoming_session), do: false

  defp status_rank(%{status: status}) do
    case status do
      value when value in [:requested, "requested"] -> 0
      value when value in [:opening, "opening"] -> 1
      value when value in [:active, "active"] -> 2
      value when value in [:closing, "closing"] -> 3
      value when value in [:closed, "closed"] -> 4
      value when value in [:failed, "failed"] -> 4
      _other -> 0
    end
  end

  defp poll_interval_ms do
    case Application.get_env(
           :serviceradar_web_ng,
           :camera_relay_poll_interval_ms,
           @default_poll_interval_ms
         ) do
      value when is_integer(value) and value >= 0 -> value
      _other -> @default_poll_interval_ms
    end
  end

  defp session_manager do
    Application.get_env(
      :serviceradar_web_ng,
      :camera_relay_session_manager,
      ServiceRadar.Camera.RelaySessionManager
    )
  end

  defp normalize_uuid_param(value) when is_binary(value) do
    case Ecto.UUID.cast(String.trim(value)) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_uuid}
    end
  end

  defp normalize_uuid_param(_value), do: {:error, :invalid_uuid}
end
