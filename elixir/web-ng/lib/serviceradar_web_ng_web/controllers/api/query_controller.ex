defmodule ServiceRadarWebNGWeb.Api.QueryController do
  use ServiceRadarWebNGWeb, :controller

  def execute(conn, params) do
    case ServiceRadarWebNG.Api.Access.execute_query(conn.assigns[:current_scope], params) do
      {:ok, response} ->
        json(conn, response)

      {:error, :forbidden} ->
        conn
        |> put_status(:forbidden)
        |> json(%{"error" => "forbidden", "message" => "You do not have permission to query this entity"})

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
end
