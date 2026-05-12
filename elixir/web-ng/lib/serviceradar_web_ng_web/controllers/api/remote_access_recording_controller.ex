defmodule ServiceRadarWebNGWeb.Api.RemoteAccessRecordingController do
  @moduledoc """
  Authenticated API for remote-access recording replay and export.
  """

  use ServiceRadarWebNGWeb, :controller

  alias ServiceRadar.Edge.RemoteAccessRecording
  alias ServiceRadar.Edge.RemoteAccessRecordingEvent
  alias ServiceRadar.Edge.RemoteAccessRecordings
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.RBAC

  action_fallback(ServiceRadarWebNGWeb.Api.FallbackController)

  @open_permission "devices.remote_access.ssh.open"
  @export_permission "devices.remote_access.recordings.export"

  def show(conn, %{"id" => id}) do
    with :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, @open_permission),
         {:ok, recording} <- fetch_recording(id, conn) do
      json(conn, %{data: recording_json(recording)})
    else
      {:error, :forbidden} -> forbidden(conn, @open_permission)
      {:error, :not_found} -> not_found(conn)
      {:error, :invalid_id} -> invalid_request(conn, "id must be a valid UUID")
      {:error, other} -> {:error, other}
    end
  end

  def events(conn, %{"id" => id}) do
    with :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, @open_permission),
         {:ok, recording} <- fetch_recording(id, conn),
         {:ok, events} <- RemoteAccessRecordings.list_events(recording, scope: get_scope(conn)) do
      json(conn, %{data: Enum.map(events, &event_json/1)})
    else
      {:error, :forbidden} -> forbidden(conn, @open_permission)
      {:error, :not_found} -> not_found(conn)
      {:error, :invalid_id} -> invalid_request(conn, "id must be a valid UUID")
      {:error, other} -> {:error, other}
    end
  end

  def export(conn, %{"id" => id}) do
    with :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, @export_permission),
         {:ok, recording} <- fetch_recording(id, conn),
         {:ok, export} <-
           RemoteAccessRecordings.export(recording,
             scope: get_scope(conn),
             actor: get_scope(conn).user
           ) do
      json(conn, %{
        data: %{
          recording: recording_json(export.recording),
          manifest: export.manifest,
          events: Enum.map(export.events, &event_json/1)
        }
      })
    else
      {:error, :forbidden} -> forbidden(conn, @export_permission)
      {:error, :not_found} -> not_found(conn)
      {:error, :invalid_id} -> invalid_request(conn, "id must be a valid UUID")
      {:error, other} -> {:error, other}
    end
  end

  defp fetch_recording(id, conn) do
    with {:ok, normalized_id} <- normalize_uuid(id),
         {:ok, %RemoteAccessRecording{} = recording} <-
           RemoteAccessRecording.get_by_id(normalized_id, scope: get_scope(conn)) do
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
      storage_backend: recording.storage_backend,
      storage_bucket: recording.storage_bucket,
      object_key: recording.object_key,
      manifest: recording.manifest || %{},
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
end
