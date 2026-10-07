defmodule ServiceRadar.Analytics.StarRocks.Query do
  @moduledoc """
  MySQL-protocol client for authorized StarRocks SRQL execution.

  Compiles stay in the SRQL dialect; this module submits the produced SQL to a
  Frontend query port. Inject `:mysql` in tests. Missing FE connectivity is an
  error, never a silent PostgreSQL fallback. EventWriter persistence stays on
  Stream Load HTTP.
  """

  alias ServiceRadar.Analytics.StarRocks
  alias ServiceRadar.Analytics.StarRocks.CatalogAllowlist
  alias ServiceRadar.Analytics.StarRocks.MySQL

  @spec execute(String.t(), keyword()) ::
          {:ok, Postgrex.Result.t()} | {:error, term()}
  def execute(sql, opts \\ []) when is_binary(sql) do
    if CatalogAllowlist.native_query?(sql) do
      with :ok <- CatalogAllowlist.assert_sql_executable(sql),
           :ok <- require_native_query_version(opts) do
        submit(sql, opts)
      end
    else
      submit(sql, opts)
    end
  end

  defp require_native_query_version(opts) do
    case submit("SELECT current_version()", opts) do
      {:ok, %{rows: [[version]]}} when is_binary(version) ->
        case Regex.run(~r/^(\d+)\.(\d+)\.(\d+)(?:-|$)/, version, capture: :all_but_first) do
          [major, minor, patch] ->
            if List.to_tuple(Enum.map([major, minor, patch], &String.to_integer/1)) >= {4, 1, 0} do
              :ok
            else
              {:error, {:starrocks_native_query_requires_version, "4.1", version}}
            end

          _ ->
            {:error, {:starrocks_version_unknown, version}}
        end

      {:error, _reason} = error ->
        error

      _ ->
        {:error, :starrocks_version_unknown}
    end
  end

  defp submit(sql, opts) do
    case mysql_fun(opts) do
      fun when is_function(fun, 1) -> fun.(sql)
      _ -> MySQL.query(sql, opts)
    end
  end

  defp mysql_fun(opts) do
    case Keyword.get(opts, :mysql) do
      fun when is_function(fun, 1) ->
        fun

      _ ->
        :serviceradar_core
        |> Application.get_env(StarRocks, [])
        |> Keyword.get(:mysql)
    end
  end
end
