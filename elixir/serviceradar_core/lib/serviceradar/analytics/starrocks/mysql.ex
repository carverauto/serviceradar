defmodule ServiceRadar.Analytics.StarRocks.MySQL do
  @moduledoc """
  Pooled MySQL-protocol client to a StarRocks Frontend query port.

  EventWriter persistence stays on Stream Load HTTP. Authorized SRQL and
  loader reads use this pool so they do not pay JSON HTTP per query. Queries
  are submitted as text protocol statements: SRQL already emits full SQL, and
  StarRocks prepared-statement support is narrower than MySQL's.

  Each connection is pinned to the node's resource group when it opens
  (`ServiceRadar.Analytics.StarRocks.Workload`), so web-ng's interactive reads
  and core's background work are isolated from each other.
  """

  alias ServiceRadar.Analytics.StarRocks.Env
  alias ServiceRadar.Analytics.StarRocks.Workload

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

  @doc """
  Reconnects every pooled session, so each is pinned again by `after_connect`.
  Sessions opened before the resource groups existed stay in `default_wg`
  until this runs.
  """
  @spec repin_sessions() :: :ok
  def repin_sessions do
    if Process.whereis(@pool), do: DBConnection.disconnect_all(@pool, 0)
    :ok
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
      connect_timeout: 3_000,
      # Every session runs in this node's resource group (Workload).
      after_connect: {Workload, :pin_session, [Workload.resource_group(Workload.current())]}
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
