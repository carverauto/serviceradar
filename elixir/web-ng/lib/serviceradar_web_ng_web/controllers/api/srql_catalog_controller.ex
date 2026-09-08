defmodule ServiceRadarWebNGWeb.Api.SrqlCatalogController do
  @moduledoc """
  Serves the browser-facing SRQL catalog used by compact editors.

  The `ETag` response header is the HTTP validator and is quoted per the HTTP
  header grammar. The JSON body's `version` field is the same digest without
  quotes so clients can display or compare it as data; wrap it in quotes before
  sending it as an `If-None-Match` value.
  """

  use ServiceRadarWebNGWeb, :controller

  alias ServiceRadarWebNGWeb.SRQL.Catalog

  @cache_control "private, max-age=300, must-revalidate"

  def show(conn, _params) do
    catalog = ServiceRadarWebNG.Api.Access.srql_catalog(conn.assigns[:current_scope])
    etag = Catalog.etag(catalog)

    conn =
      conn
      |> put_resp_header("etag", etag)
      |> put_resp_header("cache-control", @cache_control)

    if fresh?(conn, etag) do
      send_resp(conn, :not_modified, "")
    else
      json(conn, catalog)
    end
  end

  defp fresh?(conn, etag) do
    conn
    |> get_req_header("if-none-match")
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(&String.trim/1)
    |> Enum.any?(&(&1 in [etag, "W/" <> etag]))
  end
end
