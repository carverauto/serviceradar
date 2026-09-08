defmodule ServiceRadarWebNGWeb.Api.RemoteAccessDesktopTargetController do
  @moduledoc """
  Authenticated API for authorized desktop remote-access targets.
  """

  use ServiceRadarWebNGWeb, :controller

  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNG.RemoteAccessDesktopTargets
  alias ServiceRadarWebNGWeb.FeatureFlags

  action_fallback ServiceRadarWebNGWeb.Api.FallbackController

  @remote_desktop_permission "devices.remote_access.rdp.open"
  @manage_permission "settings.edge.manage"
  @credential_modes ~w(domain_delegation smart_card certificate user_present centrally_brokered)
  @target_kinds ~w(inventory_device freeform_target)
  @max_port 65_535

  def index(conn, _params) do
    with :ok <- require_remote_desktop_enabled(),
         :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, @remote_desktop_permission),
         {:ok, targets} <- RemoteAccessDesktopTargets.list_authorized(get_scope(conn)) do
      json(conn, %{data: targets})
    else
      {:error, :remote_access_desktop_rdp_disabled} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "not_found", message: "RDP remote access is not enabled"})

      {:error, :forbidden} ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "forbidden", message: "RDP remote access permission is required"})

      {:error, other} ->
        {:error, other}
    end
  end

  def admin_index(conn, _params) do
    with :ok <- require_remote_desktop_enabled(),
         :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, @manage_permission),
         {:ok, targets} <- RemoteAccessDesktopTargets.list_managed(get_scope(conn)) do
      json(conn, %{data: Enum.map(targets, &admin_target_json/1)})
    else
      {:error, :remote_access_desktop_rdp_disabled} ->
        disabled(conn)

      {:error, :forbidden} ->
        forbidden(conn, "RDP desktop target management permission is required")

      {:error, other} ->
        {:error, other}
    end
  end

  def admin_show(conn, %{"id" => id}) do
    with :ok <- require_remote_desktop_enabled(),
         :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, @manage_permission),
         {:ok, target} <- fetch_managed_target(conn, id) do
      json(conn, %{data: admin_target_json(target)})
    else
      {:error, :remote_access_desktop_rdp_disabled} ->
        disabled(conn)

      {:error, :forbidden} ->
        forbidden(conn, "RDP desktop target management permission is required")

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "desktop_target_not_found"})

      {:error, :invalid_request, message} ->
        conn |> put_status(:bad_request) |> json(%{error: "invalid_request", message: message})

      {:error, other} ->
        {:error, other}
    end
  end

  def admin_create(conn, params) do
    with :ok <- require_remote_desktop_enabled(),
         :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, @manage_permission),
         {:ok, attrs} <- normalize_create_attrs(params),
         {:ok, target} <- RemoteAccessDesktopTargets.create_managed(get_scope(conn), attrs) do
      conn
      |> put_status(:created)
      |> json(%{data: admin_target_json(target)})
    else
      {:error, :remote_access_desktop_rdp_disabled} ->
        disabled(conn)

      {:error, :forbidden} ->
        forbidden(conn, "RDP desktop target management permission is required")

      {:error, :invalid_request, message} ->
        conn |> put_status(:bad_request) |> json(%{error: "invalid_request", message: message})

      {:error, other} ->
        {:error, other}
    end
  end

  def admin_update(conn, %{"id" => id} = params) do
    with :ok <- require_remote_desktop_enabled(),
         :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, @manage_permission),
         {:ok, target} <- fetch_managed_target(conn, id),
         {:ok, attrs} <- normalize_update_attrs(params),
         {:ok, target} <- RemoteAccessDesktopTargets.update_managed(get_scope(conn), target, attrs) do
      json(conn, %{data: admin_target_json(target)})
    else
      {:error, :remote_access_desktop_rdp_disabled} ->
        disabled(conn)

      {:error, :forbidden} ->
        forbidden(conn, "RDP desktop target management permission is required")

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "desktop_target_not_found"})

      {:error, :invalid_request, message} ->
        conn |> put_status(:bad_request) |> json(%{error: "invalid_request", message: message})

      {:error, other} ->
        {:error, other}
    end
  end

  def admin_enable(conn, %{"id" => id}), do: set_admin_enabled(conn, id, true)

  def admin_disable(conn, %{"id" => id}), do: set_admin_enabled(conn, id, false)

  defp set_admin_enabled(conn, id, enabled) do
    with :ok <- require_remote_desktop_enabled(),
         :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, @manage_permission),
         {:ok, target} <- fetch_managed_target(conn, id),
         {:ok, target} <- RemoteAccessDesktopTargets.set_managed_enabled(get_scope(conn), target, enabled) do
      json(conn, %{data: admin_target_json(target)})
    else
      {:error, :remote_access_desktop_rdp_disabled} ->
        disabled(conn)

      {:error, :forbidden} ->
        forbidden(conn, "RDP desktop target management permission is required")

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "desktop_target_not_found"})

      {:error, :invalid_request, message} ->
        conn |> put_status(:bad_request) |> json(%{error: "invalid_request", message: message})

      {:error, other} ->
        {:error, other}
    end
  end

  defp require_remote_desktop_enabled do
    if FeatureFlags.remote_access_desktop_rdp_enabled?() do
      :ok
    else
      {:error, :remote_access_desktop_rdp_disabled}
    end
  end

  defp get_scope(conn), do: conn.assigns[:current_scope]

  defp fetch_managed_target(conn, id) do
    with {:ok, id} <- normalize_uuid_param(id, "id"),
         {:ok, target} <- RemoteAccessDesktopTargets.get_managed(get_scope(conn), id) do
      case target do
        nil -> {:error, :not_found}
        target -> {:ok, target}
      end
    end
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

  defp normalize_create_attrs(params) do
    with {:ok, name} <- required_string(params, "name"),
         {:ok, device_uid} <- required_string(params, "device_uid"),
         {:ok, target_host} <- required_string(params, "target_host"),
         {:ok, target_port} <- normalize_optional_port(Map.get(params, "target_port"), "target_port"),
         {:ok, target_kind} <- normalize_optional_enum(Map.get(params, "target_kind"), @target_kinds, "target_kind"),
         {:ok, credential_mode} <-
           normalize_optional_enum(
             Map.get(params, "credential_custody_mode"),
             @credential_modes,
             "credential_custody_mode"
           ),
         {:ok, credential_rule_id} <- normalize_optional_uuid(Map.get(params, "credential_rule_id"), "credential_rule_id"),
         {:ok, allowed_principals} <- normalize_string_list(Map.get(params, "allowed_principals")),
         {:ok, target_tls} <- normalize_optional_map(Map.get(params, "target_tls"), "target_tls"),
         {:ok, nla} <- normalize_optional_map(Map.get(params, "nla"), "nla"),
         {:ok, screen_policy} <- normalize_optional_map(Map.get(params, "screen_policy"), "screen_policy"),
         {:ok, redirection_policy} <-
           normalize_optional_map(Map.get(params, "redirection_policy"), "redirection_policy"),
         {:ok, recording_policy} <- normalize_optional_map(Map.get(params, "recording_policy"), "recording_policy"),
         {:ok, metadata} <- normalize_optional_map(Map.get(params, "metadata"), "metadata") do
      attrs =
        %{
          name: name,
          device_uid: device_uid,
          target_host: target_host
        }
        |> maybe_put(:description, normalize_optional_string(Map.get(params, "description")))
        |> maybe_put(:enabled, normalize_optional_boolean(Map.get(params, "enabled")))
        |> maybe_put(:target_kind, target_kind)
        |> maybe_put(:target_port, target_port)
        |> maybe_put(:agent_id, normalize_optional_string(Map.get(params, "agent_id")))
        |> maybe_put(:gateway_id, normalize_optional_string(Map.get(params, "gateway_id")))
        |> maybe_put(:credential_custody_mode, credential_mode)
        |> maybe_put(:credential_rule_id, credential_rule_id)
        |> maybe_put(:approval_required, normalize_optional_boolean(Map.get(params, "approval_required")))
        |> maybe_put(:allowed_principals, allowed_principals)
        |> maybe_put(:target_tls, target_tls)
        |> maybe_put(:nla, nla)
        |> maybe_put(:screen_policy, screen_policy)
        |> maybe_put(:redirection_policy, redirection_policy)
        |> maybe_put(:recording_policy, recording_policy)
        |> maybe_put(:metadata, metadata)

      {:ok, attrs}
    end
  end

  defp normalize_update_attrs(params) do
    with {:ok, target_port} <- normalize_optional_port(Map.get(params, "target_port"), "target_port"),
         {:ok, target_kind} <- normalize_optional_enum(Map.get(params, "target_kind"), @target_kinds, "target_kind"),
         {:ok, credential_mode} <-
           normalize_optional_enum(
             Map.get(params, "credential_custody_mode"),
             @credential_modes,
             "credential_custody_mode"
           ),
         {:ok, credential_rule_id} <- normalize_optional_uuid(Map.get(params, "credential_rule_id"), "credential_rule_id"),
         {:ok, allowed_principals} <- maybe_normalize_string_list(Map.get(params, "allowed_principals")),
         {:ok, target_tls} <- normalize_optional_map(Map.get(params, "target_tls"), "target_tls"),
         {:ok, nla} <- normalize_optional_map(Map.get(params, "nla"), "nla"),
         {:ok, screen_policy} <- normalize_optional_map(Map.get(params, "screen_policy"), "screen_policy"),
         {:ok, redirection_policy} <-
           normalize_optional_map(Map.get(params, "redirection_policy"), "redirection_policy"),
         {:ok, recording_policy} <- normalize_optional_map(Map.get(params, "recording_policy"), "recording_policy"),
         {:ok, metadata} <- normalize_optional_map(Map.get(params, "metadata"), "metadata") do
      attrs =
        %{}
        |> maybe_put(:name, normalize_optional_string(Map.get(params, "name")))
        |> maybe_put(:description, normalize_optional_string(Map.get(params, "description")))
        |> maybe_put(:enabled, normalize_optional_boolean(Map.get(params, "enabled")))
        |> maybe_put(:device_uid, normalize_optional_string(Map.get(params, "device_uid")))
        |> maybe_put(:target_kind, target_kind)
        |> maybe_put(:target_host, normalize_optional_string(Map.get(params, "target_host")))
        |> maybe_put(:target_port, target_port)
        |> maybe_put(:agent_id, normalize_optional_string(Map.get(params, "agent_id")))
        |> maybe_put(:gateway_id, normalize_optional_string(Map.get(params, "gateway_id")))
        |> maybe_put(:credential_custody_mode, credential_mode)
        |> maybe_put(:credential_rule_id, credential_rule_id)
        |> maybe_put(:approval_required, normalize_optional_boolean(Map.get(params, "approval_required")))
        |> maybe_put(:allowed_principals, allowed_principals)
        |> maybe_put(:target_tls, target_tls)
        |> maybe_put(:nla, nla)
        |> maybe_put(:screen_policy, screen_policy)
        |> maybe_put(:redirection_policy, redirection_policy)
        |> maybe_put(:recording_policy, recording_policy)
        |> maybe_put(:metadata, metadata)

      {:ok, attrs}
    end
  end

  defp required_string(params, key) do
    case normalize_optional_string(Map.get(params, key)) do
      nil -> {:error, :invalid_request, "#{key} is required"}
      value -> {:ok, value}
    end
  end

  defp normalize_optional_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalize_optional_string(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_optional_string(_value), do: nil

  defp normalize_optional_port(nil, _field), do: {:ok, nil}

  defp normalize_optional_port(value, field) do
    case normalize_integer(value) do
      port when is_integer(port) and port in 1..@max_port -> {:ok, port}
      _ -> {:error, :invalid_request, "#{field} must be an integer from 1 to #{@max_port}"}
    end
  end

  defp normalize_integer(value) when is_integer(value), do: value

  defp normalize_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} -> integer
      _ -> nil
    end
  end

  defp normalize_integer(_value), do: nil

  defp normalize_optional_enum(nil, _allowed, _field), do: {:ok, nil}

  defp normalize_optional_enum(value, allowed, field) do
    value = normalize_optional_string(value)

    if value in allowed do
      {:ok, String.to_existing_atom(value)}
    else
      {:error, :invalid_request, "#{field} must be one of #{Enum.join(allowed, ", ")}"}
    end
  end

  defp normalize_optional_uuid(nil, _field), do: {:ok, nil}

  defp normalize_optional_uuid(value, field) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_request, "#{field} must be a valid UUID"}
    end
  end

  defp normalize_uuid_param(value, field), do: normalize_optional_uuid(value, field)

  defp normalize_string_list(nil), do: {:ok, []}

  defp normalize_string_list(value) when is_list(value) do
    value =
      value
      |> Enum.map(&normalize_optional_string/1)
      |> Enum.reject(&is_nil/1)

    {:ok, value}
  end

  defp normalize_string_list(_value), do: {:error, :invalid_request, "allowed_principals must be a list"}

  defp maybe_normalize_string_list(nil), do: {:ok, nil}
  defp maybe_normalize_string_list(value), do: normalize_string_list(value)

  defp normalize_optional_map(nil, _field), do: {:ok, nil}
  defp normalize_optional_map(value, _field) when is_map(value), do: {:ok, value}
  defp normalize_optional_map(_value, field), do: {:error, :invalid_request, "#{field} must be an object"}

  defp normalize_optional_boolean(value, default \\ nil)
  defp normalize_optional_boolean(nil, default), do: default
  defp normalize_optional_boolean(value, _default) when is_boolean(value), do: value
  defp normalize_optional_boolean(value, _default) when value in ["true", "1", "yes", "on"], do: true
  defp normalize_optional_boolean(value, _default) when value in ["false", "0", "no", "off"], do: false
  defp normalize_optional_boolean(_value, default), do: default

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp admin_target_json(target) do
    %{
      id: target.id,
      name: target.name,
      description: target.description,
      enabled: target.enabled,
      protocol: to_string(target.protocol),
      target_kind: to_string(target.target_kind),
      device_uid: target.device_uid,
      target_host: target.target_host,
      target_port: target.target_port,
      agent_id: target.agent_id,
      gateway_id: target.gateway_id,
      credential_custody_mode: to_string(target.credential_custody_mode),
      credential_rule_id: target.credential_rule_id,
      approval_required: target.approval_required,
      allowed_principals: target.allowed_principals || [],
      target_tls: target.target_tls || %{},
      nla: target.nla || %{},
      screen_policy: target.screen_policy || %{},
      redirection_policy: target.redirection_policy || %{},
      recording_policy: target.recording_policy || %{},
      metadata: target.metadata || %{},
      inserted_at: DateTime.to_iso8601(target.inserted_at),
      updated_at: DateTime.to_iso8601(target.updated_at)
    }
  end

  defp disabled(conn) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "not_found", message: "RDP remote access is not enabled"})
  end

  defp forbidden(conn, message) do
    conn
    |> put_status(:forbidden)
    |> json(%{error: "forbidden", message: message})
  end
end
