defmodule ServiceRadar.Analytics.StarRocks.MySQL do
  @moduledoc """
  Pooled MySQL-protocol client to a StarRocks Frontend query port.

  EventWriter persistence stays on Stream Load HTTP. Authorized SRQL and
  loader reads use this pool so they do not pay JSON HTTP per query. Queries
  are submitted as text protocol statements: SRQL already emits full SQL, and
  StarRocks prepared-statement support is narrower than MySQL's.
  """

  alias ServiceRadar.Analytics.StarRocks.Env

  @pool __MODULE__
  @query_timeout_ms 15_000

  @spec child_spec(term()) :: Supervisor.child_spec() | nil
  def child_spec(_opts) do
    config = Env.config()

    if config[:enabled] do
      Supervisor.child_spec({MyXQL, connection_opts(config)}, id: @pool)
    end
  end

  @spec query(String.t(), keyword()) :: {:ok, Postgrex.Result.t()} | {:error, term()}
  def query(sql, opts \\ []) when is_binary(sql) do
    timeout = Keyword.get(opts, :timeout, @query_timeout_ms)
    conn = Keyword.get(opts, :conn, @pool)

    case Process.whereis(conn) do
      nil ->
        {:error, :starrocks_mysql_not_started}

      _pid ->
        case MyXQL.query(conn, sql, [], query_type: :text, timeout: timeout) do
          {:ok, result} ->
            {:ok, to_postgrex(result)}

          {:error, %DBConnection.ConnectionError{}} ->
            {:error, :connect_failed}

          {:error, %MyXQL.Error{} = error} ->
            {:error, {:starrocks_mysql, Exception.message(error)}}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @spec connection_opts(keyword()) :: keyword()
  def connection_opts(config) when is_list(config) do
    [
      name: @pool,
      hostname: Keyword.get(config, :fe_mysql_host, "127.0.0.1"),
      port: Keyword.get(config, :fe_mysql_port, 9030),
      username: Keyword.get(config, :user, "root"),
      password: Keyword.get(config, :password, ""),
      database: Keyword.get(config, :database, "serviceradar"),
      ssl: false,
      prepare: :unnamed,
      cache_size: 0,
      pool_size: Keyword.get(config, :mysql_pool_size, 8),
      timeout: @query_timeout_ms,
      connect_timeout: 3_000
    ]
  end

  defp to_postgrex(%MyXQL.Result{} = result) do
    rows = result.rows || []

    %Postgrex.Result{
      command: :select,
      columns: Enum.map(result.columns || [], &to_string/1),
      rows: rows,
      num_rows: result.num_rows || length(rows),
      connection_id: nil
    }
  end
end
