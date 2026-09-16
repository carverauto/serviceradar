defmodule ServiceRadar.Analytics.StarRocks.Query do
  @moduledoc """
  MySQL-protocol client for authorized StarRocks SRQL execution.

  Compiles stay in the SRQL dialect; this module submits the produced SQL to a
  Frontend query port. Inject `:mysql` in tests. Missing FE connectivity is an
  error, never a silent PostgreSQL fallback. EventWriter persistence stays on
  Stream Load HTTP.
  """

  alias ServiceRadar.Analytics.StarRocks
  alias ServiceRadar.Analytics.StarRocks.MySQL

  @spec execute(String.t(), keyword()) ::
          {:ok, Postgrex.Result.t()} | {:error, term()}
  def execute(sql, opts \\ []) when is_binary(sql) do
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
