defmodule ServiceRadarWebNGWeb.Api.CameraRelayStreamController do
  @moduledoc """
  Browser-authenticated websocket upgrade for camera relay session streams.
  """

  use ServiceRadarWebNGWeb, :controller

  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.Api.CameraRelaySessionController
  alias ServiceRadarWebNGWeb.Channels.CameraRelayStreamHandler

  def connect(conn, %{"id" => relay_session_id}) do
    scope = conn.assigns[:current_scope]

    with :ok <- require_permission(scope, "devices.view"),
         {:ok, normalized_id} <-
           CameraRelaySessionController.normalize_uuid_param(
             relay_session_id,
             "id"
           ),
         {:ok, session} <-
           CameraRelaySessionController.fetch_relay_session_for_scope(
             normalized_id,
             scope
           ),
         :ok <- ensure_streamable(session) do
      conn
      |> WebSockAdapter.upgrade(
        CameraRelayStreamHandler,
        [relay_session_id: normalized_id, scope: scope],
        timeout: 60_000
      )
      |> halt()
    else
      {:error, :forbidden} ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "forbidden", message: "viewer is not authorized for camera relay access"})

      {:error, :invalid_request, message} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid_request", message: message})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "relay_session_not_found", message: "relay session was not found"})

      {:error, :relay_session_inactive} ->
        conn
        |> put_status(:conflict)
        |> json(%{
          error: "relay_session_inactive",
          message: "relay session is not in a streamable state"
        })

      {:error, other} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{
          error: "relay_stream_unavailable",
          message: "failed to open relay stream: #{inspect(other)}"
        })
    end
  end

  defp require_permission(scope, permission) when is_binary(permission) do
    if RBAC.can?(scope, permission), do: :ok, else: {:error, :forbidden}
  end

  defp ensure_streamable(%{status: status}) do
    if status in [:requested, :opening, :active, :closing, "requested", "opening", "active", "closing"] do
      :ok
    else
      {:error, :relay_session_inactive}
    end
  end
end
