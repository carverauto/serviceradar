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

  def prefix_tags(conn, params) do
    conn = put_resp_header(conn, "cache-control", "no-store")

    case BitmapQueries.prefix_tags(conn.assigns[:current_scope], params) do
      {:ok, result} -> json(conn, result)
      {:error, reason} -> error(conn, reason)
    end
  end

  defp error(conn, reason) do
    {status, code} =
      case reason do
        :unauthorized ->
          {401, "unauthorized"}

        :forbidden ->
          {403, "forbidden"}

        :bitmap_disabled ->
          {404, "bitmap_disabled"}

        :invalid_cursor ->
          {400, "invalid_cursor"}

        reason
        when reason in [:query_budget, :expression_budget, "expression_budget", :prefix_range_budget, "range_budget"] ->
          {413, "query_budget"}

        reason when reason in [:unsupported_entity, :unsupported_facet, "unsupported_facet"] ->
          {422, "unsupported_query"}

        reason when reason in ["facet_unavailable", "ip_unavailable"] ->
          {422, reason}

        reason
        when reason in [
               :prefix_source_unavailable,
               :prefix_registry_unavailable,
               "catalog_not_ready",
               "catalog_budget",
               "label_budget"
             ] ->
          {503, "prefix_source_unavailable"}

        reason
        when reason in [:invalid_query, :invalid_expression, :invalid_predicate, :invalid_page_limit, :invalid_cidr] ->
          {400, "invalid_query"}

        :query_timeout ->
          {503, "query_timeout"}

        :query_busy ->
          {503, "query_busy"}

        :index_not_ready ->
          {503, "index_not_ready"}

        :source_changed ->
          {503, "source_changed"}

        _ ->
          {503, "query_unavailable"}
      end

    conn = if status == 503, do: put_resp_header(conn, "retry-after", "1"), else: conn
    conn |> put_status(status) |> json(%{error: code})
  end
end
