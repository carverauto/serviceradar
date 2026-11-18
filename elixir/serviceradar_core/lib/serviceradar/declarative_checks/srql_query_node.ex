defmodule ServiceRadar.DeclarativeChecks.SRQLQueryNode do
  @moduledoc """
  Bounded read-only `srql_query` Core signal node evaluator (`2.2`).

  Routes queries exclusively through the SRQL AST validator (`ServiceRadar.SRQLAst`)
  and `ServiceRadar.Observability.SRQLRunner` (SRQL AshAdapter / NIF translator),
  enforcing strict caps (`limit <= 1_000`, `timeout_ms <= 10_000`) and rejecting
  malformed or non-read queries before any SQL is executed.
  """

  alias ServiceRadar.Observability.SRQLRunner
  alias ServiceRadar.SRQLAst

  @max_limit 1_000
  @default_limit 100
  @max_timeout_ms 10_000
  @default_timeout_ms 5_000

  @raw_sql_regex ~r/(?i)\A\s*(select|insert|update|delete|drop|alter|create|truncate|grant|revoke|copy|with)\b/

  @doc """
  Executes a validated `srql_query` node configuration and returns a structured
  signal payload (`rows`, `row_count`, `first_row`, `value`).
  """
  @spec evaluate(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def evaluate(config, opts \\ []) when is_map(config) and is_list(opts) do
    raw_query = Map.get(config, "query") || Map.get(config, :query)
    raw_limit = Map.get(config, "limit", Map.get(config, :limit, @default_limit))
    raw_timeout = Map.get(config, "timeout_ms", Map.get(config, :timeout_ms, @default_timeout_ms))
    result_mode = Map.get(config, "result_mode", Map.get(config, :result_mode, "rows"))

    with {:ok, query} <- validate_read_only_query(raw_query, opts),
         {:ok, limit} <- validate_limit(raw_limit),
         {:ok, timeout_ms} <- validate_timeout(raw_timeout),
         {:ok, page} <- execute_srql(query, limit, timeout_ms, opts) do
      rows = Enum.take(Map.get(page, :rows, []), limit)
      count = length(rows)
      first_row = List.first(rows)

      primary_value =
        case result_mode do
          "count" -> count
          "first_row" -> first_row
          _ -> count
        end

      {:ok,
       %{
         status: :healthy,
         value: primary_value,
         observed_at: Keyword.get(opts, :now, DateTime.utc_now()),
         payload: %{
           "query" => query,
           "row_count" => count,
           "count" => count,
           "rows" => rows,
           "first_row" => first_row,
           "value" => primary_value
         }
       }}
    end
  end

  @doc """
  Validates that `query` is a read-only SRQL query and never raw SQL.
  """
  @spec validate_read_only_query(term(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def validate_read_only_query(query, opts \\ [])

  def validate_read_only_query(query, opts) when is_binary(query) and is_list(opts) do
    trimmed = String.trim(query)

    cond do
      trimmed == "" ->
        {:error, :empty_srql_query}

      String.contains?(trimmed, [";", <<0>>]) ->
        {:error, :forbidden_raw_sql}

      Regex.match?(@raw_sql_regex, trimmed) ->
        {:error, :forbidden_raw_sql}

      not String.starts_with?(trimmed, "in:") ->
        {:error, :srql_query_must_specify_entity}

      Keyword.get(opts, :skip_srql_nif?, false) or Keyword.has_key?(opts, :srql_runner) ->
        {:ok, trimmed}

      true ->
        validate_ast(trimmed, opts)
    end
  end

  def validate_read_only_query(_other, _opts), do: {:error, :invalid_srql_query}

  defp validate_ast(query, opts) do
    ast_opts =
      case Keyword.fetch(opts, :srql_parse_fn) do
        {:ok, fun} -> [parse_fn: fun]
        :error -> []
      end

    case SRQLAst.validate(query, ast_opts) do
      :ok -> {:ok, query}
      {:error, reason} -> {:error, {:invalid_srql_query, reason}}
    end
  end

  defp validate_limit(limit) when is_integer(limit) and limit >= 1 and limit <= @max_limit,
    do: {:ok, limit}

  defp validate_limit(limit) when is_integer(limit) and limit > @max_limit,
    do: {:error, {:srql_limit_exceeded, limit, @max_limit}}

  defp validate_limit(_), do: {:error, :invalid_srql_limit}

  defp validate_timeout(ms) when is_integer(ms) and ms >= 100 and ms <= @max_timeout_ms,
    do: {:ok, ms}

  defp validate_timeout(ms) when is_integer(ms) and ms > @max_timeout_ms,
    do: {:error, {:srql_timeout_exceeded, ms, @max_timeout_ms}}

  defp validate_timeout(_), do: {:error, :invalid_srql_timeout}

  defp execute_srql(query, limit, timeout_ms, opts) do
    query_opts = [limit: limit, timeout: timeout_ms]

    case Keyword.get(opts, :srql_runner) do
      fun when is_function(fun, 2) ->
        fun.(query, query_opts)

      mod when is_atom(mod) and not is_nil(mod) ->
        mod.query_page(query, query_opts)

      nil ->
        SRQLRunner.query_page(query, query_opts)
    end
  end
end
