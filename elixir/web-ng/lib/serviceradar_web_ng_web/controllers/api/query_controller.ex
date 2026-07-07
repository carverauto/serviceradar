defmodule ServiceRadarWebNGWeb.Api.QueryController do
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
        |> json(%{"error" => format_error(reason)})
    end
  end

  # SRQL error reasons are usually strings ("missing required field: query")
  # or atoms (:non_read_only_sql), but the DB-execution path can surface a
  # `%Postgrex.Error{}` or a tagged tuple. `to_string/1` raises for those,
  # turning a clean 4xx into a 500. Coerce anything non-stringable via inspect.
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason) when is_atom(reason), do: to_string(reason)

  defp format_error(reason) do
    if String.Chars.impl_for(reason), do: to_string(reason), else: inspect(reason)
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
