defmodule ServiceRadarWebNGWeb.Api.RemoteAccessHostKeyController do
  @moduledoc """
  Authenticated API for remote-access SSH host-key trust management.
  """

  use ServiceRadarWebNGWeb, :controller

  alias ServiceRadar.Edge.RemoteAccessHostKey
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.RBAC

  action_fallback(ServiceRadarWebNGWeb.Api.FallbackController)

  @manage_permission "settings.remote_access_host_keys.manage"

  def index(conn, params) do
    with :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, @manage_permission),
         {:ok, host_keys} <- host_key_manager().list(filters(params), scope: get_scope(conn)) do
      json(conn, %{data: Enum.map(host_keys, &host_key_json/1)})
    else
      {:error, :forbidden} ->
        forbidden(conn)

      {:error, other} ->
        {:error, other}
    end
  end

  def observe(conn, params) do
    with :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, @manage_permission),
         {:ok, result} <-
           host_key_manager().observe(params,
             scope: get_scope(conn),
             audit_writer: audit_writer()
           ) do
      conn
      |> put_status(:created)
      |> json(%{
        data: host_key_json(result.host_key),
        decision: Atom.to_string(result.decision),
        conflict_with: result.conflict_with
      })
    else
      {:error, :forbidden} ->
        forbidden(conn)

      {:error, reason}
      when reason in [:invalid_target_port, :unsupported_protocol, :unsupported_source] ->
        invalid_request(conn, Atom.to_string(reason))

      {:error, {:missing_required, field}} ->
        invalid_request(conn, "#{field} is required")

      {:error, other} ->
        {:error, other}
    end
  end

  def trust(conn, %{"id" => id}) do
    transition(conn, id, :trust, [])
  end

  def revoke(conn, %{"id" => id} = params) do
    transition(conn, id, :revoke, reason: params["reason"])
  end

  def reject(conn, %{"id" => id} = params) do
    transition(conn, id, :reject, reason: params["reason"])
  end

  def rotate(conn, %{"id" => id, "replacement_host_key_id" => replacement_id} = params) do
    with :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, @manage_permission),
         {:ok, result} <-
           host_key_manager().rotate(id, replacement_id,
             scope: get_scope(conn),
             reason: params["reason"],
             audit_writer: audit_writer()
           ) do
      json(conn, %{
        data: %{rotated: host_key_json(result.rotated), trusted: host_key_json(result.trusted)}
      })
    else
      {:error, :forbidden} ->
        forbidden(conn)

      {:error, :not_found} ->
        not_found(conn)

      {:error, :host_key_target_mismatch} ->
        invalid_request(conn, "replacement_host_key_id must reference the same target")

      {:error, :host_key_conflict_requires_rotation} ->
        invalid_request(conn, "conflict host keys must be accepted through rotation")

      {:error, other} ->
        {:error, other}
    end
  end

  def rotate(conn, _params), do: invalid_request(conn, "replacement_host_key_id is required")

  defp transition(conn, id, action, opts) do
    with :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, @manage_permission),
         {:ok, %RemoteAccessHostKey{} = host_key} <-
           apply(host_key_manager(), action, [
             id,
             Keyword.merge(List.wrap(opts), scope: get_scope(conn), audit_writer: audit_writer())
           ]) do
      json(conn, %{data: host_key_json(host_key)})
    else
      {:error, :forbidden} ->
        forbidden(conn)

      {:error, :not_found} ->
        not_found(conn)

      {:error, :host_key_conflict_requires_rotation} ->
        invalid_request(conn, "conflict host keys must be accepted through rotation")

      {:error, :host_key_rejected} ->
        invalid_request(conn, "rejected host keys cannot be trusted")

      {:error, other} ->
        {:error, other}
    end
  end

  defp filters(params) do
    params
    |> Map.take(["agent_id", "device_uid", "target_host", "status"])
    |> Map.reject(fn {_key, value} -> blank?(value) end)
  end

  defp host_key_json(%RemoteAccessHostKey{} = host_key) do
    %{
      id: host_key.id,
      device_uid: host_key.device_uid,
      target_host: host_key.target_host,
      target_port: host_key.target_port,
      protocol: format_value(host_key.protocol),
      agent_id: host_key.agent_id,
      gateway_id: host_key.gateway_id,
      key_type: host_key.key_type,
      fingerprint_sha256: host_key.fingerprint_sha256,
      status: format_value(host_key.status),
      source: format_value(host_key.source),
      first_seen_at: format_value(host_key.first_seen_at),
      last_seen_at: format_value(host_key.last_seen_at),
      seen_count: host_key.seen_count,
      trusted_at: format_value(host_key.trusted_at),
      trusted_by: host_key.trusted_by,
      revoked_at: format_value(host_key.revoked_at),
      revoked_by: host_key.revoked_by,
      revocation_reason: host_key.revocation_reason,
      rejected_at: format_value(host_key.rejected_at),
      rejected_by: host_key.rejected_by,
      rejection_reason: host_key.rejection_reason,
      rotated_at: format_value(host_key.rotated_at),
      rotated_by: host_key.rotated_by,
      replacement_host_key_id: host_key.replacement_host_key_id,
      supersedes_host_key_id: host_key.supersedes_host_key_id,
      rotation_reason: host_key.rotation_reason,
      metadata: host_key.metadata || %{}
    }
  end

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(nil), do: true
  defp blank?(_value), do: false

  defp invalid_request(conn, message) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "invalid_request", message: message})
  end

  defp forbidden(conn) do
    conn
    |> put_status(:forbidden)
    |> json(%{
      error: "forbidden",
      message: "Remote-access host-key management permission is required"
    })
  end

  defp not_found(conn) do
    conn
    |> put_status(:not_found)
    |> json(%{
      error: "remote_access_host_key_not_found",
      message: "remote-access host key was not found"
    })
  end

  defp format_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp format_value(value) when is_atom(value), do: Atom.to_string(value)
  defp format_value(value), do: value

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

  defp host_key_manager do
    Application.get_env(
      :serviceradar_web_ng,
      :remote_access_host_key_manager,
      ServiceRadar.Edge.RemoteAccessHostKeys
    )
  end

  defp audit_writer do
    Application.get_env(
      :serviceradar_web_ng,
      :remote_access_host_key_audit_writer,
      ServiceRadar.Events.AuditWriter
    )
  end
end
