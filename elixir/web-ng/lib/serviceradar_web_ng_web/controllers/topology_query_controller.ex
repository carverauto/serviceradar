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

        reason when reason in [:query_budget, :expression_budget, "expression_budget"] ->
          {413, "query_budget"}

        reason when reason in [:unsupported_entity, :unsupported_facet, "unsupported_facet"] ->
          {422, "unsupported_query"}

        "facet_unavailable" ->
          {422, "facet_unavailable"}

        reason when reason in [:invalid_query, :invalid_expression, :invalid_predicate, :invalid_page_limit] ->
          {400, "invalid_query"}

        reason when reason in [:query_timeout, "deadline_exceeded"] ->
          {503, "query_timeout"}

        reason when reason in [:query_busy, "pin_budget", "reader_budget"] ->
          {503, "query_busy"}

        _ ->
          {503, "query_unavailable"}
      end

    conn = if status == 503, do: put_resp_header(conn, "retry-after", "1"), else: conn
    conn |> put_status(status) |> json(%{error: code})
  end
end
