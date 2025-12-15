defmodule ServiceRadarWebNG.Api.QueryController do
  use ServiceRadarWebNGWeb, :controller

  def execute(conn, params) do
    case ServiceRadarWebNG.SRQL.query_request(params) do
      {:ok, response} ->
        json(conn, response)

      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{"error" => to_string(reason)})
    end
  end
end
