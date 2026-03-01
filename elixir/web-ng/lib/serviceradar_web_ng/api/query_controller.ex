defmodule ServiceRadarWebNG.Api.QueryController do
  use ServiceRadarWebNGWeb, :controller

  def execute(conn, params) do
    # Get actor from current_scope for Ash policy enforcement
    actor = get_actor(conn)
    params_with_actor = Map.put(params, "actor", actor)

    case srql_module().query_request(params_with_actor) do
      {:ok, response} ->
        json(conn, response)

      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{"error" => to_string(reason)})
    end
  end

  # Extract actor (user) from connection for Ash policy enforcement
  defp get_actor(conn) do
    case conn.assigns do
      %{current_scope: %{user: user}} when not is_nil(user) -> user
      _ -> nil
    end
  end

  defp srql_module do
    Application.get_env(:serviceradar_web_ng, :srql_module, ServiceRadarWebNG.SRQL)
  end
end
