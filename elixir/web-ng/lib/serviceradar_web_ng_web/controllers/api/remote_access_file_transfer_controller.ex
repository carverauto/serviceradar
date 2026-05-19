defmodule ServiceRadarWebNGWeb.Api.RemoteAccessFileTransferController do
  @moduledoc """
  Authenticated API for requesting policy-gated remote-access file transfers.
  """

  use ServiceRadarWebNGWeb, :controller

  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.RBAC

  action_fallback ServiceRadarWebNGWeb.Api.FallbackController

  @list_permission "devices.remote_access.files.list"
  @download_permission "devices.remote_access.files.download"
  @upload_permission "devices.remote_access.files.upload"
  @manage_permission "devices.remote_access.files.manage"

  @allowed_create_keys ~w(session_id operation direction path destination_path display_name)
  @read_operations ~w(list stat download)
  @manage_operations ~w(mkdir rename remove chmod chown)
  @operations @read_operations ++ ~w(upload) ++ @manage_operations
  @directions ~w(read write manage)
  @max_path_bytes 4_096
  @max_display_name_bytes 255

  def index(conn, params) do
    with :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, @list_permission),
         {:ok, session_id} <- normalize_uuid(Map.get(params, "session_id"), "session_id"),
         {:ok, transfers} <-
           remote_access_file_transfer_manager().list_transfers(session_id, scope: get_scope(conn)) do
      json(conn, %{data: Enum.map(transfers, &transfer_json/1)})
    else
      {:error, :invalid_request, message} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid_request", message: message})

      {:error, :forbidden} ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "forbidden", message: "Remote file-transfer permission is required"})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "remote_access_session_not_found", message: "remote access session was not found"})

      {:error, other} ->
        {:error, other}
    end
  end

  def create(conn, params) do
    manager = remote_access_file_transfer_manager()

    with :ok <- require_authenticated(conn),
         {:ok, request} <- normalize_create_request(params),
         :ok <- require_permission(conn, permission_for_operation(request.operation)),
         {:ok, transfer} <-
           manager.request_transfer(request.session_id, request, scope: get_scope(conn)) do
      conn
      |> put_status(:accepted)
      |> json(%{data: transfer_json(transfer)})
    else
      {:error, :invalid_request, message} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid_request", message: message})

      {:error, :forbidden} ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "forbidden", message: "Remote file-transfer permission is required"})

      {:error, :approval_required} ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "approval_required", message: "Remote file-transfer approval is required"})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "remote_access_session_not_found", message: "remote access session was not found"})

      {:error, :not_implemented} ->
        conn
        |> put_status(:not_implemented)
        |> json(%{error: "remote_access_file_transfer_unavailable", message: "remote file transfer is not available"})

      {:error, :remote_access_session_not_active} ->
        conn
        |> put_status(:conflict)
        |> json(%{error: "remote_access_session_not_active", message: "remote access session is not active"})

      {:error, reason} when reason in [:registry_unavailable, :agent_offline] ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{error: "remote_access_route_unavailable", message: "remote access route is unavailable"})

      {:error, {:agent_offline, _agent_id}} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{error: "remote_access_route_unavailable", message: "remote access route is unavailable"})

      {:error, reason} when reason in [:policy_denied, :quota_exhausted] ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: Atom.to_string(reason), message: format_reason(reason)})

      {:error, other} ->
        {:error, other}
    end
  end

  defp normalize_create_request(params) when is_map(params) do
    with :ok <- reject_unknown_create_keys(params),
         {:ok, session_id} <- normalize_uuid(Map.get(params, "session_id"), "session_id"),
         {:ok, operation} <- normalize_operation(Map.get(params, "operation")),
         {:ok, direction} <- normalize_direction(Map.get(params, "direction"), operation),
         {:ok, path} <- normalize_path(Map.get(params, "path"), "path"),
         {:ok, destination_path} <-
           normalize_destination_path(Map.get(params, "destination_path"), operation),
         {:ok, display_name} <- normalize_display_name(Map.get(params, "display_name")) do
      {:ok,
       %{
         session_id: session_id,
         operation: operation,
         direction: direction,
         path: path,
         destination_path: destination_path,
         display_name: display_name
       }}
    end
  end

  defp normalize_create_request(_params), do: {:error, :invalid_request, "request body is required"}

  defp reject_unknown_create_keys(params) do
    unknown =
      params
      |> Map.keys()
      |> Enum.map(&to_string/1)
      |> Enum.reject(&(&1 in @allowed_create_keys))

    case unknown do
      [] -> :ok
      [field | _] -> {:error, :invalid_request, "#{field} is selected by remote-access policy"}
    end
  end

  defp normalize_uuid(value, field_name) when is_binary(value) do
    case Ecto.UUID.cast(String.trim(value)) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_request, "#{field_name} must be a valid UUID"}
    end
  end

  defp normalize_uuid(_value, field_name), do: {:error, :invalid_request, "#{field_name} is required"}

  defp normalize_operation(value) when is_binary(value) do
    operation = String.trim(value)

    if operation in @operations do
      {:ok, operation}
    else
      {:error, :invalid_request, "operation is not supported"}
    end
  end

  defp normalize_operation(_value), do: {:error, :invalid_request, "operation is required"}

  defp normalize_direction(nil, operation), do: {:ok, direction_for_operation(operation)}

  defp normalize_direction(value, operation) when is_binary(value) do
    direction = String.trim(value)
    expected = direction_for_operation(operation)

    cond do
      direction not in @directions -> {:error, :invalid_request, "direction is not supported"}
      direction != expected -> {:error, :invalid_request, "direction does not match operation"}
      true -> {:ok, direction}
    end
  end

  defp normalize_direction(_value, _operation), do: {:error, :invalid_request, "direction is not supported"}

  defp normalize_path(value, field_name) when is_binary(value) do
    path = String.trim(value)

    cond do
      path == "" -> {:error, :invalid_request, "#{field_name} is required"}
      byte_size(path) > @max_path_bytes -> {:error, :invalid_request, "#{field_name} is too long"}
      path_has_control_byte?(path) -> {:error, :invalid_request, "#{field_name} contains control bytes"}
      not String.starts_with?(path, "/") -> {:error, :invalid_request, "#{field_name} must be absolute"}
      path_has_dot_segment?(path) -> {:error, :invalid_request, "#{field_name} contains unsafe path segments"}
      true -> {:ok, path}
    end
  end

  defp normalize_path(_value, field_name), do: {:error, :invalid_request, "#{field_name} is required"}

  defp path_has_control_byte?(path) do
    path
    |> :binary.bin_to_list()
    |> Enum.any?(&(&1 < 32 or &1 == 127))
  end

  defp path_has_dot_segment?(path) do
    path
    |> String.split("/", trim: true)
    |> Enum.any?(&(&1 in [".", ".."]))
  end

  defp normalize_destination_path(value, "rename"), do: normalize_path(value, "destination_path")

  defp normalize_destination_path(nil, _operation), do: {:ok, nil}

  defp normalize_destination_path(value, _operation) when is_binary(value) do
    normalize_path(value, "destination_path")
  end

  defp normalize_destination_path(_value, _operation), do: {:error, :invalid_request, "destination_path is not supported"}

  defp normalize_display_name(nil), do: {:ok, nil}

  defp normalize_display_name(value) when is_binary(value) do
    display_name = String.trim(value)

    cond do
      display_name == "" -> {:ok, nil}
      byte_size(display_name) > @max_display_name_bytes -> {:error, :invalid_request, "display_name is too long"}
      true -> {:ok, display_name}
    end
  end

  defp normalize_display_name(_value), do: {:error, :invalid_request, "display_name is not supported"}

  defp direction_for_operation(operation) when operation in @read_operations, do: "read"
  defp direction_for_operation("upload"), do: "write"
  defp direction_for_operation(operation) when operation in @manage_operations, do: "manage"

  defp permission_for_operation(operation) when operation in ~w(list stat), do: @list_permission
  defp permission_for_operation("download"), do: @download_permission
  defp permission_for_operation("upload"), do: @upload_permission
  defp permission_for_operation(operation) when operation in @manage_operations, do: @manage_permission

  defp transfer_json(transfer) when is_map(transfer) do
    %{
      id: map_value(transfer, :id),
      session_id: map_value(transfer, :session_id),
      operation: format_value(map_value(transfer, :operation)),
      direction: format_value(map_value(transfer, :direction)),
      status: format_value(map_value(transfer, :status)),
      redacted_path: map_value(transfer, :redacted_path),
      path_hash: map_value(transfer, :path_hash),
      inserted_at: format_value(map_value(transfer, :inserted_at))
    }
  end

  defp map_value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp format_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp format_value(value) when is_atom(value), do: Atom.to_string(value)
  defp format_value(value), do: value

  defp format_reason(:policy_denied), do: "remote file transfer was denied by policy"
  defp format_reason(:quota_exhausted), do: "remote file transfer quota was exhausted"

  defp remote_access_file_transfer_manager do
    Application.get_env(
      :serviceradar_web_ng,
      :remote_access_file_transfer_manager,
      ServiceRadar.Edge.RemoteAccessFileTransfers
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
