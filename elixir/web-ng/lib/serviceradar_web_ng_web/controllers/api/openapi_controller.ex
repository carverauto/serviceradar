defmodule ServiceRadarWebNGWeb.Api.OpenapiController do
  @moduledoc """
  Serves OpenAPI documents for custom JSON controllers.
  """

  use ServiceRadarWebNGWeb, :controller

  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.OpenAPI.AdminSpec

  def admin(conn, _params) do
    scope = conn.assigns[:current_scope]

    if RBAC.can?(scope, "settings.networks.manage") do
      json(conn, AdminSpec.document())
    else
      conn
      |> put_status(:forbidden)
      |> json(%{error: "forbidden", message: "Not authorized"})
    end
  end

  def published_admin_v1(conn, _params) do
    json(conn, AdminSpec.published_document("v1"))
  end
end
