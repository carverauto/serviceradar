defmodule ServiceRadar.DB.StarRocksParitySchemaRunner do
  @moduledoc """
  Applies the shipped StarRocks migrations to a parity fixture database through
  `ServiceRadar.Analytics.StarRocks.SchemaMigrator`.

  Invoked by `//integration_tests/srql_parity:parity_test` so the Rust parity
  harness and core share a single StarRocks migration path, including optimize
  and column-change job polling.
  """

  alias ServiceRadar.Analytics.StarRocks.Env
  alias ServiceRadar.Analytics.StarRocks.MySQL
  alias ServiceRadar.Analytics.StarRocks.Retention
  alias ServiceRadar.Analytics.StarRocks.Schema
  alias ServiceRadar.Analytics.StarRocks.SchemaMigrator

  @conn __MODULE__.Conn
  @timeout_ms 60_000

  def run! do
    ExUnit.start(autorun: false)
    {:ok, _} = Application.ensure_all_started(:myxql)

    host = fetch_env!("SRQL_PARITY_STARROCKS_HOST")
    port = fetch_port!("SRQL_PARITY_STARROCKS_PORT")
    user = fetch_env!("SRQL_PARITY_STARROCKS_USER")
    password = System.get_env("SRQL_PARITY_STARROCKS_PASSWORD") || ""
    database = fetch_env!("SRQL_PARITY_STARROCKS_TARGET_DATABASE")

    if !(Schema.valid_database?(database) and String.starts_with?(database, "srql_parity_") and
           database != "srql_parity_") do
      raise "refusing to migrate non-parity StarRocks database: #{inspect(database)}"
    end

    {:ok, pid} =
      MyXQL.start_link(
        hostname: host,
        port: port,
        username: user,
        password: password,
        database: database,
        ssl: false,
        prepare: :unnamed,
        cache_size: 0,
        pool_size: 1,
        timeout: @timeout_ms,
        connect_timeout: 10_000,
        name: @conn
      )

    try do
      case SchemaMigrator.migrate(
             query: &MySQL.query(&1, conn: @conn, timeout: @timeout_ms),
             database: database,
             replication_num: 1,
             create_database: false,
             retention_days:
               Retention.days_by_table(retention_days: Env.default_retention_days()),
             try_lock: fn fun -> fun.(fn -> :ok end) end,
             workload_groups: fn _query -> :ok end
           ) do
        {:ok, versions} ->
          IO.puts(
            "srql-parity: SchemaMigrator applied versions #{inspect(versions)} on #{database}"
          )

        {:error, reason} ->
          raise "StarRocks SchemaMigrator failed on #{database}: #{inspect(reason)}"
      end
    after
      if Process.alive?(pid), do: GenServer.stop(pid)
    end
  end

  defp fetch_env!(name) do
    case System.get_env(name) do
      value when is_binary(value) ->
        trimmed = String.trim(value)
        if trimmed == "", do: raise("#{name} is empty"), else: trimmed

      nil ->
        raise "#{name} is not set"
    end
  end

  defp fetch_port!(name) do
    raw = fetch_env!(name)

    case Integer.parse(raw) do
      {port, ""} when port > 0 and port <= 65_535 -> port
      _ -> raise "#{name} must be a valid TCP port, got: #{inspect(raw)}"
    end
  end
end

ServiceRadar.DB.StarRocksParitySchemaRunner.run!()
