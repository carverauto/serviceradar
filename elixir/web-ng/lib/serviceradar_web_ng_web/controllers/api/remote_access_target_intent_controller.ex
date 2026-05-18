defmodule ServiceRadarWebNGWeb.Api.RemoteAccessTargetIntentController do
  @moduledoc """
  Authenticated API for registered application and TCP remote-access intents.
  """

  use ServiceRadarWebNGWeb, :controller

  alias ServiceRadar.Edge.RemoteAccessSession
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.FeatureFlags

  action_fallback ServiceRadarWebNGWeb.Api.FallbackController

  @app_permission "devices.remote_access.app.open"
  @tcp_permission "devices.remote_access.tcp.open"

  @browser_controlled_fields ~w(
    agent_id
    allowed_methods
    allowed_path_prefixes
    approval_required
    approval_policy
    ca_bundle_ref
    credential
    credential_custody_mode
    credential_mode
    credential_rule_id
    credentials
    enhanced_recording_policy
    gateway_id
    host
    host_header
    http_headers
    max_request_bytes
    max_response_bytes
    metadata
    passphrase
    password
    path_prefixes
    principal_mappings
    private_key
    quota
    recording
    recording_policy
    request_headers
    route
    route_id
    secret
    secret_payload
    sni
    target_host
    target_port
    ticket
    tls
    tls_server_name
    token
    upstream_host
    upstream_port
    upstream_url
    url
  )

  def create_app(conn, params) do
    create_registered_target_session(conn, params, %{
      adapter: "application",
      disabled_error: :remote_access_app_disabled,
      permission: @app_permission,
      protocol: "app",
      target_kind: "registered_application_target"
    })
  end

  def create_tcp(conn, params) do
    create_registered_target_session(conn, params, %{
      adapter: "tcp",
      disabled_error: :remote_access_tcp_disabled,
      permission: @tcp_permission,
      protocol: "tcp",
      target_kind: "registered_tcp_target"
    })
  end

  defp create_registered_target_session(conn, params, config) do
    with :ok <- require_feature_enabled(config.disabled_error),
         :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, config.permission),
         {:ok, request} <- normalize_target_intent(params, config),
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

      {:error, :remote_access_app_disabled} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "not_found", message: "Application remote access is not enabled"})

      {:error, :remote_access_tcp_disabled} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "not_found", message: "TCP remote access is not enabled"})

      {:error, :forbidden} ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "forbidden", message: "Remote access permission is required"})

      {:error, reason}
      when reason in [
             :missing_agent_scope,
             :missing_remote_access_target,
             :remote_access_target_disabled,
             :unsupported_remote_access_protocol,
             :unsupported_remote_access_adapter,
             :unsupported_remote_access_target
           ] ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "remote_access_session_unavailable", message: format_reason(reason)})

      {:error, other} ->
        {:error, other}
    end
  end

  defp normalize_target_intent(params, config) when is_map(params) do
    with :ok <- reject_browser_controlled_fields(params),
         {:ok, target_id} <- normalize_uuid(Map.get(params, "target_id"), "target_id"),
         {:ok, approval_id} <- normalize_optional_uuid(Map.get(params, "approval_id"), "approval_id") do
      {:ok,
       %{
         target_id: target_id,
         device_uid: target_id,
         protocol: config.protocol,
         adapter: config.adapter,
         target_kind: config.target_kind,
         target_host: nil,
         target_port: nil,
         agent_id: nil,
         gateway_id: nil,
         credential_custody_mode: nil,
         credential_rule_id: nil,
         approval_required: nil,
         approval_id: approval_id,
         cols: nil,
         rows: nil,
         metadata: %{},
         recording_policy: %{},
         enhanced_recording_policy: %{}
       }}
    end
  end

  defp normalize_target_intent(_params, _config), do: {:error, :invalid_request, "request body is required"}

  defp reject_browser_controlled_fields(params) do
    case Enum.find(@browser_controlled_fields, &Map.has_key?(params, &1)) do
      nil -> :ok
      field -> {:error, :invalid_request, "#{field} is selected by remote-access target policy"}
    end
  end

  defp normalize_uuid(value, field_name) when is_binary(value) do
    trimmed = String.trim(value)

    case Ecto.UUID.cast(trimmed) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_request, "#{field_name} must be a valid UUID"}
    end
  end

  defp normalize_uuid(_value, field_name), do: {:error, :invalid_request, "#{field_name} is required"}

  defp normalize_optional_uuid(nil, _field_name), do: {:ok, nil}

  defp normalize_optional_uuid(value, field_name) when is_binary(value) do
    case String.trim(value) do
      "" -> {:ok, nil}
      trimmed -> normalize_uuid(trimmed, field_name)
    end
  end

  defp normalize_optional_uuid(_value, field_name), do: {:error, :invalid_request, "#{field_name} must be a valid UUID"}

  defp session_json(session, ticket) do
    %{
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
      updated_at: format_value(session.updated_at),
      ticket: ticket
    }
  end

  defp format_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp format_value(value) when is_atom(value), do: Atom.to_string(value)
  defp format_value(value), do: value

  defp format_reason(:missing_agent_scope), do: "target has no selected edge agent for remote-access routing"
  defp format_reason(:missing_remote_access_target), do: "target host could not be resolved for remote access"
  defp format_reason(:remote_access_target_disabled), do: "remote-access target is disabled"
  defp format_reason(:unsupported_remote_access_protocol), do: "requested remote-access protocol is not supported"
  defp format_reason(:unsupported_remote_access_adapter), do: "requested remote-access adapter is not supported"
  defp format_reason(:unsupported_remote_access_target), do: "requested remote-access target is not supported"
  defp format_reason(reason), do: Atom.to_string(reason)

  defp require_feature_enabled(:remote_access_app_disabled) do
    if FeatureFlags.remote_access_app_enabled?(), do: :ok, else: {:error, :remote_access_app_disabled}
  end

  defp require_feature_enabled(:remote_access_tcp_disabled) do
    if FeatureFlags.remote_access_tcp_enabled?(), do: :ok, else: {:error, :remote_access_tcp_disabled}
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

  defp remote_access_session_manager do
    Application.get_env(
      :serviceradar_web_ng,
      :remote_access_session_manager,
      ServiceRadar.Edge.RemoteAccessSessions
    )
  end

  defp get_scope(conn), do: conn.assigns[:current_scope]
end
