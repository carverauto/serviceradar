defmodule ServiceRadarWebNGWeb.TopologyQueryController do
  use Phoenix.Controller, formats: [:json]

  import Plug.Conn

  alias ServiceRadarWebNG.Topology.BitmapQueries

  def create(conn, params) do
    conn = put_resp_header(conn, "cache-control", "no-store")

    case BitmapQueries.run(conn.assigns[:current_scope], params) do
      {:ok, result} -> json(conn, result)
      {:error, reason} -> error(conn, reason)
    end
  end

  def values(conn, params) do
    conn = put_resp_header(conn, "cache-control", "no-store")

    case BitmapQueries.values(conn.assigns[:current_scope], params) do
      {:ok, result} -> json(conn, result)
      {:error, reason} -> error(conn, reason)
    end
  end

  def prefix_tags(conn, params) do
    conn = put_resp_header(conn, "cache-control", "no-store")

    case BitmapQueries.prefix_tags(conn.assigns[:current_scope], params) do
      {:ok, result} -> json(conn, result)
      {:error, reason} -> error(conn, reason)
    end
  end

  defp error(conn, reason) do
    {status, code} =
      case BitmapQueries.http_status(reason) do
        {status, code} -> {status, code}
        nil -> {503, "query_unavailable"}
      end

    conn = if status == 503, do: put_resp_header(conn, "retry-after", "1"), else: conn
    conn |> put_status(status) |> json(%{error: code})
  end
end
