defmodule ServiceRadarWebNGWeb.Api.RemoteAccessStreamController do
  @moduledoc """
  Browser-authenticated websocket upgrade for generic remote-access streams.
  """

  use ServiceRadarWebNGWeb, :controller

  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.Channels.RemoteAccessStreamHandler

  @remote_access_permission "devices.remote_access.ssh.open"
  @default_browser_stream_timeout_ms to_timeout(hour: 1)

  def connect(conn, %{"id" => session_id}) do
    scope = conn.assigns[:current_scope]

    with :ok <- require_permission(scope),
         {:ok, normalized_id} <- normalize_uuid(session_id, "id") do
      conn
      |> WebSockAdapter.upgrade(
        RemoteAccessStreamHandler,
        [session_id: normalized_id, scope: scope],
        timeout: browser_stream_timeout_ms()
      )
      |> halt()
    else
      {:error, :forbidden} ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "forbidden", message: "Remote access permission is required"})

      {:error, :invalid_request, message} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid_request", message: message})
    end
  end

  defp require_permission(scope) do
    if RBAC.can?(scope, @remote_access_permission), do: :ok, else: {:error, :forbidden}
  end

  defp normalize_uuid(value, field_name) when is_binary(value) do
    value
    |> String.trim()
    |> Ecto.UUID.cast()
    |> case do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_request, "#{field_name} must be a valid UUID"}
    end
  end

  defp normalize_uuid(_value, field_name), do: {:error, :invalid_request, "#{field_name} is required"}

  defp browser_stream_timeout_ms do
    case Application.get_env(
           :serviceradar_web_ng,
           :remote_access_browser_stream_timeout_ms,
           @default_browser_stream_timeout_ms
         ) do
      timeout_ms when is_integer(timeout_ms) and timeout_ms > 0 -> timeout_ms
      _other -> @default_browser_stream_timeout_ms
    end
  end
end
