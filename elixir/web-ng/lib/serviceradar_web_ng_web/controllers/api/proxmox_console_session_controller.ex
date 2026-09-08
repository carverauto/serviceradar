defmodule ServiceRadarWebNGWeb.Api.ProxmoxConsoleSessionController do
  @moduledoc """
  Authenticated API for issuing short-lived Proxmox console session tickets.
  """

  use ServiceRadarWebNGWeb, :controller

  alias ServiceRadar.Edge.ProxmoxConsoleSession
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.RBAC

  action_fallback ServiceRadarWebNGWeb.Api.FallbackController

  @console_permissions ["devices.console.open", "devices.console.credentials.use"]
  @create_request_fields MapSet.new(["device_uid", "terminal"])
  @terminal_fields MapSet.new(["cols", "rows"])

  def create(conn, params) do
    with :ok <- require_authenticated(conn),
         :ok <- require_permissions(conn),
         {:ok, request} <- normalize_create_request(params),
         {:ok, %{session: %ProxmoxConsoleSession{} = session, ticket: ticket}} <-
           console_session_manager().request_open(request.device_uid, request, scope: get_scope(conn)) do
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
        |> json(%{error: "forbidden", message: "Proxmox console permission is required"})

      {:error, reason} when reason in [:device_not_found, :not_found] ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "console_session_not_found", message: "console session target was not found"})

      {:error, reason}
      when reason in [
             :unsupported_console_target,
             :unsupported_console_mode,
             :no_console_credential_rule,
             :not_console_credential_rule,
             :credential_rule_scope_denied,
             :credential_rule_target_denied,
             :ambiguous_console_target,
             :console_inventory_unavailable,
             :console_controller_not_found,
             :console_controller_endpoint_missing,
             :controller_origin_mismatch,
             :invalid_controller_origin,
             :console_assignment_unavailable,
             :ambiguous_console_assignment,
             :credential_use_policy_missing,
             :credential_use_policy_invalid,
             :credential_use_policy_denied,
             :missing_agent_scope
           ] ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "console_session_unavailable", message: format_reason(reason)})

      {:error, other} ->
        {:error, other}
    end
  end

  def show(conn, %{"id" => id}) do
    with :ok <- require_authenticated(conn),
         :ok <- require_permissions(conn),
         {:ok, normalized_id} <- normalize_uuid(id, "id"),
         {:ok, %ProxmoxConsoleSession{} = session} <-
           ProxmoxConsoleSession.get_by_id(normalized_id, scope: get_scope(conn)) do
      json(conn, %{data: session_json(session)})
    else
      {:error, :invalid_request, message} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid_request", message: message})

      {:ok, nil} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "console_session_not_found", message: "console session was not found"})

      {:error, %Ash.Error.Query.NotFound{}} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "console_session_not_found", message: "console session was not found"})

      {:error, other} ->
        {:error, other}
    end
  end

  def close(conn, %{"id" => id} = params) do
    with :ok <- require_authenticated(conn),
         :ok <- require_permissions(conn),
         {:ok, normalized_id} <- normalize_uuid(id, "id"),
         {:ok, %ProxmoxConsoleSession{} = session} <-
           console_session_manager().request_close(normalized_id,
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
        |> json(%{error: "console_session_not_found", message: "console session was not found"})

      {:error, other} ->
        {:error, other}
    end
  end

  defp normalize_create_request(params) when is_map(params) do
    with :ok <- validate_request_fields(params, @create_request_fields, "request body"),
         {:ok, device_uid} <- normalize_required_string(Map.get(params, "device_uid"), "device_uid"),
         {:ok, terminal} <- normalize_terminal(Map.get(params, "terminal")) do
      {:ok, %{device_uid: device_uid, cols: Map.get(terminal, "cols"), rows: Map.get(terminal, "rows")}}
    end
  end

  defp normalize_create_request(_params), do: {:error, :invalid_request, "request body is required"}

  defp normalize_terminal(nil), do: {:ok, %{}}

  defp normalize_terminal(terminal) when is_map(terminal) do
    with :ok <- validate_request_fields(terminal, @terminal_fields, "terminal"),
         {:ok, cols} <- optional_dimension(Map.get(terminal, "cols"), "terminal.cols", 500),
         {:ok, rows} <- optional_dimension(Map.get(terminal, "rows"), "terminal.rows", 200) do
      {:ok, %{"cols" => cols, "rows" => rows}}
    end
  end

  defp normalize_terminal(_terminal), do: {:error, :invalid_request, "terminal must be an object"}

  defp optional_dimension(nil, _field, _max), do: {:ok, nil}

  defp optional_dimension(value, _field, max) when is_integer(value) and value > 0 and value <= max, do: {:ok, value}

  defp optional_dimension(_value, field, max),
    do: {:error, :invalid_request, "#{field} must be an integer from 1 to #{max}"}

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

  defp validate_request_fields(params, allowed, label) do
    unknown = params |> Map.keys() |> MapSet.new() |> MapSet.difference(allowed) |> MapSet.to_list()

    case unknown do
      [] -> :ok
      fields -> {:error, :invalid_request, "#{label} contains unsupported fields: #{Enum.join(Enum.sort(fields), ", ")}"}
    end
  end

  defp session_json(session, ticket \\ nil) do
    data = %{
      id: session.id,
      device_uid: session.device_uid,
      target_kind: format_value(session.target_kind),
      console_mode: format_value(session.console_mode),
      agent_id: session.agent_id,
      gateway_id: session.gateway_id,
      credential_rule_id: session.credential_rule_id,
      status: format_value(session.status),
      ticket_expires_at: format_value(session.ticket_expires_at),
      idle_timeout_seconds: session.idle_timeout_seconds,
      absolute_timeout_seconds: session.absolute_timeout_seconds,
      websocket_path: "/v1/proxmox/console-sessions/#{session.id}/stream",
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

  defp format_reason(:unsupported_console_target), do: "device does not expose a Proxmox console target"
  defp format_reason(:unsupported_console_mode), do: "requested console mode is not supported for this target"
  defp format_reason(:no_console_credential_rule), do: "no scoped console credential rule matches this device"
  defp format_reason(:not_console_credential_rule), do: "credential rule is not a Proxmox console rule"
  defp format_reason(:credential_rule_scope_denied), do: "credential rule scope does not include this device"
  defp format_reason(:credential_rule_target_denied), do: "credential rule target query does not include this device"
  defp format_reason(:ambiguous_console_target), do: "console target identity is ambiguous"
  defp format_reason(:console_inventory_unavailable), do: "authoritative console inventory is unavailable"
  defp format_reason(:console_controller_not_found), do: "owning Proxmox controller was not found"
  defp format_reason(:console_controller_endpoint_missing), do: "owning Proxmox controller has no endpoint"

  defp format_reason(:controller_origin_mismatch),
    do: "configured Proxmox origin does not match its authoritative endpoint"

  defp format_reason(:invalid_controller_origin), do: "configured Proxmox origin is invalid"

  defp format_reason(:console_assignment_unavailable), do: "no active console assignment matches the credential and agent"

  defp format_reason(:ambiguous_console_assignment),
    do: "multiple active console assignments match the credential and agent"

  defp format_reason(:credential_use_policy_missing), do: "console credential has no actor-use policy"
  defp format_reason(:credential_use_policy_invalid), do: "console credential actor-use policy is invalid"
  defp format_reason(:credential_use_policy_denied), do: "console credential actor-use policy denied access"
  defp format_reason(:missing_agent_scope), do: "device has no assigned edge agent for console routing"
  defp format_reason(reason), do: Atom.to_string(reason)

  defp console_session_manager do
    Application.get_env(
      :serviceradar_web_ng,
      :proxmox_console_session_manager,
      ServiceRadar.Edge.ProxmoxConsoleSessions
    )
  end

  defp get_scope(conn), do: conn.assigns[:current_scope]

  defp require_authenticated(conn) do
    case conn.assigns[:current_scope] do
      %Scope{user: user} when not is_nil(user) -> :ok
      _ -> {:error, :unauthorized}
    end
  end

  defp require_permissions(conn) do
    scope = conn.assigns[:current_scope]

    if Enum.all?(@console_permissions, &RBAC.can?(scope, &1)),
      do: :ok,
      else: {:error, :forbidden}
  end
end
