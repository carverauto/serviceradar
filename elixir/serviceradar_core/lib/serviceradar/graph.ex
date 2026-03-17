defmodule ServiceRadar.Graph do
  @moduledoc """
  Shared utilities for executing Apache AGE Cypher queries.

  Apache AGE queries return `agtype` values which Postgrex cannot decode by default.
  This module provides helpers that convert agtype to text, avoiding type handling errors.

  ## Usage

      # Execute a Cypher query for side effects (MERGE, CREATE, SET)
      ServiceRadar.Graph.execute("MERGE (n:Device {id: 'abc'})")

      # Execute a Cypher query and get parsed results
      {:ok, rows} = ServiceRadar.Graph.query("MATCH (n:Device) RETURN n")

  ## Graph Name

  All queries target the configured AGE graph by default (see
  `:age_graph_name` in the `:serviceradar_core` config). Use the `:graph` option
  to specify a different graph name.
  """

  alias ServiceRadar.Repo

  @default_graph "platform_graph"

  @doc """
  Executes a Cypher query for side effects, discarding results.

  Use this for MERGE, CREATE, SET, and DELETE operations where you don't need
  the return value.

  ## Options

    * `:graph` - The AGE graph name (default: config `:age_graph_name`, fallback "#{@default_graph}")
    * `:repo` - The Ecto repo to use (default: ServiceRadar.Repo)

  ## Examples

      :ok = ServiceRadar.Graph.execute("MERGE (n:Device {id: 'abc'})")

      case ServiceRadar.Graph.execute("MERGE (n:Device {id: 'abc'})") do
        :ok -> Logger.info("Device created")
        {:error, reason} -> Logger.warning("Failed: \#{inspect(reason)}")
      end
  """
  @spec execute(String.t(), keyword()) :: :ok | {:error, term()}
  def execute(cypher, opts \\ []) when is_binary(cypher) do
    graph = Keyword.get(opts, :graph, default_graph())
    repo = Keyword.get(opts, :repo, Repo)

    case query_age(repo, graph, cypher, :execute) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Executes a Cypher query and returns parsed results.

  The results are converted from AGE's agtype to Elixir values via JSON parsing.

  ## Options

    * `:graph` - The AGE graph name (default: config `:age_graph_name`, fallback "#{@default_graph}")
    * `:repo` - The Ecto repo to use (default: ServiceRadar.Repo)

  ## Examples

      {:ok, devices} = ServiceRadar.Graph.query("MATCH (n:Device) RETURN n")

      {:ok, [%{"id" => "abc", "name" => "router1"}]} =
        ServiceRadar.Graph.query("MATCH (n:Device {id: 'abc'}) RETURN n.id, n.name")
  """
  @spec query(String.t(), keyword()) :: {:ok, list()} | {:error, term()}
  def query(cypher, opts \\ []) when is_binary(cypher) do
    graph = Keyword.get(opts, :graph, default_graph())
    repo = Keyword.get(opts, :repo, Repo)

    case query_age(repo, graph, cypher, :query) do
      {:ok, %{rows: rows}} ->
        parsed = parse_agtype_results(rows)
        {:ok, parsed}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Escapes a value for safe inclusion in Cypher queries.

  Single quotes are doubled to prevent injection.

  ## Examples

      iex> ServiceRadar.Graph.escape("it's")
      "it''s"

      iex> ServiceRadar.Graph.escape(nil)
      ""
  """
  @spec escape(term()) :: String.t()
  def escape(nil), do: ""

  def escape(value) do
    value
    |> to_string()
    |> String.replace("'", "''")
  end

  defp default_graph do
    Application.get_env(:serviceradar_core, :age_graph_name, @default_graph)
  end

  defp sql_literal(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "''") <> "'"
  end

  defp dollar_quote(value) when is_binary(value) do
    tag = "$sr_" <> Integer.to_string(:erlang.phash2(value), 16) <> "$"
    tag <> value <> tag
  end

  defp query_age(repo, graph, cypher, mode) do
    graph
    |> candidate_sqls(cypher, mode)
    |> Enum.reduce_while(nil, fn sql, _last_error ->
      case repo.query(sql, [], prepare: :unnamed) do
        {:ok, _} = result -> {:halt, result}
        {:error, reason} -> {:cont, {:error, reason}}
      end
    end)
    |> case do
      {:ok, _} = result -> result
      {:error, _} = error -> error
      nil -> {:error, :age_query_failed}
    end
  end

  defp cypher_sql(graph, cypher, :execute, quote_style) do
    """
    SELECT ag_catalog.agtype_to_text(v)
    FROM ag_catalog.cypher(#{sql_literal(graph)}, #{quoted_cypher(cypher, quote_style)}) AS (v agtype)
    """
  end

  defp cypher_sql(graph, cypher, :query, quote_style) do
    """
    SELECT ag_catalog.agtype_to_text(result)
    FROM ag_catalog.cypher(#{sql_literal(graph)}, #{quoted_cypher(cypher, quote_style)}) AS (result agtype)
    """
  end

  defp quoted_cypher(cypher, :dollar), do: dollar_quote(cypher)
  defp quoted_cypher(cypher, :single), do: sql_literal(cypher)

  defp candidate_sqls(graph, cypher, mode) do
    # Some AGE builds oscillate between accepting dollar-quoted and single-quoted
    # cstring forms across connections. Try a short alternating sequence and
    # return the first success.
    [:dollar, :single, :dollar, :single]
    |> Enum.map(&cypher_sql(graph, cypher, mode, &1))
    |> Enum.uniq()
  end

  # Parse agtype text results into Elixir values
  defp parse_agtype_results(rows) do
    Enum.map(rows, fn
      [text_value] when is_binary(text_value) ->
        case Jason.decode(text_value) do
          {:ok, parsed} -> parsed
          {:error, _} -> parse_scalar(text_value)
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
