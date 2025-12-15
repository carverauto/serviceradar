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
  def cypher(cypher_query) when is_binary(cypher_query) do
    Repo.transaction(fn ->
      {:ok, _} = query(Repo, "LOAD 'age'", [], [])
      {:ok, _} = query(Repo, "SET search_path = #{@age_search_path}", [], [])

      sql_query = """
      SELECT ag_catalog.agtype_to_text(result) as result
      FROM ag_catalog.cypher('#{@graph_name}', #{dollar_quote(cypher_query)}) as (result ag_catalog.agtype)
      """

      result = query(Repo, sql_query, [], [])

      case result do
        {:ok, data} -> data
        {:error, error} -> Repo.rollback(error)
      end
    end)
  end

  @doc """
  Executes an openCypher query and parses each returned row into an Elixir value.
  """
  def query(cypher_query) when is_binary(cypher_query) do
    case cypher(cypher_query) do
      {:ok, result} ->
        parsed_rows = parse_agtype_results(result.rows)
        {:ok, parsed_rows}

      {:error, error} ->
        {:error, error}
    end
  end

  defp dollar_quote(query) do
    tag = dollar_quote_tag(query)
    "$#{tag}$#{query}$#{tag}$"
  end

  defp dollar_quote_tag(query) do
    tag = "sr_#{Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)}"

    if String.contains?(query, "$#{tag}$") do
      dollar_quote_tag(query)
    else
      tag
    end
  end

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
