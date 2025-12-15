defmodule ServiceRadarWebNG.Api.QueryController do
  use ServiceRadarWebNGWeb, :controller

  def execute(conn, params) do
    case srql_module().query_request(params) do
      {:ok, response} ->
        json(conn, response)

      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{"error" => to_string(reason)})
    end
  end

  defp srql_module do
    Application.get_env(:serviceradar_web_ng, :srql_module, ServiceRadarWebNG.SRQL)
  end
end
