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

    case query_age(repo, cypher_sql(graph, cypher, :execute, :dollar)) do
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

    case query_age(repo, cypher_sql(graph, cypher, :query, :dollar)) do
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

  defp query_age(repo, sql) do
    case repo.query(sql, [], prepare: :unnamed) do
      {:error, reason} = error ->
        case fallback_sql(sql, reason) do
          nil -> error
          fallback -> repo.query(fallback, [], prepare: :unnamed)
        end

      result ->
        result
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

  # Some AGE builds reject dollar-quoted cstring calls, while others reject
  # large single-quoted multiline Cypher. Retry with the alternate quoting.
  defp fallback_sql(sql, %Postgrex.Error{postgres: %{message: message}})
       when is_binary(message) do
    cond do
      String.contains?(message, "unhandled cypher(cstring) function call") ->
        swap_cypher_quote(sql, :single)

      String.contains?(message, "a dollar-quoted string constant is expected") ->
        swap_cypher_quote(sql, :dollar)

      true ->
        nil
    end
  end

  defp fallback_sql(_, _), do: nil

  defp swap_cypher_quote(sql, target_style) when is_binary(sql) do
    case Regex.run(~r/ag_catalog\.cypher\(('(?:''|[^'])*'),\s*(.+?)\)\s+AS\s+\((?:v|result)\s+agtype\)/s, sql, capture: :all_but_first) do
      [graph_literal, quoted_cypher] ->
        cypher =
          case quoted_cypher do
            <<"$", _::binary>> -> undollar_quote(quoted_cypher)
            _ -> unsql_literal(quoted_cypher)
          end

        String.replace(
          sql,
          "ag_catalog.cypher(#{graph_literal}, #{quoted_cypher})",
          "ag_catalog.cypher(#{graph_literal}, #{quoted_cypher(cypher, target_style)})"
        )

      _ ->
        nil
    end
  end

  defp undollar_quote(quoted) when is_binary(quoted) do
    [tag, rest] = String.split(quoted, "$", parts: 3) |> Enum.take(-2)
    delimiter = "$" <> tag <> "$"
    String.trim_leading(rest, delimiter) |> String.trim_trailing(delimiter)
  end

  defp unsql_literal(quoted) when is_binary(quoted) do
    quoted
    |> String.trim_leading("'")
    |> String.trim_trailing("'")
    |> String.replace("''", "'")
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
