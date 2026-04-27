defmodule ServiceRadarWebNGWeb.Api.SpatialController do
  use ServiceRadarWebNGWeb, :controller

  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.FieldSurveyReview
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
