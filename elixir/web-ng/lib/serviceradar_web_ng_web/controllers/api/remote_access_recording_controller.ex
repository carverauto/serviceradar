defmodule ServiceRadarWebNGWeb.Api.RemoteAccessRecordingController do
  @moduledoc """
  Authenticated API for remote-access recording replay and export.
  """

  use ServiceRadarWebNGWeb, :controller

  alias ServiceRadar.Edge.RemoteAccessRecording
  alias ServiceRadar.Edge.RemoteAccessRecordingEvent
  alias ServiceRadar.Edge.RemoteAccessRecordings
  alias ServiceRadar.Edge.RemoteAccessSession
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.RBAC

  action_fallback(ServiceRadarWebNGWeb.Api.FallbackController)

  @ssh_open_permission "devices.remote_access.ssh.open"
  @rdp_open_permission "devices.remote_access.rdp.open"
  @view_permissions [@ssh_open_permission, @rdp_open_permission]
  @export_permission "devices.remote_access.recordings.export"
  @delete_permission "devices.remote_access.recordings.delete"
  @view_all_permission "devices.remote_access.recordings.view_all"

  def show(conn, %{"id" => id}) do
    with :ok <- require_authenticated(conn),
         :ok <- require_any_permission(conn, @view_permissions),
         {:ok, recording} <- fetch_recording(id, conn),
         :ok <- require_recording_view_permission(conn, recording) do
      json(conn, %{data: recording_json(recording)})
    else
      {:error, :forbidden} -> forbidden(conn, "remote access")
      {:error, :not_found} -> not_found(conn)
      {:error, :invalid_id} -> invalid_request(conn, "id must be a valid UUID")
      {:error, other} -> {:error, other}
    end
  end

  def events(conn, %{"id" => id}) do
    with :ok <- require_authenticated(conn),
         :ok <- require_any_permission(conn, @view_permissions),
         {:ok, recording} <- fetch_recording(id, conn),
         :ok <- require_recording_view_permission(conn, recording),
         {:ok, events} <- RemoteAccessRecordings.list_events(recording, scope: get_scope(conn)) do
      json(conn, %{data: Enum.map(events, &event_json/1)})
    else
      {:error, :forbidden} -> forbidden(conn, "remote access")
      {:error, :not_found} -> not_found(conn)
      {:error, :invalid_id} -> invalid_request(conn, "id must be a valid UUID")
      {:error, :recording_deleted} -> gone(conn)
      {:error, other} -> {:error, other}
    end
  end

  def export(conn, %{"id" => id}) do
    with :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, @export_permission),
         {:ok, recording} <- fetch_recording(id, conn),
         :ok <- require_recording_view_permission(conn, recording),
         {:ok, export} <-
           RemoteAccessRecordings.export(recording,
             scope: get_scope(conn),
             actor: get_scope(conn).user
           ) do
      json(conn, %{
        data: %{
          recording: recording_json(export.recording),
          manifest: public_manifest(export.manifest),
          events: Enum.map(export.events, &event_json/1)
        }
      })
    else
      {:error, :forbidden} -> forbidden(conn, @export_permission)
      {:error, :not_found} -> not_found(conn)
      {:error, :invalid_id} -> invalid_request(conn, "id must be a valid UUID")
      {:error, :recording_not_exportable} -> conflict(conn, "recording_not_exportable")
      {:error, :recording_deleted} -> gone(conn)
      {:error, other} -> {:error, other}
    end
  end

  def delete(conn, %{"id" => id}) do
    with :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, @delete_permission),
         {:ok, recording} <- fetch_recording(id, conn),
         :ok <- require_recording_view_permission(conn, recording),
         {:ok, _deleted} <-
           RemoteAccessRecordings.delete(recording,
             scope: get_scope(conn),
             actor: get_scope(conn).user
           ) do
      send_resp(conn, :no_content, "")
    else
      {:error, :forbidden} -> forbidden(conn, @delete_permission)
      {:error, :not_found} -> not_found(conn)
      {:error, :invalid_id} -> invalid_request(conn, "id must be a valid UUID")
      {:error, other} -> {:error, other}
    end
  end

  defp fetch_recording(id, conn) do
    with {:ok, normalized_id} <- normalize_uuid(id),
         {:ok, %RemoteAccessRecording{} = recording} <-
           RemoteAccessRecording.get_by_id(normalized_id, scope: get_scope(conn)),
         {:ok, %RemoteAccessRecording{} = recording} <-
           Ash.load(recording, :session, scope: get_scope(conn)) do
      {:ok, recording}
    else
      {:ok, nil} -> {:error, :not_found}
      {:error, %Ash.Error.Query.NotFound{}} -> {:error, :not_found}
      :error -> {:error, :invalid_id}
      {:error, other} -> {:error, other}
    end
  end

  defp recording_json(%RemoteAccessRecording{} = recording) do
    %{
      id: recording.id,
      session_id: recording.session_id,
      status: format_value(recording.status),
      policy: recording.policy || %{},
      manifest: public_manifest(recording.manifest),
      started_at: format_value(recording.started_at),
      completed_at: format_value(recording.completed_at),
      retention_expires_at: format_value(recording.retention_expires_at),
      input_bytes: recording.input_bytes,
      output_bytes: recording.output_bytes,
      event_count: recording.event_count,
      failure_reason: recording.failure_reason
    }
  end

  defp event_json(%RemoteAccessRecordingEvent{} = event) do
    %{
      id: event.id,
      recording_id: event.recording_id,
      session_id: event.session_id,
      sequence: event.sequence,
      stream: format_value(event.stream),
      event_type: event.event_type,
      occurred_at: format_value(event.occurred_at),
      byte_count: event.byte_count,
      payload_sha256: event.payload_sha256,
      prior_event_hash: event.prior_event_hash,
      payload_text: event.payload_text,
      payload_redacted: event.payload_redacted,
      redaction_reason: event.redaction_reason,
      metadata: event.metadata || %{},
      retention_expires_at: format_value(event.retention_expires_at)
    }
  end

  defp normalize_uuid(id) do
    case Ecto.UUID.cast(id) do
      {:ok, normalized} -> {:ok, normalized}
      :error -> :error
    end
  end

  defp invalid_request(conn, message) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "invalid_request", message: message})
  end

  defp forbidden(conn, permission) do
    conn
    |> put_status(:forbidden)
    |> json(%{error: "forbidden", message: "#{permission} permission is required"})
  end

  defp not_found(conn) do
    conn
    |> put_status(:not_found)
    |> json(%{
      error: "remote_access_recording_not_found",
      message: "remote-access recording was not found"
    })
  end

  defp conflict(conn, reason) do
    conn
    |> put_status(:conflict)
    |> json(%{error: reason})
  end

  defp gone(conn) do
    conn
    |> put_status(:gone)
    |> json(%{
      error: "remote_access_recording_deleted",
      message: "remote-access recording has been deleted"
    })
  end

  defp format_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp format_value(value) when is_atom(value), do: Atom.to_string(value)
  defp format_value(value), do: value

  defp public_manifest(manifest) when is_map(manifest) do
    manifest
    |> Map.delete("storage_backend")
    |> Map.delete("storage_bucket")
    |> Map.delete("object_key")
    |> Map.delete(:storage_backend)
    |> Map.delete(:storage_bucket)
    |> Map.delete(:object_key)
  end

  defp public_manifest(_manifest), do: %{}

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

  defp require_any_permission(conn, permissions) when is_list(permissions) do
    scope = conn.assigns[:current_scope]
    if RBAC.can_any?(scope, permissions), do: :ok, else: {:error, :forbidden}
  end

  defp require_recording_view_permission(conn, %RemoteAccessRecording{} = recording) do
    scope = get_scope(conn)

    cond do
      not RBAC.can?(scope, permission_for_recording(recording)) ->
        {:error, :forbidden}

      recording_requested_by_scope_user?(recording, scope) ->
        :ok

      RBAC.can?(scope, @view_all_permission) ->
        :ok

      true ->
        {:error, :not_found}
    end
  end

  defp permission_for_recording(%RemoteAccessRecording{} = recording) do
    case recording_protocol(recording) do
      "rdp" -> @rdp_open_permission
      _protocol -> @ssh_open_permission
    end
  end

  defp recording_protocol(%RemoteAccessRecording{manifest: manifest}) when is_map(manifest) do
    manifest["protocol"] || manifest[:protocol]
  end

  defp recording_protocol(_recording), do: "ssh"

  defp recording_requested_by_scope_user?(
         %RemoteAccessRecording{session: %RemoteAccessSession{requested_by: requested_by}},
         %Scope{user: %{id: user_id}}
       )
       when not is_nil(requested_by) and not is_nil(user_id) do
    requested_by == user_id
  end

  defp recording_requested_by_scope_user?(_recording, _scope), do: false
end
