defmodule ServiceRadarWebNGWeb.Api.SpatialController do
  use ServiceRadarWebNGWeb, :controller

  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.FieldSurveyReview
  alias ServiceRadarWebNG.FieldSurveyRoomArtifacts
  alias ServiceRadarWebNG.RBAC

  def index(conn, _params) do
    with :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, "analytics.view"),
         {:ok, samples} <- FieldSurveyReview.spatial_samples(conn.assigns.current_scope) do
      json(conn, %{data: samples})
    else
      {:error, error} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "spatial_samples_unavailable", detail: inspect(error)})

      conn ->
        conn
    end
  end

  def scene(conn, _params) do
    with :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, "analytics.view"),
         {:ok, scene} <- FieldSurveyReview.spatial_scene(conn.assigns.current_scope) do
      json(conn, %{data: scene})
    else
      {:error, error} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "spatial_scene_unavailable", detail: inspect(error)})

      conn ->
        conn
    end
  end

  def room_artifacts(conn, _params) do
    with :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, "analytics.view"),
         {:ok, artifacts} <- FieldSurveyReview.room_artifacts(conn.assigns.current_scope) do
      json(conn, %{data: artifacts})
    else
      {:error, error} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "room_artifacts_unavailable", detail: inspect(error)})

      conn ->
        conn
    end
  end

  def download_room_artifact(conn, %{"id" => artifact_id}) do
    with :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, "analytics.view"),
         {:ok, artifact} <- FieldSurveyReview.room_artifact(conn.assigns.current_scope, artifact_id),
         {:ok, payload} <- FieldSurveyRoomArtifacts.fetch(artifact.object_key) do
      conn
      |> put_resp_content_type(artifact.content_type)
      |> put_resp_header("content-disposition", "attachment; filename=\"#{artifact_filename(artifact)}\"")
      |> send_resp(200, payload)
    else
      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "room_artifact_not_found"})

      {:error, error} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "room_artifact_download_unavailable", detail: inspect(error)})

      conn ->
        conn
    end
  end

  defp artifact_filename(%{session_id: session_id, artifact_type: artifact_type, content_type: content_type}) do
    extension =
      case content_type do
        "model/vnd.usdz+zip" -> "usdz"
        "application/geo+json" -> "geojson"
        "application/json" -> "json"
        "application/octet-stream" -> "bin"
        _ -> "bin"
      end

    "#{safe_filename(session_id)}-#{safe_filename(artifact_type)}.#{extension}"
  end

  defp safe_filename(value) when is_binary(value) do
    value
    |> String.replace(~r/[^A-Za-z0-9._-]/, "-")
    |> String.slice(0, 120)
  end

  defp safe_filename(_), do: "artifact"

  defp require_authenticated(conn) do
    case conn.assigns[:current_scope] do
      %Scope{user: user} when not is_nil(user) ->
        :ok

      _ ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "unauthorized"})
        |> halt()
    end
  end

  defp require_permission(conn, permission) do
    scope = conn.assigns[:current_scope]

    if RBAC.can?(scope, permission) do
      :ok
    else
      conn
      |> put_status(:forbidden)
      |> json(%{error: "forbidden"})
      |> halt()
    end
  end
end
