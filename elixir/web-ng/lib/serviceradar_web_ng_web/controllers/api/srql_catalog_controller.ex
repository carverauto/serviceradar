defmodule ServiceRadarWebNGWeb.Api.SrqlCatalogController do
  use ServiceRadarWebNGWeb, :controller

  alias ServiceRadarWebNGWeb.SRQL.Catalog

  @cache_control "private, max-age=300, must-revalidate"

  def show(conn, _params) do
    catalog = Catalog.structured()
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
