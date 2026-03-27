defmodule ServiceRadarWebNGWeb.Api.CameraRelaySessionController do
  @moduledoc """
  Authenticated API for opening and closing live camera relay sessions.
  """

  use ServiceRadarWebNGWeb, :controller

  alias ServiceRadar.Camera.RelayPlayback
  alias ServiceRadar.Camera.RelaySession
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.CameraRelayWebRTC
  alias ServiceRadarWebNG.RBAC

  action_fallback ServiceRadarWebNGWeb.Api.FallbackController

  def create(conn, params) do
    with :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, "devices.view"),
         {:ok, request} <- normalize_create_request(params),
         {:ok, session} <-
           relay_session_manager().request_open(
             request.camera_source_id,
             request.stream_profile_id,
             scope: get_scope(conn),
             insecure_skip_verify: request.insecure_skip_verify
           ) do
      conn
      |> put_status(:created)
      |> json(%{data: relay_session_json(session, conn)})
    else
      {:error, :invalid_request, message} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid_request", message: message})

      {:error, reason} when is_binary(reason) ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "relay_session_unavailable", message: reason})

      {:error, {:agent_offline, _agent_id}} ->
        conn
        |> put_status(:conflict)
        |> json(%{error: "agent_offline", message: "assigned agent is offline"})

      {:error, other} ->
        {:error, other}
    end
  end

  def close(conn, %{"id" => relay_session_id} = params) do
    with :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, "devices.view"),
         {:ok, normalized_id} <- normalize_uuid_param(relay_session_id, "id"),
         {:ok, session} <-
           relay_session_manager().request_close(
             normalized_id,
             reason: normalize_optional_string(Map.get(params, "reason")),
             scope: get_scope(conn)
           ) do
      json(conn, %{data: relay_session_json(session, conn)})
    else
      {:error, :invalid_request, message} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid_request", message: message})

      {:error, reason} when is_binary(reason) ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "relay_session_unavailable", message: reason})

      {:error, {:agent_offline, _agent_id}} ->
        conn
        |> put_status(:conflict)
        |> json(%{error: "agent_offline", message: "assigned agent is offline"})

      {:error, other} ->
        {:error, other}
    end
  end

  def show(conn, %{"id" => relay_session_id}) do
    with :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, "devices.view"),
         {:ok, normalized_id} <- normalize_uuid_param(relay_session_id, "id"),
         {:ok, session} <- fetch_relay_session_for_scope(normalized_id, get_scope(conn)) do
      json(conn, %{data: relay_session_json(session, conn)})
    else
      {:error, :invalid_request, message} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid_request", message: message})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "relay_session_not_found", message: "relay session was not found"})

      {:error, other} ->
        {:error, other}
    end
  end

  def normalize_uuid_param(value, field_name), do: normalize_uuid(value, field_name)

  def fetch_relay_session_for_scope(relay_session_id, scope) do
    fetch_relay_session(relay_session_id, scope)
  end

  defp normalize_create_request(params) when is_map(params) do
    with {:ok, camera_source_id} <-
           normalize_uuid_param(Map.get(params, "camera_source_id"), "camera_source_id"),
         {:ok, stream_profile_id} <-
           normalize_uuid_param(Map.get(params, "stream_profile_id"), "stream_profile_id") do
      {:ok,
       %{
         camera_source_id: camera_source_id,
         stream_profile_id: stream_profile_id,
         insecure_skip_verify: parse_boolean_param(Map.get(params, "insecure_skip_verify")) == true
       }}
    end
  end

  defp normalize_create_request(_params), do: {:error, :invalid_request, "request body is required"}

  defp normalize_uuid(value, field_name) when is_binary(value) do
    trimmed = String.trim(value)

    case Ecto.UUID.cast(trimmed) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_request, "#{field_name} must be a valid UUID"}
    end
  end

  defp normalize_uuid(_value, field_name), do: {:error, :invalid_request, "#{field_name} is required"}

  defp normalize_optional_string(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_optional_string(_value), do: nil

  defp parse_boolean_param(value) when value in [true, false], do: value
  defp parse_boolean_param("true"), do: true
  defp parse_boolean_param("false"), do: false
  defp parse_boolean_param("on"), do: true
  defp parse_boolean_param("1"), do: true
  defp parse_boolean_param("0"), do: false
  defp parse_boolean_param(_value), do: nil

  defp relay_session_json(session, conn) do
    playback_metadata = playback_metadata(session)

    Map.merge(playback_metadata, %{
      id: session.id,
      camera_source_id: session.camera_source_id,
      stream_profile_id: session.stream_profile_id,
      agent_id: session.agent_id,
      gateway_id: session.gateway_id,
      status: format_value(session.status),
      playback_state: relay_playback_state(session),
      viewer_count: Map.get(session, :viewer_count, 0),
      lease_expires_at: format_value(session.lease_expires_at),
      media_ingest_id: session.media_ingest_id,
      viewer_stream_path: relay_viewer_stream_path(session, conn),
      termination_kind: relay_termination_kind(session),
      close_reason: session.close_reason,
      failure_reason: session.failure_reason,
      inserted_at: format_value(session.inserted_at),
      updated_at: format_value(session.updated_at)
    })
  end

  defp playback_metadata(session) when is_map(session) do
    session
    |> Map.merge(CameraRelayWebRTC.metadata(session))
    |> RelayPlayback.browser_metadata()
    |> Map.merge(CameraRelayWebRTC.metadata(session))
  end

  defp playback_metadata(_session) do
    %{}
    |> Map.merge(CameraRelayWebRTC.metadata(%{}))
    |> RelayPlayback.browser_metadata()
    |> Map.merge(CameraRelayWebRTC.metadata(%{}))
  end

  defp format_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp format_value(value) when is_atom(value), do: Atom.to_string(value)
  defp format_value(value), do: value

  defp relay_viewer_stream_path(%{id: relay_session_id}, _conn) when is_binary(relay_session_id) do
    ~p"/v1/camera-relay-sessions/#{relay_session_id}/stream"
  end

  defp relay_viewer_stream_path(_session, _conn), do: nil

  defp relay_termination_kind(session) when is_map(session) do
    Map.get(session, :termination_kind) || Map.get(session, "termination_kind")
  end

  defp relay_playback_state(%{status: status, media_ingest_id: media_ingest_id})
       when status in [:active, "active"] and is_binary(media_ingest_id) and media_ingest_id != "" do
    "ready"
  end

  defp relay_playback_state(%{status: status}) when status in [:requested, :opening, "requested", "opening"],
    do: "pending"

  defp relay_playback_state(%{status: status}) when status in [:closing, "closing"], do: "closing"
  defp relay_playback_state(%{status: status}) when status in [:closed, "closed"], do: "closed"
  defp relay_playback_state(%{status: status}) when status in [:failed, "failed"], do: "failed"
  defp relay_playback_state(_session), do: "pending"

  defp relay_session_manager do
    Application.get_env(
      :serviceradar_web_ng,
      :camera_relay_session_manager,
      ServiceRadar.Camera.RelaySessionManager
    )
  end

  defp fetch_relay_session(relay_session_id, scope) do
    fetcher =
      Application.get_env(
        :serviceradar_web_ng,
        :camera_relay_session_fetcher,
        fn session_id, ash_opts -> RelaySession.get_by_id(session_id, ash_opts) end
      )

    case fetcher.(relay_session_id, scope: scope) do
      {:ok, nil} -> {:error, :not_found}
      other -> other
    end
  end

  defp get_scope(conn) do
    conn.assigns[:current_scope]
  end

  defp require_authenticated(conn) do
    case conn.assigns[:current_scope] do
      %Scope{user: user} when not is_nil(user) -> :ok
      _ -> {:error, :unauthorized}
    end
  end

  defp require_permission(conn, permission) when is_binary(permission) do
    scope = conn.assigns[:current_scope]
    if RBAC.can?(scope, permission), do: :ok, else: {:error, :forbidden}
  end
end
