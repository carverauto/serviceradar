defmodule ServiceRadarWebNGWeb.Api.RemoteAccessSessionController do
  @moduledoc """
  Authenticated API for issuing generic remote-access session tickets.
  """

  use ServiceRadarWebNGWeb, :controller

  alias ServiceRadar.Edge.RemoteAccessSession
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.RBAC

  action_fallback ServiceRadarWebNGWeb.Api.FallbackController

  @remote_access_permission "devices.remote_access.ssh.open"

  def create(conn, params) do
    with :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, @remote_access_permission),
         {:ok, request} <- normalize_create_request(params),
         {:ok, %{session: %RemoteAccessSession{} = session, ticket: ticket}} <-
           remote_access_session_manager().request_open(request.device_uid, request, scope: get_scope(conn)) do
      conn
      |> put_status(:created)
      |> json(%{data: session_json(session, ticket)})
    else
      {:error, :invalid_request, message} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid_request", message: message})

      {:error, :forbidden} ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "forbidden", message: "Remote access permission is required"})

      {:error, :approval_required} ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "approval_required", message: "Remote access approval is required"})

      {:error, :approval_denied} ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "approval_denied", message: "Remote access approval was denied"})

      {:error, reason} when reason in [:device_not_found, :not_found] ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "remote_access_session_not_found", message: "remote access target was not found"})

      {:error, reason}
      when reason in [
             :missing_agent_scope,
             :missing_remote_access_target,
             :unsupported_remote_access_protocol,
             :unsupported_remote_access_adapter,
             :unsupported_remote_access_target,
             :unsupported_credential_custody_mode
           ] ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "remote_access_session_unavailable", message: format_reason(reason)})

      {:error, other} ->
        {:error, other}
    end
  end

  def show(conn, %{"id" => id}) do
    with :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, @remote_access_permission),
         {:ok, normalized_id} <- normalize_uuid(id, "id"),
         {:ok, %RemoteAccessSession{} = session} <-
           RemoteAccessSession.get_by_id(normalized_id, scope: get_scope(conn)) do
      json(conn, %{data: session_json(session)})
    else
      {:error, :invalid_request, message} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid_request", message: message})

      {:ok, nil} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "remote_access_session_not_found", message: "remote access session was not found"})

      {:error, %Ash.Error.Query.NotFound{}} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "remote_access_session_not_found", message: "remote access session was not found"})

      {:error, other} ->
        {:error, other}
    end
  end

  def close(conn, %{"id" => id} = params) do
    with :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, @remote_access_permission),
         {:ok, normalized_id} <- normalize_uuid(id, "id"),
         {:ok, %RemoteAccessSession{} = session} <-
           remote_access_session_manager().request_close(normalized_id,
             reason: normalize_optional_string(Map.get(params, "reason")),
             scope: get_scope(conn)
           ) do
      json(conn, %{data: session_json(session)})
    else
      {:error, :invalid_request, message} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid_request", message: message})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "remote_access_session_not_found", message: "remote access session was not found"})

      {:error, other} ->
        {:error, other}
    end
  end

  defp normalize_create_request(params) when is_map(params) do
    with {:ok, device_uid} <- normalize_required_string(Map.get(params, "device_uid"), "device_uid") do
      terminal = Map.get(params, "terminal") || %{}

      {:ok,
       %{
         device_uid: device_uid,
         protocol: normalize_optional_string(Map.get(params, "protocol")),
         adapter: normalize_optional_string(Map.get(params, "adapter")),
         target_kind: normalize_optional_string(Map.get(params, "target_kind")),
         target_host: normalize_optional_string(Map.get(params, "target_host")),
         target_port: Map.get(params, "target_port"),
         agent_id: normalize_optional_string(Map.get(params, "agent_id")),
         gateway_id: normalize_optional_string(Map.get(params, "gateway_id")),
         credential_custody_mode: normalize_optional_string(Map.get(params, "credential_custody_mode")),
         credential_rule_id: normalize_optional_string(Map.get(params, "credential_rule_id")),
         approval_required: Map.get(params, "approval_required"),
         approval_id: normalize_optional_string(Map.get(params, "approval_id")),
         cols: Map.get(terminal, "cols"),
         rows: Map.get(terminal, "rows"),
         metadata: normalize_metadata(Map.get(params, "metadata")),
         recording_policy: normalize_metadata(Map.get(params, "recording_policy")),
         enhanced_recording_policy: normalize_metadata(Map.get(params, "enhanced_recording_policy"))
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

  defp normalize_required_string(value, field_name) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, :invalid_request, "#{field_name} is required"}
      trimmed -> {:ok, trimmed}
    end
  end

  defp normalize_required_string(_value, field_name), do: {:error, :invalid_request, "#{field_name} is required"}

  defp normalize_optional_string(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_optional_string(_value), do: nil

  defp normalize_metadata(value) when is_map(value), do: value
  defp normalize_metadata(_value), do: %{}

  defp session_json(session, ticket \\ nil) do
    data = %{
      id: session.id,
      device_uid: session.device_uid,
      target_kind: format_value(session.target_kind),
      target_host: session.target_host,
      target_port: session.target_port,
      protocol: format_value(session.protocol),
      adapter: format_value(session.adapter),
      agent_id: session.agent_id,
      gateway_id: session.gateway_id,
      credential_custody_mode: format_value(session.credential_custody_mode),
      credential_rule_id: session.credential_rule_id,
      approval_id: session.approval_id,
      rbac_decision: format_value(session.rbac_decision),
      status: format_value(session.status),
      outcome: format_value(session.outcome),
      attach_expires_at: format_value(session.attach_expires_at),
      idle_timeout_seconds: session.idle_timeout_seconds,
      absolute_timeout_seconds: session.absolute_timeout_seconds,
      websocket_path: "/v1/remote-access/sessions/#{session.id}/stream",
      close_reason: session.close_reason,
      failure_reason: session.failure_reason,
      inserted_at: format_value(session.inserted_at),
      updated_at: format_value(session.updated_at)
    }

    if is_binary(ticket), do: Map.put(data, :ticket, ticket), else: data
  end

  defp format_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp format_value(value) when is_atom(value), do: Atom.to_string(value)
  defp format_value(value), do: value

  defp format_reason(:missing_agent_scope), do: "target has no selected edge agent for remote-access routing"
  defp format_reason(:missing_remote_access_target), do: "target host could not be resolved for remote access"
  defp format_reason(:unsupported_remote_access_protocol), do: "requested remote-access protocol is not supported"
  defp format_reason(:unsupported_remote_access_adapter), do: "requested remote-access adapter is not supported"
  defp format_reason(:unsupported_remote_access_target), do: "requested remote-access target is not supported"
  defp format_reason(:unsupported_credential_custody_mode), do: "requested credential custody mode is not supported"
  defp format_reason(reason), do: Atom.to_string(reason)

  defp remote_access_session_manager do
    Application.get_env(
      :serviceradar_web_ng,
      :remote_access_session_manager,
      ServiceRadar.Edge.RemoteAccessSessions
    )
  end

  defp get_scope(conn), do: conn.assigns[:current_scope]

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
