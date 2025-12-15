defmodule ServiceRadarWebNG.Graph do
  @moduledoc """
  Graph query interface for executing openCypher queries against Apache AGE.

  ServiceRadar uses the `serviceradar` AGE graph (see `docs/docs/age-graph-schema.md`).
  """

  alias ServiceRadarWebNG.Repo
  import Ecto.Adapters.SQL, only: [query: 4]

  @graph_name "serviceradar"
  @age_search_path ~S(ag_catalog,pg_catalog,"$user",public)

  @doc """
  Executes an openCypher query and returns the raw `Postgrex.Result`.

  Returns `{:ok, result}` or `{:error, reason}`.
  """
  def cypher(cypher_query, params \\ %{}) do
    Repo.transaction(fn ->
      {:ok, _} = query(Repo, "LOAD 'age'", [], [])
      {:ok, _} = query(Repo, "SET search_path = #{@age_search_path}", [], [])

      result =
        case normalize_params(params) do
          :none ->
            sql_query = """
            SELECT ag_catalog.agtype_to_text(result) as result
            FROM ag_catalog.cypher($1, $2) as (result ag_catalog.agtype)
            """

            query(Repo, sql_query, [@graph_name, cypher_query], [])

          params_json ->
            sql_query = """
            SELECT ag_catalog.agtype_to_text(result) as result
            FROM ag_catalog.cypher($1, $2, $3) as (result ag_catalog.agtype)
            """

            query(Repo, sql_query, [@graph_name, cypher_query, params_json], [])
        end

      case result do
        {:ok, data} -> data
        {:error, error} -> Repo.rollback(error)
      end
    end)
  end

  @doc """
  Executes an openCypher query and parses each returned row into an Elixir value.
  """
  def query(cypher_query, params \\ %{}) do
    case cypher(cypher_query, params) do
      {:ok, result} ->
        parsed_rows = parse_agtype_results(result.rows)
        {:ok, parsed_rows}

      {:error, error} ->
        {:error, error}
    end
  end

  defp normalize_params(%{} = params) when map_size(params) == 0, do: :none
  defp normalize_params(%{} = params), do: Jason.encode!(params)

  defp normalize_params(params) when is_list(params) do
    if params == [] do
      :none
    else
      params_json =
        params
        |> Enum.with_index()
        |> Map.new(fn {value, index} -> {"$#{index}", value} end)

      Jason.encode!(params_json)
    end
  end

  defp normalize_params(_), do: :none

  defp parse_agtype_results(rows) do
    Enum.map(rows, fn
      [text_value] when is_binary(text_value) ->
        case Jason.decode(text_value) do
          {:ok, parsed} ->
            parsed

          {:error, _} ->
            parse_scalar(text_value)
        end

      row ->
        row
    end)
  end

  defp parse_scalar(text_value) do
    cond do
      text_value == "true" -> true
      text_value == "false" -> false
      text_value == "null" -> nil
      true -> parse_number(text_value)
    end
  end

  defp parse_number(text_value) do
    case Integer.parse(text_value) do
      {int, ""} ->
        int

      _ ->
        case Float.parse(text_value) do
          {float, ""} -> float
          _ -> text_value
        end
    end
  end
end
